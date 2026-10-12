-- =====================================================================
--  00_sanity_itemids.sql   (BigQuery Standard SQL, MIMIC-IV v3.1)
--
--  Run this FIRST and read the output. Every itemid, vocabulary and value
--  range the pipeline relies on is stated as a hypothesis here and tested
--  against the database. If a table contradicts its comment, fix 01/02/03
--  before running anything else. Nothing is written; read-only, ~15 GiB.
--
--  Sections A to J were written for the hospital-wide design and stay as
--  evidence (docs/sanity_findings.md). The ICU design (October 2026) adds
--  the inputevents sources: K (items), K2 (vocabularies and ranges),
--  L (eMAR vs inputevents concordance), M (ICU landmark grid), N (feeds and
--  dextrose), and widens B, H2 and H6.
-- =====================================================================

-- A. Lab items used for labels (glucose) and for the lab-panel features
SELECT
  'hosp.labevents' AS module,
  d.itemid,
  d.label,
  d.fluid,
  d.category,
  CASE d.itemid
    WHEN 50931 THEN 'glucose, blood chemistry (label stream)'
    WHEN 50809 THEN 'glucose, blood gas analyser (label stream)'
    WHEN 52569 THEN 'glucose, blood (label stream; confirm label)'
    WHEN 50912 THEN 'creatinine'
    WHEN 51006 THEN 'urea nitrogen (BUN)'
    WHEN 50862 THEN 'albumin'
    WHEN 50983 THEN 'sodium'
    WHEN 50971 THEN 'potassium'
    WHEN 50882 THEN 'bicarbonate'
    WHEN 50813 THEN 'lactate'
    WHEN 51301 THEN 'white blood cells'
    WHEN 51222 THEN 'hemoglobin'
    WHEN 51221 THEN 'hematocrit'
    WHEN 51265 THEN 'platelet count'
    WHEN 50878 THEN 'AST'
    WHEN 50861 THEN 'ALT'
    WHEN 50885 THEN 'bilirubin, total'
    WHEN 51237 THEN 'INR'
    WHEN 50902 THEN 'chloride'
    WHEN 50868 THEN 'anion gap'
    WHEN 50893 THEN 'calcium, total'
    WHEN 50960 THEN 'magnesium'
    WHEN 50970 THEN 'phosphate'
    WHEN 50852 THEN 'hemoglobin A1c (%)'
  END AS expected
FROM `physionet-data.mimiciv_3_1_hosp.d_labitems` AS d
WHERE d.itemid IN (50931, 50809, 52569,
                   50912, 51006, 50862, 50983, 50971, 50882, 50813,
                   51301, 51222, 51221, 51265, 50878, 50861, 50885, 51237,
                   50902, 50868, 50893, 50960, 50970, 50852)
UNION ALL
-- B. ICU chart items used for the ICU glucose stream and the ICU vitals block
SELECT
  'icu.chartevents',
  d.itemid,
  d.label,
  CAST(NULL AS STRING),
  d.category,
  CASE d.itemid
    WHEN 220621 THEN 'glucose (serum), ICU chart copy of the lab value'
    WHEN 225664 THEN 'glucose finger stick, ICU point-of-care'
    WHEN 226537 THEN 'glucose (whole blood), ICU'
    WHEN 220045 THEN 'heart rate'
    WHEN 220179 THEN 'non-invasive systolic BP'
    WHEN 220050 THEN 'arterial systolic BP'
    WHEN 220210 THEN 'respiratory rate'
    WHEN 220277 THEN 'SpO2'
    WHEN 223761 THEN 'temperature, Fahrenheit'
    WHEN 223762 THEN 'temperature, Celsius'
    WHEN 226512 THEN 'admission weight (kg)'
    WHEN 224639 THEN 'daily weight (kg)'
    WHEN 220739 THEN 'GCS, eye opening'
    WHEN 223900 THEN 'GCS, verbal response'
    WHEN 223901 THEN 'GCS, motor response'
    -- CRRT settings charted hourly while a filter runs (section O found them;
    -- 01 icu_rrt collapses their charttimes into intervals, the second
    -- dialysis source) and the per-session hemodialysis output
    WHEN 227290 THEN 'CRRT mode (hourly while CRRT runs)'
    WHEN 224154 THEN 'CRRT dialysate rate'
    WHEN 224153 THEN 'CRRT replacement rate'
    WHEN 228005 THEN 'CRRT prefilter replacement rate'
    WHEN 228006 THEN 'CRRT post-filter replacement rate'
    WHEN 224151 THEN 'CRRT effluent pressure'
    WHEN 225977 THEN 'CRRT dialysate fluid'
    WHEN 230085 THEN 'CRRT dialysate fluid (second item)'
    WHEN 226499 THEN 'hemodialysis output, charted per session'
  END
FROM `physionet-data.mimiciv_3_1_icu.d_items` AS d
WHERE d.itemid IN (220621, 225664, 226537,
                   220045, 220179, 220050, 220210, 220277, 223761, 223762,
                   226512, 224639, 220739, 223900, 223901,
                   227290, 224154, 224153, 228005, 228006, 224151, 225977, 230085, 226499)
UNION ALL
-- B2. inputevents and procedureevents items the ICU design reads by id. The
--     insulin, nutrition and dextrose items are discovered in section K and
--     never typed from memory; these are the ones whose ids are well known
--     (mimic-code uses the same vasopressor and ventilation ids).
SELECT
  'icu.inputevents',
  d.itemid,
  d.label,
  d.unitname,
  d.category,
  CASE d.itemid
    WHEN 223258 THEN 'insulin, regular (the drip item; boluses too)'
    WHEN 223259 THEN 'insulin, NPH'
    WHEN 223260 THEN 'insulin, glargine'
    WHEN 223261 THEN 'insulin, Humalog 75/25'
    WHEN 223262 THEN 'insulin, Humalog (lispro)'
    WHEN 225916 THEN 'TPN with lipids'
    WHEN 225917 THEN 'TPN without lipids'
    WHEN 221906 THEN 'norepinephrine'
    WHEN 221289 THEN 'epinephrine'
    WHEN 221662 THEN 'dopamine'
    WHEN 221653 THEN 'dobutamine'
    WHEN 222315 THEN 'vasopressin'
    WHEN 221749 THEN 'phenylephrine'
    WHEN 221986 THEN 'milrinone'
  END
FROM `physionet-data.mimiciv_3_1_icu.d_items` AS d
WHERE d.itemid IN (223258, 223259, 223260, 223261, 223262, 225916, 225917,
                   221906, 221289, 221662, 221653, 222315, 221749, 221986)
UNION ALL
SELECT
  'icu.procedureevents',
  d.itemid,
  d.label,
  d.unitname,
  d.category,
  CASE d.itemid
    WHEN 225792 THEN 'invasive ventilation (interval)'
    WHEN 225794 THEN 'non-invasive ventilation (interval)'
    WHEN 225441 THEN 'hemodialysis (interval; 5,131 rows in v3.1)'
    WHEN 225802 THEN 'dialysis, CRRT (interval; 5,399 rows)'
    WHEN 225803 THEN 'dialysis, CVVHD (dictionary only: 0 rows in v3.1)'
    WHEN 225805 THEN 'peritoneal dialysis (interval; 792 rows)'
    WHEN 225809 THEN 'dialysis, CVVHDF (dictionary only: 0 rows)'
    WHEN 225955 THEN 'dialysis, SCUF (dictionary only: 0 rows)'
  END
FROM `physionet-data.mimiciv_3_1_icu.d_items` AS d
WHERE d.itemid IN (225792, 225794, 225441, 225802, 225803, 225805, 225809, 225955)
ORDER BY module, itemid;


-- C. The emar_detail data model: which fields live on the parent row
--    (parent_field_ordinal IS NULL, the order-level summary) and which on the
--    child rows (one per product given). On MIMIC-IV v3.1 the parent row has
--    NO dose_given at all; doses, route and infusion rate are on the children,
--    1.0008 children per administration. 01 therefore sums the children.
SELECT
  d.parent_field_ordinal IS NULL AS is_parent_row,
  COUNT(*)                                                  AS rows_,
  COUNT(DISTINCT d.emar_id)                                 AS distinct_emar_ids,
  COUNTIF(d.dose_due IS NOT NULL)                           AS has_dose_due,
  COUNTIF(d.dose_given IS NOT NULL)                         AS has_dose_given,
  COUNTIF(SAFE_CAST(d.dose_given AS FLOAT64) IS NOT NULL)   AS has_numeric_dose_given,
  COUNTIF(d.route IS NOT NULL)                              AS has_route,
  COUNTIF(d.infusion_rate IS NOT NULL)                      AS has_infusion_rate,
  COUNTIF(d.product_description IS NOT NULL)                AS has_product_description,
  COUNTIF(d.administration_type IS NOT NULL)                AS has_administration_type
FROM `physionet-data.mimiciv_3_1_hosp.emar`        AS e
JOIN `physionet-data.mimiciv_3_1_hosp.emar_detail` AS d USING (emar_id)
WHERE LOWER(e.medication) LIKE '%insulin%'
GROUP BY 1;


