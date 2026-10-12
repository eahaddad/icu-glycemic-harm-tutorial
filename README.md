# Predicting glucose harm in the next 24 ICU hours

A step-by-step tutorial on MIMIC-IV v3.1 (AI in Healthcare, Fall 2026). For every ICU day on which a patient received a hypoglycemic agent, two models predict whether a glucose below 54 mg/dL (the primary outcome, the CMS hospital-harm threshold) or above 300 mg/dL (the second outcome) will be charted in the next 24 hours: a logistic regression and a gradient-boosted tree model, on 145 features built from what the ICU already charts. The data never leaves BigQuery except as three parquet files on your own Google Drive, and nothing is installed on your laptop: one Colab notebook runs the whole thing, SQL to figures, in about an hour.

The result, from the evidence run in `docs/model_results/`: for glucose < 54, the tree model reaches an AUROC of 0.863 [0.840, 0.885] on the 2017 to 2019 test era and 0.855 [0.830, 0.878] on 2020 to 2022, calibrated as it comes (O/E 0.96, slope 1.03); the riskiest 10% of ICU days catch 55% of the next day's events at one event per 18 alerts. The honest caveat is in the same tables: among the rows with an insulin infusion running, where the harm is most often iatrogenic, the AUROC falls to 0.70. The rest of the numbers are under [Results](#results).

## Run it

**You need three things, all free.** A PhysioNet account credentialed for MIMIC-IV v3.1 with BigQuery access requested on the dataset page (the Google account you link there is the one you use for everything below); a Google Cloud project with no billing account (a "sandbox", two clicks at console.cloud.google.com; the tutorial fits in its free tier and never spends money); and Google Colab.

**Then:**

