-- =====================================================================
--  02_features.sql   (BigQuery Standard SQL, MIMIC-IV v3.1)
--
--  One row per ICU landmark (stay_id, k) with ~125 leakage-safe features,
--  defined as the VIEW YOUR_PROJECT.hypo_tutorial.features. Requires 00b and
--  01: labs, chart items, inputevents and procedureevents are read from the
--  src_* extracts, the small hosp tables from physionet-data. A view, not a
--  table, because the sandbox's 10 GiB of storage is a lifetime allowance
--  (see 01); notebook 01 reads the view once and caches it as parquet, and
--  the two check queries below each recompute it (a few GB of query each).
--
--  Leakage rules enforced here (each one is a slide):
--    * labs        : visible only once stored  -> storetime < t_k (fallback charttime)
--                    AND charttime < t_k (a nominal time can trail the entry time)
--    * medications : eMAR administration time  -> charttime  < t_k
--                    inputevents segment start -> starttime  < t_k, and a
--                    running segment contributes only the part before t_k
--                    (insulin, feeds, dextrose, vasopressors, antibiotics,
--                    octreotide alike); eMAR infusion intervals (01 view 2b,
--                    built from Started / Confirmed / Stopped events) follow
--                    the same start < t_k rule
--    * glucose     : stored AND charted before t_k; a low cancelled by the repeat
--                    rule (01) is dropped only when the contradicting result was
--                    itself stored before t_k (what a clinician could know at t_k)
--    * history     : diagnoses from EARLIER admissions only (discharged
--                    before admittime); the current admission's ICD codes
--                    are discharge codes and never used
--    * ICU vitals, GCS, weight : charttime in [t_k - 24 h, t_k) AND storetime < t_k
--                    (the both-times rule, as for labs and glucose, since release .20)
--    * ventilation, dialysis : a procedureevents interval that started before t_k
--    * cultures    : specimen charttime < t_k; a date-only specimen counts
--                    only when its date is strictly before DATE(t_k)
--    * omr         : chartdate < DATE(t_k)  (date-only resolution)
--  max_feature_time is carried on every row so the notebook can assert
--  max_feature_time < t_k before fitting anything. A lab or glucose value
--  enters only when both its storetime and its charttime are before t_k.
--
--  Bookkeeping columns (never model inputs): subject_id, hadm_id, stay_id,
--  k, t_k, window_end, split, anchor_year_group, years_after_anchor, window_hours, race,
--  insurance, language, marital_status, the four labels,
--  label_window_n_glucose (results in the LABEL window: reporting only,
--  it is future information and must never be in X), and the drip record
--  flags drip_inputevents_24h / drip_emar_24h / drip_running_inputevents_at_tk
--  / drip_running_emar_at_tk / stay_has_inputevents_drip /
--  emar_interval_open_at_tk (which record saw the drip; the eMAR-only drips
--  sit mostly in 2020-2022, so the flags would teach a model the era: they
--  serve the evaluation's subgroup tables).
-- =====================================================================

CREATE OR REPLACE VIEW `YOUR_PROJECT.hypo_tutorial.features` AS
WITH lm AS (
  SELECT
    c.subject_id, c.hadm_id, c.stay_id, c.k, c.t_k, c.window_end, c.icu_day,
    c.split, c.anchor_year_group, c.years_after_anchor, c.window_hours,
    c.n_hypo_admin_24h, c.n_doses_24h, c.n_insulin_sc_24h, c.n_su_admin_24h, c.n_megl_admin_24h,
    c.n_sc_from_inputevents_24h, c.insulin_drip_24h, c.drip_running_at_tk,
    c.drip_inputevents_24h, c.drip_emar_24h, c.drip_running_inputevents_at_tk, c.drip_running_emar_at_tk,
    c.stay_has_inputevents_drip, c.emar_interval_open_at_tk,
    c.hrs_since_last_hypo_admin,
    c.y_lt54_24h, c.y_lt40_24h, c.y_cms816_24h, c.y_gt300_24h, c.n_glucose_in_window,
    b.admittime, b.intime, b.age_at_admit, b.gender, b.admission_type, b.admission_location,
    b.ed_arrival, b.hours_in_hospital_before_icu, b.first_careunit,
    b.race, b.insurance, b.language, b.marital_status,
    EXTRACT(HOUR FROM b.intime)      AS icu_admit_hour,
    EXTRACT(DAYOFWEEK FROM c.t_k)    AS weekday_tk
  FROM `YOUR_PROJECT.hypo_tutorial.cohort_landmarks` AS c
  JOIN `YOUR_PROJECT.hypo_tutorial.stay_base`        AS b USING (stay_id)
),

-- ---------------------------------------------------------------------
-- Lab panel: last value and hours since, per analyte, stored before t_k
-- ---------------------------------------------------------------------
lab_items AS (
  SELECT * FROM UNNEST([
    STRUCT(50912 AS itemid, 'creatinine'  AS name),
    STRUCT(51006 AS itemid, 'bun'         AS name),
    STRUCT(50862 AS itemid, 'albumin'     AS name),
    STRUCT(50983 AS itemid, 'sodium'      AS name),
    STRUCT(50971 AS itemid, 'potassium'   AS name),
    STRUCT(50882 AS itemid, 'bicarbonate' AS name),
    STRUCT(50813 AS itemid, 'lactate'     AS name),
    STRUCT(51301 AS itemid, 'wbc'         AS name),
    STRUCT(51222 AS itemid, 'hemoglobin'  AS name),
    STRUCT(51221 AS itemid, 'hematocrit'  AS name),
    STRUCT(51265 AS itemid, 'platelets'   AS name),
    STRUCT(50878 AS itemid, 'ast'         AS name),
    STRUCT(50861 AS itemid, 'alt'         AS name),
    STRUCT(50885 AS itemid, 'bilirubin'   AS name),
    STRUCT(51237 AS itemid, 'inr'         AS name),
    STRUCT(50902 AS itemid, 'chloride'    AS name),
    STRUCT(50868 AS itemid, 'anion_gap'   AS name),
    STRUCT(50893 AS itemid, 'calcium'     AS name),
    STRUCT(50960 AS itemid, 'magnesium'   AS name),
    STRUCT(50970 AS itemid, 'phosphate'   AS name)
  ])
),
cohort_adm AS (
  SELECT DISTINCT hadm_id FROM `YOUR_PROJECT.hypo_tutorial.stay_base`
),
lab_raw AS (
  -- 00 section H7: sane 0.1 / 99.9 percentiles, a handful of impossible
  -- extremes and a few hundred zero or negative values. Zero/negative is
  -- dropped here for every analyte except anion gap; the high tail is left
  -- to the notebook, which winsorises every lab feature at the training-set
  -- 0.1 and 99.9 percentiles and applies the same cut-points everywhere.
  SELECT le.hadm_id, li.name, le.charttime,
         COALESCE(le.storetime, le.charttime) AS avail_time,
         le.valuenum
  FROM `YOUR_PROJECT.hypo_tutorial.src_labevents` AS le
  JOIN lab_items                                   AS li USING (itemid)
  JOIN cohort_adm                                  AS b  ON b.hadm_id = le.hadm_id
  WHERE le.valuenum IS NOT NULL
    AND (le.valuenum > 0 OR li.name = 'anion_gap')
),
lab_lm AS (
  -- a result enters when BOTH its availability time (storetime) and its
  -- nominal time (charttime) are before the landmark. The first real run
  -- found 948 landmark rows (0.7%) whose latest input was a value stored
  -- before t_k under a charttime at or after it (MetaVision and the lab
  -- system both carry nominal times that can trail the entry time); the
  -- information was available, but a value timed after the landmark has no
  -- place in a feature row that claims to see nothing after it. Table 1b
  -- below measures the phenomenon.
  SELECT l.stay_id, l.k, r.name, r.valuenum, r.charttime,
         DATETIME_DIFF(l.t_k, r.charttime, MINUTE) / 60.0 AS hrs_before,
         ROW_NUMBER() OVER (PARTITION BY l.stay_id, l.k, r.name ORDER BY r.charttime DESC) AS rn
  FROM lm AS l
  JOIN lab_raw AS r ON r.hadm_id = l.hadm_id AND r.avail_time < l.t_k AND r.charttime < l.t_k
),
lab_feat AS (
  SELECT stay_id, k,
    MAX(IF(name = 'creatinine'  AND rn = 1, valuenum,   NULL)) AS creatinine_last,
    MAX(IF(name = 'creatinine'  AND rn = 1, hrs_before, NULL)) AS creatinine_hrs,
    MAX(IF(name = 'bun'         AND rn = 1, valuenum,   NULL)) AS bun_last,
    MAX(IF(name = 'bun'         AND rn = 1, hrs_before, NULL)) AS bun_hrs,
    MAX(IF(name = 'albumin'     AND rn = 1, valuenum,   NULL)) AS albumin_last,
    MAX(IF(name = 'albumin'     AND rn = 1, hrs_before, NULL)) AS albumin_hrs,
    MAX(IF(name = 'sodium'      AND rn = 1, valuenum,   NULL)) AS sodium_last,
    MAX(IF(name = 'sodium'      AND rn = 1, hrs_before, NULL)) AS sodium_hrs,
    MAX(IF(name = 'potassium'   AND rn = 1, valuenum,   NULL)) AS potassium_last,
    MAX(IF(name = 'potassium'   AND rn = 1, hrs_before, NULL)) AS potassium_hrs,
    MAX(IF(name = 'bicarbonate' AND rn = 1, valuenum,   NULL)) AS bicarbonate_last,
    MAX(IF(name = 'bicarbonate' AND rn = 1, hrs_before, NULL)) AS bicarbonate_hrs,
    MAX(IF(name = 'lactate'     AND rn = 1, valuenum,   NULL)) AS lactate_last,
    MAX(IF(name = 'lactate'     AND rn = 1, hrs_before, NULL)) AS lactate_hrs,
    MAX(IF(name = 'wbc'         AND rn = 1, valuenum,   NULL)) AS wbc_last,
    MAX(IF(name = 'wbc'         AND rn = 1, hrs_before, NULL)) AS wbc_hrs,
    MAX(IF(name = 'hemoglobin'  AND rn = 1, valuenum,   NULL)) AS hemoglobin_last,
    MAX(IF(name = 'hemoglobin'  AND rn = 1, hrs_before, NULL)) AS hemoglobin_hrs,
    MAX(IF(name = 'hematocrit'  AND rn = 1, valuenum,   NULL)) AS hematocrit_last,
    MAX(IF(name = 'hematocrit'  AND rn = 1, hrs_before, NULL)) AS hematocrit_hrs,
    MAX(IF(name = 'platelets'   AND rn = 1, valuenum,   NULL)) AS platelets_last,
    MAX(IF(name = 'platelets'   AND rn = 1, hrs_before, NULL)) AS platelets_hrs,
    MAX(IF(name = 'ast'         AND rn = 1, valuenum,   NULL)) AS ast_last,
    MAX(IF(name = 'ast'         AND rn = 1, hrs_before, NULL)) AS ast_hrs,
    MAX(IF(name = 'alt'         AND rn = 1, valuenum,   NULL)) AS alt_last,
    MAX(IF(name = 'alt'         AND rn = 1, hrs_before, NULL)) AS alt_hrs,
    MAX(IF(name = 'bilirubin'   AND rn = 1, valuenum,   NULL)) AS bilirubin_last,
    MAX(IF(name = 'bilirubin'   AND rn = 1, hrs_before, NULL)) AS bilirubin_hrs,
    MAX(IF(name = 'inr'         AND rn = 1, valuenum,   NULL)) AS inr_last,
    MAX(IF(name = 'inr'         AND rn = 1, hrs_before, NULL)) AS inr_hrs,
    MAX(IF(name = 'chloride'    AND rn = 1, valuenum,   NULL)) AS chloride_last,
    MAX(IF(name = 'chloride'    AND rn = 1, hrs_before, NULL)) AS chloride_hrs,
    MAX(IF(name = 'anion_gap'   AND rn = 1, valuenum,   NULL)) AS anion_gap_last,
    MAX(IF(name = 'anion_gap'   AND rn = 1, hrs_before, NULL)) AS anion_gap_hrs,
    MAX(IF(name = 'calcium'     AND rn = 1, valuenum,   NULL)) AS calcium_last,
    MAX(IF(name = 'calcium'     AND rn = 1, hrs_before, NULL)) AS calcium_hrs,
    MAX(IF(name = 'magnesium'   AND rn = 1, valuenum,   NULL)) AS magnesium_last,
    MAX(IF(name = 'magnesium'   AND rn = 1, hrs_before, NULL)) AS magnesium_hrs,
    MAX(IF(name = 'phosphate'   AND rn = 1, valuenum,   NULL)) AS phosphate_last,
    MAX(IF(name = 'phosphate'   AND rn = 1, hrs_before, NULL)) AS phosphate_hrs,
    MAX(charttime)                                               AS lab_max_time
  FROM lab_lm
  GROUP BY stay_id, k
),

-- HbA1c: the last value from ANY time before t_k, including earlier
-- admissions and outpatient draws (labevents rows with hadm_id NULL),
-- joined by subject_id.
hba1c_feat AS (
  SELECT l.stay_id, l.k,
         r.valuenum                                            AS hba1c_last,
         DATETIME_DIFF(l.t_k, r.charttime, HOUR) / 24.0        AS hba1c_days_ago
  FROM lm AS l
  JOIN (
    SELECT subject_id, charttime, COALESCE(storetime, charttime) AS avail_time, valuenum
    FROM `YOUR_PROJECT.hypo_tutorial.src_labevents`
    WHERE itemid = 50852 AND valuenum IS NOT NULL
  ) AS r ON r.subject_id = l.subject_id
  WHERE r.avail_time < l.t_k AND r.charttime < l.t_k
  QUALIFY ROW_NUMBER() OVER (PARTITION BY l.stay_id, l.k ORDER BY r.charttime DESC) = 1
),

-- ---------------------------------------------------------------------
-- Glucose trajectory from the combined stream (01), stored before t_k.
-- "stay" counts are over the hospital admission so far.
-- ---------------------------------------------------------------------
glu_lm AS (
  SELECT l.stay_id, l.k, g.glucose, g.charttime,
         DATETIME_DIFF(l.t_k, g.charttime, MINUTE) / 60.0 AS hrs_before,
         ROW_NUMBER() OVER (PARTITION BY l.stay_id, l.k ORDER BY g.charttime DESC) AS rn
  FROM lm AS l
  JOIN `YOUR_PROJECT.hypo_tutorial.glucose_events` AS g
    ON g.hadm_id = l.hadm_id
   AND g.storetime < l.t_k
   AND g.charttime < l.t_k            -- both times before the landmark (see lab_lm)
   -- a low contradicted by a repeat is left out only when the repeat itself was
   -- visible before t_k; a repeat stored after t_k is information the landmark
   -- did not have (the review of 12 October 2026: look-ahead through the flag)
   AND NOT (g.cancelled_by_repeat AND g.repeat_storetime < l.t_k)
),
glu_feat AS (
  SELECT stay_id, k,
    MAX(IF(rn = 1, glucose,    NULL))                   AS glucose_last,
    MAX(IF(rn = 2, glucose,    NULL))                   AS glucose_prev,
    MAX(IF(rn = 3, glucose,    NULL))                   AS glucose_prev2,
    MAX(IF(rn = 1, hrs_before, NULL))                   AS hrs_since_glucose,
    MIN(IF(hrs_before <= 24, glucose, NULL))            AS glucose_min_24h,
    MAX(IF(hrs_before <= 24, glucose, NULL))            AS glucose_max_24h,
    AVG(IF(hrs_before <= 24, glucose, NULL))            AS glucose_mean_24h,
    STDDEV(IF(hrs_before <= 24, glucose, NULL))         AS glucose_sd_24h,
    COUNTIF(hrs_before <= 24)                           AS glucose_n_24h,
    COUNTIF(hrs_before <= 24 AND glucose > 300)         AS glucose_n_gt300_24h,
    COUNTIF(hrs_before <= 24 AND glucose < 70)          AS glucose_n_lt70_24h,
    MIN(glucose)                                        AS glucose_min_stay,
    MAX(glucose)                                        AS glucose_max_stay,
    COUNTIF(glucose < 70)                               AS glucose_n_lt70_stay,
    COUNTIF(glucose < 54)                               AS glucose_n_lt54_stay,
    COUNTIF(glucose < 40)                               AS glucose_n_lt40_stay,
    COUNTIF(glucose > 300)                              AS glucose_n_gt300_stay,
    COUNT(*)                                            AS glucose_n_stay,
    MAX(charttime)                                      AS glucose_max_time
  FROM glu_lm
  GROUP BY stay_id, k
),

-- ---------------------------------------------------------------------
-- Subcutaneous and bolus doses in [t_k - 24 h, t_k) from both sources (01)
-- ---------------------------------------------------------------------
sc_feat AS (
  SELECT l.stay_id, l.k,
    SUM(IF(d.drug_class = 'insulin' AND d.insulin_kind = 'basal', d.dose_units, 0))                  AS insulin_basal_units_24h,
    SUM(IF(d.drug_class = 'insulin' AND d.insulin_kind = 'bolus' AND NOT d.insulin_iv, d.dose_units, 0)) AS insulin_bolus_units_24h,
    MAX(IF(d.drug_class = 'insulin' AND d.insulin_iv, 1, 0))                                         AS insulin_iv_push_24h,
    MAX(d.charttime)                                                                                 AS sc_max_time
  FROM lm AS l
  JOIN `YOUR_PROJECT.hypo_tutorial.sc_doses` AS d
    ON d.hadm_id = l.hadm_id
   AND d.charttime >= DATETIME_SUB(l.t_k, INTERVAL 24 HOUR)
   AND d.charttime <  l.t_k
  GROUP BY l.stay_id, l.k
),

-- ---------------------------------------------------------------------
-- Insulin drip intervals (01 insulin_drips: inputevents segments with a
-- rate, eMAR Started / Confirmed / Stopped intervals without one)
-- overlapping [t_k - 24 h, t_k), flowsheet first as in 01: the eMAR
-- intervals are read only for a stay without any inputevents drip segment.
-- A running interval contributes only the part before t_k. Rates and units
-- come from inputevents only, so an eMAR-only drip has drip_hours_24h > 0
-- and NULL rate features; the notebook's missing indicators carry that.
-- ---------------------------------------------------------------------
drip_lm AS (
  SELECT l.stay_id, l.k, l.t_k, d.source, d.starttime, d.endtime, d.rate,
         GREATEST(d.starttime, DATETIME_SUB(l.t_k, INTERVAL 24 HOUR))   AS seg_start,
         LEAST(d.endtime, l.t_k)                                        AS seg_end,
         d.endtime >= l.t_k                                             AS running_at_tk
  FROM lm AS l
  JOIN `YOUR_PROJECT.hypo_tutorial.insulin_drips` AS d
    ON d.hadm_id = l.hadm_id
   AND d.starttime <  l.t_k
   AND d.endtime   >= DATETIME_SUB(l.t_k, INTERVAL 24 HOUR)
   AND (d.source = 'inputevents' OR NOT l.stay_has_inputevents_drip)
),
drip_feat AS (
  SELECT stay_id, k,
    COUNTIF(source = 'inputevents')                                                 AS drip_segments_24h,
    ROUND(GREATEST(
      SUM(IF(source = 'inputevents', DATETIME_DIFF(seg_end, seg_start, MINUTE), 0)),
      SUM(IF(source = 'emar',        DATETIME_DIFF(seg_end, seg_start, MINUTE), 0))) / 60.0, 2) AS drip_hours_24h,
    IF(COUNTIF(source = 'inputevents') > 0,
       ROUND(SUM(IF(source = 'inputevents', rate * DATETIME_DIFF(seg_end, seg_start, MINUTE) / 60.0, 0)), 2), NULL) AS drip_units_24h,
    MAX(rate)                                                                       AS drip_rate_max_24h,
    ROUND(SAFE_DIVIDE(SUM(IF(source = 'inputevents', rate * DATETIME_DIFF(seg_end, seg_start, MINUTE), NULL)),
                      SUM(IF(source = 'inputevents', DATETIME_DIFF(seg_end, seg_start, MINUTE), NULL))), 2) AS drip_rate_mean_24h,
    MAX(IF(running_at_tk, rate, NULL))                                              AS drip_rate_at_tk,
    MAX(IF(running_at_tk, 1, 0))                                                    AS drip_running_at_tk,
    -- when no interval is running at t_k, hours since the last one ended
    IF(MAX(IF(running_at_tk, 1, 0)) = 0,
       DATETIME_DIFF(MAX(t_k), MAX(endtime), MINUTE) / 60.0, NULL)                  AS hrs_since_drip_stop,
    MAX(seg_start)                                                                  AS drip_max_time
  FROM drip_lm
  GROUP BY stay_id, k
),
drip_stay AS (
  -- cumulative drip hours in this admission before t_k, the larger of the two sources
  SELECT stay_id, k, ROUND(GREATEST(MAX(IF(source = 'inputevents', hours, 0)), MAX(IF(source = 'emar', hours, 0))), 1) AS drip_hours_stay
  FROM (
    SELECT l.stay_id, l.k, d.source,
           SUM(DATETIME_DIFF(LEAST(d.endtime, l.t_k), d.starttime, MINUTE)) / 60.0 AS hours
    FROM lm AS l
    JOIN `YOUR_PROJECT.hypo_tutorial.insulin_drips` AS d
      ON d.hadm_id = l.hadm_id AND d.starttime < l.t_k
     AND (d.source = 'inputevents' OR NOT l.stay_has_inputevents_drip)
    GROUP BY l.stay_id, l.k, d.source
  )
  GROUP BY stay_id, k
),

-- ---------------------------------------------------------------------
-- Feeds and dextrose (inputevents, 01) around the landmark
-- ---------------------------------------------------------------------
nut_lm AS (
  -- running / hours features come from rate rows only (00 section N: the
  -- amount rows are one-minute boluses and flushes); D50 is counted from its
  -- amount rows
  SELECT l.stay_id, l.k, l.t_k, n.kind, n.starttime, n.endtime, n.rate, n.amount, n.has_rate,
         GREATEST(n.starttime, DATETIME_SUB(l.t_k, INTERVAL 24 HOUR))   AS seg_start,
         LEAST(n.endtime, l.t_k)                                        AS seg_end,
         n.has_rate AND n.endtime >= l.t_k                              AS running_at_tk
  FROM lm AS l
  JOIN `YOUR_PROJECT.hypo_tutorial.icu_nutrition` AS n
    ON n.stay_id = l.stay_id
   AND n.starttime <  l.t_k
   AND n.endtime   >= DATETIME_SUB(l.t_k, INTERVAL 24 HOUR)
   AND (n.has_rate OR n.kind = 'd50')
),
nut_feat AS (
  SELECT stay_id, k,
    MAX(IF(kind = 'enteral' AND running_at_tk, 1, 0))                                          AS enteral_running_at_tk,
    ROUND(SUM(IF(kind = 'enteral', DATETIME_DIFF(seg_end, seg_start, MINUTE), 0)) / 60.0, 2)   AS enteral_hours_24h,
    MAX(IF(kind = 'enteral' AND running_at_tk, rate, NULL))                                    AS enteral_rate_at_tk,
    -- fed in the last 24 h but nothing running at the landmark: an interruption
    IF(MAX(IF(kind = 'enteral', 1, 0)) = 1 AND MAX(IF(kind = 'enteral' AND running_at_tk, 1, 0)) = 0, 1, 0) AS enteral_interrupted_24h,
    IF(MAX(IF(kind = 'enteral', 1, 0)) = 1 AND MAX(IF(kind = 'enteral' AND running_at_tk, 1, 0)) = 0,
       DATETIME_DIFF(MAX(t_k), MAX(IF(kind = 'enteral', endtime, NULL)), MINUTE) / 60.0, NULL)  AS hrs_since_enteral_stop,
    MAX(IF(kind = 'parenteral' AND running_at_tk, 1, 0))                                       AS parenteral_running_at_tk,
    ROUND(SUM(IF(kind = 'parenteral', DATETIME_DIFF(seg_end, seg_start, MINUTE), 0)) / 60.0, 2) AS parenteral_hours_24h,
    MAX(IF(kind = 'dextrose_fluid' AND running_at_tk, 1, 0))                                   AS dextrose_fluid_running_at_tk,
    SUM(IF(kind = 'dextrose_fluid' AND running_at_tk, rate, 0))                                AS dextrose_fluid_rate_at_tk,
    ROUND(SUM(IF(kind = 'dextrose_fluid', DATETIME_DIFF(seg_end, seg_start, MINUTE), 0)) / 60.0, 2) AS dextrose_fluid_hours_24h,
    COUNTIF(kind = 'd50')                                                                      AS d50_n_24h,
    MAX(seg_start)                                                                             AS nut_max_time
  FROM nut_lm
  GROUP BY stay_id, k
),
d50_stay AS (
  SELECT l.stay_id, l.k, COUNT(*) AS d50_n_stay
  FROM lm AS l
  JOIN `YOUR_PROJECT.hypo_tutorial.icu_nutrition` AS n
    ON n.stay_id = l.stay_id AND n.kind = 'd50' AND n.starttime < l.t_k
  GROUP BY l.stay_id, l.k
),

-- ---------------------------------------------------------------------
-- Other medications in [t_k - 24 h, t_k) from the classified eMAR table (01)
-- ---------------------------------------------------------------------
med_feat AS (
  SELECT l.stay_id, l.k,
    COUNTIF(m.held AND m.drug_class = 'insulin')                                                      AS n_insulin_held_24h,
    MAX(IF(m.bolus_given AND m.drug_class = 'insulin' AND m.is_sliding_scale, 1, 0))                   AS insulin_sliding_scale_24h,
    COUNTIF(m.ss_no_dose AND m.drug_class = 'insulin')                                                AS n_ss_no_dose_24h,
    MAX(IF(m.bolus_given AND m.drug_class = 'steroid',         1, 0))                                 AS steroid_24h,
    MAX(IF(m.bolus_given AND m.drug_class = 'betablocker',     1, 0))                                 AS betablocker_24h,
    MAX(IF(m.bolus_given AND m.drug_class = 'quinolone',       1, 0))                                 AS quinolone_24h,
    MAX(IF(m.bolus_given AND m.drug_class = 'dextrose_rescue', 1, 0))                                 AS dextrose_rescue_emar_24h,
    COUNTIF(m.bolus_given OR m.infusion_start)                                                        AS n_admin_any_24h,
    MAX(IF(m.bolus_given OR m.infusion_start OR m.held OR m.ss_no_dose, m.charttime, NULL))           AS med_max_time
  FROM lm AS l
  JOIN `YOUR_PROJECT.hypo_tutorial.emar_cohort` AS m
    ON m.hadm_id = l.hadm_id
   AND m.charttime >= DATETIME_SUB(l.t_k, INTERVAL 24 HOUR)
   AND m.charttime <  l.t_k
  GROUP BY l.stay_id, l.k
),
su_stay AS (
  -- sulfonylurea at any point in the admission before t_k (long half-life)
  SELECT l.stay_id, l.k, 1 AS su_any_stay
  FROM lm AS l
  JOIN `YOUR_PROJECT.hypo_tutorial.sc_doses` AS d
    ON d.hadm_id = l.hadm_id AND d.drug_class = 'sulfonylurea' AND d.charttime < l.t_k
  GROUP BY l.stay_id, l.k
),

-- ---------------------------------------------------------------------
-- Vasopressors (inputevents) in [t_k - 24 h, t_k) and ventilation at t_k
-- (procedureevents intervals). Ids verified by 00 section B2.
-- ---------------------------------------------------------------------
vaso_feat AS (
  SELECT l.stay_id, l.k,
    COUNT(DISTINCT ie.itemid)   AS n_vasopressors_24h,
    MAX(GREATEST(ie.starttime, DATETIME_SUB(l.t_k, INTERVAL 24 HOUR))) AS vaso_max_time
  FROM lm AS l
  JOIN `YOUR_PROJECT.hypo_tutorial.src_inputevents` AS ie
    ON ie.stay_id = l.stay_id
   AND ie.itemid IN (221906, 221289, 221662, 221653, 222315, 221749, 221986)
   AND COALESCE(ie.statusdescription, '') != 'Rewritten'
   AND ie.starttime <  l.t_k
   AND ie.endtime   >= DATETIME_SUB(l.t_k, INTERVAL 24 HOUR)
  GROUP BY l.stay_id, l.k
),
vent_feat AS (
  SELECT l.stay_id, l.k,
    MAX(IF(pe.itemid = 225792, 1, 0)) AS invasive_vent_at_tk,
    MAX(IF(pe.itemid = 225794, 1, 0)) AS niv_at_tk
  FROM lm AS l
  JOIN `YOUR_PROJECT.hypo_tutorial.src_procedureevents` AS pe
    ON pe.stay_id = l.stay_id
   AND pe.itemid IN (225792, 225794)
   AND pe.starttime <= l.t_k
   AND pe.endtime   >  l.t_k
  GROUP BY l.stay_id, l.k
),

-- ---------------------------------------------------------------------
-- Renal replacement therapy, antibiotics, cultures and octreotide: the ICU
-- hypoglycemia risk factors the first feature set lacked (Vriesendorp 2006:
-- CVVH with bicarbonate replacement fluid OR 14, sepsis OR 2.2, octreotide
-- OR 6.0 with a wide interval; Krinsley 2007 and Waeschle 2008: sepsis
-- severity). Sources are the 01 tables icu_rrt, icu_antibiotics, cultures
-- and icu_octreotide, verified by 00 sections O, O2, P and P2.
--   * rrt_at_tk: a dialysis interval (01 icu_rrt: procedureevents intervals
--     and chartevents CRRT charting / hemodialysis output, merged) that
--     started before t_k and had not ended; crrt_at_tk when the interval is
--     CRRT; ihd_24h when an intermittent session (interval or per-session
--     output charting) falls in the look-back; rrt_24h and rrt_hours_24h from
--     the overlap of every interval with the look-back (a hemodialysis output
--     marker is one minute long, so it flags a session without adding hours).
--   * antibiotic_24h: any antibiotic segment overlapping the look-back;
--     n_antibiotics_24h: distinct agents; antibiotic_started_24h: the first
--     segment of an agent in this stay began in the look-back;
--     hrs_since_first_antibiotic: hours from the stay's earliest antibiotic
--     start before t_k (how far into a treatment course the patient is).
--   * n_cultures_24h, blood_culture_24h: specimens collected in the look-back;
--     a specimen with only a collection date counts when that date is strictly
--     before DATE(t_k) and not before DATE(t_k - 24 h), the omr rule, so a
--     same-day collection that may have happened after t_k never enters.
--   * suspected_infection_24h = antibiotic_started_24h AND n_cultures_24h > 0
--     (a 24 h simplification of the Sepsis-3 suspicion window, which allows
--     72 h between the two; the simplification keeps the window inside the
--     look-back so it cannot leak).
--   * octreotide_24h: an eMAR octreotide dose or infusion start, or an
--     inputevents octreotide segment overlapping the look-back.
-- ---------------------------------------------------------------------
rrt_feat AS (
  SELECT l.stay_id, l.k,
    MAX(IF(r.endtime > l.t_k, 1, 0))                                                        AS rrt_at_tk,
    MAX(IF(r.endtime > l.t_k AND r.rrt_kind = 'crrt', 1, 0))                                AS crrt_at_tk,
    1                                                                                       AS rrt_24h,
    MAX(IF(r.rrt_kind = 'ihd', 1, 0))                                                       AS ihd_24h,
    ROUND(SUM(DATETIME_DIFF(LEAST(r.endtime, l.t_k),
                            GREATEST(r.starttime, DATETIME_SUB(l.t_k, INTERVAL 24 HOUR)), MINUTE)) / 60.0, 2) AS rrt_hours_24h,
    MAX(GREATEST(r.starttime, DATETIME_SUB(l.t_k, INTERVAL 24 HOUR)))                       AS rrt_max_time
  FROM lm AS l
  JOIN `YOUR_PROJECT.hypo_tutorial.icu_rrt` AS r
    ON r.stay_id = l.stay_id
   AND r.starttime <  l.t_k
   AND r.endtime   >= DATETIME_SUB(l.t_k, INTERVAL 24 HOUR)
  GROUP BY l.stay_id, l.k
),
abx_feat AS (
  SELECT l.stay_id, l.k,
    1                                                                                                AS antibiotic_24h,
    COUNT(DISTINCT a.itemid)                                                                         AS n_antibiotics_24h,
    MAX(IF(a.is_first_start_in_stay AND a.starttime >= DATETIME_SUB(l.t_k, INTERVAL 24 HOUR), 1, 0)) AS antibiotic_started_24h,
    MAX(GREATEST(a.starttime, DATETIME_SUB(l.t_k, INTERVAL 24 HOUR)))                                AS abx_max_time
  FROM lm AS l
  JOIN `YOUR_PROJECT.hypo_tutorial.icu_antibiotics` AS a
    ON a.stay_id = l.stay_id
   AND a.starttime <  l.t_k
   AND a.endtime   >= DATETIME_SUB(l.t_k, INTERVAL 24 HOUR)
  GROUP BY l.stay_id, l.k
),
abx_stay AS (
  SELECT l.stay_id, l.k,
    MAX(DATETIME_DIFF(l.t_k, a.starttime, MINUTE)) / 60.0 AS hrs_since_first_antibiotic   -- the earliest start = the largest gap
  FROM lm AS l
  JOIN `YOUR_PROJECT.hypo_tutorial.icu_antibiotics` AS a
    ON a.stay_id = l.stay_id AND a.starttime < l.t_k
  GROUP BY l.stay_id, l.k
),
cult_feat AS (
  SELECT l.stay_id, l.k,
    COUNT(DISTINCT c.micro_specimen_id)                                       AS n_cultures_24h,
    MAX(IF(REGEXP_CONTAINS(LOWER(COALESCE(c.spec_type_desc, '')), r'blood'), 1, 0)) AS blood_culture_24h,
    MAX(c.collected_time)                                                     AS cult_max_time
  FROM lm AS l
  JOIN `YOUR_PROJECT.hypo_tutorial.cultures` AS c
    ON c.hadm_id = l.hadm_id
   AND ((NOT c.date_only AND c.collected_time >= DATETIME_SUB(l.t_k, INTERVAL 24 HOUR) AND c.collected_time < l.t_k)
     OR (c.date_only AND DATE(c.collected_time) >= DATE(DATETIME_SUB(l.t_k, INTERVAL 24 HOUR)) AND DATE(c.collected_time) < DATE(l.t_k)))
  GROUP BY l.stay_id, l.k
),
octr_feat AS (
  SELECT stay_id, k, 1 AS octreotide_24h, MAX(octr_time) AS octr_max_time
  FROM (
    SELECT l.stay_id, l.k, m.charttime AS octr_time
    FROM lm AS l
    JOIN `YOUR_PROJECT.hypo_tutorial.emar_cohort` AS m
      ON m.hadm_id = l.hadm_id
     AND (m.bolus_given OR m.infusion_start)
     AND m.drug_class = 'octreotide'
     AND m.charttime >= DATETIME_SUB(l.t_k, INTERVAL 24 HOUR)
     AND m.charttime <  l.t_k
    UNION ALL
    SELECT l.stay_id, l.k, GREATEST(o.starttime, DATETIME_SUB(l.t_k, INTERVAL 24 HOUR))
    FROM lm AS l
    JOIN `YOUR_PROJECT.hypo_tutorial.icu_octreotide` AS o
      ON o.stay_id = l.stay_id
     AND o.starttime <  l.t_k
     AND o.endtime   >= DATETIME_SUB(l.t_k, INTERVAL 24 HOUR)
  )
  GROUP BY stay_id, k
),

-- ---------------------------------------------------------------------
-- History from EARLIER admissions only (the whole admissions table, any era)
-- ---------------------------------------------------------------------
prior_hist AS (
  SELECT
    cur.hadm_id,
    COUNT(DISTINCT prev.hadm_id) AS n_prior_admissions,
    MAX(IF((dx.icd_version = 9  AND dx.icd_code LIKE '250%')
        OR (dx.icd_version = 10 AND REGEXP_CONTAINS(dx.icd_code, r'^E1[013]')), 1, 0))        AS prior_dm,
    MAX(IF((dx.icd_version = 9  AND REGEXP_CONTAINS(dx.icd_code, r'^251[012]'))
        OR (dx.icd_version = 10 AND REGEXP_CONTAINS(dx.icd_code, r'^E16[012]|^E1[013]64')), 1, 0)) AS prior_hypoglycemia_dx,
    MAX(IF((dx.icd_version = 9  AND dx.icd_code LIKE '585%')
        OR (dx.icd_version = 10 AND dx.icd_code LIKE 'N18%'), 1, 0))                         AS prior_ckd,
    MAX(IF((dx.icd_version = 9  AND dx.icd_code LIKE '571%')
        OR (dx.icd_version = 10 AND REGEXP_CONTAINS(dx.icd_code, r'^K7[0-7]')), 1, 0))        AS prior_liver,
    MAX(IF((dx.icd_version = 9  AND dx.icd_code LIKE '428%')
        OR (dx.icd_version = 10 AND dx.icd_code LIKE 'I50%'), 1, 0))                         AS prior_hf
  FROM (SELECT DISTINCT hadm_id, subject_id, admittime FROM `YOUR_PROJECT.hypo_tutorial.stay_base`) AS cur
  LEFT JOIN `physionet-data.mimiciv_3_1_hosp.admissions` AS prev
         ON prev.subject_id = cur.subject_id AND prev.dischtime < cur.admittime
  LEFT JOIN `physionet-data.mimiciv_3_1_hosp.diagnoses_icd` AS dx
         ON dx.hadm_id = prev.hadm_id
  GROUP BY cur.hadm_id
),

-- ---------------------------------------------------------------------
-- Where the patient is at t_k: care unit (transfers) and service
-- ---------------------------------------------------------------------
unit_lm AS (
  SELECT l.stay_id, l.k, t.careunit AS careunit_tk
  FROM lm AS l
  JOIN `physionet-data.mimiciv_3_1_hosp.transfers` AS t
    ON t.hadm_id = l.hadm_id
   AND t.intime <= l.t_k
   AND (t.outtime > l.t_k OR t.outtime IS NULL)
  WHERE t.eventtype != 'discharge'
  QUALIFY ROW_NUMBER() OVER (PARTITION BY l.stay_id, l.k ORDER BY t.intime DESC) = 1
),
service_lm AS (
  SELECT l.stay_id, l.k, s.curr_service AS service_tk
  FROM lm AS l
  JOIN `physionet-data.mimiciv_3_1_hosp.services` AS s
    ON s.hadm_id = l.hadm_id
  WHERE s.transfertime <= l.t_k
  QUALIFY ROW_NUMBER() OVER (PARTITION BY l.stay_id, l.k ORDER BY s.transfertime DESC) = 1
),

-- ---------------------------------------------------------------------
-- ICU vitals, GCS and weight in the last 24 h
-- ---------------------------------------------------------------------
vitals_raw AS (
  -- Plausibility bounds per item, the mimic-code vitals_first_day ones for
  -- the vitals (00 H2 found a heart rate of 10,000,000); weight 20 to 400 kg;
  -- GCS components in their scale ranges.
  SELECT ce.stay_id, ce.charttime, COALESCE(ce.storetime, ce.charttime) AS storetime, ce.itemid, ce.valuenum
  FROM `YOUR_PROJECT.hypo_tutorial.src_chartevents` AS ce
  JOIN `YOUR_PROJECT.hypo_tutorial.stay_base`       AS b USING (stay_id)
  WHERE ce.itemid IN (220045, 220179, 220050, 220210, 220277, 223761, 223762,
                      226512, 224639, 220739, 223900, 223901)
    AND ce.valuenum IS NOT NULL
    AND CASE ce.itemid
          WHEN 220045 THEN ce.valuenum > 0  AND ce.valuenum < 300    -- heart rate
          WHEN 220179 THEN ce.valuenum > 0  AND ce.valuenum < 400    -- NIBP systolic
          WHEN 220050 THEN ce.valuenum > 0  AND ce.valuenum < 400    -- arterial systolic
          WHEN 220210 THEN ce.valuenum > 0  AND ce.valuenum < 70     -- respiratory rate
          WHEN 220277 THEN ce.valuenum > 0  AND ce.valuenum <= 100   -- SpO2
          WHEN 223761 THEN ce.valuenum > 70 AND ce.valuenum < 120    -- temperature F
          WHEN 223762 THEN ce.valuenum > 10 AND ce.valuenum < 50     -- temperature C
          WHEN 226512 THEN ce.valuenum >= 20 AND ce.valuenum <= 400  -- admission weight kg
          WHEN 224639 THEN ce.valuenum >= 20 AND ce.valuenum <= 400  -- daily weight kg
          WHEN 220739 THEN ce.valuenum BETWEEN 1 AND 4               -- GCS eye
          WHEN 223900 THEN ce.valuenum BETWEEN 1 AND 5               -- GCS verbal
          WHEN 223901 THEN ce.valuenum BETWEEN 1 AND 6               -- GCS motor
        END
),
gcs_sum AS (
  -- one total per charting time when all three components are present
  SELECT stay_id, charttime, MAX(storetime) AS storetime, SUM(valuenum) AS gcs_total
  FROM vitals_raw
  WHERE itemid IN (220739, 223900, 223901)
  GROUP BY stay_id, charttime
  HAVING COUNT(DISTINCT itemid) = 3
),
vitals_feat AS (
  SELECT l.stay_id, l.k,
    AVG(IF(v.itemid = 220045,               v.valuenum, NULL)) AS hr_mean_24h,
    MAX(IF(v.itemid = 220045,               v.valuenum, NULL)) AS hr_max_24h,
    AVG(IF(v.itemid IN (220179, 220050),    v.valuenum, NULL)) AS sbp_mean_24h,
    MIN(IF(v.itemid IN (220179, 220050),    v.valuenum, NULL)) AS sbp_min_24h,
    AVG(IF(v.itemid = 220210,               v.valuenum, NULL)) AS rr_mean_24h,
    MIN(IF(v.itemid = 220277,               v.valuenum, NULL)) AS spo2_min_24h,
    MAX(CASE WHEN v.itemid = 223762 THEN v.valuenum
             WHEN v.itemid = 223761 THEN (v.valuenum - 32) * 5 / 9 END) AS temp_max_24h_c,
    MAX(v.charttime)                                           AS vitals_max_time
  FROM lm AS l
  JOIN vitals_raw AS v
    ON v.stay_id = l.stay_id
   AND v.charttime >= DATETIME_SUB(l.t_k, INTERVAL 24 HOUR)
   AND v.charttime <  l.t_k
   AND v.storetime <  l.t_k           -- both times before the landmark, as for labs
  GROUP BY l.stay_id, l.k
),
gcs_feat AS (
  SELECT l.stay_id, l.k,
    MIN(g.gcs_total) AS gcs_min_24h,
    MAX(g.charttime) AS gcs_max_time
  FROM lm AS l
  JOIN gcs_sum AS g
    ON g.stay_id = l.stay_id
   AND g.charttime >= DATETIME_SUB(l.t_k, INTERVAL 24 HOUR)
   AND g.charttime <  l.t_k
   AND g.storetime <  l.t_k
  GROUP BY l.stay_id, l.k
),
weight_feat AS (
  -- last charted ICU weight before t_k, any time in the stay
  SELECT l.stay_id, l.k, v.valuenum AS weight_kg_icu, v.charttime AS weight_time
  FROM lm AS l
  JOIN vitals_raw AS v
    ON v.stay_id = l.stay_id AND v.itemid IN (226512, 224639) AND v.charttime < l.t_k AND v.storetime < l.t_k
  QUALIFY ROW_NUMBER() OVER (PARTITION BY l.stay_id, l.k ORDER BY v.charttime DESC) = 1
),

-- ---------------------------------------------------------------------
-- Body size from the outpatient-measurement table (date resolution only)
-- ---------------------------------------------------------------------
omr_lm AS (
  -- 00 section H4: both spellings of BMI and weight map to one concept
  SELECT l.stay_id, l.k,
         IF(o.result_name IN ('BMI (kg/m2)', 'BMI'), 'bmi', 'weight_lbs') AS concept,
         SAFE_CAST(o.result_value AS FLOAT64) AS val,
         ROW_NUMBER() OVER (PARTITION BY l.stay_id, l.k, IF(o.result_name IN ('BMI (kg/m2)', 'BMI'), 'bmi', 'weight_lbs')
                            ORDER BY o.chartdate DESC, o.seq_num DESC) AS rn
  FROM lm AS l
  JOIN `physionet-data.mimiciv_3_1_hosp.omr` AS o
    ON o.subject_id = l.subject_id AND o.chartdate < DATE(l.t_k)
  WHERE o.result_name IN ('BMI (kg/m2)', 'BMI', 'Weight (Lbs)', 'Weight')
    AND SAFE_CAST(o.result_value AS FLOAT64) > 0
),
omr_feat AS (
  SELECT stay_id, k,
    MAX(IF(concept = 'bmi'        AND rn = 1, val,              NULL)) AS bmi_last,
    MAX(IF(concept = 'weight_lbs' AND rn = 1, val * 0.45359237, NULL)) AS weight_kg_omr
  FROM omr_lm
  GROUP BY stay_id, k
)

-- ---------------------------------------------------------------------
-- Assemble
-- ---------------------------------------------------------------------
SELECT
  -- bookkeeping (never inputs)
  l.subject_id, l.hadm_id, l.stay_id, l.k, l.t_k, l.window_end, l.split, l.anchor_year_group, l.years_after_anchor, l.window_hours,
  l.race, l.insurance, l.language, l.marital_status,
  l.y_lt54_24h, l.y_lt40_24h, l.y_cms816_24h, l.y_gt300_24h,
  l.n_glucose_in_window                                  AS label_window_n_glucose,   -- future information: reporting only
  -- demographics and context
  l.age_at_admit, l.gender, l.admission_type, l.admission_location, l.ed_arrival,
  l.hours_in_hospital_before_icu, l.icu_day, l.icu_admit_hour, l.weekday_tk,
  l.first_careunit,
  u.careunit_tk,
  sv.service_tk,
  COALESCE(vt.invasive_vent_at_tk, 0)                    AS invasive_vent_at_tk,
  COALESCE(vt.niv_at_tk, 0)                              AS niv_at_tk,
  COALESCE(vp.n_vasopressors_24h, 0)                     AS n_vasopressors_24h,
  -- renal replacement therapy (01 icu_rrt)
  COALESCE(rr.rrt_at_tk, 0)                              AS rrt_at_tk,
  COALESCE(rr.crrt_at_tk, 0)                             AS crrt_at_tk,
  COALESCE(rr.rrt_24h, 0)                                AS rrt_24h,
  COALESCE(rr.ihd_24h, 0)                                AS ihd_24h,
  COALESCE(rr.rrt_hours_24h, 0)                          AS rrt_hours_24h,
  -- antibiotics, cultures and the suspicion-of-infection proxy (01 icu_antibiotics, cultures)
  COALESCE(ab.antibiotic_24h, 0)                         AS antibiotic_24h,
  COALESCE(ab.n_antibiotics_24h, 0)                      AS n_antibiotics_24h,
  COALESCE(ab.antibiotic_started_24h, 0)                 AS antibiotic_started_24h,
  abs_.hrs_since_first_antibiotic,
  COALESCE(cu.n_cultures_24h, 0)                         AS n_cultures_24h,
  COALESCE(cu.blood_culture_24h, 0)                      AS blood_culture_24h,
  IF(COALESCE(ab.antibiotic_started_24h, 0) = 1 AND COALESCE(cu.n_cultures_24h, 0) > 0, 1, 0) AS suspected_infection_24h,
  -- octreotide from either source (01 emar_cohort drug_class, icu_octreotide)
  COALESCE(oc.octreotide_24h, 0)                         AS octreotide_24h,
  -- history from earlier admissions
  COALESCE(h.n_prior_admissions, 0)                      AS n_prior_admissions,
  COALESCE(h.prior_dm, 0)                                AS prior_dm,
  COALESCE(h.prior_hypoglycemia_dx, 0)                   AS prior_hypoglycemia_dx,
  COALESCE(h.prior_ckd, 0)                               AS prior_ckd,
  COALESCE(h.prior_liver, 0)                             AS prior_liver,
  COALESCE(h.prior_hf, 0)                                AS prior_hf,
  -- hypoglycemic agents, last 24 h (counts from 01)
  l.n_hypo_admin_24h, l.n_doses_24h, l.n_insulin_sc_24h, l.n_su_admin_24h, l.n_megl_admin_24h,
  l.n_sc_from_inputevents_24h, l.hrs_since_last_hypo_admin,
  COALESCE(s.insulin_basal_units_24h, 0)                 AS insulin_basal_units_24h,
  COALESCE(s.insulin_bolus_units_24h, 0)                 AS insulin_bolus_units_24h,
  COALESCE(s.insulin_iv_push_24h, 0)                     AS insulin_iv_push_24h,
  COALESCE(m.n_insulin_held_24h, 0)                      AS n_insulin_held_24h,
  COALESCE(m.insulin_sliding_scale_24h, 0)               AS insulin_sliding_scale_24h,
  COALESCE(m.n_ss_no_dose_24h, 0)                        AS n_ss_no_dose_24h,
  COALESCE(su.su_any_stay, 0)                            AS su_any_stay,
  -- the insulin drip (inputevents segments and eMAR infusion intervals, 01)
  l.insulin_drip_24h,
  l.drip_inputevents_24h,                                   -- bookkeeping (see header)
  l.drip_emar_24h,                                          -- bookkeeping (see header)
  l.drip_running_inputevents_at_tk,                         -- bookkeeping (see header)
  l.drip_running_emar_at_tk,                                -- bookkeeping (see header)
  l.stay_has_inputevents_drip,                              -- bookkeeping (see header)
  l.emar_interval_open_at_tk,                               -- bookkeeping (see header)
  COALESCE(dr.drip_running_at_tk, 0)                     AS drip_running_at_tk,
  COALESCE(dr.drip_segments_24h, 0)                      AS drip_segments_24h,
  COALESCE(dr.drip_hours_24h, 0)                         AS drip_hours_24h,
  dr.drip_units_24h,                                        -- NULL when the drip is known from the eMAR only
  dr.drip_rate_at_tk,
  dr.drip_rate_max_24h,
  dr.drip_rate_mean_24h,
  dr.hrs_since_drip_stop,
  COALESCE(ds.drip_hours_stay, 0)                        AS drip_hours_stay,
  -- feeds and dextrose (inputevents)
  COALESCE(n.enteral_running_at_tk, 0)                   AS enteral_running_at_tk,
  COALESCE(n.enteral_hours_24h, 0)                       AS enteral_hours_24h,
  n.enteral_rate_at_tk,
  COALESCE(n.enteral_interrupted_24h, 0)                 AS enteral_interrupted_24h,
  n.hrs_since_enteral_stop,
  COALESCE(n.parenteral_running_at_tk, 0)                AS parenteral_running_at_tk,
  COALESCE(n.parenteral_hours_24h, 0)                    AS parenteral_hours_24h,
  COALESCE(n.dextrose_fluid_running_at_tk, 0)            AS dextrose_fluid_running_at_tk,
  COALESCE(n.dextrose_fluid_rate_at_tk, 0)               AS dextrose_fluid_rate_at_tk,     -- mL/h, summed over running dextrose fluids
  COALESCE(n.dextrose_fluid_hours_24h, 0)                AS dextrose_fluid_hours_24h,
  COALESCE(n.d50_n_24h, 0)                               AS d50_n_24h,
  COALESCE(d5.d50_n_stay, 0)                             AS d50_n_stay,
  -- other drugs, last 24 h (eMAR)
  COALESCE(m.steroid_24h, 0)                             AS steroid_24h,
  COALESCE(m.betablocker_24h, 0)                         AS betablocker_24h,
  COALESCE(m.quinolone_24h, 0)                           AS quinolone_24h,
  COALESCE(m.dextrose_rescue_emar_24h, 0)                AS dextrose_rescue_emar_24h,
  COALESCE(m.n_admin_any_24h, 0)                         AS n_admin_any_24h,
  -- glucose trajectory
  g.glucose_last, g.glucose_prev, g.glucose_prev2, g.hrs_since_glucose,
  g.glucose_min_24h, g.glucose_max_24h, g.glucose_mean_24h, g.glucose_sd_24h,
  COALESCE(g.glucose_n_24h, 0)                           AS glucose_n_24h,
  COALESCE(g.glucose_n_gt300_24h, 0)                     AS glucose_n_gt300_24h,
  COALESCE(g.glucose_n_lt70_24h, 0)                      AS glucose_n_lt70_24h,
  g.glucose_min_stay, g.glucose_max_stay,
  COALESCE(g.glucose_n_lt70_stay, 0)                     AS glucose_n_lt70_stay,
  COALESCE(g.glucose_n_lt54_stay, 0)                     AS glucose_n_lt54_stay,
  COALESCE(g.glucose_n_lt40_stay, 0)                     AS glucose_n_lt40_stay,
  COALESCE(g.glucose_n_gt300_stay, 0)                    AS glucose_n_gt300_stay,
  COALESCE(g.glucose_n_stay, 0)                          AS glucose_n_stay,
  -- lab panel
  lf.* EXCEPT (stay_id, k, lab_max_time),
  a1c.hba1c_last, a1c.hba1c_days_ago,
  -- ICU vitals, GCS, weight
  v.hr_mean_24h, v.hr_max_24h, v.sbp_mean_24h, v.sbp_min_24h, v.rr_mean_24h, v.spo2_min_24h, v.temp_max_24h_c,
  gc.gcs_min_24h,
  COALESCE(w.weight_kg_icu, o.weight_kg_omr)             AS weight_kg_last,
  o.bmi_last,
  -- leakage assertion support: the latest timestamp any feature was built from
  GREATEST(
    COALESCE(g.glucose_max_time,  DATETIME '1900-01-01 00:00:00'),
    COALESCE(lf.lab_max_time,     DATETIME '1900-01-01 00:00:00'),
    COALESCE(s.sc_max_time,       DATETIME '1900-01-01 00:00:00'),
    COALESCE(m.med_max_time,      DATETIME '1900-01-01 00:00:00'),
    COALESCE(dr.drip_max_time,    DATETIME '1900-01-01 00:00:00'),
    COALESCE(n.nut_max_time,      DATETIME '1900-01-01 00:00:00'),
    COALESCE(vp.vaso_max_time,    DATETIME '1900-01-01 00:00:00'),
    COALESCE(rr.rrt_max_time,     DATETIME '1900-01-01 00:00:00'),
    COALESCE(ab.abx_max_time,     DATETIME '1900-01-01 00:00:00'),
    COALESCE(cu.cult_max_time,    DATETIME '1900-01-01 00:00:00'),
    COALESCE(oc.octr_max_time,    DATETIME '1900-01-01 00:00:00'),
    COALESCE(v.vitals_max_time,   DATETIME '1900-01-01 00:00:00'),
    COALESCE(gc.gcs_max_time,     DATETIME '1900-01-01 00:00:00'),
    COALESCE(w.weight_time,       DATETIME '1900-01-01 00:00:00')
  ) AS max_feature_time
FROM lm AS l
LEFT JOIN lab_feat    AS lf  USING (stay_id, k)
LEFT JOIN hba1c_feat  AS a1c USING (stay_id, k)
LEFT JOIN glu_feat    AS g   USING (stay_id, k)
LEFT JOIN sc_feat     AS s   USING (stay_id, k)
LEFT JOIN drip_feat   AS dr  USING (stay_id, k)
LEFT JOIN drip_stay   AS ds  USING (stay_id, k)
LEFT JOIN nut_feat    AS n   USING (stay_id, k)
LEFT JOIN d50_stay    AS d5  USING (stay_id, k)
LEFT JOIN med_feat    AS m   USING (stay_id, k)
LEFT JOIN su_stay     AS su  USING (stay_id, k)
LEFT JOIN vaso_feat   AS vp  USING (stay_id, k)
LEFT JOIN vent_feat   AS vt  USING (stay_id, k)
LEFT JOIN rrt_feat    AS rr  USING (stay_id, k)
LEFT JOIN abx_feat    AS ab  USING (stay_id, k)
LEFT JOIN abx_stay    AS abs_ USING (stay_id, k)
LEFT JOIN cult_feat   AS cu  USING (stay_id, k)
LEFT JOIN octr_feat   AS oc  USING (stay_id, k)
LEFT JOIN prior_hist  AS h   USING (hadm_id)
LEFT JOIN unit_lm     AS u   USING (stay_id, k)
LEFT JOIN service_lm  AS sv  USING (stay_id, k)
LEFT JOIN vitals_feat AS v   USING (stay_id, k)
LEFT JOIN gcs_feat    AS gc  USING (stay_id, k)
LEFT JOIN weight_feat AS w   USING (stay_id, k)
LEFT JOIN omr_feat    AS o   USING (stay_id, k);


-- ---------------------------------------------------------------------
-- Checks to paste back: leakage assertion, then a profile by drip status
-- ---------------------------------------------------------------------
SELECT
  COUNTIF(max_feature_time >= t_k) AS rows_violating_leakage_rule,   -- must be 0
  COUNT(*)                         AS rows_total,
  COUNT(DISTINCT CONCAT(CAST(stay_id AS STRING), '-', CAST(k AS STRING))) AS distinct_keys   -- must equal rows_total
FROM `YOUR_PROJECT.hypo_tutorial.features`;

-- Table 1b. Nominal time after the entry time: how often a glucose result or a
-- panel lab carries a charttime later than its storetime, by how much, and how
-- many landmark rows had such a value straddling t_k (stored before, timed at
-- or after). Those are the rows the first run's assertion flagged (948 of
-- 128,108) and that the both-times rule now excludes; the pipeline loses one
-- value for one landmark in each, nothing else.
WITH lm AS (
  SELECT stay_id, hadm_id, k, t_k FROM `YOUR_PROJECT.hypo_tutorial.cohort_landmarks`
),
glu AS (
  SELECT 'glucose stream' AS source, hadm_id, charttime, storetime
  FROM `YOUR_PROJECT.hypo_tutorial.glucose_events`
),
lab AS (
  SELECT 'lab panel' AS source, le.hadm_id, le.charttime, COALESCE(le.storetime, le.charttime) AS storetime
  FROM `YOUR_PROJECT.hypo_tutorial.src_labevents` AS le
  JOIN (SELECT DISTINCT hadm_id FROM `YOUR_PROJECT.hypo_tutorial.cohort_landmarks`) AS b USING (hadm_id)
  WHERE le.itemid IN (50912, 51006, 50862, 50983, 50971, 50882, 50813, 51301, 51222, 51221,
                      51265, 50878, 50861, 50885, 51237, 50902, 50868, 50893, 50960, 50970)
    AND le.valuenum IS NOT NULL
),
rows_ AS (SELECT * FROM glu UNION ALL SELECT * FROM lab),
straddle AS (
  SELECT r.source, l.stay_id, l.k
  FROM rows_ AS r
  JOIN lm AS l ON l.hadm_id = r.hadm_id AND r.storetime < l.t_k AND r.charttime >= l.t_k
  GROUP BY r.source, l.stay_id, l.k
)
SELECT
  r.source,
  COUNT(*)                                                                   AS results,
  COUNTIF(r.storetime < r.charttime)                                         AS stored_before_charttime,
  ROUND(100 * COUNTIF(r.storetime < r.charttime) / COUNT(*), 2)              AS pct,
  APPROX_QUANTILES(IF(r.storetime < r.charttime, DATETIME_DIFF(r.charttime, r.storetime, MINUTE), NULL), 100)[OFFSET(50)] AS p50_minutes_early,
  APPROX_QUANTILES(IF(r.storetime < r.charttime, DATETIME_DIFF(r.charttime, r.storetime, MINUTE), NULL), 100)[OFFSET(90)] AS p90_minutes_early,
  (SELECT COUNT(*) FROM straddle AS s WHERE s.source = r.source)             AS landmark_rows_with_a_straddling_value