-- D. The event_txt vocabulary for hypoglycemic agents, with the way 01 will
--    classify each value. Five flags, read them against clinical sense:
--      bolus_given     a dose entered the patient at this time
--      infusion_start  an insulin drip began / restarted (opens an interval)
--      infusion_stop   a drip ended (closes an interval)
--      held            a due dose was not given for a clinical reason
--      ss_no_dose      sliding-scale check, glucose below the scale, nothing due
--    Note there is no "Rate Change" for insulin in eMAR; drips are intervals.
SELECT
  e.event_txt,
  COUNT(*) AS n,
  REGEXP_CONTAINS(LOWER(COALESCE(e.event_txt, '')), r'administered|confirmed')
    AND NOT REGEXP_CONTAINS(LOWER(COALESCE(e.event_txt, '')), r'\bnot\b')              AS bolus_given,
  REGEXP_CONTAINS(LOWER(COALESCE(e.event_txt, '')), r'\bstarted|restarted')
    AND NOT REGEXP_CONTAINS(LOWER(COALESCE(e.event_txt, '')), r'\bnot\b')              AS infusion_start,
  REGEXP_CONTAINS(LOWER(COALESCE(e.event_txt, '')), r'stopped')
    AND NOT REGEXP_CONTAINS(LOWER(COALESCE(e.event_txt, '')), r'\bnot\b')              AS infusion_stop,
  (REGEXP_CONTAINS(LOWER(COALESCE(e.event_txt, '')), r'not given')
     AND NOT REGEXP_CONTAINS(LOWER(COALESCE(e.event_txt, '')), r'sliding scale'))
    OR REGEXP_CONTAINS(LOWER(COALESCE(e.event_txt, '')), r'hold dose')                 AS held,
  REGEXP_CONTAINS(LOWER(COALESCE(e.event_txt, '')), r'not given per sliding scale')    AS ss_no_dose
FROM `physionet-data.mimiciv_3_1_hosp.emar` AS e
WHERE REGEXP_CONTAINS(LOWER(e.medication),
        r'insulin|glipizide|glyburide|glibenclamide|glimepiride|tolbutamide|chlorpropamide|tolazamide|repaglinide|nateglinide')
GROUP BY e.event_txt
ORDER BY n DESC;


-- D2. What the ambiguous event_txt values are attached to. "Confirmed" is
--     counted as a bolus given on the assumption that it marks self-administered
--     medication (insulin pumps, oral agents from home supply). If the
--     medications below say otherwise, delete "|confirmed" from the regex in
--     01_cohort_labels.sql. Up to 8 medication strings per value, by count.
SELECT event_txt, medication, n
FROM (
  SELECT e.event_txt, e.medication, COUNT(*) AS n,
         ROW_NUMBER() OVER (PARTITION BY e.event_txt ORDER BY COUNT(*) DESC) AS rn
  FROM `physionet-data.mimiciv_3_1_hosp.emar` AS e
  WHERE REGEXP_CONTAINS(LOWER(e.medication),
          r'insulin|glipizide|glyburide|glibenclamide|glimepiride|tolbutamide|chlorpropamide|tolazamide|repaglinide|nateglinide')
    AND (e.event_txt IS NULL
         OR e.event_txt IN ('Confirmed', 'Delayed Confirmed', 'Confirmed in Other Location',
                            ' in Other Location', 'Delayed ', 'Documented in O.R. Holding',
                            'Partial Administered', 'Started', 'Restarted'))
  GROUP BY e.event_txt, e.medication
)
WHERE rn <= 8
ORDER BY event_txt, n DESC;


-- E. anchor_year_group spelling (the era filter in 01 matches these strings exactly)
SELECT anchor_year_group, COUNT(*) AS patients
FROM `physionet-data.mimiciv_3_1_hosp.patients`
GROUP BY 1
ORDER BY 1;


-- F. Insulin infusion intervals as eMAR records them (Started / Restarted to
--    the next Stopped, another Started, or discharge). In the hospital-wide
--    design this set the drip cap; in the ICU design the drip comes from
--    inputevents (every rate change, explicit end times) and this table is the
--    cross-check: section L compares the two sources per stay.
WITH ev AS (
  SELECT
    e.hadm_id, e.medication, e.charttime,
    LOWER(COALESCE(e.event_txt, '')) AS evt,
    a.dischtime
  FROM `physionet-data.mimiciv_3_1_hosp.emar`       AS e
  JOIN `physionet-data.mimiciv_3_1_hosp.admissions` AS a USING (hadm_id)
  WHERE REGEXP_CONTAINS(LOWER(e.medication), r'insulin')
    AND e.charttime IS NOT NULL
    AND REGEXP_CONTAINS(LOWER(COALESCE(e.event_txt, '')), r'\bstarted|restarted|stopped')
    AND NOT REGEXP_CONTAINS(LOWER(COALESCE(e.event_txt, '')), r'\bnot\b')
),
seq AS (
  SELECT *,
         REGEXP_CONTAINS(evt, r'\bstarted|restarted')                          AS is_start,
         LEAD(charttime) OVER w                                                AS next_time,
         LEAD(REGEXP_CONTAINS(evt, r'stopped')) OVER w                         AS next_is_stop
  FROM ev
  WINDOW w AS (PARTITION BY hadm_id, medication ORDER BY charttime)
),
intervals AS (
  SELECT
    CASE
      WHEN next_time IS NULL OR next_time > dischtime THEN 'no stop before discharge'
      WHEN next_is_stop                               THEN 'closed by Stopped'
      ELSE                                                 'closed by another Started'
    END AS how_closed,
    DATETIME_DIFF(LEAST(COALESCE(next_time, dischtime), dischtime), charttime, MINUTE) / 60.0 AS hours
  FROM seq
  WHERE is_start
)
SELECT
  how_closed,
  COUNT(*)                                    AS intervals,
  ROUND(AVG(hours), 1)                        AS mean_hours,
  APPROX_QUANTILES(hours, 100)[OFFSET(50)]    AS median_hours,
  APPROX_QUANTILES(hours, 100)[OFFSET(90)]    AS p90_hours,
  COUNTIF(hours > 96)                         AS over_96h,
  COUNTIF(hours > 168)                        AS over_168h
FROM intervals
GROUP BY how_closed
ORDER BY intervals DESC;


-- G. The 18,542 hypoglycemic-agent rows with event_txt IS NULL (0.7% of insulin
--    rows, 99.7% the generic "Insulin" string, i.e. sliding-scale orders).
--    Working hypothesis: a row generated when a dose was due but never acted
--    on or charted. The columns below test it: due-but-not-acted rows should be
--    scheduled, have no charttime / storetime, no child rows, no dose_due, and
--    sit on orders that do have charted rows. Child rows WITH doses would mean
--    something was given and the event text is missing, which would change
--    the rule in 01. A concentration in one era would point to a charting-
--    system transition. 01 currently treats these rows as nothing.
WITH null_events AS (
  SELECT e.emar_id, e.poe_id, e.subject_id, e.charttime, e.scheduletime, e.storetime, e.medication
  FROM `physionet-data.mimiciv_3_1_hosp.emar` AS e
  WHERE e.event_txt IS NULL
    AND REGEXP_CONTAINS(LOWER(e.medication),
          r'insulin|glipizide|glyburide|glibenclamide|glimepiride|tolbutamide|chlorpropamide|tolazamide|repaglinide|nateglinide')
),
detail AS (
  SELECT
    emar_id,
    COUNTIF(parent_field_ordinal IS NOT NULL)                                           AS n_child_rows,
    COUNTIF(parent_field_ordinal IS NOT NULL AND dose_given IS NOT NULL)                AS n_child_rows_with_dose,
    MAX(IF(parent_field_ordinal IS NULL, administration_type, NULL))                    AS administration_type,
    MAX(IF(parent_field_ordinal IS NULL, SAFE_CAST(dose_due AS FLOAT64), NULL))         AS dose_due
  FROM `physionet-data.mimiciv_3_1_hosp.emar_detail`
  WHERE emar_id IN (SELECT emar_id FROM null_events)
  GROUP BY emar_id
),
charted AS (
  SELECT poe_id, COUNT(*) AS n_charted_rows_same_order
  FROM `physionet-data.mimiciv_3_1_hosp.emar`
  WHERE event_txt IS NOT NULL
    AND poe_id IN (SELECT poe_id FROM null_events WHERE poe_id IS NOT NULL)
  GROUP BY poe_id
)
SELECT
  p.anchor_year_group,
  COUNT(*)                                                             AS rows_,
  ROUND(100 * COUNTIF(n.charttime IS NULL) / COUNT(*), 1)              AS pct_no_charttime,
  ROUND(100 * COUNTIF(n.scheduletime IS NOT NULL) / COUNT(*), 1)       AS pct_scheduled,
  ROUND(100 * COUNTIF(n.storetime IS NULL) / COUNT(*), 1)              AS pct_no_storetime,
  ROUND(100 * COUNTIF(d.n_child_rows > 0) / COUNT(*), 1)               AS pct_with_child_rows,
  ROUND(100 * COUNTIF(d.n_child_rows_with_dose > 0) / COUNT(*), 1)     AS pct_with_child_dose,
  ROUND(100 * COUNTIF(d.dose_due IS NOT NULL) / COUNT(*), 1)           AS pct_with_dose_due,
  ROUND(100 * COUNTIF(c.n_charted_rows_same_order > 0) / COUNT(*), 1)  AS pct_order_has_charted_rows,
  ROUND(100 * COUNTIF(n.medication = 'Insulin') / COUNT(*), 1)         AS pct_generic_insulin,
  ANY_VALUE(d.administration_type)                                     AS example_administration_type
