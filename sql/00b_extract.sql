-- =====================================================================
--  00b_extract.sql   (BigQuery Standard SQL, MIMIC-IV v3.1)
--
--  The one pass over the full physionet-data tables. Run it once per project;
--  01, 02 and 03 read only the tables it writes.
--
--  Why this file exists. BigQuery bills a query by the bytes of the columns
--  it reads, not by the rows it returns, and the physionet-data tables are
--  neither partitioned nor clustered, so a query that touches
--  icu.chartevents (433 million rows) reads the whole of every column it
--  names, 3.2 GiB per 8-byte column, however narrow its WHERE clause. The
--  first version of this tutorial read chartevents seven times in 00 and
--  another seven across 01 to 03, and the free tier of 1 TiB a month was
--  used up in a day of iterating. The README's cost section has the
--  measured numbers.
--
--  Why it is this small. The BigQuery sandbox (a project with no billing
--  account, which is what a student has) grants a LIFETIME 10 GiB of storage
--  for the project: Google's sandbox page says the quota "is not refunded
--  upon data deletion". Every CREATE OR REPLACE TABLE spends it, dropping a
--  table gives nothing back, and tables expire after 60 days. So this file
--  is written to run exactly once per project (pipeline/run_bigquery.py
--  refuses a second run), the extracts are cut to the rows and columns the
--  pipeline reads, and 01 to 03 create VIEWS over them plus two one-row
--  tables and the landmark table. Columns a later file can recover from a
--  small table are not stored twice: hadm_id and subject_id of a chart row
--  come from icustays, a chart item's unit from d_items.
--
--  The universe. The cohort is "ICU days with a hypoglycemic agent in the
--  previous 24 h", so an admission in which no insulin, sulfonylurea or
--  meglitinide was ever given before the last ICU discharge can never
--  produce a row, and its labs, eMAR, flowsheet and procedure rows are never
--  read. Statement 1 finds the admissions that can (any eMAR row naming one
--  of these agents, whatever its event text, or any inputevents insulin row;
--  a superset of what 01 counts as an administration) and every other
--  statement keeps only their rows. The one exception is ICU glucose, which
--  is kept for every stay: 01 tables 9 and 10 report meter zeros and
--  hypoglycemia across all eligible stays, insulin or not. The agent
--  patterns are written to hypo_tutorial.agent_patterns and 01 reads them
--  from there, so the universe and the classification cannot drift apart;
--  changing them is, by construction, a new extract.
--
--  What it does not do. Nothing here depends on the DECLAREs of 01
--  (eligibility, caps, windows, item classes found by label): the extract
--  covers every stay of every universe admission and every item on the
--  verified lists, so changing 01, 02 or 03 never requires re-running this
--  file, with the one exception above. The sanity file 00 still reads
--  physionet-data in full, because its sections look for things outside
--  these lists; it is the author's discovery pass, its results are recorded
--  in docs/sanity_findings.md and docs/sanity_results/, and a student re-runs
--  a section only to verify it, knowing the cost.
--
--  Clustering. Every extract is clustered by itemid first, so a query that
--  names an item list (the glucose items, the dialysis items, the vasopressor
--  items) reads only the blocks that hold them; the vitals are most of
--  src_chartevents and are read whole by 02, which is the one scan that
--  cannot be cheaper.
--
--  Privacy: the extract lives in the credentialed user's own project, as the
--  mimic-code derived tables do. Nothing leaves BigQuery except the aggregate
--  tables and, through the pull step, the final parquet files, which stay
--  with the user.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS `YOUR_PROJECT.hypo_tutorial`;


-- ---------------------------------------------------------------------
-- 1. The agent patterns (one row; 01 reads them) and the universe: the
--    admissions with an ICU stay in which a hypoglycemic agent appears before
--    the last ICU discharge, from either source. Reads emar once (hadm_id,
--    charttime, medication) and inputevents once (hadm_id, itemid).
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE `YOUR_PROJECT.hypo_tutorial.agent_patterns` AS
SELECT
  r'insulin'                                                                           AS insulin_regex,
  r'glipizide|glyburide|glibenclamide|glimepiride|tolbutamide|chlorpropamide|tolazamide' AS sulfonylurea_regex,
  r'repaglinide|nateglinide'                                                           AS meglitinide_regex,
  r'insulin'                                                                           AS inputevents_insulin_regex;