FROM rows_ AS r
GROUP BY r.source
ORDER BY r.source;

SELECT
  drip_running_at_tk,
  COUNT(*)                                                    AS rows_,
  ROUND(100 * AVG(y_lt54_24h), 2)                             AS pct_lt54,
  ROUND(100 * AVG(y_gt300_24h), 2)                            AS pct_gt300,
  ROUND(100 * COUNTIF(label_window_n_glucose = 0) / COUNT(*), 1) AS pct_no_result_in_label_window,
  ROUND(AVG(glucose_n_24h), 1)                                AS mean_glucose_checks_24h,
  ROUND(100 * COUNTIF(glucose_last IS NULL) / COUNT(*), 1)    AS pct_no_glucose_before_tk,
  ROUND(100 * COUNTIF(creatinine_last IS NULL) / COUNT(*), 1) AS pct_no_creatinine,
  ROUND(100 * COUNTIF(hba1c_last IS NULL) / COUNT(*), 1)      AS pct_no_hba1c,
  ROUND(100 * COUNTIF(weight_kg_last IS NULL) / COUNT(*), 1)  AS pct_no_weight,
  ROUND(100 * COUNTIF(gcs_min_24h IS NULL) / COUNT(*), 1)     AS pct_no_gcs,
  ROUND(100 * AVG(enteral_running_at_tk), 1)                  AS pct_enteral_running,
  ROUND(100 * AVG(enteral_interrupted_24h), 1)                AS pct_enteral_interrupted,
  ROUND(100 * AVG(parenteral_running_at_tk), 1)               AS pct_parenteral,
  ROUND(100 * AVG(invasive_vent_at_tk), 1)                    AS pct_invasive_vent,
  ROUND(100 * AVG(IF(n_vasopressors_24h > 0, 1, 0)), 1)       AS pct_vasopressor,
  ROUND(100 * AVG(rrt_at_tk), 2)                              AS pct_rrt_at_tk,
  ROUND(100 * AVG(antibiotic_24h), 1)                         AS pct_antibiotic_24h,
  ROUND(100 * AVG(suspected_infection_24h), 1)                AS pct_suspected_infection_24h,
  ROUND(100 * AVG(octreotide_24h), 2)                         AS pct_octreotide_24h,
  ROUND(100 * COUNTIF(insulin_basal_units_24h + insulin_bolus_units_24h > 0) / COUNT(*), 1) AS pct_with_sc_units,
  ROUND(AVG(insulin_bolus_units_24h), 1)                      AS mean_bolus_units_24h,
  MAX(insulin_bolus_units_24h)                                AS max_bolus_units_24h,
  MAX(insulin_basal_units_24h)                                AS max_basal_units_24h,
  ROUND(AVG(drip_units_24h), 1)                               AS mean_drip_units_24h,
  MAX(drip_rate_max_24h)                                      AS max_drip_rate,
  ROUND(AVG(n_ss_no_dose_24h), 2)                             AS mean_ss_no_dose_24h,
  ROUND(100 * AVG(IF(drip_emar_24h = 1 AND drip_inputevents_24h = 0, 1, 0)), 2) AS pct_drip_from_emar_only,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(drip_running_at_tk = 1 AND drip_rate_at_tk IS NOT NULL),
                          COUNTIF(drip_running_at_tk = 1)), 1)  AS pct_running_with_rate_known
FROM `YOUR_PROJECT.hypo_tutorial.features`
GROUP BY drip_running_at_tk
ORDER BY drip_running_at_tk;