FROM null_events AS n
JOIN `physionet-data.mimiciv_3_1_hosp.patients` AS p USING (subject_id)
LEFT JOIN detail  AS d USING (emar_id)
LEFT JOIN charted AS c USING (poe_id)
GROUP BY p.anchor_year_group
ORDER BY p.anchor_year_group;


-- =====================================================================
-- H. Value-domain checks for the assumptions 02 and 03 still make from
--    memory: units, code formats and the exact strings the filters use.
--    Five read-only tables. Nothing downstream changes unless one of them
--    contradicts a comment below.
-- =====================================================================

-- H1. Lab units per itemid. 02 uses valuenum as-is, so every analyte must be
--     charted in one unit: glucose mg/dL, creatinine mg/dL, potassium mEq/L,
--     lactate mmol/L, HbA1c %, hemoglobin g/dL, platelets K/uL, INR unitless.
--     A second unit with a material share means a conversion is missing.
SELECT
  le.itemid,
  ANY_VALUE(d.label)                       AS label,
  le.valueuom,
  COUNT(*)                                 AS results,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY le.itemid), 1) AS pct_of_itemid,
  COUNTIF(le.valuenum IS NULL)             AS null_valuenum,
  APPROX_QUANTILES(le.valuenum, 100)[OFFSET(1)]  AS p01,
  APPROX_QUANTILES(le.valuenum, 100)[OFFSET(50)] AS p50,
  APPROX_QUANTILES(le.valuenum, 100)[OFFSET(99)] AS p99
FROM `physionet-data.mimiciv_3_1_hosp.labevents`  AS le
JOIN `physionet-data.mimiciv_3_1_hosp.d_labitems` AS d USING (itemid)
WHERE le.itemid IN (50931, 50809, 52569,
                    50912, 51006, 50862, 50983, 50971, 50882, 50813,
                    51301, 51222, 51221, 51265, 50878, 50861, 50885, 51237,
                    50902, 50868, 50893, 50960, 50970, 50852)
GROUP BY le.itemid, le.valueuom
ORDER BY le.itemid, results DESC;


-- H2. ICU chart units and ranges per itemid. 223761 must read like Fahrenheit
--     (p50 near 98) and 223762 like Celsius (p50 near 37), because 02 converts
--     223761 with (F - 32) * 5 / 9. Glucose p01 / p99 show whether the
--     fingerstick stream carries implausible values that need clipping.
--     Weight items must read in kg (p50 near 80) and the three GCS components
--     in their 1 to 4 / 1 to 5 / 1 to 6 ranges; 02 sums them.
SELECT
  ce.itemid,
  ANY_VALUE(d.label)                       AS label,
  ce.valueuom,
  COUNT(*)                                 AS results,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY ce.itemid), 1) AS pct_of_itemid,
  APPROX_QUANTILES(ce.valuenum, 100)[OFFSET(1)]  AS p01,
  APPROX_QUANTILES(ce.valuenum, 100)[OFFSET(50)] AS p50,
  APPROX_QUANTILES(ce.valuenum, 100)[OFFSET(99)] AS p99,
  MIN(ce.valuenum)                         AS min_value,
  MAX(ce.valuenum)                         AS max_value
FROM `physionet-data.mimiciv_3_1_icu.chartevents` AS ce
JOIN `physionet-data.mimiciv_3_1_icu.d_items`     AS d USING (itemid)
WHERE ce.itemid IN (220621, 225664, 226537,
                    220045, 220179, 220050, 220210, 220277, 223761, 223762,
                    226512, 224639, 220739, 223900, 223901)
  AND ce.valuenum IS NOT NULL
GROUP BY ce.itemid, ce.valueuom
ORDER BY ce.itemid, results DESC;


-- H3. ICD code formats. 02's history regexes assume codes are stored without
--     the decimal point ('E1165', '25000'). dotted_codes must be 0, and every
--     pattern should match a plausible number of rows and distinct codes.
WITH dx AS (
  SELECT icd_version, icd_code
  FROM `physionet-data.mimiciv_3_1_hosp.diagnoses_icd`
)
SELECT 'any code with a dot' AS pattern, NULL AS icd_version,
       COUNTIF(REGEXP_CONTAINS(icd_code, r'\.')) AS rows_, NULL AS distinct_codes, NULL AS min_code, NULL AS max_code
FROM dx
UNION ALL
SELECT 'diabetes ICD-9 250%', 9, COUNT(*), COUNT(DISTINCT icd_code), MIN(icd_code), MAX(icd_code)
FROM dx WHERE icd_version = 9 AND icd_code LIKE '250%'
UNION ALL
SELECT 'diabetes ICD-10 E10/E11/E13', 10, COUNT(*), COUNT(DISTINCT icd_code), MIN(icd_code), MAX(icd_code)
FROM dx WHERE icd_version = 10 AND REGEXP_CONTAINS(icd_code, r'^E1[013]')
UNION ALL
SELECT 'hypoglycemia ICD-9 251.0-251.2', 9, COUNT(*), COUNT(DISTINCT icd_code), MIN(icd_code), MAX(icd_code)
FROM dx WHERE icd_version = 9 AND REGEXP_CONTAINS(icd_code, r'^251[012]')
UNION ALL
SELECT 'hypoglycemia ICD-10 E16.0-2 / E1x.64x', 10, COUNT(*), COUNT(DISTINCT icd_code), MIN(icd_code), MAX(icd_code)
FROM dx WHERE icd_version = 10 AND REGEXP_CONTAINS(icd_code, r'^E16[012]|^E1[013]64')
UNION ALL
SELECT 'CKD ICD-9 585% / ICD-10 N18%', NULL, COUNT(*), COUNT(DISTINCT icd_code), MIN(icd_code), MAX(icd_code)
FROM dx WHERE (icd_version = 9 AND icd_code LIKE '585%') OR (icd_version = 10 AND icd_code LIKE 'N18%')
UNION ALL
SELECT 'liver ICD-9 571% / ICD-10 K70-K77', NULL, COUNT(*), COUNT(DISTINCT icd_code), MIN(icd_code), MAX(icd_code)
FROM dx WHERE (icd_version = 9 AND icd_code LIKE '571%') OR (icd_version = 10 AND REGEXP_CONTAINS(icd_code, r'^K7[0-7]'))
UNION ALL
SELECT 'heart failure ICD-9 428% / ICD-10 I50%', NULL, COUNT(*), COUNT(DISTINCT icd_code), MIN(icd_code), MAX(icd_code)
FROM dx WHERE (icd_version = 9 AND icd_code LIKE '428%') OR (icd_version = 10 AND icd_code LIKE 'I50%')
ORDER BY pattern;


-- H4. omr result names. 02 reads 'BMI (kg/m2)' and 'Weight (Lbs)' literally and
--     converts pounds to kg. If weight also appears in kg, or BMI under another
--     spelling, the filter in 02 needs those strings too.
SELECT
  result_name,
  COUNT(*)                                                   AS rows_,
  COUNTIF(SAFE_CAST(result_value AS FLOAT64) IS NOT NULL)    AS numeric_values,
  APPROX_QUANTILES(SAFE_CAST(result_value AS FLOAT64), 100)[OFFSET(50)] AS p50
FROM `physionet-data.mimiciv_3_1_hosp.omr`
GROUP BY result_name
ORDER BY rows_ DESC
LIMIT 15;


-- H5. transfers.eventtype and careunit, and services.curr_service. 02 keeps
--     eventtype != 'discharge' and expects the discharge row to carry no
--     careunit; the care-unit strings become a categorical feature, so their
--     cardinality matters (expect ~40 units, ~20 services).
SELECT 'transfers.eventtype' AS field, eventtype AS value, COUNT(*) AS rows_,
       COUNTIF(careunit IS NULL) AS rows_with_null_careunit
FROM `physionet-data.mimiciv_3_1_hosp.transfers`
GROUP BY eventtype
UNION ALL
SELECT 'transfers.careunit (distinct count as rows_)', 'all', COUNT(DISTINCT careunit), NULL
FROM `physionet-data.mimiciv_3_1_hosp.transfers`
UNION ALL
SELECT 'services.curr_service', curr_service, COUNT(*), NULL
FROM `physionet-data.mimiciv_3_1_hosp.services`
GROUP BY curr_service
ORDER BY field, rows_ DESC;