CREATE OR REPLACE TABLE `YOUR_PROJECT.hypo_tutorial.src_universe` AS
WITH icu_adm AS (
  SELECT hadm_id, MIN(intime) AS first_icu_in, MAX(outtime) AS last_icu_out
  FROM `physionet-data.mimiciv_3_1_icu.icustays`
  GROUP BY hadm_id
),
p AS (SELECT * FROM `YOUR_PROJECT.hypo_tutorial.agent_patterns`),
emar_hit AS (
  SELECT DISTINCT em.hadm_id
  FROM `physionet-data.mimiciv_3_1_hosp.emar` AS em
  JOIN icu_adm AS w USING (hadm_id)
  CROSS JOIN p
  WHERE em.charttime <= w.last_icu_out
    AND em.medication IS NOT NULL
    AND (REGEXP_CONTAINS(LOWER(em.medication), p.insulin_regex)
         OR REGEXP_CONTAINS(LOWER(em.medication), p.sulfonylurea_regex)
         OR REGEXP_CONTAINS(LOWER(em.medication), p.meglitinide_regex))
),
ie_hit AS (
  SELECT DISTINCT ie.hadm_id
  FROM `physionet-data.mimiciv_3_1_icu.inputevents` AS ie
  JOIN `physionet-data.mimiciv_3_1_icu.d_items`     AS d USING (itemid)
  CROSS JOIN p
  WHERE d.linksto = 'inputevents'
    AND REGEXP_CONTAINS(LOWER(d.label), p.inputevents_insulin_regex)
)
SELECT
  w.hadm_id, w.first_icu_in, w.last_icu_out,
  e.hadm_id IS NOT NULL AS in_emar,
  i.hadm_id IS NOT NULL AS in_inputevents
FROM icu_adm AS w
LEFT JOIN emar_hit AS e USING (hadm_id)
LEFT JOIN ie_hit   AS i USING (hadm_id)
WHERE e.hadm_id IS NOT NULL OR i.hadm_id IS NOT NULL;


-- ---------------------------------------------------------------------
-- 2. ICU chart events for the 24 items the pipeline reads (00 A/B, H2, J,
--    O): glucose for the labels and the trajectory (every stay), and for the
--    universe stays the seven mimic-code vitals, weight, the three GCS
--    components, the eight CRRT settings and the per-session hemodialysis
--    output. storetime (when the value was entered or validated) is kept
--    for every row: 02 uses a value as a feature only when both its
--    charttime and its storetime precede the landmark, for the glucose
--    stream and for the vitals, weight and GCS alike (release .20; before it
--    only the glucose items carried storetime). hadm_id, subject_id and the
--    unit are not stored: 01 recovers them from icustays and d_items.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE `YOUR_PROJECT.hypo_tutorial.src_chartevents`
CLUSTER BY itemid, stay_id AS
WITH universe_stays AS (
  SELECT s.stay_id
  FROM `physionet-data.mimiciv_3_1_icu.icustays` AS s
  JOIN `YOUR_PROJECT.hypo_tutorial.src_universe` AS u USING (hadm_id)
)
SELECT
  ce.stay_id, ce.itemid, ce.charttime, ce.valuenum, ce.storetime
FROM `physionet-data.mimiciv_3_1_icu.chartevents` AS ce
LEFT JOIN universe_stays AS u USING (stay_id)
WHERE ce.stay_id IS NOT NULL
  AND (
    ce.itemid IN (220621, 225664, 226537)                              -- glucose: serum copy, fingerstick, whole blood; every stay
    OR (u.stay_id IS NOT NULL AND ce.itemid IN (
      220045, 220179, 220050, 220210, 220277, 223761, 223762,          -- heart rate, NIBP and arterial systolic, RR, SpO2, temperature F and C
      226512, 224639,                                                  -- admission weight, daily weight
      220739, 223900, 223901,                                          -- GCS eye, verbal, motor
      227290, 224154, 224153, 228005, 228006, 224151, 225977, 230085,  -- CRRT mode, dialysate and replacement rates, effluent pressure, dialysate fluid
      226499                                                           -- hemodialysis output, per session
    ))
  );


