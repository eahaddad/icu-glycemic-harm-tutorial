# The evidence run: release .20 of the notebook, 12 October 2026

The `results/` folder exactly as `notebooks/hypo_harm_tutorial.ipynb` wrote it in Colab on MIMIC-IV v3.1 with
`RUN_DATA_STAGE = always` and `EXTRACT_FORCE = True` (the extract, the data stage, the cohort stage and the models in
one run), packed by the notebook's last cell. It replaces the release .16 run after the review of 12 October 2026
(`docs/model_findings.md`): the repeat-test rule, the feature-side exclusion, the entry-time rule for vitals, weight and
GCS, the landmark-time flowsheet flag and the fold-internal preparation are all in it. Every file is an aggregate: no row, identifier or timestamp from MIMIC-IV appears anywhere in it, and
the subgroup table pools levels under 100 rows and blanks cells under 10 events. `docs/model_findings.md` reads
these tables; the deck's numbers come from here. The rows were pulled in a fixed order and sorted before the
folds were drawn, so a re-run on the same data reproduces these files (arm B to the last digit).

| file | what it holds |
|---|---|
| `00b_extract_check09.csv` | the extract's size table: rows and GiB per `src_*` table (2.78 GiB in all) |
| `01_cohort_labels_check15.csv` to `check34.csv` | tables 1 to 20 of `sql/01_cohort_labels.sql` (check15 is table 1, check31 table 17; check32 table 18, the repeat rule before and after; check33 table 19, rows per split by years after the anchor; check34 table 20, entry lags per record kind) |
| `02_features_check01.csv` to `check03.csv` | the leakage assertion (0 of 128,135 rows), Table 1b (entry time against nominal time), the profile by drip status |
| `eda_*.csv` | the cohort stage: rates per split, era and ICU day, censoring, missingness, monitoring density |
| `run_settings.json` | release, rows, training eras, bootstrap draws, library versions of the run |
| `model_splits.csv` | rows, subjects, events and rates per split |
| `feature_prep_cutpoints.csv` | winsorising cut-points and training medians of the 109 numeric inputs |
| `cv_path_armA_*.csv`, `cv_folds_armB_*.csv` | the tuning tables: log loss per C; best iteration per fold and the refit rounds |
| `oof_calibration_*.csv` | how the out-of-fold training predictions were calibrated and what the Platt step learned from them |
| `metrics_by_arm_outcome_era.csv` | every metric with its 1,000-draw subject bootstrap interval |
| `headline_metrics.csv` | the same, one line per arm, outcome and era |
| `reliability_tables.csv` | observed against predicted risk per decile |
| `decision_curves.csv` | net benefit per threshold against acting on every row and on none |
| `operating_points.csv` | sensitivity, PPV and alerts per 100 rows at 5, 10 and 20% alert rates |
| `subgroups.csv` | discrimination and O/E by drip status, drip record, era, care unit, sex, race group and ICU day |
| `importance_arm*_*.csv` | standardised coefficients (arm A) and mean absolute SHAP (arm B), top 20 |
| `sensitivities_armB_lt54.csv` | training on 2011 to 2016 only, measured rows only, windows of 6 h or more, anchor-year admissions only |
| `figures/` | calibration and decision curves, ROC and precision-recall, importance, per outcome |