-- H6. Where the glucose values sit below 54 and above 300, per item. A true
--     hypoglycemia distribution thins out smoothly as values fall; a pile-up
--     in the 10-19 or 0-9 buckets, or a bucket that is mostly cancelled by the
--     5-minute repeat rule, points to meter "LO" readings or mmol/L entries
--     typed as mg/dL. This decides GLUCOSE_MIN in 01 (default 10). The upper
--     buckets do the same job for the > 300 label: the tail should thin from
--     301-399 through 400-599 to 600-1000, and anything above 1000 is where
--     the meter "HI" readings and typing errors live (GLUCOSE_MAX = 2000).
WITH g AS (
  SELECT 'hosp.labevents' AS module, itemid, valuenum AS v
  FROM `physionet-data.mimiciv_3_1_hosp.labevents`
  WHERE itemid IN (50931, 50809, 52569) AND valuenum IS NOT NULL
  UNION ALL
  SELECT 'icu.chartevents', itemid, valuenum
  FROM `physionet-data.mimiciv_3_1_icu.chartevents`
  WHERE itemid IN (220621, 225664, 226537) AND valuenum IS NOT NULL
)
SELECT
  module, itemid,
  COUNT(*)                          AS results,
  COUNTIF(v < 0)                    AS below_0,
  COUNTIF(v = 0)                    AS exactly_0,
  COUNTIF(v > 0  AND v < 10)        AS from_0_to_9,
  COUNTIF(v >= 10 AND v < 20)       AS from_10_to_19,
  COUNTIF(v >= 20 AND v < 30)       AS from_20_to_29,
  COUNTIF(v >= 30 AND v < 40)       AS from_30_to_39,
  COUNTIF(v >= 40 AND v < 54)       AS from_40_to_53,
  COUNTIF(v >= 54 AND v < 70)       AS from_54_to_69,
  COUNTIF(v > 300 AND v < 400)      AS from_301_to_399,
  COUNTIF(v >= 400 AND v < 600)     AS from_400_to_599,
  COUNTIF(v >= 600 AND v <= 1000)   AS from_600_to_1000,
  COUNTIF(v > 1000 AND v <= 2000)   AS from_1001_to_2000,
  COUNTIF(v > 2000)                 AS above_2000
FROM g
GROUP BY module, itemid
ORDER BY module, itemid;


-- H7. Extremes of the lab panel. H1 showed one unit per analyte and sane
--     percentiles; this shows whether single absurd values exist (they would
--     distort the standardisation used by the logistic-regression arm).
SELECT
  le.itemid,
  ANY_VALUE(d.label)         AS label,
  COUNT(*)                   AS results,
  MIN(le.valuenum)           AS min_value,
  APPROX_QUANTILES(le.valuenum, 1000)[OFFSET(1)]   AS p001,
  APPROX_QUANTILES(le.valuenum, 1000)[OFFSET(999)] AS p999,
  MAX(le.valuenum)           AS max_value,
  COUNTIF(le.valuenum <= 0)  AS zero_or_negative
FROM `physionet-data.mimiciv_3_1_hosp.labevents`  AS le
JOIN `physionet-data.mimiciv_3_1_hosp.d_labitems` AS d USING (itemid)
WHERE le.itemid IN (50931, 50809, 52569,
                    50912, 51006, 50862, 50983, 50971, 50882, 50813,
                    51301, 51222, 51221, 51265, 50878, 50861, 50885, 51237,
                    50902, 50868, 50893, 50960, 50970, 50852)
  AND le.valuenum IS NOT NULL
GROUP BY le.itemid
ORDER BY le.itemid;


-- ---------------------------------------------------------------------
-- I. Dose value domain of the hypoglycemic agents. The first 01 run printed
--    a mean dose of 155,911,922,996 units for "Administered" insulin rows
--    (median-sized doses elsewhere), so dose_given carries at least one
--    barcode-sized value. 02 sums doses into insulin_basal_units_24h and
--    insulin_bolus_units_24h and 03 prints every dose, so the cap in 01
--    (DOSE_MAX_INSULIN_UNITS, DOSE_MAX_ANY) has to be read off this table:
--    the percentiles say what a real dose looks like, over_200 / over_1e7
--    say how many rows the caps remove. Child rows only (the parent row
--    never carries dose_given, section C). All eras.
-- ---------------------------------------------------------------------
WITH given AS (
  SELECT em.emar_id, LOWER(em.medication) AS med
  FROM `physionet-data.mimiciv_3_1_hosp.emar` AS em
  WHERE REGEXP_CONTAINS(LOWER(em.medication),
          r'insulin|glipizide|glyburide|glibenclamide|glimepiride|tolbutamide|chlorpropamide|tolazamide|repaglinide|nateglinide')
    AND REGEXP_CONTAINS(LOWER(COALESCE(em.event_txt, '')), r'administered|confirmed')
    AND NOT REGEXP_CONTAINS(LOWER(COALESCE(em.event_txt, '')), r'\bnot\b')
),
doses AS (
  SELECT
    IF(REGEXP_CONTAINS(g.med, r'insulin'), 'insulin', 'oral agent') AS drug_class,
    LOWER(d.dose_given_unit)                                        AS unit,
    SAFE_CAST(d.dose_given AS FLOAT64)                              AS dose
  FROM given AS g
  JOIN `physionet-data.mimiciv_3_1_hosp.emar_detail` AS d USING (emar_id)
  WHERE d.parent_field_ordinal IS NOT NULL
    AND d.dose_given IS NOT NULL
)
SELECT
  drug_class,
  unit,
  COUNT(*)                                        AS child_rows,
  COUNTIF(dose IS NULL)                           AS non_numeric,
  APPROX_QUANTILES(dose, 1000)[OFFSET(500)]       AS p50,
  APPROX_QUANTILES(dose, 1000)[OFFSET(900)]       AS p90,
  APPROX_QUANTILES(dose, 1000)[OFFSET(990)]       AS p99,
  APPROX_QUANTILES(dose, 1000)[OFFSET(999)]       AS p999,
  MAX(dose)                                       AS max_dose,
  COUNTIF(dose <= 0)                              AS zero_or_negative,
  COUNTIF(dose > 100)                             AS over_100,
  COUNTIF(dose > 200)                             AS over_200,
  COUNTIF(dose > 1000)                            AS over_1000,
  COUNTIF(dose >= 10000000)                       AS over_1e7
FROM doses
GROUP BY drug_class, unit
HAVING COUNT(*) >= 100
ORDER BY drug_class, child_rows DESC;


-- ---------------------------------------------------------------------
-- J. Every glucose-like item in both dictionaries, with its result count.
--    The first 01 run found 0.66% of at-risk days with a result below
--    54 mg/dL, well below what studies built on fingerstick meter data
--    report. If MIMIC-IV held ward point-of-care glucose, it
--    would appear here as a hosp item with millions of results. The label
--    stream (50931, 50809, 52569, 220621, 225664, 226537) must cover every
--    item this table shows with a material count.
-- ---------------------------------------------------------------------
SELECT 'hosp.labevents' AS module, d.itemid, d.label, d.fluid AS fluid_or_category, d.category AS category_or_type,
       COUNT(le.labevent_id) AS results
FROM `physionet-data.mimiciv_3_1_hosp.d_labitems` AS d
LEFT JOIN `physionet-data.mimiciv_3_1_hosp.labevents` AS le USING (itemid)
WHERE REGEXP_CONTAINS(LOWER(d.label), r'gluc|finger|point of care|\bpoc\b')
GROUP BY d.itemid, d.label, d.fluid, d.category
UNION ALL
SELECT 'icu.chartevents', d.itemid, d.label, d.category, d.param_type,
       COUNT(ce.charttime)
FROM `physionet-data.mimiciv_3_1_icu.d_items` AS d
LEFT JOIN `physionet-data.mimiciv_3_1_icu.chartevents` AS ce USING (itemid)
WHERE REGEXP_CONTAINS(LOWER(d.label), r'gluc|finger')
  AND d.linksto = 'chartevents'
GROUP BY d.itemid, d.label, d.category, d.param_type
ORDER BY module, results DESC;


-- =====================================================================
-- ICU design: the inputevents sources. Every id below is discovered from
-- d_items and counted, so 01 and 02 read the same label patterns and never
-- a remembered number.
-- =====================================================================