-- ---------------------------------------------------------------------
-- 3. Lab results of universe admissions up to the last ICU discharge (02
--    takes the last value before a landmark, so later rows are never read):
--    the three glucose items and the 20-analyte panel, plus HbA1c for every
--    universe patient from any time, outpatient rows (hadm_id NULL)
--    included, because 02 takes the last HbA1c before t_k from the whole
--    record by subject. Rows without a numeric value are dropped; no
--    downstream query uses them. The unit stays because 03 prints it.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE `YOUR_PROJECT.hypo_tutorial.src_labevents`
CLUSTER BY itemid, hadm_id AS
WITH adm AS (SELECT hadm_id, last_icu_out FROM `YOUR_PROJECT.hypo_tutorial.src_universe`),
     pt  AS (SELECT DISTINCT s.subject_id
             FROM `physionet-data.mimiciv_3_1_icu.icustays` AS s
             JOIN `YOUR_PROJECT.hypo_tutorial.src_universe` AS u USING (hadm_id))
SELECT le.subject_id, le.hadm_id, le.itemid, le.charttime, le.storetime, le.valuenum, le.valueuom
FROM `physionet-data.mimiciv_3_1_hosp.labevents` AS le
LEFT JOIN adm AS a ON a.hadm_id = le.hadm_id
LEFT JOIN pt  AS p ON p.subject_id = le.subject_id
WHERE le.valuenum IS NOT NULL
  AND (
    (a.hadm_id IS NOT NULL AND le.charttime <= a.last_icu_out AND le.itemid IN (
       50931, 50809, 52569,                                                  -- glucose: chemistry, blood gas, the rare third item
       50912, 51006, 50862, 50983, 50971, 50882, 50813, 51301, 51222, 51221, -- creatinine, BUN, albumin, sodium, potassium, bicarbonate, lactate, WBC, hemoglobin, hematocrit
       51265, 50878, 50861, 50885, 51237, 50902, 50868, 50893, 50960, 50970  -- platelets, AST, ALT, bilirubin, INR, chloride, anion gap, calcium, magnesium, phosphate
    ))
    OR (p.subject_id IS NOT NULL AND le.itemid = 50852)                      -- HbA1c, any time, any setting
  );


-- ---------------------------------------------------------------------
-- 4. eMAR administrations of universe admissions, up to the last ICU
--    discharge (the ward days after the ICU are the bulk of these
--    admissions' eMAR rows and nothing downstream reads them; every row
--    before and during the ICU is kept, because su_any_stay and
--    hrs_since_last_hypo_admin look back over the whole admission so far).
--    Every medication is kept (02 reads insulin, octreotide, the hypoglycemic
--    agents and the medication counts; the rest costs little and lets a
--    reader add a drug class without a new extract).
--    The detail rows are collapsed here, once, the way 00 C showed they
--    must be read: dose_given sits on the child rows (one per product) and
--    is summed per emar_id; the parent row carries administration_type and
--    the infusion rate. 01 applies the caps and the classification on top.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE `YOUR_PROJECT.hypo_tutorial.src_emar`
CLUSTER BY hadm_id AS
WITH e AS (
  SELECT em.hadm_id, em.emar_id, em.charttime, em.storetime, em.medication, em.event_txt
  FROM `physionet-data.mimiciv_3_1_hosp.emar` AS em
  JOIN `YOUR_PROJECT.hypo_tutorial.src_universe` AS w USING (hadm_id)
  WHERE em.charttime IS NOT NULL
    AND em.medication IS NOT NULL
    AND em.charttime <= w.last_icu_out
),
d AS (
  SELECT
    d.emar_id,
    SUM(SAFE_CAST(d.dose_given AS FLOAT64))        AS dose_given,
    MAX(d.dose_given_unit)                         AS dose_given_unit,
    MAX(d.route)                                   AS route,
    MAX(d.infusion_rate)                           AS infusion_rate,
    MAX(d.infusion_rate_unit)                      AS infusion_rate_unit,
    MAX(d.administration_type)                     AS administration_type,
    COUNTIF(d.parent_field_ordinal IS NOT NULL)    AS n_products
  FROM `physionet-data.mimiciv_3_1_hosp.emar_detail` AS d
  JOIN (SELECT DISTINCT emar_id FROM e) AS k USING (emar_id)
  GROUP BY d.emar_id
)
SELECT e.hadm_id, e.emar_id, e.charttime, e.storetime, e.medication, e.event_txt,
       d.dose_given, d.dose_given_unit, d.route, d.infusion_rate, d.infusion_rate_unit, d.administration_type,
       COALESCE(d.n_products, 0) AS n_products
FROM e
LEFT JOIN d USING (emar_id);


