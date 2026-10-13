# Predicting glucose harm in the next 24 ICU hours

A step-by-step tutorial on MIMIC-IV v3.1 (AI in Healthcare, Fall 2026). For every ICU day on which a patient received a hypoglycemic agent, two models predict whether a glucose below 54 mg/dL (the primary outcome; 54 is the ADA level 2 threshold, and CMS's hospital-harm measure uses the 40 mg/dL event reported here as a secondary outcome) or above 300 mg/dL (the second outcome) will be documented before the next 24 hours are up, or before ICU discharge or death if those come first: a logistic regression and a gradient-boosted tree model, on 145 features built from what the ICU already charts. Every prediction can be reconstructed from the records the EHR held at its prediction time: a record enters a row only if both its clinical time and its entry time precede the landmark, for doses, infusions, procedures and charted values alike, and a test in the repository proves it on an invented database. The data never leaves BigQuery except as three parquet files on your own Google Drive, and nothing is installed on your laptop: one Colab notebook runs the whole thing, SQL to figures (the modeling stage took 32 minutes in the evidence run, by the timestamps of its own result files; 19 on a faster Colab machine for the previous release).

The result, from the evidence run in `docs/model_results/` (release .23, 13 October 2026, the notebook run from a clone of this repository into an empty Drive folder): for glucose < 54, the tree model reaches an AUROC of 0.864 [0.841, 0.884] on the patients anchored in 2017 to 2019 and 0.850 [0.826, 0.875] on those anchored in 2020 to 2022, calibrated as it comes (O/E 0.97 [0.84, 1.11], slope 1.05 [0.96, 1.13]); the riskiest 10% of ICU days catch 57% of the next day's events (128 of 226) at one event per 17 alerts. The honest caveat is in the same tables: among the rows with an insulin infusion running, where the harm is most often iatrogenic, the AUROC falls to 0.71 (37 events), and refitting the model without any drip input leaves both numbers where they are (0.860 overall, 0.700 on those rows), so the drip columns are not what carries the headline. The rest of the numbers are under [Results](#results). Two independent reviews shaped the current release: the first (of release .19) found four pipeline faults, which release .20 corrected; the second (of .21) asked for an unfiltered primary endpoint, availability rules on every treatment record and a test that enforces them, which release .22 adds; the third (of .22) found one record kind the availability rule had missed, a dose charted in both sources whose eMAR copy was not yet entered, and a test harness that failed under pandas 2, both corrected in release .23 together with the eMAR tie that made two runs of .22 differ by one row (`docs/model_findings.md`, "The third review"); the .23 run added eight landmark rows and no events, and moved no AUROC by more than 0.002.

## Run it

**You need three things, all free.** A PhysioNet account credentialed for MIMIC-IV v3.1 with BigQuery access requested on the dataset page (the Google account you link there is the one you use for everything below); a Google Cloud project with no billing account (a "sandbox", two clicks at console.cloud.google.com; the tutorial fits in its free tier and never spends money); and Google Colab.

**Then:**

1. Open the notebook in Colab: [`notebooks/hypo_harm_tutorial.ipynb`](notebooks/hypo_harm_tutorial.ipynb) (in Colab: File, Open notebook, GitHub tab, paste this repository's address). Runtime type: CPU. Nothing in the tutorial uses a GPU.
2. In the setup cell, paste your project id into `PROJECT` and this repository's address into `REPO`. Leave `RUN_DATA_STAGE` at `auto`.
3. Runtime, Run all. Pick the one Google account in the Drive dialog and at the BigQuery sign-in.

**What happens.** Stage 0 mounts your Drive and clones the code from `REPO` (it refuses code from another release than the notebook's). Stage 1 runs the SQL in your project: the extract once (about 32 GiB of query bytes, 2.78 GiB stored), the cohort and feature files (about 11 GiB in the .20 run; the per-landmark views of .22 add compute, not bytes), and pulls three parquet files to your Drive; it skips itself on later runs when the parquet is already there. Stage 2 checks the pulled rows against the SQL's own check tables (sizes and rates per split, censoring, the leakage assertion on every row, missingness, monitoring density). Stage 3 fits and evaluates the two models for both outcomes (32 minutes in the evidence run, of which the six sensitivities are 7; 19 minutes on a faster machine for the previous release's five; Colab machines vary). Stage 4 packs every aggregate table and figure into one zip and downloads it. The parquet files and the row-level predictions stay on your Drive.

**What to check as it runs.** [`docs/runbook.md`](docs/runbook.md) lists every cell, what it prints, how long it takes, the checkpoint numbers to compare with (the release .23 run: 127,277 landmark rows; train 87,762 rows with 1,234 documented events below 54, test 21,702 with 226, shift test 17,813 with 190; leakage 0; C = 0.01 for both outcomes; 194 and 323 trees; AUROC 0.864 / 0.850 to two decimals), and a table of everything that went wrong on the first runs with its cause and fix. Read it before the first run.

**Three rules.** One Google account for everything (PhysioNet, Colab, the Drive dialog). One release: the notebook and the repository carry the same release marker and the setup cell checks it. Nothing row-level leaves your Drive: share the results zip and a cleared notebook, never the parquet or the predictions.

## Where to read next

| document | what it holds |
| --- | --- |
| [`docs/runbook.md`](docs/runbook.md) | the run, cell by cell: prerequisites, what each cell prints, the checkpoint numbers, what to share, the troubleshooting table |
| [`docs/design.md`](docs/design.md) | the long form: the four SQL files and what each check table tests, the runner, the rules the SQL encodes and the evidence behind each, the modeling choices, the BigQuery cost model and why a student fits in the free tier |
| [`docs/sanity_findings.md`](docs/sanity_findings.md) | every item id, unit, vocabulary and range stated as a hypothesis and tested on the real tables before use; the tables are in `docs/sanity_results/` |
| [`docs/cohort_findings.md`](docs/cohort_findings.md) | the six ICU cohort runs: what each check table showed and what it changed (the storetime leakage, the eMAR "Confirmed" rows, the 2020 to 2022 flowsheet gap, the two drip records and the 16 h cap) |
| [`docs/model_findings.md`](docs/model_findings.md) | every model run with its verdicts, the reproducibility findings (row order, solver tolerance, the bootstrap), and the evidence run the numbers are quoted from |
| [`docs/model_results/`](docs/model_results/) | the evidence run's output files: the SQL check tables, the cohort tables, the model tables and the figures (`README.md` there is the index) |

## What is in the repository

```
notebooks/    hypo_harm_tutorial.ipynb   the tutorial: setup, data, cohort, models, pack (no outputs: they would show patient rows)
sql/          00b_extract.sql            one pass over the big tables into clustered extracts, once per project
              01_cohort_labels.sql       landmarks, the records as each landmark could see them, exposure, labels, split; twenty-one check tables
              02_features.sql            the feature view; the leakage assertion
              00_sanity_itemids.sql      the discovery pass behind docs/sanity_findings.md (not run routinely)
pipeline/     run_bigquery.py            the runner: extract, pipeline, pull, cost
src/          hypo_tutorial/             columns.py (column roles), features.py (preparation), models.py (the two arms), evaluate.py (metrics, bootstrap)
tests/        test_evaluate.py           the weighted bootstrap against scikit-learn
              make_synthetic.py          an invented six-patient MIMIC-IV-shaped database, one planted case per rule
              run_pipeline.py            runs the four SQL files on it (DuckDB) and prints every check table
              prefix_invariance.py       proves that records entered after a landmark change nothing at that landmark
docs/         runbook.md  design.md  sanity_findings.md  cohort_findings.md  model_findings.md  model_results/  sanity_results/
results/      where the runner and the notebook write their aggregate tables (empty in the repository)
requirements.txt
RELEASE                                  the release marker the setup cell checks
```

## Why the ICU

The first version of this pipeline was hospital-wide. Its first real run found 0.66% of at-risk days with a result below 54 mg/dL, because MIMIC-IV carries no ward point-of-care glucose (`00` section J): on the ward the label was "a venous lab happened to be low". In the ICU glucose is charted every 1 to 4 hours, insulin drips sit in `icu.inputevents` with every rate change, and feeds and dextrose are charted, so both labels are measured. The hospital-wide evidence is kept in `docs/sanity_findings.md`.

## The design in one paragraph

One row per ICU day: landmark times t_k = ICU admission + 24k hours, up to 28 per stay. A row exists when a hypoglycemic agent was given in the 24 hours before t_k (an eMAR or flowsheet dose, or an insulin infusion record the landmark could see). The features are everything the EHR held at t_k, and "held" means entered as well as charted: a record enters a row only when both its clinical time and its storetime (MIMIC-IV's entry time) precede the landmark. For a lab or glucose value that matters because 11.35% of ICU glucose results carry a charttime later than their storetime (the nominal time trails the entry) and 941 landmark rows would otherwise have carried a value timed after their landmark; the vitals, weight and GCS are entered a median 22 to 29 minutes after their charttime; an insulin infusion segment is entered a median 1 minute after its start and 67 minutes before its end, so its start and rate are known from its entry on, its end only when the next segment is entered (a rate change) or at its nominal time (a stop, which the data does not timestamp); the eMAR infusion state is rebuilt at every landmark from the events entered before it, so a Stopped entered later cannot close an interval early and a Stopped charted after 16 hours of silence cannot reopen one. The label is any documented glucose below 54 (or above 300) with its charttime in the next 24 hours, cut at ICU discharge or death; the CMS816 repeat-result exclusion (a low contradicted within five minutes by a result above 80) defines a sensitivity endpoint and the CMS816 secondary outcome, not the primary label, because a contradicted low is excluded by the rule, not shown to be a measurement error. Patients are split by their anchor year group: those anchored in 2008 to 2016 train, those anchored in 2017 to 2019 are the primary test, those anchored in 2020 to 2022 a second test under a documentation shift, because for them the flowsheet medication and procedure records stop for about 60% of stays while the eMAR and the vitals continue. The split is patient-disjoint, by anchor group rather than by calendar time (a patient's later admissions keep the group; every row says how many years after the anchor it falls), and the test groups were inspected during development, so the result is an exploratory internal validation. Folds, bootstrap draws and splits are all by patient, since a patient contributes up to 28 correlated rows, and the feature preparation is refitted inside every fold. `docs/design.md` has every rule with the table that justified it.

## Results

The evidence run (release .23, 13 October 2026; `docs/model_findings.md` has every run, table and verdict, `docs/model_results/` the run's files). The validation is an exploratory internal one: patient-disjoint, by anchor group, and development-informed, since the test groups were never fitted on but their event rates and monitoring density were looked at while the cohort rules were set. A temporal claim would need admission-period splits with the patients who span two periods handled explicitly; an untouched one, patients whose records did not shape the pipeline.

| outcome, era | arm A, logistic regression | arm B, LightGBM |
| --- | --- | --- |
| < 54, patients anchored 2017 to 2019 | 0.836 [0.812, 0.861] | 0.864 [0.841, 0.884] |
| < 54, patients anchored 2020 to 2022 | 0.826 [0.795, 0.855] | 0.850 [0.826, 0.875] |
| > 300, patients anchored 2017 to 2019 | 0.881 [0.871, 0.890] | 0.893 [0.884, 0.902] |
| > 300, patients anchored 2020 to 2022 | 0.869 [0.858, 0.879] | 0.878 [0.869, 0.888] |

AUROC with 1,000-draw patient-level bootstrap intervals; 226 and 190 documented events in the two test groups. For < 54 the AUPRC of arm B is 0.078 and 0.077 against a prevalence of 1.04% and 1.07%, the O/E ratio 0.97 [0.84, 1.11] and 1.14 [1.00, 1.29]. The raw LightGBM was calibrated on the primary group and the Platt step made it worse (O/E 0.85; its out-of-fold predictions under-predict the training rows by 15%, `oof_calibration_lt54.csv`), so the raw arm B is the primary model. Among rows with an insulin infusion running, arm B's AUROC falls to 0.71 on the primary group (37 events) and 0.73 on the shift group (38): the headline hides the subgroup an alert would serve. The sixth sensitivity refits the preparation and arm B without any drip input: 0.860 and 0.855 on every row, 0.700 and 0.733 on the drip rows, against 0.864, 0.850, 0.705 and 0.730 with them, so the drip columns add about 0.004 overall and nothing inside the drip rows; the rest of the inputs separate infusion rows from the others on their own, and the infusion rows are harder either way. Flagging the riskiest 10% of at-risk ICU days catches 57% of the next day's events at one event per 17 alerts (the riskiest 5%, 42% at one per 11; the riskiest 20%, 75% at one per 26); the decision curve sits above acting on everyone at every threshold from 0.5% to 10%, which is potential clinical utility on this data, not a demonstrated benefit. On the patients anchored in 2020 to 2022 both arms under-predict by 12 to 14% with discrimination intact (arm B's interval, 1.00 to 1.29, just includes 1), and the drift sits on the rows with an infusion (O/E 1.53 on rows with one running, 1.06 on rows with no drip): a charting change moves the level, not the ranking. Dropping 2008 to 2010 from training, scoring measured rows only, or windows of 6 h or more moves the AUROC by at most 0.02 (0.846, 0.863, 0.861); scoring the anchor-year admissions alone (the rows whose calendar period is certain) gives 0.867 and 0.864 on 152 and 163 events; arm B refitted on the repeat-excluded endpoint gives 0.863 and 0.852 against that endpoint (218 and 186 events). The availability rule has a price the run measured (table 21): 99.5% of ventilation intervals, 57.9% of running feed segments and 25.3% of running insulin drip segments had not been entered at the landmark, so those features see less than the patient received; the discrimination did not move. Stage 3 took 32 minutes in Colab, by the timestamps of the run's own result files. Two runs of the previous release on two machines reproduced every cohort count except one landmark row and every AUROC to two decimals; the .23 run against the .22 evidence run, which measures the two corrections rather than the residue, differs by eight landmark rows, no events, and at most 0.002 of any AUROC (`docs/model_findings.md`).

Reporting follows TRIPOD+AI (Collins et al., BMJ 2024;385:e078378): discrimination, calibration and clinical utility, each with patient-level bootstrap intervals, the two test eras reported apart and never pooled, subgroups by infusion status, record, era, care unit, sex, race group and ICU day, written to be shared as they are (levels under 100 rows pooled, cells under 10 events without a count).

## Tests

`tests/test_evaluate.py` pins the weighted bootstrap to its references: every weighted metric against scikit-learn on the row-repeated table (to 1e-10; slope and intercept to 1e-7), the whole bootstrap against the release .8 stack-and-refit implementation it keeps as a function, and the solver tolerance behind the calibration slope and intercept (it prints the three solvers side by side). It needs no data and no credentials:

```
pip install -r requirements.txt
python tests/test_evaluate.py
```

The SQL has its own tests, on an invented six-patient MIMIC-IV-shaped database with one planted case per rule (`tests/make_synthetic.py` lists them: a dose charted in both sources whose eMAR copy is entered after the landmark, two eMAR sessions opening in the same minute, the era and length-of-stay filters, both drip records, a dose charted in two sources, a Rewritten row, a rate change, a feed interruption, dextrose after a low, the repeat-result rule at its 300-second and 80 mg/dL boundaries, censoring at discharge and death, history from an earlier admission only, garbage values, and the availability cases: a flowsheet segment, a rate change, an eMAR Stopped and an eMAR dose each charted before a landmark but entered after it, an eMAR start with 16 hours of silence before its Stopped, a rate-less segment crossing a landmark, a repeat result charted after the landmark but entered before it). `tests/run_pipeline.py` runs the four SQL files on it through DuckDB and prints every check table, with the expected numbers in the fixture's docstring. `tests/prefix_invariance.py` is the general test: for every landmark of the grid it rebuilds the database as the EHR held it at that moment (every record entered at or after the landmark removed, a rate change not yet written left open) and checks that the landmark is at risk in both databases or in neither and that every model input is identical; it also doubles the completed amount of a rate-less segment crossing a landmark and checks that nothing at that landmark moves. The three need no data and no credentials:

```
python tests/make_synthetic.py
python tests/run_pipeline.py
python tests/prefix_invariance.py
```

The check tables the SQL prints on the real data are the test a peer runs: `docs/runbook.md` lists the numbers each must show.

## Compliance

Only open-weight models run on the data, inside the student's own Colab session or BigQuery project. The parquet files live in the student's own Google Drive, never a shared drive, a shared link or a repository. No MIMIC rows or notes go into any chat assistant or third-party API. Slides and rendered notebook outputs show aggregates, code and invented example rows only; the notebook is committed without outputs.

## References

Collins GS et al. TRIPOD+AI statement. BMJ 2024;385:e078378. Van Calster B et al. Calibration: the Achilles heel of predictive analytics. BMC Medicine 2019;17:230. Vickers AJ, Elkin EB. Decision curve analysis. Medical Decision Making 2006;26:565. Riley RD et al. Minimum sample size for developing a multivariable prediction model. Statistics in Medicine 2019;38:1276. Ke G et al. LightGBM. NeurIPS 2017. Lundberg SM, Lee S-I. A unified approach to interpreting model predictions. NeurIPS 2017. Johnson AEW et al. MIMIC-IV, a freely accessible electronic health record dataset. Scientific Data 2023;10:1. Mathioudakis NN et al. Development and validation of a machine learning model to predict near-term risk of iatrogenic hypoglycemia in hospitalized patients. JAMA Network Open 2021. Fralick M et al. Using real-time machine learning to prevent in-hospital hypoglycemia: a prospective study. Internal and Emergency Medicine 2023;18:325.