-- K. inputevents items for insulin, dextrose and nutrition, with how 01 will
--    class each one (planned_class). Hypotheses: the insulin items are
--    223258 (regular, the drip item) and its siblings; dextrose 50% is its
--    own item (rescue); other dextrose-containing fluids are maintenance
--    fluids; enteral and parenteral nutrition carry their own categories.
--    An item with a material count and no planned_class means 01 is blind to
--    it; an item classed wrongly means the regex needs a word.
WITH counts AS (
  SELECT itemid,
         COUNT(*)                   AS rows_,
         COUNT(DISTINCT stay_id)    AS stays,
         COUNTIF(rate IS NOT NULL)  AS rows_with_rate
  FROM `physionet-data.mimiciv_3_1_icu.inputevents`
  GROUP BY itemid
)
SELECT
  d.itemid, d.label, d.category, d.unitname,
  c.rows_, c.stays, c.rows_with_rate,
  -- the same order 01 uses: the category decides nutrition before a label
  -- regex can misread "Boost Glucose Control" or "Dextrose PN"
  CASE
    WHEN REGEXP_CONTAINS(LOWER(d.label), r'insulin')                                    THEN 'insulin'
    WHEN REGEXP_CONTAINS(LOWER(d.label), r'dextrose 50|\bd50')                          THEN 'dextrose 50% (rescue)'
    WHEN REGEXP_CONTAINS(LOWER(COALESCE(d.category, '')), r'parenteral')
      OR REGEXP_CONTAINS(LOWER(d.label), r'\btpn')                                      THEN 'parenteral nutrition'
    WHEN REGEXP_CONTAINS(LOWER(COALESCE(d.category, '')), r'enteral')                   THEN 'enteral nutrition'
    WHEN REGEXP_CONTAINS(LOWER(d.label), r'dextrose|\bd5|\bd10|\bd20|\bd30|glucose')    THEN 'dextrose-containing fluid'
    WHEN REGEXP_CONTAINS(LOWER(COALESCE(d.category, '')), r'nutrition')                 THEN 'nutrition, other'
  END AS planned_class
FROM `physionet-data.mimiciv_3_1_icu.d_items` AS d
LEFT JOIN counts AS c USING (itemid)
WHERE d.linksto = 'inputevents'
  AND (REGEXP_CONTAINS(LOWER(d.label), r'insulin|dextrose|glucose|\btpn|\bd5|\bd10|\bd50')
       OR REGEXP_CONTAINS(LOWER(COALESCE(d.category, '')), r'nutrition|parenteral|enteral'))
ORDER BY planned_class, rows_ DESC;


-- K1. The inputevents category vocabulary (MetaVision order categories), so
--     the nutrition classes above are read off real category strings.
SELECT
  d.category,
  COUNT(DISTINCT d.itemid) AS items,
  COUNT(ie.itemid)         AS rows_
FROM `physionet-data.mimiciv_3_1_icu.d_items` AS d
LEFT JOIN `physionet-data.mimiciv_3_1_icu.inputevents` AS ie USING (itemid)
WHERE d.linksto = 'inputevents'
GROUP BY d.category
ORDER BY rows_ DESC;


-- K2. How insulin is charted in inputevents: order category, rate and amount
--     units, status, and the value ranges. Hypotheses 01 encodes:
--       * a drip is a row with a rate in units per hour (rateuom says hour)
--         and ordercategorydescription "Continuous Med"; a bolus is a row
--         with an amount in units and no rate;
--       * statusdescription "Rewritten" marks a row superseded by a corrected
--         one and is excluded (originalrate / originalamount keep the old
--         values on the replacement row);
--       * rates above DRIP_RATE_MAX units/h and amounts above
--         DOSE_MAX_INSULIN_UNITS are charting errors (read the maxima).
SELECT
  d.label,
  ie.ordercategorydescription,
  ie.rateuom,
  ie.amountuom,
  ie.statusdescription,
  COUNT(*)                                              AS rows_,
  COUNTIF(ie.rate IS NOT NULL)                          AS rows_with_rate,
  APPROX_QUANTILES(ie.rate, 100)[OFFSET(50)]            AS rate_p50,
  APPROX_QUANTILES(ie.rate, 100)[OFFSET(99)]            AS rate_p99,
  MAX(ie.rate)                                          AS rate_max,
  APPROX_QUANTILES(ie.amount, 100)[OFFSET(50)]          AS amount_p50,
  APPROX_QUANTILES(ie.amount, 100)[OFFSET(99)]          AS amount_p99,
  MAX(ie.amount)                                        AS amount_max,
  ROUND(AVG(DATETIME_DIFF(ie.endtime, ie.starttime, MINUTE)) / 60.0, 2) AS mean_hours
FROM `physionet-data.mimiciv_3_1_icu.inputevents` AS ie
JOIN `physionet-data.mimiciv_3_1_icu.d_items`     AS d USING (itemid)
WHERE REGEXP_CONTAINS(LOWER(d.label), r'insulin')
GROUP BY d.label, ie.ordercategorydescription, ie.rateuom, ie.amountuom, ie.statusdescription
HAVING COUNT(*) >= 100
ORDER BY rows_ DESC;


-- L. Do eMAR and inputevents record the same insulin? Both exist for ICU
--    patients. Hypotheses: a subcutaneous dose in the ICU is charted in both
--    (so 01 must count it once: eMAR first, inputevents only when no eMAR
--    insulin bolus sits within 60 minutes); a drip appears as Started /
--    Stopped in eMAR and as rate segments in inputevents. The match
--    percentages say how true that is; the de-duplication rule in 01 is
--    read off this table.
WITH stays AS (
  SELECT stay_id, hadm_id, intime, outtime
  FROM `physionet-data.mimiciv_3_1_icu.icustays`
),
emar_sc AS (
  SELECT s.stay_id, e.charttime
  FROM `physionet-data.mimiciv_3_1_hosp.emar` AS e
  JOIN stays AS s
    ON s.hadm_id = e.hadm_id
   AND e.charttime >= s.intime
   AND e.charttime <  s.outtime
  WHERE REGEXP_CONTAINS(LOWER(e.medication), r'insulin')
    AND REGEXP_CONTAINS(LOWER(COALESCE(e.event_txt, '')), r'administered|confirmed')
    AND NOT REGEXP_CONTAINS(LOWER(COALESCE(e.event_txt, '')), r'\bnot\b')
),
ie_rows AS (
  SELECT ie.stay_id, ie.starttime,
         ie.rate IS NOT NULL AND REGEXP_CONTAINS(LOWER(COALESCE(ie.rateuom, '')), r'hour|min') AS is_drip
  FROM `physionet-data.mimiciv_3_1_icu.inputevents` AS ie
  JOIN `physionet-data.mimiciv_3_1_icu.d_items`     AS d USING (itemid)
  WHERE REGEXP_CONTAINS(LOWER(d.label), r'insulin')
    AND COALESCE(ie.statusdescription, '') != 'Rewritten'
),
ie_bolus AS (SELECT stay_id, starttime AS charttime FROM ie_rows WHERE NOT is_drip),
matched_emar AS (
  SELECT e.stay_id, e.charttime, MAX(IF(i.stay_id IS NULL, 0, 1)) AS has_match
  FROM emar_sc AS e
  LEFT JOIN ie_bolus AS i
    ON i.stay_id = e.stay_id
   AND ABS(DATETIME_DIFF(i.charttime, e.charttime, MINUTE)) <= 60
  GROUP BY e.stay_id, e.charttime
),
matched_ie AS (
  SELECT i.stay_id, i.charttime, MAX(IF(e.stay_id IS NULL, 0, 1)) AS has_match
  FROM ie_bolus AS i
  LEFT JOIN emar_sc AS e
    ON e.stay_id = i.stay_id
   AND ABS(DATETIME_DIFF(e.charttime, i.charttime, MINUTE)) <= 60
  GROUP BY i.stay_id, i.charttime
),
drip_emar AS (
  SELECT DISTINCT s.stay_id
  FROM `physionet-data.mimiciv_3_1_hosp.emar` AS e
  JOIN stays AS s
    ON s.hadm_id = e.hadm_id
   AND e.charttime >= s.intime
   AND e.charttime <  s.outtime
  WHERE REGEXP_CONTAINS(LOWER(e.medication), r'insulin')
    AND REGEXP_CONTAINS(LOWER(COALESCE(e.event_txt, '')), r'\bstarted|restarted')
    AND NOT REGEXP_CONTAINS(LOWER(COALESCE(e.event_txt, '')), r'\bnot\b')
),
drip_ie AS (SELECT DISTINCT stay_id FROM ie_rows WHERE is_drip)
SELECT 'eMAR insulin boluses inside ICU stays' AS what,
       COUNT(*) AS rows_, ROUND(100 * AVG(has_match), 1) AS pct_matched_in_other_source
FROM matched_emar
UNION ALL
SELECT 'inputevents insulin boluses (rows without a rate)',
       COUNT(*), ROUND(100 * AVG(has_match), 1)
FROM matched_ie
UNION ALL
SELECT 'stays with an insulin drip in eMAR (Started)',
       COUNT(*), ROUND(100 * COUNTIF(i.stay_id IS NOT NULL) / COUNT(*), 1)
FROM drip_emar AS e LEFT JOIN drip_ie AS i USING (stay_id)
UNION ALL
SELECT 'stays with an insulin drip in inputevents (rate rows)',
       COUNT(*), ROUND(100 * COUNTIF(e.stay_id IS NOT NULL) / COUNT(*), 1)