-- ---------------------------------------------------------------------
-- 5. ICU flowsheet orders of universe stays: the inputevents rows 01 and 02
--    read, by dictionary category (00 K1). From "Medications" only the items
--    the pipeline names (insulin by label, octreotide by label, the seven
--    mimic-code vasopressors by id); every Antibiotics and Nutrition item;
--    and the Fluids/Intake items whose label names dextrose or glucose (the
--    carrier bags and D50). The rest of Medications (sedation, electrolytes,
--    heparin: about 4 million rows), the other fluids and the blood products
--    are not read by anything downstream and are left out.
--    Every procedureevents row of universe stays (ventilation, dialysis) is
--    kept, reduced to the columns 01 to 03 read.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE `YOUR_PROJECT.hypo_tutorial.src_inputevents`
CLUSTER BY itemid, stay_id AS
WITH universe_stays AS (
  SELECT s.stay_id
  FROM `physionet-data.mimiciv_3_1_icu.icustays` AS s
  JOIN `YOUR_PROJECT.hypo_tutorial.src_universe` AS u USING (hadm_id)
),
p AS (SELECT inputevents_insulin_regex FROM `YOUR_PROJECT.hypo_tutorial.agent_patterns`)
SELECT ie.hadm_id, ie.stay_id, ie.itemid, ie.starttime, ie.endtime, ie.storetime,
       ie.amount, ie.amountuom, ie.rate, ie.rateuom, ie.ordercategorydescription, ie.statusdescription
FROM `physionet-data.mimiciv_3_1_icu.inputevents` AS ie
JOIN universe_stays                                AS u USING (stay_id)
JOIN `physionet-data.mimiciv_3_1_icu.d_items`     AS d USING (itemid)
CROSS JOIN p
WHERE ie.stay_id IS NOT NULL
  AND (
    (d.category = 'Medications' AND (
         REGEXP_CONTAINS(LOWER(d.label), p.inputevents_insulin_regex)
      OR REGEXP_CONTAINS(LOWER(d.label), r'octreotide|sandostatin')
      OR d.itemid IN (221906, 221289, 221662, 221653, 222315, 221749, 221986)))   -- norepinephrine, epinephrine, dopamine, dobutamine, vasopressin, phenylephrine, milrinone
    OR REGEXP_CONTAINS(LOWER(COALESCE(d.category, '')), r'antibiotics|nutrition')
    OR REGEXP_CONTAINS(LOWER(d.label), r'dextrose|glucose|\bd5|\bd10|\bd20|\bd30|\bd50')
  );

CREATE OR REPLACE TABLE `YOUR_PROJECT.hypo_tutorial.src_procedureevents`
CLUSTER BY itemid, stay_id AS
SELECT pe.hadm_id, pe.stay_id, pe.itemid, pe.starttime, pe.endtime, pe.storetime, pe.statusdescription
FROM `physionet-data.mimiciv_3_1_icu.procedureevents` AS pe
JOIN `physionet-data.mimiciv_3_1_icu.icustays`        AS s USING (stay_id)
JOIN `YOUR_PROJECT.hypo_tutorial.src_universe`        AS u ON u.hadm_id = s.hadm_id
WHERE pe.stay_id IS NOT NULL;


-- ---------------------------------------------------------------------
-- 6. Microbiology specimens of universe admissions, collected before the
--    last ICU discharge: the source has one row per organism and antibiotic
--    tested; one row per specimen is kept, since 01 only asks when a
--    specimen was collected and of what type. Organisms and
--    susceptibilities are never read (they are resulted days later).
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE `YOUR_PROJECT.hypo_tutorial.src_microbiologyevents`
CLUSTER BY hadm_id AS
SELECT DISTINCT m.hadm_id, m.micro_specimen_id, m.chartdate, m.charttime, m.spec_type_desc
FROM `physionet-data.mimiciv_3_1_hosp.microbiologyevents` AS m
JOIN `YOUR_PROJECT.hypo_tutorial.src_universe`          AS u USING (hadm_id)
WHERE m.chartdate IS NOT NULL
  AND COALESCE(m.charttime, m.chartdate) <= u.last_icu_out;


-- ---------------------------------------------------------------------
-- 7. What was written: rows and size per table. The runner saves this as
--    CSV; it is the storage line of the README's cost section, and on the
--    sandbox the whole dataset has to stay under 10 GiB for the life of the
--    project.
-- ---------------------------------------------------------------------
SELECT table_id, row_count, ROUND(size_bytes / POW(1024, 3), 2) AS gib
FROM `YOUR_PROJECT.hypo_tutorial.__TABLES__`
ORDER BY size_bytes DESC;