1. Open the notebook in Colab: [`notebooks/hypo_harm_tutorial.ipynb`](notebooks/hypo_harm_tutorial.ipynb) (in Colab: File, Open notebook, GitHub tab, paste this repository's address). Runtime type: CPU. Nothing in the tutorial uses a GPU.
2. In the setup cell, paste your project id into `PROJECT` and this repository's address into `REPO`. Leave `RUN_DATA_STAGE` at `auto`.
3. Runtime, Run all. Pick the one Google account in the Drive dialog and at the BigQuery sign-in.

**What happens.** Stage 0 mounts your Drive and clones the code from `REPO` (it refuses code from another release than the notebook's). Stage 1 runs the SQL in your project: the extract once (29.1 GiB of query bytes, 2.47 GiB stored, measured), the cohort and feature files (about 11 GiB), and pulls three parquet files to your Drive; it skips itself on later runs when the parquet is already there. Stage 2 checks the pulled rows against the SQL's own check tables (sizes and rates per split, censoring, the leakage assertion on every row, missingness, monitoring density). Stage 3 fits and evaluates the two models for both outcomes (10 to 30 minutes, Colab machines vary). Stage 4 packs every aggregate table and figure into one zip and downloads it. The parquet files and the row-level predictions stay on your Drive.

**What to check as it runs.** [`docs/runbook.md`](docs/runbook.md) lists every cell, what it prints, how long it takes, the checkpoint numbers to compare with (128,131 landmark rows; train 88,552 rows with 1,223 events below 54, test 21,743 with 219, shift test 17,836 with 187; leakage 0; C = 0.03; 206 and 394 trees; AUROC 0.863 / 0.855), and a table of everything that went wrong on the first runs with its cause and fix. Read it before the first run.

**Three rules.** One Google account for everything (PhysioNet, Colab, the Drive dialog). One release: the notebook and the repository carry the same release marker and the setup cell checks it. Nothing row-level leaves your Drive: share the results zip and a cleared notebook, never the parquet or the predictions.

## Where to read next

| document | what it holds |
| --- | --- |
| [`docs/runbook.md`](docs/runbook.md) | the run, cell by cell: prerequisites, what each cell prints, the checkpoint numbers, what to share, the troubleshooting table |
| [`docs/design.md`](docs/design.md) | the long form: the four SQL files and what each check table tests, the runner, the rules the SQL encodes and the evidence behind each, the modeling choices, the BigQuery cost model and why a student fits in the free tier |
| [`docs/sanity_findings.md`](docs/sanity_findings.md) | every item id, unit, vocabulary and range stated as a hypothesis and tested on the real tables before use; the tables are in `docs/sanity_results/` |
| [`docs/cohort_findings.md`](docs/cohort_findings.md) | the six ICU cohort runs: what each check table showed and what it changed (the storetime leakage, the eMAR "Confirmed" rows, the 2020 to 2022 flowsheet gap, the two drip records and the 16 h cap) |
| [`docs/model_findings.md`](docs/model_findings.md) | every model run with its verdicts, the reproducibility findings (row order, solver tolerance, the bootstrap), and the evidence run the numbers are quoted from |
| [`docs/model_results/`](docs/model_results/) | the evidence run's 52 output files: the SQL check tables, the cohort tables, the model tables and the figures (`README.md` there is the index) |

## What is in the repository

```
notebooks/    hypo_harm_tutorial.ipynb   the tutorial: setup, data, cohort, models, pack (no outputs: they would show patient rows)
sql/          00b_extract.sql            one pass over the big tables into clustered extracts, once per project
              01_cohort_labels.sql       landmarks, exposure, labels, split; seventeen check tables
              02_features.sql            the feature view; the leakage assertion
              00_sanity_itemids.sql      the discovery pass behind docs/sanity_findings.md (not run routinely)
pipeline/     run_bigquery.py            the runner: extract, pipeline, pull, cost
src/          hypo_tutorial/             columns.py (column roles), features.py (preparation), models.py (the two arms), evaluate.py (metrics, bootstrap)
tests/        test_evaluate.py           the weighted bootstrap against scikit-learn
docs/         runbook.md  design.md  sanity_findings.md  cohort_findings.md  model_findings.md  model_results/  sanity_results/
results/      where the runner and the notebook write their aggregate tables (empty in the repository)
requirements.txt
RELEASE                                  the release marker the setup cell checks
```

## Why the ICU

The first version of this pipeline was hospital-wide. Its first real run found 0.66% of at-risk days with a result below 54 mg/dL, because MIMIC-IV carries no ward point-of-care glucose (`00` section J): on the ward the label was "a venous lab happened to be low". In the ICU glucose is charted every 1 to 4 hours, insulin drips sit in `icu.inputevents` with every rate change, and feeds and dextrose are charted, so both labels are measured. The hospital-wide evidence is kept in `docs/sanity_findings.md`.

## The design in one paragraph

One row per ICU day: landmark times t_k = ICU admission + 24k hours, up to 28 per stay. A row exists when a hypoglycemic agent was given in the 24 hours before t_k (an eMAR or flowsheet dose, or an insulin infusion running). The features are everything charted before t_k, and "before" means entered before: a lab or glucose value counts only when both its charttime and its storetime precede the landmark, because 11.5% of ICU glucose results are stored after their nominal time and 948 landmark rows would otherwise have seen the future. The label is any glucose below 54 (or above 300) with its charttime in the next 24 hours, cut at ICU discharge or death. Patients are split by era (anchor year group): 2008 to 2016 train, 2017 to 2019 the primary test, 2020 to 2022 a second test under a documentation shift, because in those years the flowsheet medication and procedure records stop for about 60% of stays while the eMAR and the vitals continue. Folds, bootstrap draws and splits are all by patient, since a patient contributes up to 28 correlated rows. `docs/design.md` has every rule with the table that justified it.

## Results

The evidence run (release .16, 12 October 2026; `docs/model_findings.md` has every run, table and verdict, `docs/model_results/` the run's 52 files):

| outcome, era | arm A, logistic regression | arm B, LightGBM |
| --- | --- | --- |
| < 54, 2017 to 2019 | 0.840 [0.813, 0.866] | 0.863 [0.840, 0.885] |
| < 54, 2020 to 2022 | 0.825 [0.793, 0.855] | 0.855 [0.830, 0.878] |
| > 300, 2017 to 2019 | 0.882 [0.872, 0.891] | 0.894 [0.885, 0.902] |
| > 300, 2020 to 2022 | 0.870 [0.860, 0.881] | 0.882 [0.873, 0.891] |

AUROC with 1,000-draw patient-level bootstrap intervals. For < 54 the AUPRC is 0.079 and 0.076 against a 1% prevalence, the O/E ratio 0.96 and 1.18. The raw LightGBM was calibrated on the primary era and the Platt step made it worse (O/E 0.83; its out-of-fold predictions under-predict the training rows by 17%, `oof_calibration_lt54.csv`), so the raw arm B is the primary model. Among rows with an insulin infusion running, arm B's AUROC falls to 0.70 on the primary era: the headline hides the subgroup an alert would serve. Flagging the riskiest 10% of at-risk ICU days catches 55% of the next day's events at one event per 18 alerts; the decision curve sits above acting on everyone at every threshold from 0.5% to 10%. On 2020 to 2022 both arms under-predict by about 18% with discrimination intact, and the drift sits on the rows with an infusion: a charting change moves the level, not the ranking. Dropping 2008 to 2010 from training, scoring measured rows only, or windows of 6 h or more moves the AUROC by at most 0.01. Stage 3 took 27 minutes in Colab (eleven on an earlier machine).

Reporting follows TRIPOD+AI (Collins et al., BMJ 2024;385:e078378): discrimination, calibration and clinical utility, each with patient-level bootstrap intervals, the two test eras reported apart and never pooled, subgroups by infusion status, record, era, care unit, sex, race group and ICU day, written to be shared as they are (levels under 100 rows pooled, cells under 10 events without a count).

## Tests

`tests/test_evaluate.py` pins the weighted bootstrap to its references: every weighted metric against scikit-learn on the row-repeated table (to 1e-10; slope and intercept to 1e-7), the whole bootstrap against the release .8 stack-and-refit implementation it keeps as a function, and the solver tolerance behind the calibration slope and intercept (it prints the three solvers side by side). It needs no data and no credentials:

```
pip install -r requirements.txt
python tests/test_evaluate.py
```

During development the SQL was also run, before every release, on an invented six-patient database with one planted case per cohort rule; that harness is development tooling and is not part of this release. The check tables the SQL prints are the test a peer runs: `docs/runbook.md` lists the numbers each must show.

## Compliance

Only open-weight models run on the data, inside the student's own Colab session or BigQuery project. The parquet files live in the student's own Google Drive, never a shared drive, a shared link or a repository. No MIMIC rows or notes go into any chat assistant or third-party API. Slides and rendered notebook outputs show aggregates, code and invented example rows only; the notebook is committed without outputs.

## References

Collins GS et al. TRIPOD+AI statement. BMJ 2024;385:e078378. Van Calster B et al. Calibration: the Achilles heel of predictive analytics. BMC Medicine 2019;17:230. Vickers AJ, Elkin EB. Decision curve analysis. Medical Decision Making 2006;26:565. Riley RD et al. Minimum sample size for developing a multivariable prediction model. Statistics in Medicine 2019;38:1276. Ke G et al. LightGBM. NeurIPS 2017. Lundberg SM, Lee S-I. A unified approach to interpreting model predictions. NeurIPS 2017. Johnson AEW et al. MIMIC-IV, a freely accessible electronic health record dataset. Scientific Data 2023;10:1. Mathioudakis NN et al. Development and validation of a machine learning model to predict near-term risk of iatrogenic hypoglycemia in hospitalized patients. JAMA Network Open 2021. Fralick M et al. Using real-time machine learning to prevent in-hospital hypoglycemia: a prospective study. Internal and Emergency Medicine 2023;18:325.