FROM drip_ie AS i LEFT JOIN drip_emar AS e USING (stay_id)
ORDER BY what;


-- L2. The same bolus match at four windows. The first run matched 46% of
--     eMAR boluses within 60 minutes and 38% of inputevents boluses. If the
--     match rate climbs steeply with the window, the two sources record the
--     same doses with an offset (widen SOURCE_MATCH_MINUTES); if it is flat,
--     they record different doses and the union is right.
WITH stays AS (
  SELECT stay_id, hadm_id, intime, outtime
  FROM `physionet-data.mimiciv_3_1_icu.icustays`
),
emar_sc AS (
  SELECT s.stay_id, e.charttime
  FROM `physionet-data.mimiciv_3_1_hosp.emar` AS e
  JOIN stays AS s
    ON s.hadm_id = e.hadm_id
   AND e.charttime >= s.intime
   AND e.charttime <  s.outtime
  WHERE REGEXP_CONTAINS(LOWER(e.medication), r'insulin')
    AND REGEXP_CONTAINS(LOWER(COALESCE(e.event_txt, '')), r'administered|confirmed')
    AND NOT REGEXP_CONTAINS(LOWER(COALESCE(e.event_txt, '')), r'\bnot\b')
),
ie_bolus AS (
  SELECT ie.stay_id, ie.starttime AS charttime
  FROM `physionet-data.mimiciv_3_1_icu.inputevents` AS ie
  JOIN `physionet-data.mimiciv_3_1_icu.d_items`     AS d USING (itemid)
  WHERE REGEXP_CONTAINS(LOWER(d.label), r'insulin')
    AND COALESCE(ie.statusdescription, '') != 'Rewritten'
    AND NOT REGEXP_CONTAINS(LOWER(COALESCE(ie.ordercategorydescription, '')), r'continuous')
    AND ie.rate IS NULL
),
nearest AS (
  SELECT e.stay_id, e.charttime,
         MIN(ABS(DATETIME_DIFF(i.charttime, e.charttime, MINUTE))) AS gap_min
  FROM emar_sc AS e
  LEFT JOIN ie_bolus AS i
    ON i.stay_id = e.stay_id
   AND ABS(DATETIME_DIFF(i.charttime, e.charttime, MINUTE)) <= 720
  GROUP BY e.stay_id, e.charttime
)
SELECT
  COUNT(*)                                             AS emar_boluses_in_icu,
  ROUND(100 * COUNTIF(gap_min <= 30)  / COUNT(*), 1)   AS pct_matched_30min,
  ROUND(100 * COUNTIF(gap_min <= 60)  / COUNT(*), 1)   AS pct_matched_60min,
  ROUND(100 * COUNTIF(gap_min <= 120) / COUNT(*), 1)   AS pct_matched_120min,
  ROUND(100 * COUNTIF(gap_min <= 240) / COUNT(*), 1)   AS pct_matched_240min,
  ROUND(100 * COUNTIF(gap_min <= 720) / COUNT(*), 1)   AS pct_matched_720min
FROM nearest;


-- M. The ICU landmark grid. Landmarks are intime + 24k h while the patient is
--    still in the ICU, so the length-of-stay distribution fixes how many rows
--    a stay contributes and whether MAX_K = 14 wastes anything. Stays per
--    admission says how often one hospital stay holds several ICU stays
--    (each is its own landmark series; history features still use hadm_id).
WITH s AS (
  SELECT
    stay_id, hadm_id,
    DATETIME_DIFF(outtime, intime, MINUTE) / 60.0        AS los_h,
    COUNT(*) OVER (PARTITION BY hadm_id)                 AS stays_in_admission
  FROM `physionet-data.mimiciv_3_1_icu.icustays`
  WHERE outtime > intime
)
SELECT
  COUNT(*)                                                       AS stays,
  COUNT(DISTINCT hadm_id)                                        AS admissions,
  ROUND(100 * COUNTIF(stays_in_admission > 1) / COUNT(*), 1)     AS pct_stays_in_multi_stay_admissions,
  APPROX_QUANTILES(los_h, 100)[OFFSET(50)]                       AS median_los_h,
  APPROX_QUANTILES(los_h, 100)[OFFSET(90)]                       AS p90_los_h,
  ROUND(100 * COUNTIF(los_h >= 24) / COUNT(*), 1)                AS pct_24h_plus,
  ROUND(100 * COUNTIF(los_h >= 48) / COUNT(*), 1)                AS pct_48h_plus,
  ROUND(100 * COUNTIF(los_h >= 72) / COUNT(*), 1)                AS pct_72h_plus,
  ROUND(100 * COUNTIF(los_h >= 168) / COUNT(*), 1)               AS pct_7d_plus,
  ROUND(100 * COUNTIF(los_h >= 360) / COUNT(*), 1)               AS pct_15d_plus,
  SUM(LEAST(GREATEST(CAST(CEIL(los_h / 24.0) AS INT64) - 1, 0), 14)) AS landmark_rows_k_1_to_14,
  SUM(GREATEST(CAST(CEIL(los_h / 24.0) AS INT64) - 1 - 14, 0))       AS rows_lost_beyond_k_14
FROM s;


-- N. Feeds and dextrose in inputevents: units, rates, segment lengths and the
--    gaps between consecutive enteral segments. Hypotheses: enteral feeds are
--    charted as mL/hour segments that run for hours and stop for procedures;
--    TPN runs continuously; dextrose 50% is an amount, not a rate. 02 turns
--    these into running-at-landmark flags, hours in the last 24 h and feed
--    interruptions, so the units and the gap distribution must look like that.
WITH items AS (
  SELECT itemid,
    CASE
      WHEN REGEXP_CONTAINS(LOWER(label), r'dextrose 50|\bd50')                          THEN 'dextrose 50% (rescue)'
      WHEN REGEXP_CONTAINS(LOWER(COALESCE(category, '')), r'parenteral')
        OR REGEXP_CONTAINS(LOWER(label), r'\btpn')                                      THEN 'parenteral nutrition'
      WHEN REGEXP_CONTAINS(LOWER(COALESCE(category, '')), r'enteral')                   THEN 'enteral nutrition'
      WHEN REGEXP_CONTAINS(LOWER(label), r'dextrose|\bd5|\bd10|\bd20|\bd30|glucose')    THEN 'dextrose-containing fluid'
    END AS planned_class
  FROM `physionet-data.mimiciv_3_1_icu.d_items`
  WHERE linksto = 'inputevents'
    AND NOT REGEXP_CONTAINS(LOWER(label), r'insulin|ranitidine')
),
seg AS (
  SELECT i.planned_class, ie.stay_id, ie.starttime, ie.endtime, ie.rate, ie.rateuom, ie.amount, ie.amountuom,
         DATETIME_DIFF(ie.endtime, ie.starttime, MINUTE) / 60.0 AS hours
  FROM `physionet-data.mimiciv_3_1_icu.inputevents` AS ie
  JOIN items AS i USING (itemid)
  WHERE i.planned_class IS NOT NULL
    AND COALESCE(ie.statusdescription, '') != 'Rewritten'
)
SELECT
  planned_class, rateuom, amountuom,
  COUNT(*)                                        AS rows_,
  COUNT(DISTINCT stay_id)                         AS stays,
  COUNTIF(rate IS NULL)                           AS rows_no_rate,
  APPROX_QUANTILES(rate, 100)[OFFSET(50)]         AS rate_p50,
  APPROX_QUANTILES(rate, 100)[OFFSET(99)]         AS rate_p99,
  MAX(rate)                                       AS rate_max,
  APPROX_QUANTILES(amount, 100)[OFFSET(50)]       AS amount_p50,
  APPROX_QUANTILES(hours, 100)[OFFSET(50)]        AS hours_p50,
  APPROX_QUANTILES(hours, 100)[OFFSET(99)]        AS hours_p99,
  MAX(hours)                                      AS hours_max
FROM seg
GROUP BY planned_class, rateuom, amountuom
HAVING COUNT(*) >= 100
ORDER BY planned_class, rows_ DESC;


-- N2. Gaps between consecutive enteral feed segments of one stay. Contiguous
--     segments (gap <= 0) are rate changes; gaps of hours are interruptions,
--     the feature 02 calls enteral_interrupted_24h.
WITH items AS (
  SELECT itemid
  FROM `physionet-data.mimiciv_3_1_icu.d_items`
  WHERE linksto = 'inputevents'
    AND REGEXP_CONTAINS(LOWER(COALESCE(category, '')), r'enteral')
    AND NOT REGEXP_CONTAINS(LOWER(COALESCE(category, '')), r'parenteral')
),
seg AS (
  SELECT ie.stay_id, ie.starttime, ie.endtime
  FROM `physionet-data.mimiciv_3_1_icu.inputevents` AS ie
  JOIN items USING (itemid)
  WHERE COALESCE(ie.statusdescription, '') != 'Rewritten'
),
gaps AS (
  SELECT stay_id,
         DATETIME_DIFF(starttime, LAG(endtime) OVER (PARTITION BY stay_id ORDER BY starttime, endtime), MINUTE) / 60.0 AS gap_h
  FROM seg
)
SELECT
  COUNT(*)                                 AS segments_with_a_predecessor,
  COUNTIF(gap_h <= 0)                      AS contiguous_or_overlapping,
  COUNTIF(gap_h > 0  AND gap_h <= 1)       AS gap_up_to_1h,
  COUNTIF(gap_h > 1  AND gap_h <= 4)       AS gap_1_to_4h,
  COUNTIF(gap_h > 4  AND gap_h <= 24)      AS gap_4_to_24h,
  COUNTIF(gap_h > 24)                      AS gap_over_24h
