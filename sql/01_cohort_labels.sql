-- =====================================================================
--  01_cohort_labels.sql   (BigQuery Standard SQL, MIMIC-IV v3.1)
--
--  ICU glycemic-harm cohort: daily landmark rows for ICU stays, at risk when
--  insulin was given in the previous 24 h, labelled with the two CMS
--  hospital-harm glucose events in the next 24 h of ICU time:
--      y_lt54_24h   glucose < 54 mg/dL  (primary, the harm outcome)
--      y_gt300_24h  glucose > 300 mg/dL (second outcome, CMS871-style day)
--      y_lt40_24h, y_cms816_24h (secondary, reported with wide intervals)
--
--  Replace YOUR_PROJECT with your project id (dataset lives in US, same
--  region as physionet-data). Requires 00b_extract.sql. Creates, in dataset
--  hypo_tutorial, one small table of parameters, one table of landmark rows
--  and otherwise VIEWS:
--
--    params             the DECLARE values below, as one row, read by the views
--
--    stay_base          one row per eligible ICU stay (era, LOS >= 24 h, split:
--                       train / test / test_shifted, from the two era DECLAREs)
--    emar_cohort        every eMAR row for cohort admissions, classified
--    emar_insulin_infusions
--                       insulin infusion intervals rebuilt from the eMAR's
--                       Started / Confirmed / Stopped events (second drip
--                       source; the first ICU run showed inputevents misses
--                       more than half of the 2020-2022 drips)
--    icu_insulin        every inputevents insulin row for cohort stays:
--                       drips (rate segments) and boluses, Rewritten excluded,
--                       implausible rates and doses flagged
--    insulin_drips      the drip intervals of both sources, one view
--    sc_doses           subcutaneous / bolus doses from both sources, counted
--                       once (eMAR first, inputevents when eMAR has nothing
--                       within SOURCE_MATCH_MINUTES)
--    icu_nutrition      enteral, parenteral, dextrose fluid and dextrose 50%
--                       segments from inputevents
--    icu_rrt            dialysis intervals: procedureevents intervals and
--                       chartevents CRRT charting / hemodialysis output,
--                       merged per stay (00 sections O, O2, O3)
--    icu_antibiotics    antibiotic segments from inputevents, with the first
--                       start of each agent in the stay (00 section P)
--    cultures           specimens collected, from hosp.microbiologyevents
--                       (one row per specimen; date-only rows flagged)
--    icu_octreotide     octreotide infusions and pushes from inputevents, by
--                       label (00 section P2); eMAR octreotide is a drug_class
--    glucose_events     the lab + ICU glucose stream, de-duplicated, with the
--                       repeat-test rule: a result below 54 followed within 5
--                       minutes by a result above 80 is flagged (cancelled_by_repeat),
--                       and repeat_storetime says when the contradicting result
--                       became visible (02 applies the flag to features only when
--                       that was before the landmark)
--    cohort_landmarks   one row per (stay_id, k): at-risk rows with labels
--    (agent_patterns, written by 00b, supplies the hypoglycemic-agent regexes:
--    the extract's universe and this file's classification share one definition)
--                       (the one materialized table: 02 joins it many times)
--
--  Why views. The BigQuery sandbox (no billing account) grants a LIFETIME
--  10 GiB of storage that is never refunded on deletion, and every CREATE OR
--  REPLACE TABLE spends it. The extracts of 00b take about half of it once;
--  everything derived from them is a view, so re-running this file after a
--  change costs query bytes (1 TiB a month, refilled) and no storage. Views
--  cannot read script variables, which is what the params table is for: a
--  DECLARE changes, the table is rewritten (a few hundred bytes), and every
--  view reflects it on its next read.
--
--  Why the ICU (October 2026): the hospital-wide version of this file found
--  0.66% of at-risk days with a result below 54, because MIMIC-IV carries no
--  ward fingerstick glucose (00 section J): on the ward the label was
--  "a venous lab happened to be low". In the ICU glucose is charted every
--  1 to 4 h, insulin drips sit in inputevents with every rate change, and
--  feeds and dextrose are charted, so both labels are measured.
--
--  Design: landmark t_k = intime + 24*k h, k = 1..MAX_K, kept while the
--  patient is in the ICU and alive. At risk when a subcutaneous or bolus
--  dose was given in [t_k - 24 h, t_k) or a drip interval overlaps it. The
--  drip record is flowsheet first: inputevents segments when the stay has
--  charted one by t_k, the eMAR infusion intervals only while it has not
--  (the flag is evaluated per landmark from segments started before t_k, so
--  a segment charted later in the stay cannot change an earlier row; the fourth
--  ICU run, table 7: where the flowsheet is complete, a row "running" on an
--  eMAR interval alone is checked 8 to 10 times in 24 h and has the event
--  rate of rows with no drip, an interval that outlived the drip; where the
--  flowsheet is absent, 2020-2022, the same rows are checked 13 times and
--  carry the drip rows' event rate).
--  Labels look at [t_k, window_end), window_end = the earlier of t_k + 24 h,
--  ICU discharge and death: events after ICU discharge are not observed.
--
--  What the sanity file taught, encoded here (docs/sanity_findings.md):
--    * emar_detail: doses sit on child rows, summed per emar_id (C);
--      "Not Given per Sliding Scale" is a check with nothing due (D);
--      NULL event text with a charted dose is an administration (G);
--      "Confirmed" is the nurse's check of a running insulin infusion
--      (first ICU run, table 13: 100% carry the administration type
--      "Insulin Infusion (IV Drip)", 73% sit inside an inputevents drip
--      segment): drip evidence, never a dose; the 19 pump rows are named
--      by their medication text and excluded from the infusion record;
--      route is never populated for insulin; IV push protocols by name (C).
--    * dose_given carries barcode-sized values: capped (I, 01 run).
--    * ICU glucose items carry impossible values: [GLUCOSE_MIN, GLUCOSE_MAX].
--    * inputevents: rows with statusdescription "Rewritten" are superseded
--      (K2); drips are rate rows in units/hour; boluses are amount rows.
--
--  Requires 00b_extract.sql: every event table below is read from the
--  src_* extracts in YOUR_PROJECT.hypo_tutorial, never from physionet-data,
--  so a run costs a few GB and can be repeated while the DECLAREs are tuned.
-- =====================================================================

-- Landmarks per stay: k = 1..MAX_K. 00 section M on MIMIC-IV v3.1: 94,444
-- stays, median ICU stay 47 h, 11.8% of stays last 7 days or more and 3.6%
-- 15 days or more; k = 1..14 would hold 260,068 landmark rows and lose
-- 35,081 (12%) beyond day 15, so the grid runs to 28 days. Rows from one
-- long stay are correlated; every split and bootstrap is grouped by subject.
DECLARE MAX_K INT64 DEFAULT 28;

-- Glucose plausibility window for the label stream, in mg/dL (00 H2, H6):
-- charted ICU values include -124, 0, 0.12 and 1,653,550; the floor of 10
-- keeps the smooth physiological tail of the lab stream and removes the
-- meter "LO" readings charted as 0 (section 6 table 9 counts them).
DECLARE GLUCOSE_MIN FLOAT64 DEFAULT 10;
DECLARE GLUCOSE_MAX FLOAT64 DEFAULT 2000;

-- Dose plausibility (00 section I). A single insulin administration above
-- 200 units is a charting error (U-500 patients can receive 100 to 300);
-- any dose of any drug at 1e7 or more is one too (penicillin G is 5e6).
-- The raw value is kept beside the capped one in both source tables.
DECLARE DOSE_MAX_INSULIN_UNITS FLOAT64 DEFAULT 200;
DECLARE DOSE_MAX_ANY           FLOAT64 DEFAULT 10000000;

-- Drip rate plausibility, units per hour. 00 section K2 on MIMIC-IV v3.1:
-- charted rates have p50 4, p99 21 and maxima of 510 to 3,013 units/h, so
-- 100 is a ceiling, not a clinical bound. Rows above it are flagged, not used.
DECLARE DRIP_RATE_MAX FLOAT64 DEFAULT 100;

-- Feed and fluid rate plausibility, mL per hour (00 section N: enteral p99
-- 240, parenteral p99 208, dextrose fluids p99 250, maxima 20,790 to 60,000).
DECLARE FEED_RATE_MAX FLOAT64 DEFAULT 500;

-- A subcutaneous dose charted in both eMAR and inputevents within this many
-- minutes is one dose. 00 section L: 46% of eMAR ICU boluses have an
-- inputevents bolus within 60 min; L2: 42% at 30 min, 48% at 120, 51% at 240,
-- 62% at 720, so a clock offset does not explain the gap and the sources
-- chart different doses. 60 stays; the choice moves the double count by
-- about two points either way.
DECLARE SOURCE_MATCH_MINUTES INT64 DEFAULT 60;

-- An eMAR insulin infusion with no Stopped event ends this many hours after
-- its last Started or Confirmed event. The third ICU run (table 15, every
-- era): inside intervals that a Stopped did close, the longest gap between
-- consecutive events is 6.5 to 7.4 h at the median, 9.3 to 9.5 h at the 90th
-- percentile and 12.8 to 16.3 h at the 99th, so a drip still running leaves
-- a new event within 16 h in 99 of 100 cases; a longer silence is a drip
-- that ended without its Stopped row. 48 h, the first value (00 F), kept
-- rows "running" that were checked a third less often than the rest.
DECLARE INFUSION_CAP_HOURS INT64 DEFAULT 16;

-- The split, by the patient's anchor_year_group. All five groups are built
-- and the group travels on every row, so the notebook can regroup them;
-- these two name the split column. The split is patient-disjoint and only
-- approximately temporal: a patient's anchor year lies in the group's range,
-- but their later admissions keep the group whatever year they fall in
-- (table 17 shows admissions up to five years after the anchor), so "trained
-- on 2008 - 2016" means "on patients anchored in 2008 - 2016". Every row
-- carries years_after_anchor (admittime year minus anchor_year, exact under
-- MIMIC's date shift) for the notebook's anchor-year-only sensitivity.
-- 2017 - 2019 is the primary held-out group: the third ICU
-- run (table 14) found inputevents and procedureevents rows on only 38% and
-- 41% of 2020 - 2022 universe stays against 88 to 96% in every earlier era,
-- with chartevents complete, so 2020 - 2022 is held out as the
-- documentation-shift test (split 'test_shifted'), never trained on, and
-- reported apart. Set PRIMARY_TEST_ERA to '2020 - 2022' and SHIFTED_TEST_ERA
-- to '' to test on the latest era alone.
DECLARE PRIMARY_TEST_ERA STRING DEFAULT '2017 - 2019';
DECLARE SHIFTED_TEST_ERA STRING DEFAULT '2020 - 2022';

-- CRRT settings are charted about hourly while a filter runs (00 O). Two
-- consecutive charting times further apart than this many hours start a new
-- dialysis interval; each interval ends one hour after its last charting.
DECLARE RRT_GAP_HOURS FLOAT64 DEFAULT 3;

CREATE SCHEMA IF NOT EXISTS `YOUR_PROJECT.hypo_tutorial`;

-- The DECLARE values, materialized for the views (a view cannot read a script
-- variable). Rewriting this one-row table is how a parameter is changed.
CREATE OR REPLACE TABLE `YOUR_PROJECT.hypo_tutorial.params` AS
SELECT
  MAX_K                  AS max_k,
  GLUCOSE_MIN            AS glucose_min,
  GLUCOSE_MAX            AS glucose_max,
  DOSE_MAX_INSULIN_UNITS AS dose_max_insulin_units,
  DOSE_MAX_ANY           AS dose_max_any,
  DRIP_RATE_MAX          AS drip_rate_max,
  FEED_RATE_MAX          AS feed_rate_max,
  SOURCE_MATCH_MINUTES   AS source_match_minutes,
  INFUSION_CAP_HOURS     AS infusion_cap_hours,
  RRT_GAP_HOURS          AS rrt_gap_hours,
  PRIMARY_TEST_ERA       AS primary_test_era,
  SHIFTED_TEST_ERA       AS shifted_test_era;


-- ---------------------------------------------------------------------
-- 1. Eligible ICU stays. All five anchor_year_groups are kept (MIMIC-IV
--    holds MetaVision stays from 2008 on); the split column comes from the
--    two era DECLAREs (train / test / test_shifted) and the training eras
--    stay a notebook setting read off tables 2, 10 and 14. LOS >= 24 h
--    leaves room for k = 1. All MIMIC-IV patients are adults.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT.hypo_tutorial.stay_base` AS
SELECT
  s.subject_id,
  s.hadm_id,
  s.stay_id,
  s.intime,
  s.outtime,
  s.first_careunit,
  s.last_careunit,
  DATETIME_DIFF(s.outtime, s.intime, MINUTE) / 60.0               AS los_icu_hours,
  a.admittime,
  a.dischtime,
  a.deathtime,
  a.admission_type,
  a.admission_location,
  a.insurance,
  a.language,
  a.marital_status,
  a.race,
  a.hospital_expire_flag,
  a.edregtime IS NOT NULL                                         AS ed_arrival,
  DATETIME_DIFF(s.intime, a.admittime, MINUTE) / 60.0             AS hours_in_hospital_before_icu,
  p.gender,
  p.anchor_year_group,
  p.anchor_age + (EXTRACT(YEAR FROM a.admittime) - p.anchor_year)  AS age_at_admit,
  EXTRACT(YEAR FROM a.admittime) - p.anchor_year                   AS years_after_anchor,
  CASE
    WHEN p.anchor_year_group = (SELECT shifted_test_era FROM `YOUR_PROJECT.hypo_tutorial.params`) THEN 'test_shifted'
    WHEN p.anchor_year_group = (SELECT primary_test_era FROM `YOUR_PROJECT.hypo_tutorial.params`) THEN 'test'
    ELSE 'train'
  END                                                              AS split
FROM `physionet-data.mimiciv_3_1_icu.icustays`     AS s
JOIN `physionet-data.mimiciv_3_1_hosp.admissions`  AS a USING (hadm_id)
JOIN `physionet-data.mimiciv_3_1_hosp.patients`    AS p ON p.subject_id = s.subject_id
WHERE p.anchor_year_group IN ('2008 - 2010', '2011 - 2013', '2014 - 2016', '2017 - 2019', '2020 - 2022')
  AND s.outtime > s.intime
  AND DATETIME_DIFF(s.outtime, s.intime, HOUR) >= 24;


-- ---------------------------------------------------------------------
-- 2. eMAR rows for cohort admissions, classified once (from the 00b extract,
--    which already holds every eMAR row of admissions with an ICU stay and
--    the detail rows of those administrations). eMAR supplies the
--    subcutaneous doses (first source), held doses, sliding-scale checks,
--    self-administered insulin and the other drug classes. Orders are never
--    used: an order is not a dose.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT.hypo_tutorial.emar_cohort` AS
WITH cohort_adm AS (
  SELECT DISTINCT hadm_id FROM `YOUR_PROJECT.hypo_tutorial.stay_base`
),
e AS (
  -- src_emar (00b) already holds one row per administration with the detail
  -- rows collapsed: dose_given summed over the child rows, administration
  -- type and infusion rate from the parent row (00 C)
  SELECT
    em.hadm_id, em.emar_id, em.charttime, em.medication, em.event_txt,
    em.dose_given AS dose_given_raw, em.dose_given_unit, em.administration_type, em.n_products,
    LOWER(em.medication) AS med,
    LOWER(COALESCE(em.event_txt, '')) AS evt,
    -- the hypoglycemic-agent patterns come from 00b (hypo_tutorial.agent_patterns): they
    -- define the extract's universe, so the classification here cannot drift from it
    ap.insulin_regex, ap.sulfonylurea_regex, ap.meglitinide_regex
  FROM `YOUR_PROJECT.hypo_tutorial.src_emar` AS em
  JOIN cohort_adm AS b ON b.hadm_id = em.hadm_id
  CROSS JOIN `YOUR_PROJECT.hypo_tutorial.agent_patterns` AS ap
)
SELECT
  e.hadm_id, e.emar_id, e.charttime, e.medication, e.event_txt,
  -- "Administered" in any form and "Partial Administered" count as a bolus
  -- given; anything containing "not" is out; NULL event text or the
  -- truncated " in Other Location" with a charted dose counts as given.
  -- "Confirmed" is NOT a bolus: table 13 of the first ICU run showed every
  -- such insulin row under the administration type "Insulin Infusion (IV
  -- Drip)", 0.4% with a dose; it is the nurse confirming a running drip.
  (REGEXP_CONTAINS(e.evt, r'administered') AND NOT REGEXP_CONTAINS(e.evt, r'\bnot\b'))
    OR ((e.event_txt IS NULL OR e.evt = ' in other location') AND e.dose_given_raw IS NOT NULL)  AS bolus_given,
  REGEXP_CONTAINS(e.evt, r'\bstarted|restarted')
    AND NOT REGEXP_CONTAINS(e.evt, r'\bnot\b')                                       AS infusion_start,
  REGEXP_CONTAINS(e.evt, r'stopped')
    AND NOT REGEXP_CONTAINS(e.evt, r'\bnot\b')                                       AS infusion_stop,
  (REGEXP_CONTAINS(e.evt, r'not given') AND NOT REGEXP_CONTAINS(e.evt, r'sliding scale'))
    OR REGEXP_CONTAINS(e.evt, r'hold dose')                                          AS held,
  REGEXP_CONTAINS(e.evt, r'not given per sliding scale')                             AS ss_no_dose,
  -- a confirmed infusion check; the handful of pump rows (medication text
  -- names the pump, 00 D2: 19 rows in the database) are kept apart
  REGEXP_CONTAINS(e.evt, r'confirmed') AND NOT REGEXP_CONTAINS(e.evt, r'\bnot\b')
    AND NOT REGEXP_CONTAINS(e.med, r'pump')                                          AS infusion_confirmed,
  REGEXP_CONTAINS(e.evt, r'confirmed') AND NOT REGEXP_CONTAINS(e.evt, r'\bnot\b')
    AND REGEXP_CONTAINS(e.med, r'pump')                                              AS pump_confirmed,
  CASE
    WHEN REGEXP_CONTAINS(e.med, e.insulin_regex)                                                              THEN 'insulin'
    WHEN REGEXP_CONTAINS(e.med, e.sulfonylurea_regex)                                                         THEN 'sulfonylurea'
    WHEN REGEXP_CONTAINS(e.med, e.meglitinide_regex)                                                          THEN 'meglitinide'
    WHEN REGEXP_CONTAINS(e.med, r'dextrose 50|d50|glucagon|glucose gel')                                     THEN 'dextrose_rescue'
    WHEN REGEXP_CONTAINS(e.med, r'dexamethasone|prednisone|prednisolone|methylprednisolone|hydrocortisone')   THEN 'steroid'
    WHEN REGEXP_CONTAINS(e.med, r'metoprolol|carvedilol|atenolol|propranolol|labetalol|bisoprolol|nadolol|esmolol') THEN 'betablocker'
    WHEN REGEXP_CONTAINS(e.med, r'ciprofloxacin|levofloxacin|moxifloxacin')                                   THEN 'quinolone'
    WHEN REGEXP_CONTAINS(e.med, r'octreotide|sandostatin')                                                    THEN 'octreotide'
    ELSE 'other'
  END AS drug_class,
  CASE
    WHEN NOT REGEXP_CONTAINS(e.med, e.insulin_regex) THEN NULL
    WHEN REGEXP_CONTAINS(e.med, r'glargine|detemir|degludec|lantus|levemir|tresiba|basaglar|semglee|toujeo|nph|isophane|humulin n|novolin n|70/30|75/25|50/50') THEN 'basal'
    ELSE 'bolus'
  END AS insulin_kind,
  CASE
    WHEN e.dose_given_raw IS NULL OR e.dose_given_raw <= 0 OR e.dose_given_raw >= (SELECT dose_max_any FROM `YOUR_PROJECT.hypo_tutorial.params`)     THEN NULL
    WHEN REGEXP_CONTAINS(e.med, e.insulin_regex) AND e.dose_given_raw > (SELECT dose_max_insulin_units FROM `YOUR_PROJECT.hypo_tutorial.params`)      THEN NULL
    ELSE e.dose_given_raw
  END                                                                                               AS dose_given,
  e.dose_given_raw,
  e.dose_given_unit,
  -- the sliding-scale flag 02 reads (the administration_type string itself is not carried)
  REGEXP_CONTAINS(LOWER(COALESCE(e.administration_type, '')), r'sliding')                           AS is_sliding_scale,
  e.n_products,
  REGEXP_CONTAINS(e.med, e.insulin_regex) AND REGEXP_CONTAINS(e.med, r'hyperkalemia|overdose')     AS insulin_iv
FROM e;


-- ---------------------------------------------------------------------
-- 2b. Insulin infusion intervals from the eMAR. The eMAR records a drip as
--     events, not segments: Started / Restarted when the bag is hung,
--     Confirmed at each nurse's check of the running infusion (table 13),
--     Stopped when it ends (00 sections D, F). An interval opens at a start
--     event, or at a Confirmed when no interval is open (the start was
--     charted elsewhere or before the admission's rows), and closes at the
--     first Stopped after it, at the next start, or INFUSION_CAP_HOURS after
--     its last start or confirmation when nothing closes it. The first ICU
--     run made this view necessary: eMAR infusion starts sit on 20% of
--     eligible stays in every era from 2017 on, while inputevents drip rows
--     fell from 20% to 9% of stays in 2020-2022 (table 12), so a rule that
--     read inputevents alone lost more than half of the test era's drips.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT.hypo_tutorial.emar_insulin_infusions` AS
WITH ev AS (
  SELECT hadm_id, charttime,
         CASE WHEN infusion_stop THEN 'stop' WHEN infusion_start THEN 'start' ELSE 'confirm' END AS kind,
         CASE WHEN infusion_stop THEN 0    WHEN infusion_start THEN 1       ELSE 2 END           AS kind_order
  FROM `YOUR_PROJECT.hypo_tutorial.emar_cohort`
  WHERE drug_class = 'insulin'
    AND NOT insulin_iv                                  -- the hyperkalemia / overdose push protocols are not drips
    AND (infusion_start OR infusion_stop OR infusion_confirmed)
),
seq AS (
  SELECT *,
         LAG(kind)      OVER w AS prev_kind,
         LAG(charttime) OVER w AS prev_time
  FROM ev
  WINDOW w AS (PARTITION BY hadm_id ORDER BY charttime, kind_order)
),
marks AS (
  SELECT *,
         CASE
           WHEN kind = 'start' THEN 1
           WHEN kind = 'confirm' AND (prev_kind IS NULL OR prev_kind = 'stop'
                                      OR DATETIME_DIFF(charttime, prev_time, HOUR) >= (SELECT infusion_cap_hours FROM `YOUR_PROJECT.hypo_tutorial.params`)) THEN 1
           ELSE 0
         END AS opens
  FROM seq
),
sessions AS (
  SELECT *,
         SUM(opens) OVER (PARTITION BY hadm_id ORDER BY charttime, kind_order ROWS UNBOUNDED PRECEDING) AS session_id
  FROM marks
),
agg AS (
  SELECT
    hadm_id, session_id,
    MIN(IF(kind != 'stop', charttime, NULL))                 AS start_time,
    MIN(IF(kind = 'stop',  charttime, NULL))                 AS stop_time,
    MAX(IF(kind != 'stop', charttime, NULL))                 AS last_evidence,
    COUNTIF(kind = 'start')                                  AS n_starts,
    COUNTIF(kind = 'confirm')                                AS n_confirmations,
    -- the longest gap between consecutive start / confirm events inside the session (table 15)
    MAX(IF(kind != 'stop' AND prev_kind IS NOT NULL AND prev_kind != 'stop' AND opens = 0,
           DATETIME_DIFF(charttime, prev_time, MINUTE) / 60.0, NULL))                      AS max_evidence_gap_hours
  FROM sessions
  GROUP BY hadm_id, session_id
),
closed AS (
  SELECT a.*,
         LEAD(a.start_time) OVER (PARTITION BY a.hadm_id ORDER BY a.start_time) AS next_start,
         (SELECT infusion_cap_hours FROM `YOUR_PROJECT.hypo_tutorial.params`)   AS cap_hours
  FROM agg AS a
  WHERE a.start_time IS NOT NULL                       -- a session that is only a Stopped has no start evidence
)
SELECT
  hadm_id, session_id, start_time,
  LEAST(COALESCE(stop_time, DATETIME_ADD(last_evidence, INTERVAL cap_hours HOUR)),
        COALESCE(next_start, DATETIME '9999-12-31 00:00:00'))                                AS end_time,
  CASE
    WHEN next_start IS NOT NULL AND next_start <= COALESCE(stop_time, DATETIME_ADD(last_evidence, INTERVAL cap_hours HOUR)) THEN 'restarted'
    WHEN stop_time IS NOT NULL THEN 'stopped'
    ELSE 'cap'
  END                                                                                       AS end_reason,
  n_starts > 0                                                                              AS has_start_event,
  n_confirmations,
  max_evidence_gap_hours
FROM closed
WHERE LEAST(COALESCE(stop_time, DATETIME_ADD(last_evidence, INTERVAL cap_hours HOUR)),
            COALESCE(next_start, DATETIME '9999-12-31 00:00:00')) > start_time;


-- ---------------------------------------------------------------------
-- 3. inputevents insulin rows for cohort stays. Items by label (00 section
--    K: Regular, Humalog, Glargine, NPH, Novolog, 70/30, Humalog 75/25, U500).
--    How insulin is charted there (00 K2, MIMIC-IV v3.1):
--      * "Continuous Med" rows carry a rate in units/hour and end at a
--        ChangeDose/Rate, Stopped, Paused or FinishedRunning status: these
--        are the drip segments (158,888 rate rows, p50 4 units/h);
--      * "Continuous IV" rows (2,245) are the same drip charted without a
--        rate: an amount in units over 10 to 22 hours. Their rate is derived
--        as amount / hours, never treated as a bolus;
--      * "Drug Push" rows (p50 4 units, 1-minute duration) are boluses;
--      * a "Bolus" status on a Continuous Med row (177) is a bolus given
--        from the drip: its amount is a bolus, its rate is ignored;
--      * Rewritten rows are superseded (fewer than 100 for insulin) and
--        dropped.
--    Implausible rates (above DRIP_RATE_MAX) and amounts are flagged and
--    kept out of the exposure and the features, never silently used.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT.hypo_tutorial.icu_insulin` AS
WITH items AS (
  SELECT itemid, label
  FROM `physionet-data.mimiciv_3_1_icu.d_items`
  WHERE linksto = 'inputevents'
    AND REGEXP_CONTAINS(LOWER(label), (SELECT inputevents_insulin_regex FROM `YOUR_PROJECT.hypo_tutorial.agent_patterns`))
),
raw AS (
  SELECT
    ie.hadm_id, ie.stay_id, ie.itemid, i.label,
    ie.starttime, ie.endtime, ie.storetime,
    ie.amount, ie.amountuom, ie.rate, ie.rateuom,
    ie.ordercategorydescription, ie.statusdescription,
    DATETIME_DIFF(ie.endtime, ie.starttime, MINUTE) / 60.0                                AS hours,
    ie.rate IS NOT NULL AND REGEXP_CONTAINS(LOWER(COALESCE(ie.rateuom, '')), r'hour|min') AS has_rate,
    REGEXP_CONTAINS(LOWER(COALESCE(ie.ordercategorydescription, '')), r'continuous')      AS is_continuous,
    COALESCE(ie.statusdescription, '') = 'Bolus'                                          AS bolus_from_drip,
    REGEXP_CONTAINS(LOWER(COALESCE(ie.amountuom, '')), r'unit')                           AS amount_in_units
  FROM `YOUR_PROJECT.hypo_tutorial.src_inputevents` AS ie
  JOIN items                                         AS i USING (itemid)
  JOIN `YOUR_PROJECT.hypo_tutorial.stay_base`        AS b USING (stay_id)
  WHERE COALESCE(ie.statusdescription, '') != 'Rewritten'
),
typed AS (
  SELECT *,
    -- the rate used downstream: charted when present, else amount / hours for
    -- the rate-less "Continuous IV" rows
    CASE
      WHEN bolus_from_drip                                  THEN NULL
      WHEN has_rate                                         THEN rate
      WHEN is_continuous AND amount_in_units AND hours > 0  THEN amount / hours
      ELSE NULL
    END AS rate_eff,
    CASE
      WHEN bolus_from_drip THEN 'bolus from drip'
      WHEN has_rate        THEN 'charted'
      WHEN is_continuous   THEN 'derived from amount / hours'
      ELSE 'none'
    END AS rate_source
  FROM raw
)
SELECT
  hadm_id, stay_id, itemid, label,
  starttime, endtime, storetime,
  amount, amountuom, rate, rateuom,
  ordercategorydescription, statusdescription,
  hours, has_rate, is_continuous, bolus_from_drip, rate_source,
  rate_eff                                                                        AS drip_rate,
  rate_eff IS NOT NULL AND rate_eff > 0 AND rate_eff <= (SELECT drip_rate_max FROM `YOUR_PROJECT.hypo_tutorial.params`)
    AND endtime > starttime                                                       AS is_drip,
  rate_eff IS NOT NULL AND (rate_eff <= 0 OR rate_eff > (SELECT drip_rate_max FROM `YOUR_PROJECT.hypo_tutorial.params`))            AS rate_implausible,
  -- a bolus: a non-continuous row (Drug Push), or a Bolus status on the drip
  bolus_from_drip OR (NOT is_continuous AND rate IS NULL)                        AS is_bolus,
  CASE
    WHEN NOT (bolus_from_drip OR (NOT is_continuous AND rate IS NULL))           THEN NULL
    WHEN amount IS NULL OR amount <= 0 OR amount > (SELECT dose_max_insulin_units FROM `YOUR_PROJECT.hypo_tutorial.params`)         THEN NULL
    WHEN NOT amount_in_units                                                      THEN NULL
    ELSE amount
  END                                                                             AS bolus_units,
  IF(REGEXP_CONTAINS(LOWER(label), r'nph|glargine|75/25|70/30|50/50|detemir|degludec'), 'basal', 'bolus') AS insulin_kind
FROM typed;


-- ---------------------------------------------------------------------
-- 3b. The drip intervals of both sources in one view. inputevents segments
--     carry the rate; eMAR intervals carry none. 02 takes hours from either
--     source (the larger of the two where both describe the same drip) and
--     rates from inputevents only.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT.hypo_tutorial.insulin_drips` AS
SELECT hadm_id, stay_id, 'inputevents' AS source, starttime, endtime, drip_rate AS rate
FROM `YOUR_PROJECT.hypo_tutorial.icu_insulin`
WHERE is_drip
UNION ALL
SELECT hadm_id, CAST(NULL AS INT64), 'emar', start_time, end_time, CAST(NULL AS FLOAT64)
FROM `YOUR_PROJECT.hypo_tutorial.emar_insulin_infusions`;


-- ---------------------------------------------------------------------
-- 4. Subcutaneous and bolus doses of hypoglycemic agents, counted once.
--    eMAR is the first source (hospital-wide, barcode-scanned); an
--    inputevents bolus is added only when no eMAR insulin bolus sits within
--    SOURCE_MATCH_MINUTES on the same admission. source says which.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT.hypo_tutorial.sc_doses` AS
WITH emar_doses AS (
  SELECT
    hadm_id, charttime, drug_class, insulin_kind,
    IF(drug_class = 'insulin' AND REGEXP_CONTAINS(LOWER(COALESCE(dose_given_unit, '')), r'unit'), dose_given, NULL) AS dose_units,
    insulin_iv,
    'emar' AS source
  FROM `YOUR_PROJECT.hypo_tutorial.emar_cohort`
  WHERE bolus_given
    AND drug_class IN ('insulin', 'sulfonylurea', 'meglitinide')
),
ie_boluses AS (
  SELECT
    i.hadm_id, i.starttime AS charttime, 'insulin' AS drug_class, i.insulin_kind,
    i.bolus_units AS dose_units,
    FALSE AS insulin_iv,
    'inputevents' AS source
  FROM `YOUR_PROJECT.hypo_tutorial.icu_insulin` AS i
  WHERE i.is_bolus
),
p AS (
  SELECT source_match_minutes FROM `YOUR_PROJECT.hypo_tutorial.params`
),
ie_unmatched AS (
  SELECT i.* EXCEPT (source_match_minutes)
  FROM (SELECT b.*, p.source_match_minutes FROM ie_boluses AS b CROSS JOIN p) AS i
  LEFT JOIN emar_doses AS e
    ON e.hadm_id = i.hadm_id
   AND e.drug_class = 'insulin'
   AND ABS(DATETIME_DIFF(e.charttime, i.charttime, MINUTE)) <= i.source_match_minutes
  WHERE e.hadm_id IS NULL
)
SELECT * FROM emar_doses
UNION ALL
SELECT * FROM ie_unmatched;


-- ---------------------------------------------------------------------
-- 5. Feeds and dextrose from inputevents for cohort stays (00 sections K, N).
-- ---------------------------------------------------------------------
-- Classes in this order (00 section K on MIMIC-IV v3.1): dextrose 50% is its
-- own item (16,333 amount rows); the category decides parenteral (TPN with
-- and without lipids, peripheral PN; the "Dextrose PN" and amino-acid
-- components are gram rows without a rate) and enteral (112 formula items,
-- including "Boost Glucose Control", which a label regex would misread as a
-- dextrose fluid); the dextrose-containing fluids are what is left (Dextrose
-- 5% is 1.2 M rows, most of them two-hour carrier bags for other drugs, so
-- the feature is a rate, not a flag). Running-at-landmark features use rate
-- rows only (has_rate); amount rows are boluses and flushes.
CREATE OR REPLACE VIEW `YOUR_PROJECT.hypo_tutorial.icu_nutrition` AS
WITH items AS (
  SELECT itemid, label,
    CASE
      WHEN REGEXP_CONTAINS(LOWER(label), r'dextrose 50|\bd50')                          THEN 'd50'
      WHEN REGEXP_CONTAINS(LOWER(COALESCE(category, '')), r'parenteral')
        OR REGEXP_CONTAINS(LOWER(label), r'\btpn')                                      THEN 'parenteral'
      WHEN REGEXP_CONTAINS(LOWER(COALESCE(category, '')), r'enteral')                   THEN 'enteral'
      WHEN REGEXP_CONTAINS(LOWER(label), r'dextrose|\bd5|\bd10|\bd20|\bd30|glucose')    THEN 'dextrose_fluid'
    END AS kind
  FROM `physionet-data.mimiciv_3_1_icu.d_items`
  WHERE linksto = 'inputevents'
    AND NOT REGEXP_CONTAINS(LOWER(label), r'insulin|ranitidine')
)
SELECT
  ie.stay_id, ie.hadm_id, ie.itemid, i.label, i.kind,
  ie.starttime, ie.endtime,
  ie.rate, ie.rateuom, ie.amount, ie.amountuom,
  DATETIME_DIFF(ie.endtime, ie.starttime, MINUTE) / 60.0                                AS hours,
  ie.rate IS NOT NULL AND REGEXP_CONTAINS(LOWER(COALESCE(ie.rateuom, '')), r'hour')
    AND ie.rate > 0 AND ie.rate <= (SELECT feed_rate_max FROM `YOUR_PROJECT.hypo_tutorial.params`) AND ie.endtime > ie.starttime           AS has_rate,
  ie.rate IS NOT NULL AND (ie.rate <= 0 OR ie.rate > (SELECT feed_rate_max FROM `YOUR_PROJECT.hypo_tutorial.params`))                     AS rate_implausible
FROM `YOUR_PROJECT.hypo_tutorial.src_inputevents` AS ie
JOIN items                                         AS i USING (itemid)
JOIN `YOUR_PROJECT.hypo_tutorial.stay_base`        AS b USING (stay_id)
WHERE i.kind IS NOT NULL
  AND COALESCE(ie.statusdescription, '') != 'Rewritten'
  AND ie.endtime >= ie.starttime;


-- ---------------------------------------------------------------------
-- 5b. Renal replacement therapy, antibiotics and cultures: the three risk
--     factors the ICU hypoglycemia literature names that the first feature
--     set lacked (Vriesendorp 2006; Krinsley 2007; Waeschle 2008).
--     Dialysis intervals come from procedureevents by label and from the
--     chartevents CRRT settings and hemodialysis output, merged (00 O found
--     each source alone misses a fifth of the stays the other has).
--     Antibiotics are the inputevents category "Antibiotics" (00 section P);
--     an agent's first segment in the stay is a start. Cultures are specimen
--     collections in hosp.microbiologyevents; charttime when present, else
--     the collection date at midnight.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT.hypo_tutorial.icu_rrt` AS
-- Dialysis intervals from two sources, merged per stay (00 O, O2, O3):
--   (a) procedureevents intervals whose label says dialysis, CRRT, CVVH or
--       SCUF, excluding "Dialysis Catheter" (an access line that stays in for
--       days) and "CRRT Filter Change" (zero length); in v3.1 that is
--       Dialysis - CRRT (225802), Hemodialysis (225441) and Peritoneal
--       Dialysis (225805), the CVVHD / CVVHDF / SCUF items having no rows.
--   (b) chartevents: the hourly CRRT settings (mode, dialysate and
--       replacement rates, effluent pressure, dialysate fluid) collapsed into
--       intervals, a new one whenever two charting times are more than
--       RRT_GAP_HOURS apart, each ending one hour after its last charting; and
--       the per-session Hemodialysis Output (226499) as a one-minute marker.
--   00 O found CRRT settings on about 2,900 stays against 2,274 with a CRRT
--   interval and hemodialysis output on 3,225 stays against 2,746 with an
--   interval, so neither source alone covers dialysis.
-- Overlapping pieces from both sources become one interval (gaps and
-- islands), so rrt_hours_24h in 02 never counts the same hour twice.
-- rrt_kind: 'crrt' if any piece is CRRT, else 'pd', else 'ihd';
-- source: 'procedureevents', 'chartevents' or 'both'.
WITH pe_items AS (
  SELECT itemid, label,
         CASE WHEN REGEXP_CONTAINS(LOWER(label), r'crrt|cvvh|scuf') THEN 'crrt'
              WHEN REGEXP_CONTAINS(LOWER(label), r'peritoneal')     THEN 'pd'
              ELSE 'ihd' END AS rrt_kind
  FROM `physionet-data.mimiciv_3_1_icu.d_items`
  WHERE linksto = 'procedureevents'
    AND REGEXP_CONTAINS(LOWER(label), r'dialysis|crrt|cvvh|scuf')
    AND NOT REGEXP_CONTAINS(LOWER(label), r'catheter|filter change')
),
pieces_pe AS (
  SELECT pe.stay_id, pe.hadm_id, i.rrt_kind, 'procedureevents' AS source, pe.starttime, pe.endtime
  FROM `YOUR_PROJECT.hypo_tutorial.src_procedureevents` AS pe
  JOIN pe_items                                          AS i USING (itemid)
  JOIN `YOUR_PROJECT.hypo_tutorial.stay_base`            AS b USING (stay_id)
  WHERE COALESCE(pe.statusdescription, '') != 'Rewritten'
    AND pe.endtime > pe.starttime
),
crrt_chart AS (
  SELECT DISTINCT ce.stay_id, b.hadm_id, ce.charttime
  FROM `YOUR_PROJECT.hypo_tutorial.src_chartevents` AS ce
  JOIN `YOUR_PROJECT.hypo_tutorial.stay_base`       AS b USING (stay_id)
  WHERE ce.itemid IN (227290, 224154, 224153, 228005, 228006, 224151, 225977, 230085)
),
crrt_islands AS (
  SELECT stay_id, hadm_id, charttime,
         -- a new interval starts when the previous charting is more than RRT_GAP_HOURS back
         SUM(IF(prev_time IS NULL OR DATETIME_DIFF(charttime, prev_time, MINUTE) > (SELECT rrt_gap_hours FROM `YOUR_PROJECT.hypo_tutorial.params`) * 60, 1, 0))
           OVER (PARTITION BY stay_id ORDER BY charttime ROWS UNBOUNDED PRECEDING) AS island
  FROM (
    SELECT stay_id, hadm_id, charttime,
           LAG(charttime) OVER (PARTITION BY stay_id ORDER BY charttime) AS prev_time
    FROM crrt_chart
  )
),
pieces_crrt AS (
  SELECT stay_id, hadm_id, 'crrt' AS rrt_kind, 'chartevents' AS source,
         MIN(charttime) AS starttime,
         DATETIME_ADD(MAX(charttime), INTERVAL 1 HOUR) AS endtime
  FROM crrt_islands
  GROUP BY stay_id, hadm_id, island
),
pieces_hd_output AS (
  SELECT DISTINCT ce.stay_id, b.hadm_id, 'ihd' AS rrt_kind, 'chartevents' AS source,
         DATETIME_SUB(ce.charttime, INTERVAL 1 MINUTE) AS starttime,
         ce.charttime                                   AS endtime
  FROM `YOUR_PROJECT.hypo_tutorial.src_chartevents` AS ce
  JOIN `YOUR_PROJECT.hypo_tutorial.stay_base`       AS b USING (stay_id)
  WHERE ce.itemid = 226499
),
pieces AS (
  SELECT * FROM pieces_pe
  UNION ALL SELECT * FROM pieces_crrt
  UNION ALL SELECT * FROM pieces_hd_output
),
ordered AS (
  SELECT *,
         MAX(endtime) OVER (PARTITION BY stay_id ORDER BY starttime, endtime
                            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prev_max_end
  FROM pieces
),
merged AS (
  SELECT *,
         SUM(IF(prev_max_end IS NULL OR starttime > prev_max_end, 1, 0))
           OVER (PARTITION BY stay_id ORDER BY starttime, endtime ROWS UNBOUNDED PRECEDING) AS island
  FROM ordered
)
SELECT
  stay_id, hadm_id, island AS rrt_interval_seq,
  MIN(starttime) AS starttime,
  MAX(endtime)   AS endtime,
  DATETIME_DIFF(MAX(endtime), MIN(starttime), MINUTE) / 60.0 AS hours,
  CASE WHEN COUNTIF(rrt_kind = 'crrt') > 0 THEN 'crrt'
       WHEN COUNTIF(rrt_kind = 'pd')   > 0 THEN 'pd'
       ELSE 'ihd' END AS rrt_kind,
  CASE WHEN COUNTIF(source = 'procedureevents') > 0 AND COUNTIF(source = 'chartevents') > 0 THEN 'both'
       WHEN COUNTIF(source = 'procedureevents') > 0 THEN 'procedureevents'
       ELSE 'chartevents' END AS source
FROM merged
GROUP BY stay_id, hadm_id, island;

CREATE OR REPLACE VIEW `YOUR_PROJECT.hypo_tutorial.icu_antibiotics` AS
WITH items AS (
  SELECT itemid, label
  FROM `physionet-data.mimiciv_3_1_icu.d_items`
  WHERE linksto = 'inputevents'
    AND category = 'Antibiotics'
),
seg AS (
  SELECT
    ie.stay_id, ie.hadm_id, ie.itemid, i.label, ie.starttime, ie.endtime,
    MIN(ie.starttime) OVER (PARTITION BY ie.stay_id, ie.itemid) AS first_start_in_stay
  FROM `YOUR_PROJECT.hypo_tutorial.src_inputevents` AS ie
  JOIN items                                         AS i USING (itemid)
  JOIN `YOUR_PROJECT.hypo_tutorial.stay_base`        AS b USING (stay_id)
  WHERE COALESCE(ie.statusdescription, '') != 'Rewritten'
    AND ie.endtime >= ie.starttime
)
SELECT
  stay_id, hadm_id, itemid, label, starttime, endtime,
  starttime = first_start_in_stay AS is_first_start_in_stay
FROM seg;

CREATE OR REPLACE VIEW `YOUR_PROJECT.hypo_tutorial.cultures` AS
-- one row per specimen (microbiologyevents has one row per organism and
-- antibiotic tested, so a single blood culture can be 30 rows); collected_time
-- is the charttime when present, else the collection date at midnight, and
-- date_only tells 02 to apply the date rule to that row
-- Screening and serology specimens are not a work-up for infection and are
-- excluded: the MRSA admission screen (00 P: 64,759 specimens on 55,610
-- admissions, routine on ICU admission, so it would fire on nearly every
-- first landmark), serology and immunology panels. 00 P also showed that
-- every common specimen type carries a charttime (0.0% date-only), so the
-- date rule below is a guard that costs nothing in v3.1.
SELECT DISTINCT
  m.hadm_id,
  m.micro_specimen_id,
  COALESCE(m.charttime, DATETIME(m.chartdate)) AS collected_time,
  m.charttime IS NULL                          AS date_only,
  m.spec_type_desc
FROM `YOUR_PROJECT.hypo_tutorial.src_microbiologyevents` AS m
JOIN (SELECT DISTINCT hadm_id FROM `YOUR_PROJECT.hypo_tutorial.stay_base`) AS b USING (hadm_id)
WHERE m.chartdate IS NOT NULL
  AND NOT REGEXP_CONTAINS(LOWER(COALESCE(m.spec_type_desc, '')), r'mrsa screen|serology|immunology');

CREATE OR REPLACE VIEW `YOUR_PROJECT.hypo_tutorial.icu_octreotide` AS
-- ICU octreotide infusions and pushes from inputevents, found by label (00 P2
-- prints the items); eMAR octreotide rows are already classed in emar_cohort
-- (drug_class = 'octreotide'), and 02 takes the union of the two sources
SELECT
  ie.stay_id, ie.hadm_id, ie.itemid, i.label, ie.starttime, ie.endtime,
  ie.rate IS NOT NULL AND ie.rate > 0 AS has_rate
FROM `YOUR_PROJECT.hypo_tutorial.src_inputevents` AS ie
JOIN (SELECT itemid, label FROM `physionet-data.mimiciv_3_1_icu.d_items`
      WHERE linksto = 'inputevents' AND REGEXP_CONTAINS(LOWER(label), r'octreotide|sandostatin')) AS i USING (itemid)
JOIN `YOUR_PROJECT.hypo_tutorial.stay_base`        AS b USING (stay_id)
WHERE COALESCE(ie.statusdescription, '') != 'Rewritten'
  AND ie.endtime >= ie.starttime;


-- ---------------------------------------------------------------------
-- 6. The glucose stream: hospital lab + ICU chart, one row per distinct
--    (hadm_id, charttime, value). 220621 is usually the ICU's copy of the
--    lab result, so the de-duplication matters for counts.
--    storetime = when the result became visible; features use it (02),
--    labels use charttime. Repeat-test rule, after CMS816's exclusion for
--    its < 40 measure ("a subsequent glucose > 80 mg/dL within 5 minutes"),
--    extended here to every result below 54: a LOW result contradicted by
--    any result above 80 charted within 300 seconds is a false positive
--    (a contaminated draw or a meter error) and is excluded from the labels.
--    Until release .20 the flag had no "low" condition and looked only at the
--    next result, so a 110 followed by a 120, or a 350 by a 320, was dropped
--    too (the review of 12 October 2026 found it). repeat_storetime is when
--    the contradicting result became visible: 02 may exclude a cancelled low
--    from the features only when that time precedes the landmark, otherwise
--    the exclusion would use a result the clinician had not yet seen.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT.hypo_tutorial.glucose_events` AS
WITH cohort_adm AS (
  SELECT DISTINCT hadm_id FROM `YOUR_PROJECT.hypo_tutorial.stay_base`
),
raw AS (
  SELECT le.hadm_id, le.charttime,
         COALESCE(le.storetime, le.charttime) AS storetime,
         le.valuenum AS glucose, 'lab' AS source
  FROM `YOUR_PROJECT.hypo_tutorial.src_labevents` AS le
  JOIN cohort_adm                                  AS b ON b.hadm_id = le.hadm_id
  WHERE le.itemid IN (50931, 50809, 52569)
    AND le.valuenum BETWEEN (SELECT glucose_min FROM `YOUR_PROJECT.hypo_tutorial.params`) AND (SELECT glucose_max FROM `YOUR_PROJECT.hypo_tutorial.params`)
  UNION ALL
  SELECT s.hadm_id, ce.charttime,
         COALESCE(ce.storetime, ce.charttime),
         ce.valuenum, 'icu'
  FROM `YOUR_PROJECT.hypo_tutorial.src_chartevents` AS ce
  JOIN `physionet-data.mimiciv_3_1_icu.icustays`    AS s ON s.stay_id = ce.stay_id   -- every stay of the admission, eligible or not
  JOIN cohort_adm                                   AS b ON b.hadm_id = s.hadm_id
  WHERE ce.itemid IN (220621, 225664, 226537)
    AND ce.valuenum BETWEEN (SELECT glucose_min FROM `YOUR_PROJECT.hypo_tutorial.params`) AND (SELECT glucose_max FROM `YOUR_PROJECT.hypo_tutorial.params`)
),
dedup AS (
  SELECT hadm_id, charttime, glucose,
         MIN(storetime)                              AS storetime,
         STRING_AGG(DISTINCT source ORDER BY source) AS sources
  FROM raw
  GROUP BY hadm_id, charttime, glucose
),
repeats AS (
  -- for each LOW result, the earliest visibility of any contradicting result
  -- (> 80 mg/dL, charted 0 to 300 seconds after it, any of them, not only the next)
  SELECT d.hadm_id, d.charttime, d.glucose, MIN(r.storetime) AS repeat_storetime
  FROM dedup AS d
  JOIN dedup AS r
    ON r.hadm_id = d.hadm_id
   AND r.glucose > 80
   AND r.charttime >= d.charttime
   AND r.charttime <= DATETIME_ADD(d.charttime, INTERVAL 300 SECOND)
   AND NOT (r.charttime = d.charttime AND r.glucose = d.glucose)
  WHERE d.glucose < 54
  GROUP BY d.hadm_id, d.charttime, d.glucose
)
SELECT
  d.hadm_id, d.charttime, d.storetime, d.glucose, d.sources,
  rp.repeat_storetime IS NOT NULL AS cancelled_by_repeat,
  rp.repeat_storetime,
  d.glucose < 40  AS lt40,
  d.glucose < 54  AS lt54,
  d.glucose < 70  AS lt70,
  d.glucose > 300 AS gt300
FROM dedup AS d
LEFT JOIN repeats AS rp
  ON rp.hadm_id = d.hadm_id AND rp.charttime = d.charttime AND rp.glucose = d.glucose;


-- ---------------------------------------------------------------------
-- 7. Landmark rows, the at-risk rule and the labels.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE `YOUR_PROJECT.hypo_tutorial.cohort_landmarks` AS
WITH first_flowsheet_drip AS (
  -- when the flowsheet first charted an insulin drip segment in the stay: from
  -- that time on the drip record is inputevents alone (see the header). The
  -- flag below is evaluated against t_k, so it is knowable at the landmark; a
  -- segment charted later in the stay does not change an earlier row.
  SELECT stay_id, MIN(starttime) AS first_drip_start
  FROM `YOUR_PROJECT.hypo_tutorial.icu_insulin` WHERE is_drip
  GROUP BY stay_id
),
landmarks AS (
  SELECT
    b.subject_id, b.hadm_id, b.stay_id, b.split, b.anchor_year_group, b.years_after_anchor, k,
    DATETIME_ADD(b.intime, INTERVAL k * 24 HOUR) AS t_k,
    b.intime, b.outtime, b.deathtime,
    COALESCE(f.first_drip_start < DATETIME_ADD(b.intime, INTERVAL k * 24 HOUR), FALSE) AS stay_has_inputevents_drip
  FROM `YOUR_PROJECT.hypo_tutorial.stay_base` AS b
  LEFT JOIN first_flowsheet_drip               AS f USING (stay_id)
  CROSS JOIN UNNEST(GENERATE_ARRAY(1, MAX_K)) AS k
),
landmarks_alive AS (
  -- keep t_k only while the patient is still in the ICU and alive;
  -- window_end truncates the outcome window at ICU discharge or death
  SELECT
    subject_id, hadm_id, stay_id, split, anchor_year_group, years_after_anchor, k, t_k, stay_has_inputevents_drip,
    LEAST(DATETIME_ADD(t_k, INTERVAL 24 HOUR), outtime, COALESCE(deathtime, outtime)) AS window_end
  FROM landmarks
  WHERE t_k < outtime
    AND (deathtime IS NULL OR t_k < deathtime)
),
exposure AS (
  -- a dose is a point in time, a drip interval (either source, 3b) is an interval
  SELECT hadm_id, drug_class, source, charttime AS expo_start, charttime AS expo_end, FALSE AS is_drip
  FROM `YOUR_PROJECT.hypo_tutorial.sc_doses`
  UNION ALL
  SELECT hadm_id, 'insulin', source, starttime, endtime, TRUE
  FROM `YOUR_PROJECT.hypo_tutorial.insulin_drips`
),
at_risk AS (
  -- the CMS816 denominator idea, applied daily: a hypoglycemic agent was
  -- given in the 24 h before the landmark (dose in the window, or a drip
  -- interval overlapping it). Flowsheet first: an eMAR interval counts only
  -- while the stay's flowsheet has charted no inputevents drip segment (by t_k).
  SELECT
    l.stay_id, l.k,
    COUNT(*)                                            AS n_hypo_admin_24h,
    COUNTIF(NOT x.is_drip)                              AS n_doses_24h,
    COUNTIF(x.drug_class = 'insulin' AND NOT x.is_drip) AS n_insulin_sc_24h,
    COUNTIF(x.drug_class = 'sulfonylurea')              AS n_su_admin_24h,
    COUNTIF(x.drug_class = 'meglitinide')               AS n_megl_admin_24h,
    COUNTIF(x.source = 'inputevents' AND NOT x.is_drip) AS n_sc_from_inputevents_24h,
    MAX(IF(x.is_drip, 1, 0))                            AS insulin_drip_24h,
    MAX(IF(x.is_drip AND x.expo_end >= l.t_k, 1, 0))    AS drip_running_at_tk,
    MAX(IF(x.is_drip AND x.source = 'inputevents', 1, 0)) AS drip_inputevents_24h,   -- bookkeeping: which source saw the drip
    MAX(IF(x.is_drip AND x.source = 'emar', 1, 0))        AS drip_emar_24h,
    MAX(IF(x.is_drip AND x.source = 'inputevents' AND x.expo_end >= l.t_k, 1, 0)) AS drip_running_inputevents_at_tk,
    MAX(IF(x.is_drip AND x.source = 'emar'        AND x.expo_end >= l.t_k, 1, 0)) AS drip_running_emar_at_tk,
    MAX(LEAST(x.expo_end, l.t_k))                       AS last_hypo_admin_time
  FROM landmarks_alive AS l
  JOIN exposure AS x
    ON x.hadm_id = l.hadm_id
   AND x.expo_start <  l.t_k
   AND x.expo_end   >= DATETIME_SUB(l.t_k, INTERVAL 24 HOUR)
   -- flowsheet first applies to the drip intervals only: an eMAR DOSE counts in every stay
   -- (the fifth ICU run dropped 10,034 rows when this test lacked NOT x.is_drip)
   AND (NOT x.is_drip OR x.source != 'emar' OR NOT l.stay_has_inputevents_drip)
  GROUP BY l.stay_id, l.k
),
emar_open AS (
  -- diagnostic (table 7): landmarks with an eMAR interval open at t_k,
  -- whether the rule used it or not
  SELECT DISTINCT l.stay_id, l.k
  FROM landmarks_alive AS l
  JOIN `YOUR_PROJECT.hypo_tutorial.emar_insulin_infusions` AS i
    ON i.hadm_id = l.hadm_id AND i.start_time < l.t_k AND i.end_time >= l.t_k
),
events_in_window AS (
  -- any confirmed result below / above threshold in [t_k, window_end)
  SELECT
    l.stay_id, l.k,
    MAX(IF(g.lt54, 1, 0))                AS y_lt54_24h,
    MAX(IF(g.lt40, 1, 0))                AS y_lt40_24h,
    MAX(IF(g.gt300, 1, 0))               AS y_gt300_24h,
    MIN(IF(g.lt54, g.charttime, NULL))   AS first_lt54_time,
    MIN(IF(g.lt40, g.charttime, NULL))   AS first_lt40_time,
    MIN(IF(g.gt300, g.charttime, NULL))  AS first_gt300_time,
    COUNTIF(g.lt70)                      AS n_lt70_in_window,
    COUNTIF(g.gt300)                     AS n_gt300_in_window,
    COUNTIF(g.glucose IS NOT NULL)       AS n_glucose_in_window
  FROM landmarks_alive AS l
  LEFT JOIN `YOUR_PROJECT.hypo_tutorial.glucose_events` AS g
    ON g.hadm_id = l.hadm_id
   AND NOT g.cancelled_by_repeat
   AND g.charttime >= l.t_k
   AND g.charttime <  l.window_end
  GROUP BY l.stay_id, l.k
),
cms_events AS (
  -- a confirmed < 40 result with a hypoglycemic agent given in the 24 h
  -- before the result: the CMS816 numerator event, independent of landmarks
  SELECT DISTINCT g.hadm_id, g.charttime
  FROM `YOUR_PROJECT.hypo_tutorial.glucose_events` AS g
  JOIN exposure AS x
    ON x.hadm_id = g.hadm_id
   AND x.expo_start <= g.charttime
   AND x.expo_end   >= DATETIME_SUB(g.charttime, INTERVAL 24 HOUR)
  WHERE g.lt40 AND NOT g.cancelled_by_repeat
),
cms_in_window AS (
  SELECT
    l.stay_id, l.k,
    MAX(IF(c.charttime IS NULL, 0, 1)) AS y_cms816_24h
  FROM landmarks_alive AS l
  LEFT JOIN cms_events AS c
    ON c.hadm_id = l.hadm_id
   AND c.charttime >= l.t_k
   AND c.charttime <  l.window_end
  GROUP BY l.stay_id, l.k
)
SELECT
  l.subject_id,
  l.hadm_id,
  l.stay_id,
  l.k,
  l.k + 1                                                       AS icu_day,
  l.t_k,
  l.window_end,
  DATETIME_DIFF(l.window_end, l.t_k, MINUTE) / 60.0             AS window_hours,
  l.split,
  l.anchor_year_group,
  l.years_after_anchor,
  r.n_hypo_admin_24h,
  r.n_doses_24h,
  r.n_insulin_sc_24h,
  r.n_su_admin_24h,
  r.n_megl_admin_24h,
  r.n_sc_from_inputevents_24h,
  r.insulin_drip_24h,
  r.drip_running_at_tk,
  r.drip_inputevents_24h,
  r.drip_emar_24h,
  r.drip_running_inputevents_at_tk,
  r.drip_running_emar_at_tk,
  l.stay_has_inputevents_drip,
  eo.stay_id IS NOT NULL                                        AS emar_interval_open_at_tk,
  DATETIME_DIFF(l.t_k, r.last_hypo_admin_time, MINUTE) / 60.0   AS hrs_since_last_hypo_admin,
  e.y_lt54_24h,
  e.y_lt40_24h,
  e.y_gt300_24h,
  c.y_cms816_24h,
  e.first_lt54_time,
  e.first_lt40_time,
  e.first_gt300_time,
  DATETIME_DIFF(e.first_lt54_time, l.t_k, MINUTE) / 60.0        AS hrs_to_first_lt54,
  e.n_lt70_in_window,
  e.n_gt300_in_window,
  e.n_glucose_in_window
FROM landmarks_alive  AS l
JOIN at_risk          AS r USING (stay_id, k)   -- inner join = the at-risk rule
JOIN events_in_window AS e USING (stay_id, k)
JOIN cms_in_window    AS c USING (stay_id, k)
LEFT JOIN emar_open   AS eo USING (stay_id, k);


-- ---------------------------------------------------------------------
-- 8. The numbers everything downstream depends on. Seventeen tables, all
--    aggregates, all safe to paste back. In the console's statement tree
--    some begin with WITH, not SELECT, and the tree scrolls;
--    INFORMATION_SCHEMA.JOBS_BY_USER lists every child job if one seems
--    to be missing.
-- ---------------------------------------------------------------------

-- Table 1. Per split: rows, stays, admissions, subjects, both outcomes,
-- censoring. Rows with window_hours < 6 are the ones the notebook's
-- "short window" sensitivity drops.
SELECT
  split,
  COUNT(*)                         AS landmark_rows,
  COUNT(DISTINCT stay_id)          AS stays,
  COUNT(DISTINCT hadm_id)          AS admissions,
  COUNT(DISTINCT subject_id)       AS subjects,
  SUM(y_lt54_24h)                  AS pos_lt54,
  ROUND(100 * AVG(y_lt54_24h), 2)  AS pct_lt54,
  SUM(y_lt40_24h)                  AS pos_lt40,
  SUM(y_cms816_24h)                AS pos_cms816,
  SUM(y_gt300_24h)                 AS pos_gt300,
  ROUND(100 * AVG(y_gt300_24h), 2) AS pct_gt300,
  SUM(insulin_drip_24h)            AS rows_with_drip_24h,
  SUM(drip_running_at_tk)          AS rows_drip_running_at_tk,
  ROUND(AVG(window_hours), 1)      AS mean_window_hours,
  COUNTIF(window_hours < 24)       AS short_windows,
  COUNTIF(window_hours < 6)        AS windows_under_6h
FROM `YOUR_PROJECT.hypo_tutorial.cohort_landmarks`
GROUP BY split
ORDER BY split;

-- Table 2. Per era: what each anchor_year_group contributes (TRAIN_ERAS in
-- the notebook is read off this table and table 10).
SELECT
  anchor_year_group,
  split,
  COUNT(*)                         AS landmark_rows,
  COUNT(DISTINCT stay_id)          AS stays,
  SUM(y_lt54_24h)                  AS pos_lt54,
  ROUND(100 * AVG(y_lt54_24h), 2)  AS pct_lt54,
  SUM(y_gt300_24h)                 AS pos_gt300,
  ROUND(100 * AVG(y_gt300_24h), 2) AS pct_gt300,
  ROUND(100 * AVG(insulin_drip_24h), 1) AS pct_with_drip
FROM `YOUR_PROJECT.hypo_tutorial.cohort_landmarks`
GROUP BY anchor_year_group, split
ORDER BY anchor_year_group;

-- Table 3. Per ICU day.
SELECT
  icu_day,
  COUNT(*)                         AS rows_,
  SUM(y_lt54_24h)                  AS pos_lt54,
  ROUND(100 * AVG(y_lt54_24h), 2)  AS pct_lt54,
  SUM(y_lt40_24h)                  AS pos_lt40,
  SUM(y_gt300_24h)                 AS pos_gt300,
  ROUND(100 * AVG(y_gt300_24h), 2) AS pct_gt300
FROM `YOUR_PROJECT.hypo_tutorial.cohort_landmarks`
GROUP BY icu_day
ORDER BY icu_day;

-- Table 4. Drip segments: rates, lengths, and what the plausibility rules
-- removed. Rate changes per drip-day is the number of segments.
SELECT
  rate_source,
  COUNT(*)                                                          AS rows_,
  COUNTIF(is_drip)                                                  AS drip_segments,
  COUNT(DISTINCT IF(is_drip, stay_id, NULL))                        AS stays_with_a_drip,
  APPROX_QUANTILES(IF(is_drip, drip_rate, NULL), 100)[OFFSET(50)]   AS rate_p50_units_h,
  APPROX_QUANTILES(IF(is_drip, drip_rate, NULL), 100)[OFFSET(90)]   AS rate_p90,
  APPROX_QUANTILES(IF(is_drip, drip_rate, NULL), 100)[OFFSET(99)]   AS rate_p99,
  APPROX_QUANTILES(IF(is_drip, hours, NULL), 100)[OFFSET(50)]       AS segment_hours_p50,
  APPROX_QUANTILES(IF(is_drip, hours, NULL), 100)[OFFSET(90)]       AS segment_hours_p90,
  MAX(IF(is_drip, hours, NULL))                                     AS segment_hours_max,
  COUNTIF(rate_implausible)                                         AS rows_rate_implausible,
  COUNTIF(is_bolus)                                                 AS bolus_rows,
  COUNTIF(is_bolus AND bolus_units IS NULL)                         AS bolus_rows_without_usable_units
FROM `YOUR_PROJECT.hypo_tutorial.icu_insulin`
GROUP BY rate_source
ORDER BY rows_ DESC, rate_source;

-- Table 5. Where the subcutaneous doses come from, and whether they carry
-- units (the de-duplication rule and 00 section L, re-read on the cohort).
SELECT
  source,
  drug_class,
  COUNT(*)                                                     AS doses,
  ROUND(100 * COUNTIF(dose_units IS NOT NULL) / COUNT(*), 1)   AS pct_with_units,
  ROUND(AVG(dose_units), 2)                                    AS mean_units,
  APPROX_QUANTILES(dose_units, 100)[OFFSET(50)]                AS median_units,
  ROUND(100 * COUNTIF(insulin_iv) / COUNT(*), 1)               AS pct_iv_push_protocol
FROM `YOUR_PROJECT.hypo_tutorial.sc_doses`
GROUP BY source, drug_class
ORDER BY source, doses DESC, drug_class;

-- Table 6. eMAR dose availability per event text, insulin rows (and the
-- doses removed by the caps).
SELECT
  event_txt,
  COUNT(*)                                                             AS rows_,
  ROUND(100 * COUNTIF(dose_given_raw IS NOT NULL) / COUNT(*), 1)       AS pct_with_dose,
  COUNTIF(dose_given_raw IS NOT NULL AND dose_given IS NULL)           AS doses_removed_by_cap,
  ROUND(AVG(dose_given), 2)                                            AS mean_dose_capped,
  APPROX_QUANTILES(dose_given, 100)[OFFSET(50)]                        AS median_dose,
  ROUND(100 * COUNTIF(n_products > 0) / COUNT(*), 1)                   AS pct_with_child_rows,
  COUNTIF(infusion_confirmed)                                          AS infusion_confirmations,
  COUNTIF(pump_confirmed)                                              AS pump_confirmations
FROM `YOUR_PROJECT.hypo_tutorial.emar_cohort`
WHERE drug_class = 'insulin'
GROUP BY event_txt
HAVING COUNT(*) >= 1000
ORDER BY rows_ DESC, event_txt;

-- Table 7. Glucose monitoring density and the event rates, by whether a drip
-- was running at the landmark and which record says so. The ICU reason for
-- the pivot in one table: the share of rows with no result in the label
-- window should be small. The fourth run split the running rows by source
-- and settled the rule: rows running on an inputevents segment were checked
-- 15 to 17 times in 24 h with under 1% lacking a result and a low-glucose
-- rate of 1.9 to 3.0%; rows running on an eMAR interval alone split in two.
-- In 2020-2022, where the flowsheet is absent, they were checked 12.7 times
-- with a 2.4% event rate, a drip; in the eras where the flowsheet is
-- complete they were checked 8 to 10 times with the no-drip event rate (0.9
-- to 1.3%), an eMAR interval that outlived the drip. Hence flowsheet first.
-- The third category below shows the rows the rule now declines: an eMAR
-- interval open at t_k in a stay the flowsheet covers.
SELECT
  split,
  CASE
    WHEN drip_running_inputevents_at_tk = 1                      THEN 'inputevents'
    WHEN drip_running_emar_at_tk = 1                             THEN 'emar only (stay without flowsheet drips)'
    WHEN emar_interval_open_at_tk AND stay_has_inputevents_drip  THEN 'none (emar interval open, flowsheet stay)'
    ELSE 'none'
  END                                                                      AS running_source,
  COUNT(*)                                                                 AS rows_,
  ROUND(100 * COUNTIF(n_glucose_in_window = 0) / COUNT(*), 1)              AS pct_rows_no_result_in_window,
  ROUND(100 * COUNTIF(n_glucose_in_window = 1) / COUNT(*), 1)              AS pct_rows_one_result,
  ROUND(100 * COUNTIF(n_glucose_in_window >= 4) / COUNT(*), 1)             AS pct_rows_four_plus,
  ROUND(AVG(n_glucose_in_window), 2)                                       AS mean_results_in_window,
  SUM(y_lt54_24h)                                                          AS pos_lt54,
  ROUND(100 * AVG(y_lt54_24h), 2)                                          AS pct_lt54,
  SUM(y_gt300_24h)                                                         AS pos_gt300,
  ROUND(100 * AVG(y_gt300_24h), 2)                                         AS pct_gt300
FROM `YOUR_PROJECT.hypo_tutorial.cohort_landmarks`
GROUP BY split, running_source
ORDER BY split, running_source;

-- Table 8. Feeds and dextrose around the landmarks, and the rescue check:
-- a real < 54 event is usually followed by dextrose 50%. Among positive
-- rows, the share with a D50 amount within 2 h after the first low result
-- is evidence that the label finds treated events, not artefacts.
WITH lm AS (
  SELECT stay_id, k, t_k, y_lt54_24h, first_lt54_time
  FROM `YOUR_PROJECT.hypo_tutorial.cohort_landmarks`
),
running AS (
  SELECT
    l.stay_id, l.k,
    MAX(IF(n.kind = 'enteral'        AND n.starttime < l.t_k AND n.endtime >= l.t_k, 1, 0)) AS enteral_at_tk,
    MAX(IF(n.kind = 'parenteral'     AND n.starttime < l.t_k AND n.endtime >= l.t_k, 1, 0)) AS parenteral_at_tk,
    MAX(IF(n.kind = 'dextrose_fluid' AND n.starttime < l.t_k AND n.endtime >= l.t_k, 1, 0)) AS dextrose_fluid_at_tk,
    MAX(IF(n.kind = 'enteral'        AND n.starttime < l.t_k AND n.endtime >= DATETIME_SUB(l.t_k, INTERVAL 24 HOUR), 1, 0)) AS enteral_24h
  FROM lm AS l
  LEFT JOIN `YOUR_PROJECT.hypo_tutorial.icu_nutrition` AS n
    ON n.stay_id = l.stay_id
   AND n.starttime < l.t_k
   AND n.endtime  >= DATETIME_SUB(l.t_k, INTERVAL 24 HOUR)
  GROUP BY l.stay_id, l.k
),
rescue AS (
  SELECT
    l.stay_id, l.k,
    MAX(IF(d.stay_id IS NULL, 0, 1)) AS d50_after_event
  FROM lm AS l
  LEFT JOIN `YOUR_PROJECT.hypo_tutorial.icu_nutrition` AS d
    ON d.stay_id = l.stay_id
   AND d.kind = 'd50'
   AND d.starttime >= l.first_lt54_time
   AND d.starttime <  DATETIME_ADD(l.first_lt54_time, INTERVAL 2 HOUR)
  WHERE l.y_lt54_24h = 1
  GROUP BY l.stay_id, l.k
)
SELECT
  COUNT(*)                                                            AS rows_,
  ROUND(100 * AVG(r.enteral_at_tk), 1)                                AS pct_enteral_running_at_tk,
  ROUND(100 * AVG(r.enteral_24h), 1)                                  AS pct_enteral_in_last_24h,
  ROUND(100 * AVG(r.parenteral_at_tk), 1)                             AS pct_parenteral_at_tk,
  ROUND(100 * AVG(r.dextrose_fluid_at_tk), 1)                         AS pct_dextrose_fluid_at_tk,
  COUNTIF(l.y_lt54_24h = 1)                                           AS pos_lt54,
  ROUND(100 * SAFE_DIVIDE(SUM(s.d50_after_event), COUNTIF(l.y_lt54_24h = 1)), 1) AS pct_pos_with_d50_within_2h
FROM lm AS l
JOIN running AS r USING (stay_id, k)
LEFT JOIN rescue AS s USING (stay_id, k);

-- Table 9. Possible meter "LO" readings: fingerstick values charted as 0,
-- how many fall in an at-risk label window, and how many of those were not
-- rechecked >= 80 within 5 minutes. The stated sensitivity of the floor.
WITH zeros AS (
  SELECT s.hadm_id, ce.charttime
  FROM `YOUR_PROJECT.hypo_tutorial.src_chartevents` AS ce
  JOIN `physionet-data.mimiciv_3_1_icu.icustays`    AS s ON s.stay_id = ce.stay_id
  JOIN (SELECT DISTINCT hadm_id FROM `YOUR_PROJECT.hypo_tutorial.stay_base`) AS b ON b.hadm_id = s.hadm_id
  WHERE ce.itemid = 225664 AND ce.valuenum = 0
),
in_window AS (
  SELECT z.hadm_id, z.charttime, MAX(IF(l.hadm_id IS NULL, 0, 1)) AS in_at_risk_window
  FROM zeros AS z
  LEFT JOIN `YOUR_PROJECT.hypo_tutorial.cohort_landmarks` AS l
    ON l.hadm_id = z.hadm_id
   AND z.charttime >= l.t_k
   AND z.charttime <  l.window_end
  GROUP BY z.hadm_id, z.charttime
),
rechecked AS (
  SELECT z.hadm_id, z.charttime, MAX(IF(g.hadm_id IS NULL, 0, 1)) AS rechecked_normal_5min
  FROM zeros AS z
  LEFT JOIN `YOUR_PROJECT.hypo_tutorial.glucose_events` AS g
    ON g.hadm_id = z.hadm_id
   AND g.glucose >= 80
   AND g.charttime >  z.charttime
   AND DATETIME_DIFF(g.charttime, z.charttime, MINUTE) <= 5
  GROUP BY z.hadm_id, z.charttime
)
SELECT
  COUNT(*)                                                              AS fingerstick_zero_readings,
  SUM(w.in_at_risk_window)                                              AS inside_at_risk_label_window,
  COUNTIF(w.in_at_risk_window = 1 AND r.rechecked_normal_5min = 0)      AS would_have_been_events
FROM in_window AS w
JOIN rechecked AS r USING (hadm_id, charttime);

-- Table 10. Source coverage per era over every eligible ICU stay in the
-- database (not only the cohort): the share of stays with any inputevents
-- insulin row, with any eMAR insulin bolus, and with a glucose below 54 in
-- the ICU. Flat columns mean the early eras are safe to train on.
WITH stays AS (
  SELECT s.stay_id, s.hadm_id, s.intime, s.outtime, p.anchor_year_group
  FROM `physionet-data.mimiciv_3_1_icu.icustays`   AS s
  JOIN `physionet-data.mimiciv_3_1_hosp.patients`  AS p USING (subject_id)
  WHERE s.outtime > s.intime
    AND DATETIME_DIFF(s.outtime, s.intime, HOUR) >= 24
),
ie AS (
  SELECT DISTINCT ie.stay_id
  FROM `YOUR_PROJECT.hypo_tutorial.src_inputevents` AS ie
  JOIN `physionet-data.mimiciv_3_1_icu.d_items`     AS d USING (itemid)
  WHERE REGEXP_CONTAINS(LOWER(d.label), r'insulin')
),
em AS (
  SELECT DISTINCT s.stay_id
  FROM `YOUR_PROJECT.hypo_tutorial.src_emar` AS e
  JOIN stays AS s
    ON s.hadm_id = e.hadm_id
   AND e.charttime >= s.intime
   AND e.charttime <  s.outtime
  WHERE REGEXP_CONTAINS(LOWER(e.medication), r'insulin')
    AND REGEXP_CONTAINS(LOWER(COALESCE(e.event_txt, '')), r'administered|confirmed')
    AND NOT REGEXP_CONTAINS(LOWER(COALESCE(e.event_txt, '')), r'\bnot\b')
),
low AS (
  SELECT DISTINCT s.stay_id
  FROM `YOUR_PROJECT.hypo_tutorial.src_chartevents` AS ce
  JOIN stays AS s ON s.stay_id = ce.stay_id
  WHERE ce.itemid IN (220621, 225664, 226537)
    AND ce.valuenum >= 10
    AND ce.valuenum <  54
)
SELECT
  s.anchor_year_group,
  COUNT(*)                                                     AS eligible_stays,
  ROUND(100 * COUNTIF(ie.stay_id IS NOT NULL) / COUNT(*), 1)   AS pct_with_inputevents_insulin,
  ROUND(100 * COUNTIF(em.stay_id IS NOT NULL) / COUNT(*), 1)   AS pct_with_emar_insulin_bolus,
  ROUND(100 * COUNTIF(low.stay_id IS NOT NULL) / COUNT(*), 2)  AS pct_with_icu_glucose_lt54,
  ROUND(100 * SAFE_DIVIDE(COUNTIF((ie.stay_id IS NOT NULL OR em.stay_id IS NOT NULL) AND low.stay_id IS NOT NULL),
                          COUNTIF(ie.stay_id IS NOT NULL OR em.stay_id IS NOT NULL)), 2) AS pct_lt54_among_insulin_stays
FROM stays AS s
LEFT JOIN ie  USING (stay_id)
LEFT JOIN em  USING (stay_id)
LEFT JOIN low USING (stay_id)
GROUP BY s.anchor_year_group
ORDER BY s.anchor_year_group;

-- Table 11. Coverage of the added sources on the landmark rows, with the same
-- window rules 02 uses: the share of rows with dialysis at the landmark (and
-- continuous dialysis), any dialysis in the look-back, an antibiotic given in
-- the look-back, an antibiotic started in it, a culture collected in it (the
-- date-only rule for specimens without a charttime), both (the suspicion-of-
-- infection proxy), and octreotide from either source. Cells under 10
-- patients are suppressed in the deck, not here.
WITH lm AS (
  SELECT stay_id, hadm_id, k, t_k FROM `YOUR_PROJECT.hypo_tutorial.cohort_landmarks`
),
rrt AS (
  SELECT l.stay_id, l.k,
         MAX(IF(r.endtime > l.t_k, 1, 0))                                                   AS rrt_at_tk,
         MAX(IF(r.endtime > l.t_k AND r.rrt_kind = 'crrt', 1, 0))                           AS crrt_at_tk,
         MAX(IF(r.endtime > l.t_k AND r.source = 'chartevents', 1, 0))                      AS rrt_at_tk_chart_only,
         MAX(IF(r.rrt_kind = 'ihd', 1, 0))                                                  AS ihd_24h
  FROM lm AS l
  JOIN `YOUR_PROJECT.hypo_tutorial.icu_rrt` AS r
    ON r.stay_id = l.stay_id AND r.starttime < l.t_k AND r.endtime >= DATETIME_SUB(l.t_k, INTERVAL 24 HOUR)
  GROUP BY l.stay_id, l.k
),
abx AS (
  SELECT l.stay_id, l.k,
         MAX(IF(a.is_first_start_in_stay AND a.starttime >= DATETIME_SUB(l.t_k, INTERVAL 24 HOUR), 1, 0)) AS started_24h
  FROM lm AS l
  JOIN `YOUR_PROJECT.hypo_tutorial.icu_antibiotics` AS a
    ON a.stay_id = l.stay_id AND a.starttime < l.t_k AND a.endtime >= DATETIME_SUB(l.t_k, INTERVAL 24 HOUR)
  GROUP BY l.stay_id, l.k
),
cul AS (
  SELECT l.stay_id, l.k, COUNT(DISTINCT c.micro_specimen_id) AS n_cultures
  FROM lm AS l
  JOIN `YOUR_PROJECT.hypo_tutorial.cultures` AS c
    ON c.hadm_id = l.hadm_id
   AND ((NOT c.date_only AND c.collected_time >= DATETIME_SUB(l.t_k, INTERVAL 24 HOUR) AND c.collected_time < l.t_k)
     OR (c.date_only AND DATE(c.collected_time) >= DATE(DATETIME_SUB(l.t_k, INTERVAL 24 HOUR)) AND DATE(c.collected_time) < DATE(l.t_k)))
  GROUP BY l.stay_id, l.k
),
octr AS (
  SELECT l.stay_id, l.k, 1 AS octreotide_24h
  FROM lm AS l
  JOIN `YOUR_PROJECT.hypo_tutorial.emar_cohort` AS m
    ON m.hadm_id = l.hadm_id AND (m.bolus_given OR m.infusion_start) AND m.drug_class = 'octreotide'
   AND m.charttime >= DATETIME_SUB(l.t_k, INTERVAL 24 HOUR) AND m.charttime < l.t_k
  GROUP BY l.stay_id, l.k
  UNION DISTINCT
  SELECT l.stay_id, l.k, 1
  FROM lm AS l
  JOIN `YOUR_PROJECT.hypo_tutorial.icu_octreotide` AS o
    ON o.stay_id = l.stay_id AND o.starttime < l.t_k AND o.endtime >= DATETIME_SUB(l.t_k, INTERVAL 24 HOUR)
  GROUP BY l.stay_id, l.k
)
SELECT
  COUNT(*)                                                                   AS rows_,
  ROUND(100 * COUNTIF(r.rrt_at_tk = 1) / COUNT(*), 2)                        AS pct_rrt_at_tk,
  ROUND(100 * COUNTIF(r.crrt_at_tk = 1) / COUNT(*), 2)                       AS pct_crrt_at_tk,
  ROUND(100 * COUNTIF(r.rrt_at_tk_chart_only = 1) / COUNT(*), 2)             AS pct_rrt_at_tk_found_only_by_charting,
  ROUND(100 * COUNTIF(r.stay_id IS NOT NULL) / COUNT(*), 2)                  AS pct_rrt_24h,
  ROUND(100 * COUNTIF(r.ihd_24h = 1) / COUNT(*), 2)                          AS pct_ihd_24h,
  ROUND(100 * COUNTIF(a.stay_id IS NOT NULL) / COUNT(*), 1)                  AS pct_antibiotic_24h,
  ROUND(100 * COUNTIF(a.started_24h = 1) / COUNT(*), 1)                      AS pct_antibiotic_started_24h,
  ROUND(100 * COUNTIF(c.n_cultures > 0) / COUNT(*), 1)                       AS pct_culture_sent_24h,
  ROUND(100 * COUNTIF(a.started_24h = 1 AND c.n_cultures > 0) / COUNT(*), 1) AS pct_suspected_infection_24h,
  ROUND(100 * COUNTIF(o.octreotide_24h = 1) / COUNT(*), 2)                   AS pct_octreotide_24h
FROM lm AS l
LEFT JOIN rrt  AS r USING (stay_id, k)
LEFT JOIN abx  AS a USING (stay_id, k)
LEFT JOIN cul  AS c USING (stay_id, k)
LEFT JOIN octr AS o USING (stay_id, k);

-- Table 12. Where an insulin drip is visible, per era, over the same eligible
-- stays as Table 10. The first ICU run (11 October 2026) showed inputevents
-- insulin on 52% of eligible stays in 2008-2010 and 19% in 2020-2022 while
-- eMAR insulin boluses rose from 12% to 51% (Table 10), and the share of
-- landmark rows with a drip fell from 21% to 8% in the test era (Table 2). The
-- at-risk rule reads drips from inputevents only. If the test era charts its
-- drips on the eMAR (Started / Restarted / Stopped events, 00 sections D and
-- F) instead of MetaVision, the rule misses them there and the test set is
-- not the training set's population. Per era: stays with an inputevents drip
-- row (a Continuous Med or Continuous IV insulin row that is not Rewritten,
-- before the rate-plausibility rule), with an eMAR insulin infusion start
-- inside the stay, with both, with each alone, and with a Confirmed insulin
-- row (Table 13 asks what those are).
WITH stays AS (
  SELECT s.stay_id, s.hadm_id, s.intime, s.outtime, p.anchor_year_group
  FROM `physionet-data.mimiciv_3_1_icu.icustays`   AS s
  JOIN `physionet-data.mimiciv_3_1_hosp.patients`  AS p USING (subject_id)
  WHERE s.outtime > s.intime
    AND DATETIME_DIFF(s.outtime, s.intime, HOUR) >= 24
),
ie AS (
  SELECT DISTINCT ie.stay_id
  FROM `YOUR_PROJECT.hypo_tutorial.src_inputevents` AS ie
  JOIN `physionet-data.mimiciv_3_1_icu.d_items`     AS d USING (itemid)
  WHERE REGEXP_CONTAINS(LOWER(d.label), (SELECT inputevents_insulin_regex FROM `YOUR_PROJECT.hypo_tutorial.agent_patterns`))
    AND REGEXP_CONTAINS(LOWER(COALESCE(ie.ordercategorydescription, '')), r'continuous')
    AND COALESCE(ie.statusdescription, '') NOT IN ('Rewritten', 'Bolus')
),
em_rows AS (
  SELECT s.stay_id, LOWER(COALESCE(e.event_txt, '')) AS evt
  FROM `YOUR_PROJECT.hypo_tutorial.src_emar` AS e
  JOIN stays AS s
    ON s.hadm_id = e.hadm_id
   AND e.charttime >= s.intime
   AND e.charttime <  s.outtime
  WHERE REGEXP_CONTAINS(LOWER(e.medication), (SELECT insulin_regex FROM `YOUR_PROJECT.hypo_tutorial.agent_patterns`))
),
em AS (
  SELECT DISTINCT stay_id FROM em_rows
  WHERE REGEXP_CONTAINS(evt, r'\bstarted|restarted') AND NOT REGEXP_CONTAINS(evt, r'\bnot\b')
),
emc AS (
  SELECT DISTINCT stay_id FROM em_rows
  WHERE REGEXP_CONTAINS(evt, r'confirmed') AND NOT REGEXP_CONTAINS(evt, r'\bnot\b')
)
SELECT
  s.anchor_year_group,
  COUNT(*)                                                                               AS eligible_stays,
  ROUND(100 * COUNTIF(ie.stay_id IS NOT NULL) / COUNT(*), 1)                             AS pct_inputevents_drip,
  ROUND(100 * COUNTIF(em.stay_id IS NOT NULL) / COUNT(*), 1)                             AS pct_emar_infusion_started,
  ROUND(100 * COUNTIF(ie.stay_id IS NOT NULL AND em.stay_id IS NOT NULL) / COUNT(*), 1)  AS pct_both,
  ROUND(100 * COUNTIF(ie.stay_id IS NOT NULL AND em.stay_id IS NULL) / COUNT(*), 1)      AS pct_inputevents_only,
  ROUND(100 * COUNTIF(ie.stay_id IS NULL AND em.stay_id IS NOT NULL) / COUNT(*), 1)      AS pct_emar_only,
  ROUND(100 * COUNTIF(emc.stay_id IS NOT NULL) / COUNT(*), 1)                            AS pct_emar_insulin_confirmed
FROM stays AS s
LEFT JOIN ie  USING (stay_id)
LEFT JOIN em  USING (stay_id)
LEFT JOIN emc USING (stay_id)
GROUP BY s.anchor_year_group
ORDER BY s.anchor_year_group;

-- Table 13. What an eMAR "Confirmed" insulin row is. 00 section D2 read it as
-- a nurse confirming self-administered insulin (pump patients) and the first
-- ICU run carried it as self_admin, a flag that landed on 38.5% of landmark
-- rows with a drip running against 6.9% without one. This table settled it:
-- 48,861 of 48,864 cohort rows carry the administration type "Insulin
-- Infusion (IV Drip)" and 72.8% fall inside an inputevents drip segment (one
-- hour of tolerance either side); 79.3% are on admissions with such a
-- segment, the rest on admissions whose drip inputevents never recorded.
-- Confirmed is therefore drip evidence (view 2b) and never a dose. Kept as
-- the standing check: grouped by administration_type so the vocabulary is
-- read, not assumed.
WITH cohort_adm AS (
  SELECT DISTINCT hadm_id FROM `YOUR_PROJECT.hypo_tutorial.stay_base`
),
confirmed AS (
  SELECT e.emar_id, e.hadm_id, e.charttime, e.dose_given, e.administration_type
  FROM `YOUR_PROJECT.hypo_tutorial.src_emar` AS e
  JOIN cohort_adm AS b USING (hadm_id)
  WHERE REGEXP_CONTAINS(LOWER(e.medication), (SELECT insulin_regex FROM `YOUR_PROJECT.hypo_tutorial.agent_patterns`))
    AND REGEXP_CONTAINS(LOWER(COALESCE(e.event_txt, '')), r'confirmed')
    AND NOT REGEXP_CONTAINS(LOWER(COALESCE(e.event_txt, '')), r'\bnot\b')
),
drips AS (
  SELECT hadm_id, starttime, endtime FROM `YOUR_PROJECT.hypo_tutorial.icu_insulin` WHERE is_drip
),
adm_with_drip AS (
  SELECT DISTINCT hadm_id FROM drips
),
inside AS (
  SELECT DISTINCT c.emar_id
  FROM confirmed AS c
  JOIN drips AS d
    ON d.hadm_id = c.hadm_id
   AND c.charttime >= DATETIME_SUB(d.starttime, INTERVAL 1 HOUR)
   AND c.charttime <= DATETIME_ADD(d.endtime,   INTERVAL 1 HOUR)
)
SELECT
  COALESCE(c.administration_type, '(none)')                                  AS administration_type,
  COUNT(*)                                                                   AS confirmed_insulin_rows,
  COUNT(DISTINCT c.hadm_id)                                                  AS admissions,
  ROUND(100 * COUNTIF(i.emar_id IS NOT NULL) / COUNT(*), 1)                  AS pct_inside_an_inputevents_drip,
  ROUND(100 * COUNTIF(a.hadm_id IS NOT NULL) / COUNT(*), 1)                  AS pct_on_an_admission_with_a_drip,
  ROUND(100 * COUNTIF(c.dose_given IS NOT NULL) / COUNT(*), 1)               AS pct_with_dose
FROM confirmed AS c
LEFT JOIN inside        AS i USING (emar_id)
LEFT JOIN adm_with_drip AS a USING (hadm_id)
GROUP BY administration_type
ORDER BY confirmed_insulin_rows DESC, administration_type
LIMIT 20;

-- Table 14. ICU module completeness per era, over the eligible stays of the
-- universe (00b: admissions with a hypoglycemic agent before the last ICU
-- discharge; every src_* extract is complete for them within the items it
-- keeps). Table 12 showed inputevents insulin drips on 9% of 2020-2022 stays
-- against 20% before, with the eMAR flat at 20%. The question this answers:
-- did inputevents lose insulin in that era, or everything? Per era, the share
-- of universe stays with any extracted inputevents row, a continuous
-- infusion row of any drug, a vasopressor, an antibiotic, an enteral feed, a
-- dextrose-containing fluid; any procedureevents row and a ventilation
-- interval; an hourly heart rate and a GCS charting. A column that falls
-- with insulin names a table that is thin in the test era, and every feature
-- built from it. Reads the extracts only, so both routes can run it.
WITH stays AS (
  SELECT s.stay_id, s.hadm_id, p.anchor_year_group
  FROM `physionet-data.mimiciv_3_1_icu.icustays`   AS s
  JOIN `physionet-data.mimiciv_3_1_hosp.patients`  AS p USING (subject_id)
  JOIN `YOUR_PROJECT.hypo_tutorial.src_universe`   AS u USING (hadm_id)
  WHERE s.outtime > s.intime
    AND DATETIME_DIFF(s.outtime, s.intime, HOUR) >= 24
),
eligible AS (
  SELECT p.anchor_year_group, COUNT(*) AS eligible_stays
  FROM `physionet-data.mimiciv_3_1_icu.icustays`   AS s
  JOIN `physionet-data.mimiciv_3_1_hosp.patients`  AS p USING (subject_id)
  WHERE s.outtime > s.intime
    AND DATETIME_DIFF(s.outtime, s.intime, HOUR) >= 24
  GROUP BY p.anchor_year_group
),
ie AS (
  SELECT ie.stay_id,
         1                                                                                                      AS any_row,
         MAX(IF(REGEXP_CONTAINS(LOWER(COALESCE(ie.ordercategorydescription, '')), r'continuous'), 1, 0))        AS continuous,
         MAX(IF(ie.itemid IN (221906, 221289, 221662, 221653, 222315, 221749, 221986), 1, 0))                    AS vasopressor,
         MAX(IF(REGEXP_CONTAINS(LOWER(COALESCE(d.category, '')), r'antibiotics'), 1, 0))                        AS antibiotic,
         MAX(IF(REGEXP_CONTAINS(LOWER(COALESCE(d.category, '')), r'enteral')
                AND NOT REGEXP_CONTAINS(LOWER(COALESCE(d.category, '')), r'parenteral'), 1, 0))                 AS enteral,
         MAX(IF(REGEXP_CONTAINS(LOWER(d.label), r'dextrose|\bd5|\bd10|\bd20|\bd30|\bd50'), 1, 0))               AS dextrose
  FROM `YOUR_PROJECT.hypo_tutorial.src_inputevents` AS ie
  JOIN `physionet-data.mimiciv_3_1_icu.d_items`     AS d USING (itemid)
  JOIN stays USING (stay_id)
  GROUP BY ie.stay_id
),
pe AS (
  SELECT pe.stay_id, 1 AS any_row, MAX(IF(pe.itemid IN (225792, 225794), 1, 0)) AS ventilation
  FROM `YOUR_PROJECT.hypo_tutorial.src_procedureevents` AS pe
  JOIN stays USING (stay_id)
  GROUP BY pe.stay_id
),
ce AS (
  SELECT ce.stay_id,
         MAX(IF(ce.itemid = 220045, 1, 0)) AS heart_rate,
         MAX(IF(ce.itemid = 220739, 1, 0)) AS gcs
  FROM `YOUR_PROJECT.hypo_tutorial.src_chartevents` AS ce
  JOIN stays USING (stay_id)
  WHERE ce.itemid IN (220045, 220739)
  GROUP BY ce.stay_id
)
SELECT
  s.anchor_year_group,
  e.eligible_stays,
  COUNT(*)                                                                 AS universe_stays,
  ROUND(100 * COUNT(*) / e.eligible_stays, 1)                              AS pct_of_eligible_in_universe,
  ROUND(100 * COUNTIF(COALESCE(ie.any_row, 0) = 1) / COUNT(*), 1)          AS pct_any_extracted_inputevents,
  ROUND(100 * COUNTIF(COALESCE(ie.continuous, 0) = 1) / COUNT(*), 1)       AS pct_continuous_infusion_any_drug,
  ROUND(100 * COUNTIF(COALESCE(ie.vasopressor, 0) = 1) / COUNT(*), 1)      AS pct_vasopressor,
  ROUND(100 * COUNTIF(COALESCE(ie.antibiotic, 0) = 1) / COUNT(*), 1)       AS pct_antibiotic,
  ROUND(100 * COUNTIF(COALESCE(ie.enteral, 0) = 1) / COUNT(*), 1)          AS pct_enteral_feed,
  ROUND(100 * COUNTIF(COALESCE(ie.dextrose, 0) = 1) / COUNT(*), 1)         AS pct_dextrose_fluid,
  ROUND(100 * COUNTIF(COALESCE(pe.any_row, 0) = 1) / COUNT(*), 1)          AS pct_any_procedureevents,
  ROUND(100 * COUNTIF(COALESCE(pe.ventilation, 0) = 1) / COUNT(*), 1)      AS pct_ventilation,
  ROUND(100 * COUNTIF(COALESCE(ce.heart_rate, 0) = 1) / COUNT(*), 1)       AS pct_heart_rate_charted,
  ROUND(100 * COUNTIF(COALESCE(ce.gcs, 0) = 1) / COUNT(*), 1)              AS pct_gcs_charted
FROM stays AS s
JOIN eligible AS e USING (anchor_year_group)
LEFT JOIN ie USING (stay_id)
LEFT JOIN pe USING (stay_id)
LEFT JOIN ce USING (stay_id)
GROUP BY s.anchor_year_group, e.eligible_stays
ORDER BY s.anchor_year_group;

-- Table 15. The eMAR infusion intervals (view 2b) and what they add to the
-- cohort, per era. First the intervals: how many, how they end (Stopped,
-- the next start, the cap), their length, the confirmations inside them,
-- the longest gap between consecutive events inside closed intervals (the
-- evidence for INFUSION_CAP_HOURS), how many opened on a Confirmed with no
-- Started, and how many overlap an inputevents drip segment on the same
-- admission. Then the landmark rows: the share with a drip from either
-- source, from inputevents, from the eMAR, from the eMAR alone, and the
-- share at risk only because of an eMAR interval (no dose and no inputevents
-- segment in the look-back): the rows the first run's rule did not have.
WITH iv AS (
  SELECT i.*, p.anchor_year_group,
         EXISTS (SELECT 1 FROM `YOUR_PROJECT.hypo_tutorial.icu_insulin` AS d
                 WHERE d.hadm_id = i.hadm_id AND d.is_drip
                   AND d.starttime < i.end_time AND d.endtime > i.start_time) AS overlaps_inputevents_drip
  FROM `YOUR_PROJECT.hypo_tutorial.emar_insulin_infusions` AS i
  JOIN `physionet-data.mimiciv_3_1_hosp.admissions` AS a USING (hadm_id)
  JOIN `physionet-data.mimiciv_3_1_hosp.patients`   AS p ON p.subject_id = a.subject_id
),
intervals AS (
  SELECT
    anchor_year_group,
    COUNT(*)                                                                 AS emar_intervals,
    ROUND(100 * COUNTIF(end_reason = 'stopped') / COUNT(*), 1)               AS pct_closed_by_stopped,
    ROUND(100 * COUNTIF(end_reason = 'restarted') / COUNT(*), 1)             AS pct_closed_by_next_start,
    ROUND(100 * COUNTIF(end_reason = 'cap') / COUNT(*), 1)                   AS pct_closed_by_cap,
    ROUND(APPROX_QUANTILES(DATETIME_DIFF(end_time, start_time, MINUTE) / 60.0, 100)[OFFSET(50)], 1) AS hours_p50,
    ROUND(APPROX_QUANTILES(DATETIME_DIFF(end_time, start_time, MINUTE) / 60.0, 100)[OFFSET(90)], 1) AS hours_p90,
    ROUND(AVG(n_confirmations), 1)                                           AS confirmations_per_interval,
    ROUND(APPROX_QUANTILES(IF(end_reason = 'stopped', max_evidence_gap_hours, NULL), 100)[OFFSET(50)], 1) AS evidence_gap_hours_p50_closed,
    ROUND(APPROX_QUANTILES(IF(end_reason = 'stopped', max_evidence_gap_hours, NULL), 100)[OFFSET(90)], 1) AS evidence_gap_hours_p90_closed,
    ROUND(APPROX_QUANTILES(IF(end_reason = 'stopped', max_evidence_gap_hours, NULL), 100)[OFFSET(99)], 1) AS evidence_gap_hours_p99_closed,
    ROUND(100 * COUNTIF(NOT has_start_event) / COUNT(*), 1)                 AS pct_opened_by_confirmed_only,
    ROUND(100 * COUNTIF(overlaps_inputevents_drip) / COUNT(*), 1)            AS pct_overlapping_an_inputevents_drip
  FROM iv
  GROUP BY anchor_year_group
),
rows_ AS (
  SELECT
    anchor_year_group,
    COUNT(*)                                                                                   AS landmark_rows,
    ROUND(100 * AVG(insulin_drip_24h), 1)                                                      AS pct_with_drip,
    ROUND(100 * AVG(drip_inputevents_24h), 1)                                                  AS pct_drip_inputevents,
    ROUND(100 * AVG(drip_emar_24h), 1)                                                         AS pct_drip_emar,
    ROUND(100 * AVG(IF(drip_emar_24h = 1 AND drip_inputevents_24h = 0, 1, 0)), 1)              AS pct_drip_emar_only,
    ROUND(100 * AVG(IF(drip_emar_24h = 1 AND drip_inputevents_24h = 0 AND n_doses_24h = 0, 1, 0)), 1) AS pct_at_risk_only_through_emar_drip,
    ROUND(100 * AVG(drip_running_at_tk), 1)                                                    AS pct_drip_running_at_tk,
    ROUND(100 * AVG(IF(drip_running_emar_at_tk = 1 AND drip_running_inputevents_at_tk = 0, 1, 0)), 1) AS pct_running_emar_only_at_tk,
    ROUND(100 * AVG(IF(emar_interval_open_at_tk AND stay_has_inputevents_drip AND drip_running_inputevents_at_tk = 0, 1, 0)), 1) AS pct_emar_open_declined_at_tk
  FROM `YOUR_PROJECT.hypo_tutorial.cohort_landmarks`
  GROUP BY anchor_year_group
)
SELECT r.anchor_year_group, r.landmark_rows, r.pct_with_drip, r.pct_drip_inputevents, r.pct_drip_emar,
       r.pct_drip_emar_only, r.pct_at_risk_only_through_emar_drip, r.pct_drip_running_at_tk, r.pct_running_emar_only_at_tk,
       r.pct_emar_open_declined_at_tk,
       i.* EXCEPT (anchor_year_group)
FROM rows_ AS r
LEFT JOIN intervals AS i USING (anchor_year_group)
ORDER BY r.anchor_year_group;

-- Table 16. The 2020-2022 flowsheet gap by care unit. Table 14 (third run)
-- found inputevents rows on 37.7% and procedureevents rows on 40.6% of the
-- universe stays of 2020-2022 against 88 to 96% in every earlier era, with
-- chartevents complete. Whether the gap sits in particular units (a charting
-- system that changed in those units) or falls evenly (an export that
-- stopped) decides how it is described on the slide and whether a unit
-- subgroup of the test era has complete features. Per first care unit, for
-- the two latest eras: stays, the share with any extracted inputevents row,
-- with any procedureevents row, and with an eMAR insulin row inside the stay.
WITH stays AS (
  SELECT s.stay_id, s.hadm_id, s.intime, s.outtime, s.first_careunit, p.anchor_year_group
  FROM `physionet-data.mimiciv_3_1_icu.icustays`   AS s
  JOIN `physionet-data.mimiciv_3_1_hosp.patients`  AS p USING (subject_id)
  JOIN `YOUR_PROJECT.hypo_tutorial.src_universe`   AS u USING (hadm_id)
  WHERE s.outtime > s.intime
    AND DATETIME_DIFF(s.outtime, s.intime, HOUR) >= 24
    AND p.anchor_year_group IN ('2017 - 2019', '2020 - 2022')
),
ie AS (SELECT DISTINCT stay_id FROM `YOUR_PROJECT.hypo_tutorial.src_inputevents`),
pe AS (SELECT DISTINCT stay_id FROM `YOUR_PROJECT.hypo_tutorial.src_procedureevents`),
em AS (
  SELECT DISTINCT s.stay_id
  FROM `YOUR_PROJECT.hypo_tutorial.src_emar` AS e
  JOIN stays AS s
    ON s.hadm_id = e.hadm_id AND e.charttime >= s.intime AND e.charttime < s.outtime
  WHERE REGEXP_CONTAINS(LOWER(e.medication), (SELECT insulin_regex FROM `YOUR_PROJECT.hypo_tutorial.agent_patterns`))
)
SELECT
  s.anchor_year_group,
  s.first_careunit,
  COUNT(*)                                                             AS universe_stays,
  ROUND(100 * COUNTIF(ie.stay_id IS NOT NULL) / COUNT(*), 1)           AS pct_any_extracted_inputevents,
  ROUND(100 * COUNTIF(pe.stay_id IS NOT NULL) / COUNT(*), 1)           AS pct_any_procedureevents,
  ROUND(100 * COUNTIF(em.stay_id IS NOT NULL) / COUNT(*), 1)           AS pct_emar_insulin_in_stay
FROM stays AS s
LEFT JOIN ie USING (stay_id)
LEFT JOIN pe USING (stay_id)
LEFT JOIN em USING (stay_id)
GROUP BY s.anchor_year_group, s.first_careunit
HAVING COUNT(*) >= 50
ORDER BY s.anchor_year_group, universe_stays DESC, s.first_careunit;

-- Table 17. The 2020-2022 gap by year relative to the anchor year. Table 16
-- (fourth run) showed the gap evenly across care units (31 to 40% of stays
-- with inputevents in every ICU of 2020-2022 against 88 to 97% in 2017-2019),
-- so it is not a charting system that changed in some units. The remaining
-- question is when it starts: a patient's dates are shifted by one offset,
-- so admittime year minus anchor_year is the real number of years after the
-- anchor year, and a gap that opens at a fixed offset is an export that
-- stopped on a date. Per era and offset: universe stays, the share with any
-- extracted inputevents row and with any procedureevents row.
WITH stays AS (
  SELECT s.stay_id, p.anchor_year_group,
         EXTRACT(YEAR FROM a.admittime) - p.anchor_year AS years_after_anchor
  FROM `physionet-data.mimiciv_3_1_icu.icustays`    AS s
  JOIN `physionet-data.mimiciv_3_1_hosp.admissions` AS a USING (hadm_id)
  JOIN `physionet-data.mimiciv_3_1_hosp.patients`   AS p ON p.subject_id = s.subject_id
  JOIN `YOUR_PROJECT.hypo_tutorial.src_universe`    AS u ON u.hadm_id = s.hadm_id
  WHERE s.outtime > s.intime
    AND DATETIME_DIFF(s.outtime, s.intime, HOUR) >= 24
    AND p.anchor_year_group IN ('2017 - 2019', '2020 - 2022')
),
ie AS (SELECT DISTINCT stay_id FROM `YOUR_PROJECT.hypo_tutorial.src_inputevents`),
pe AS (SELECT DISTINCT stay_id FROM `YOUR_PROJECT.hypo_tutorial.src_procedureevents`)
SELECT
  s.anchor_year_group,
  s.years_after_anchor,
  COUNT(*)                                                             AS universe_stays,
  ROUND(100 * COUNTIF(ie.stay_id IS NOT NULL) / COUNT(*), 1)           AS pct_any_extracted_inputevents,
  ROUND(100 * COUNTIF(pe.stay_id IS NOT NULL) / COUNT(*), 1)           AS pct_any_procedureevents
FROM stays AS s
LEFT JOIN ie USING (stay_id)
LEFT JOIN pe USING (stay_id)
GROUP BY s.anchor_year_group, s.years_after_anchor
HAVING COUNT(*) >= 50
ORDER BY s.anchor_year_group, s.years_after_anchor;


-- Table 18. The repeat-test rule, before and after release .20. Over the
-- de-duplicated glucose stream of cohort admissions, per value band: how
-- many results the rule now cancels (a result below 54 contradicted by any
-- result above 80 charted within 300 seconds) and how many the rule before
-- release .20 flagged (any result whose NEXT result was >= 80 within 5 whole
-- minutes, with no "low" condition). The bands at or above 54 must show 0 in
-- the new column; what the old column shows there is what the old rule took
-- out of the glucose history and the > 300 label.
WITH g AS (
  SELECT g.*,
         LEAD(charttime) OVER w AS next_time,
         LEAD(glucose)   OVER w AS next_glucose
  FROM `YOUR_PROJECT.hypo_tutorial.glucose_events` AS g
  WINDOW w AS (PARTITION BY hadm_id ORDER BY charttime, glucose)
)
SELECT
  CASE WHEN glucose < 40 THEN '1: < 40' WHEN glucose < 54 THEN '2: 40 - 53' WHEN glucose < 80 THEN '3: 54 - 79'
       WHEN glucose <= 300 THEN '4: 80 - 300' ELSE '5: > 300' END                                  AS band,
  COUNT(*)                                                                                         AS results,
  COUNTIF(cancelled_by_repeat)                                                                     AS cancelled_now,
  COUNTIF(COALESCE(next_glucose >= 80 AND DATETIME_DIFF(next_time, charttime, MINUTE) <= 5, FALSE)) AS flagged_by_old_rule,
  COUNTIF(cancelled_by_repeat AND repeat_storetime > storetime)                                     AS cancelled_with_repeat_visible_later
FROM g
GROUP BY band
ORDER BY band;

-- Table 19. Where the rows of each split fall relative to the patient's
-- anchor year. The split is by anchor_year_group, so a patient's later
-- admissions keep the group whatever year they fall in; this table says how
-- much of each split is anchor-year admissions (years_after_anchor = 0, the
-- rows the notebook's anchor-year-only sensitivity keeps) and how far the
-- rest reach. The implied calendar range of an admission is the group's
-- three years shifted by the offset.
SELECT
  split,
  anchor_year_group,
  years_after_anchor,
  COUNT(*)                                                                   AS rows_,
  COUNT(DISTINCT stay_id)                                                    AS stays,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY split), 1)         AS pct_of_split_rows,
  SUM(y_lt54_24h)                                                            AS events_lt54
FROM `YOUR_PROJECT.hypo_tutorial.cohort_landmarks`
GROUP BY split, anchor_year_group, years_after_anchor
HAVING COUNT(*) >= 10
ORDER BY split, anchor_year_group, years_after_anchor;

-- Table 20. When each predictor record became visible, against the time the
-- features use it at. For point observations (vitals, weight, GCS; the
-- glucose stream) the entry lag storetime - charttime: 02 requires both
-- before the landmark, so the lag is what the both-times rule removes near
-- a landmark. For interval records (insulin drip segments from inputevents,
-- eMAR insulin events) the row is stored when it is finalised, usually at or
-- after its end, while the fact it carries (an infusion started at this
-- time at this rate) was visible at the bedside from its start; 02 reads a
-- running segment clipped at the landmark and never its end or its total
-- amount, which is why the storetime rule is not applied to intervals. This
-- table is the evidence for that distinction: per record kind, the lag
-- percentiles and the share of rows stored after the time the feature uses.
WITH chart AS (
  SELECT CASE WHEN itemid IN (220621, 225664, 226537) THEN 'chartevents: glucose'
              WHEN itemid IN (226512, 224639) THEN 'chartevents: weight'
              WHEN itemid IN (220739, 223900, 223901) THEN 'chartevents: GCS'
              WHEN itemid IN (220045, 220179, 220050, 220210, 220277, 223761, 223762) THEN 'chartevents: vitals'
              ELSE NULL END AS kind,
         DATETIME_DIFF(storetime, charttime, MINUTE) AS lag_min
  FROM `YOUR_PROJECT.hypo_tutorial.src_chartevents`
  WHERE storetime IS NOT NULL
),
drips AS (
  SELECT 'inputevents: insulin drip segment, store - start' AS kind, DATETIME_DIFF(storetime, starttime, MINUTE) AS lag_min
  FROM `YOUR_PROJECT.hypo_tutorial.icu_insulin` WHERE is_drip AND storetime IS NOT NULL
  UNION ALL
  SELECT 'inputevents: insulin drip segment, store - end', DATETIME_DIFF(storetime, endtime, MINUTE)
  FROM `YOUR_PROJECT.hypo_tutorial.icu_insulin` WHERE is_drip AND storetime IS NOT NULL
),
emar AS (
  SELECT 'emar: insulin event, store - chart' AS kind, DATETIME_DIFF(e.storetime, e.charttime, MINUTE) AS lag_min
  FROM `YOUR_PROJECT.hypo_tutorial.src_emar` AS e
  JOIN (SELECT DISTINCT hadm_id FROM `YOUR_PROJECT.hypo_tutorial.cohort_landmarks`) AS c USING (hadm_id)
  WHERE e.storetime IS NOT NULL
    AND REGEXP_CONTAINS(LOWER(e.medication), r'insulin')
),
lags AS (
  SELECT kind, lag_min FROM chart WHERE kind IS NOT NULL
  UNION ALL SELECT kind, lag_min FROM drips
  UNION ALL SELECT kind, lag_min FROM emar
)
SELECT
  kind,
  COUNT(*)                                                    AS rows_,
  ROUND(100 * COUNTIF(lag_min > 0) / COUNT(*), 2)             AS pct_stored_after,
  ROUND(100 * COUNTIF(lag_min > 60) / COUNT(*), 2)            AS pct_stored_more_than_1h_after,
  APPROX_QUANTILES(lag_min, 100)[OFFSET(50)]                  AS lag_p50_min,
  APPROX_QUANTILES(lag_min, 100)[OFFSET(90)]                  AS lag_p90_min,
  APPROX_QUANTILES(lag_min, 100)[OFFSET(99)]                  AS lag_p99_min
FROM lags
GROUP BY kind
ORDER BY kind;