FROM gaps
WHERE gap_h IS NOT NULL;


-- =====================================================================
-- Risk factors the first feature set lacked (Vriesendorp 2006: CVVH with
-- bicarbonate replacement fluid OR 14, sepsis OR 2.2; Krinsley 2007 and
-- Waeschle 2008: sepsis severity). Discovered from the dictionaries, as above.
-- =====================================================================

-- O. Renal replacement therapy. Hypothesis: dialysis is charted as
--    procedureevents intervals (Hemodialysis, Dialysis - CRRT, CVVHDF, CVVHD,
--    SCUF, Peritoneal Dialysis) with explicit start and end times; the CRRT
--    settings in chartevents (mode, replacement and dialysate rates) are
--    charted hourly while a filter runs. This table lists every item whose
--    label looks like dialysis in all three ICU event tables with rows and
--    stays, so a stay with hourly CRRT charting but no interval shows as a gap.
--    First run (10 Oct 2026): only three procedureevents items carry rows
--    (Dialysis - CRRT 5,399 rows / 2,274 stays, mean 56.5 h; Hemodialysis
--    5,131 / 2,746, mean 12.9 h; Peritoneal Dialysis 792 / 180); CVVHD, CVVHDF
--    and SCUF exist in the dictionary with 0 rows. Two label matches are NOT
--    dialysis and 01 excludes them: "Dialysis Catheter" (224270, an access
--    line that stays in for days, 4,464 stays) and "CRRT Filter Change"
--    (225436, a zero-length event). "Dialysis patient" (225126) is the
--    admission-history question, charted on 46,956 stays. CRRT settings are
--    charted on about 2,900 stays, more than the 2,274 with a CRRT interval,
--    and Hemodialysis Output (226499) on 3,225 stays against 2,746 with an
--    interval: both sources are needed, so 01 icu_rrt unions them (O2, O3).
WITH items AS (
  SELECT itemid, label, linksto, category
  FROM `physionet-data.mimiciv_3_1_icu.d_items`
  WHERE REGEXP_CONTAINS(LOWER(label), r'dialysis|crrt|cvvh|scuf|hemodialysis|dialysate|replacement rate|ultrafiltrat|effluent')
),
counts AS (
  SELECT itemid, COUNT(*) AS rows_, COUNT(DISTINCT stay_id) AS stays,
         ROUND(AVG(DATETIME_DIFF(endtime, starttime, MINUTE)) / 60.0, 1) AS mean_hours
  FROM `physionet-data.mimiciv_3_1_icu.procedureevents`
  GROUP BY itemid
  UNION ALL
  SELECT itemid, COUNT(*), COUNT(DISTINCT stay_id), NULL
  FROM `physionet-data.mimiciv_3_1_icu.chartevents`
  WHERE itemid IN (SELECT itemid FROM items WHERE linksto = 'chartevents')
  GROUP BY itemid
  UNION ALL
  SELECT itemid, COUNT(*), COUNT(DISTINCT stay_id), ROUND(AVG(DATETIME_DIFF(endtime, starttime, MINUTE)) / 60.0, 1)
  FROM `physionet-data.mimiciv_3_1_icu.inputevents`
  WHERE itemid IN (SELECT itemid FROM items WHERE linksto = 'inputevents')
  GROUP BY itemid
)
SELECT i.linksto, i.itemid, i.label, i.category, c.rows_, c.stays, c.mean_hours
FROM items AS i
LEFT JOIN counts AS c USING (itemid)
WHERE c.rows_ > 0
ORDER BY i.linksto, c.rows_ DESC;


-- O2. Coverage of the two RRT sources per stay, for CRRT and for intermittent
--     hemodialysis separately: stays with a procedureevents interval, stays
--     with the chartevents marker (hourly CRRT settings; a per-session
--     Hemodialysis Output), the overlap, and the stays each source misses.
--     The first run of this section matched "Dialysis Catheter" as an interval
--     and so understated the gap (630 CRRT stays); this version excludes the
--     catheter and filter-change items, as 01 does.
--     Corrected run (10 Oct 2026): CRRT: 2,274 stays with an interval, 2,927
--     with charting, 2,271 in both, 656 charting-only, 3 interval-only, so the
--     charting is a near-superset and the merge in 01 loses nothing.
--     Hemodialysis: 2,746 with an interval, 3,225 with an output charting,
--     2,075 in both, 1,150 output-only, 671 interval-only: the two sources
--     overlap on only 53% of their union, so both are kept.
WITH pe AS (
  SELECT DISTINCT p.stay_id,
         IF(REGEXP_CONTAINS(LOWER(d.label), r'crrt|cvvh|scuf'), 'crrt',
            IF(REGEXP_CONTAINS(LOWER(d.label), r'peritoneal'), 'pd', 'ihd')) AS kind
  FROM `physionet-data.mimiciv_3_1_icu.procedureevents` AS p
  JOIN `physionet-data.mimiciv_3_1_icu.d_items`         AS d USING (itemid)
  WHERE d.linksto = 'procedureevents'
    AND REGEXP_CONTAINS(LOWER(d.label), r'dialysis|crrt|cvvh|scuf')
    AND NOT REGEXP_CONTAINS(LOWER(d.label), r'catheter|filter change')
    AND p.endtime > p.starttime
),
ce AS (
  SELECT DISTINCT stay_id, IF(itemid = 226499, 'ihd', 'crrt') AS kind
  FROM `physionet-data.mimiciv_3_1_icu.chartevents`
  WHERE itemid IN (227290, 224154, 224153, 228005, 228006, 224151, 225977, 230085, 226499)
)
SELECT
  k.kind,
  (SELECT COUNT(*) FROM pe WHERE pe.kind = k.kind)                                                       AS stays_with_interval,
  (SELECT COUNT(*) FROM ce WHERE ce.kind = k.kind)                                                       AS stays_with_chart_marker,
  (SELECT COUNT(*) FROM pe JOIN ce USING (stay_id, kind) WHERE pe.kind = k.kind)                         AS stays_in_both,
  (SELECT COUNT(*) FROM ce LEFT JOIN pe USING (stay_id, kind) WHERE ce.kind = k.kind AND pe.stay_id IS NULL) AS chart_marker_without_interval,
  (SELECT COUNT(*) FROM pe LEFT JOIN ce USING (stay_id, kind) WHERE pe.kind = k.kind AND ce.stay_id IS NULL) AS interval_without_chart_marker
FROM (SELECT 'crrt' AS kind UNION ALL SELECT 'ihd') AS k
ORDER BY k.kind;


-- O3. Where the per-session Hemodialysis Output (226499) sits relative to the
--     Hemodialysis interval it belongs to, on stays that have both: 01 treats
--     an output charting with no interval as a one-minute marker of a session
--     in the look-back (rrt_24h, ihd_24h) and never as hours. If the output is
--     charted at the end of the interval the marker is well placed; if it is
--     charted hours later the marker lands in a later look-back than the session.
--     First run (10 Oct 2026; the two pct_within columns lacked the division
--     by the row count, fixed here): 4,949 output chartings on stays with
--     intervals, 38.2% inside an interval, 45.4% within 1 h of an interval
--     end, 52.5% within 4 h, p50 2.1 h from the nearest end, p90 96.7 h. Half
--     the outputs sit at a session the interval source also has; the other
--     half are days away from any interval, sessions the interval source
--     missed on stays it otherwise covers. The marker stays.
WITH hd AS (
  SELECT p.stay_id, p.starttime, p.endtime
  FROM `physionet-data.mimiciv_3_1_icu.procedureevents` AS p
  WHERE p.itemid = 225441 AND p.endtime > p.starttime
),
outp AS (
  SELECT stay_id, charttime
  FROM `physionet-data.mimiciv_3_1_icu.chartevents`
  WHERE itemid = 226499
),
nearest AS (
  SELECT o.stay_id, o.charttime,
         MIN(ABS(DATETIME_DIFF(o.charttime, h.endtime, MINUTE))) / 60.0 AS hours_from_nearest_interval_end,
         MAX(IF(o.charttime >= h.starttime AND o.charttime <= h.endtime, 1, 0))  AS inside_an_interval
  FROM outp AS o
  JOIN hd   AS h USING (stay_id)
  GROUP BY o.stay_id, o.charttime
)
SELECT
  COUNT(*)                                                                AS output_chartings_on_stays_with_intervals,
  ROUND(100 * AVG(inside_an_interval), 1)                                 AS pct_inside_an_interval,
  ROUND(100 * COUNTIF(hours_from_nearest_interval_end <= 1) / COUNT(*), 1) AS pct_within_1h_of_an_end,
  ROUND(100 * COUNTIF(hours_from_nearest_interval_end <= 4) / COUNT(*), 1) AS pct_within_4h_of_an_end,
  ROUND(APPROX_QUANTILES(hours_from_nearest_interval_end, 100)[OFFSET(50)], 1) AS p50_hours_from_end,
  ROUND(APPROX_QUANTILES(hours_from_nearest_interval_end, 100)[OFFSET(90)], 1) AS p90_hours_from_end
FROM nearest;


-- O4. Do the CRRT charting islands reproduce the CRRT intervals? On the 2,271
--     stays with both sources, hours of CRRT per stay from the procedureevents
--     intervals against hours from the charting collapsed with the 01 rule
--     (a new island after a gap over RRT_GAP_HOURS = 3 h, each island ending
--     one hour after its last charting). Hypothesis: the ratio sits near 1 for
--     most stays, so rrt_hours_24h means the same thing whichever source found
--     the interval. A ratio well above 1 says the islands bridge real pauses
--     (lower the gap); well below 1 says charting is sparser than hourly
--     (raise it or lengthen the tail).
--     First run (10 Oct 2026): 2,271 stays, p50 interval hours 87.7, p50
--     charting hours 82.8, ratio p10 0.66, p50 0.98, p90 1.12, 76.0% of stays
--     within 20%, 2.66 islands per stay. The rule stands at 3 h; the low tail
--     (a tenth of stays where charting covers two thirds of the interval or
--     less) is where the two sources disagree, and the merge takes the union.
WITH pe AS (
  SELECT p.stay_id, SUM(DATETIME_DIFF(p.endtime, p.starttime, MINUTE)) / 60.0 AS interval_hours
  FROM `physionet-data.mimiciv_3_1_icu.procedureevents` AS p
  WHERE p.itemid = 225802 AND p.endtime > p.starttime
  GROUP BY p.stay_id
),
ch AS (
  SELECT DISTINCT stay_id, charttime
  FROM `physionet-data.mimiciv_3_1_icu.chartevents`
  WHERE itemid IN (227290, 224154, 224153, 228005, 228006, 224151, 225977, 230085)
),
islands AS (
  SELECT stay_id, charttime,
         SUM(IF(prev_time IS NULL OR DATETIME_DIFF(charttime, prev_time, MINUTE) > 3 * 60, 1, 0))
           OVER (PARTITION BY stay_id ORDER BY charttime ROWS UNBOUNDED PRECEDING) AS island
  FROM (SELECT stay_id, charttime, LAG(charttime) OVER (PARTITION BY stay_id ORDER BY charttime) AS prev_time FROM ch)
),
per_island AS (
  SELECT stay_id, island, DATETIME_DIFF(MAX(charttime), MIN(charttime), MINUTE) / 60.0 + 1 AS island_hours
  FROM islands
  GROUP BY stay_id, island
),
island_hours AS (
  SELECT stay_id, SUM(island_hours) AS charting_hours, COUNT(*) AS n_islands
  FROM per_island
  GROUP BY stay_id
),
both_ AS (
  SELECT pe.stay_id, pe.interval_hours, ih.charting_hours, ih.n_islands,
         SAFE_DIVIDE(ih.charting_hours, pe.interval_hours) AS ratio
  FROM pe JOIN island_hours AS ih USING (stay_id)
)
SELECT
  COUNT(*)                                                       AS stays_with_both,
  ROUND(APPROX_QUANTILES(interval_hours, 100)[OFFSET(50)], 1)    AS p50_interval_hours,
  ROUND(APPROX_QUANTILES(charting_hours, 100)[OFFSET(50)], 1)    AS p50_charting_hours,
  ROUND(APPROX_QUANTILES(ratio, 100)[OFFSET(10)], 2)             AS ratio_p10,
  ROUND(APPROX_QUANTILES(ratio, 100)[OFFSET(50)], 2)             AS ratio_p50,
  ROUND(APPROX_QUANTILES(ratio, 100)[OFFSET(90)], 2)             AS ratio_p90,
  ROUND(100 * COUNTIF(ratio BETWEEN 0.8 AND 1.25) / COUNT(*), 1) AS pct_within_20pct,
  ROUND(AVG(n_islands), 2)                                       AS mean_islands_per_stay
FROM both_;


-- P. Antibiotics in inputevents (category "Antibiotics", 55 items, 617 k rows
--    in K1) and cultures in hosp.microbiologyevents. Hypotheses 02 encodes:
--    an antibiotic segment overlapping the look-back is "antibiotic given in
--    the last 24 h" (the segments are short infusions, so "running at t_k"
--    would be rare and meaningless); the first segment of an item in the stay
--    is an "antibiotic start"; a specimen collected in the look-back is a
--    "culture sent"; a start plus a culture in the same 24 h is the Sepsis-3
--    style suspicion of infection. Specimen collection has charttime for most
--    rows and only chartdate for the rest; the pct_charttime_null column says
--    how many. A date-only specimen counts only when its date is strictly
--    before DATE(t_k) (the omr rule), because a same-day collection may have
--    happened after the landmark.
SELECT
  'inputevents antibiotics' AS what, d.label AS value,
  COUNT(*) AS rows_, COUNT(DISTINCT ie.stay_id) AS stays,
  ROUND(100 * COUNTIF(ie.rate IS NOT NULL) / COUNT(*), 1) AS pct_with_rate,
  ROUND(AVG(DATETIME_DIFF(ie.endtime, ie.starttime, MINUTE)) / 60.0, 2) AS mean_hours
FROM `physionet-data.mimiciv_3_1_icu.inputevents` AS ie
JOIN `physionet-data.mimiciv_3_1_icu.d_items`     AS d USING (itemid)
WHERE d.category = 'Antibiotics'
GROUP BY d.label
HAVING COUNT(*) >= 1000
UNION ALL
SELECT 'inputevents antibiotics: order category', ie.ordercategorydescription,
       COUNT(*), COUNT(DISTINCT ie.stay_id), ROUND(100 * COUNTIF(ie.rate IS NOT NULL) / COUNT(*), 1),
       ROUND(AVG(DATETIME_DIFF(ie.endtime, ie.starttime, MINUTE)) / 60.0, 2)
FROM `physionet-data.mimiciv_3_1_icu.inputevents` AS ie
JOIN `physionet-data.mimiciv_3_1_icu.d_items`     AS d USING (itemid)
WHERE d.category = 'Antibiotics'
GROUP BY ie.ordercategorydescription
UNION ALL
SELECT 'microbiologyevents specimen type', spec_type_desc,
       COUNT(DISTINCT micro_specimen_id), COUNT(DISTINCT hadm_id),
       ROUND(100 * COUNTIF(charttime IS NULL) / COUNT(*), 1), NULL
FROM `physionet-data.mimiciv_3_1_hosp.microbiologyevents`
WHERE hadm_id IS NOT NULL
GROUP BY spec_type_desc
HAVING COUNT(DISTINCT micro_specimen_id) >= 5000
ORDER BY what, rows_ DESC;


-- P2. Octreotide (Vriesendorp: simultaneous octreotide and insulin, OR 6.0,
--     wide interval) in both sources. Hypothesis 01 and 02 encode: the eMAR
--     names it "Octreotide" or "Sandostatin" (boluses and infusion Started
--     rows), and ICU infusions sit in inputevents under a label containing
--     "octreotide" (01 icu_octreotide reads that label; the union of the two
--     sources is the feature, the rule 00 L forced for insulin).
SELECT
  'emar' AS source, medication AS name,
  COUNT(*) AS rows_,
  COUNTIF(REGEXP_CONTAINS(LOWER(COALESCE(event_txt, '')), r'administered|confirmed|started')
          AND NOT REGEXP_CONTAINS(LOWER(COALESCE(event_txt, '')), r'\bnot\b')) AS given_rows,
  COUNT(DISTINCT hadm_id) AS admissions_or_stays
FROM `physionet-data.mimiciv_3_1_hosp.emar`
WHERE REGEXP_CONTAINS(LOWER(medication), r'octreotide|sandostatin')
GROUP BY medication
UNION ALL
SELECT 'inputevents', CONCAT(CAST(d.itemid AS STRING), ' ', d.label, ' [', d.category, ']'),
       COUNT(*), COUNTIF(ie.rate IS NOT NULL), COUNT(DISTINCT ie.stay_id)
FROM `physionet-data.mimiciv_3_1_icu.inputevents` AS ie
JOIN `physionet-data.mimiciv_3_1_icu.d_items`     AS d USING (itemid)
WHERE REGEXP_CONTAINS(LOWER(d.label), r'octreotide|sandostatin')
GROUP BY d.itemid, d.label, d.category
ORDER BY source, rows_ DESC;
