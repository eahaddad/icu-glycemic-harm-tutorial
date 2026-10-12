# The evidence run: release .22 of the notebook, 12 October 2026

The `results/` folder as `notebooks/hypo_harm_tutorial.ipynb` wrote it in Colab on MIMIC-IV v3.1 with
`RUN_DATA_STAGE = always` (the cohort and feature SQL, the cohort stage and the models in one run, on the extract the
release .20 run had written), packed by the notebook's last cell. It replaces the release .20 run after the second
review of 12 October 2026 (`docs/model_findings.md`, `docs/review_response_2.md`): the unfiltered < 54 primary label
with the repeat-excluded label as a sensitivity endpoint, the availability rule on every record (entered and charted
before the landmark), the per-landmark drip, eMAR and dialysis records, the deterministic tiebreakers, table 21 and the
extended table 20 are all in it. Every file is an aggregate: no row, identifier or timestamp from MIMIC-IV appears
anywhere in it, and the subgroup table pools levels under 100 rows and blanks cells under 10 events.
`docs/model_findings.md` reads these tables; every number in the deck is read from here by the script that builds it.
The rows were pulled in a fixed order and sorted before the folds were drawn, so a re-run on the same data reproduces
these files (arm B to the last digit).

Two things to know about the folder as it came off Drive. The results zip of the run also carried the release .20
pipeline's check tables (`01_cohort_labels_check15.csv` to `check34.csv`, stamped 16:45): the notebook packs the
`results/` folder on Drive as it stands, that folder keeps the files of earlier runs, and the .22 runner names its
tables differently (`table01` to `table21`), so the old names were not overwritten. They are not this run's and are
not kept here; the next release empties the check tables from the Drive folder before copying the new ones in.
`00b_extract_check09.csv` is the extract's size table from the .20 extract step (also 16:45), which release .22 did
not rerun: the extract is unchanged between the two releases.

| file | what it holds |
|---|---|
| `00b_extract_check09.csv` | the extract's size table: rows and GiB per `src_*` table (2.78 GiB in all), from the .20 extract step |
| `01_cohort_labels_table01.csv` to `table21.csv` | tables 1 to 21 of `sql/01_cohort_labels.sql`, named after their `-- Table N.` headers (table01 the cohort per split; table07 monitoring density by drip record; table13 what a Confirmed row is; table15 the eMAR intervals and the cap; table18 the repeat rule; table19 rows per split by years after the anchor; table20 entry lags per record kind; table21 what the availability rule withholds per record kind) |
| `02_features_check01.csv` to `check03.csv` | the leakage assertion (0 of 127,269 rows), Table 1b (entry time against nominal time: 11.35% of ICU glucose results, 941 straddling rows), the profile by drip status |
| `eda_*.csv` | the cohort stage: rates per split, era and ICU day, censoring, missingness (one row per input, 145), monitoring density |
| `run_settings.json` | release, rows, training eras, bootstrap draws, library versions of the run |
| `model_splits.csv` | rows, subjects, events and rates per split |
| `feature_prep_cutpoints.csv` | winsorising cut-points and training medians of the 109 numeric inputs |
| `cv_path_armA_*.csv`, `cv_folds_armB_*.csv` | the tuning tables: log loss per C (0.01 chosen for < 54, 0.03 for > 300); best iteration per fold and the refit rounds (153 and 402) |
| `oof_calibration_*.csv` | how the out-of-fold training predictions were calibrated and what the Platt step learned from them |
| `metrics_by_arm_outcome_era.csv` | every metric with its 1,000-draw subject bootstrap interval |
| `headline_metrics.csv` | the same, one line per arm, outcome and era |
| `reliability_tables.csv` | observed against predicted risk per decile |
| `decision_curves.csv` | net benefit per threshold against acting on every row and on none |
| `operating_points.csv` | sensitivity, PPV and alerts per 100 rows at 5, 10 and 20% alert rates |
| `subgroups.csv` | discrimination and O/E by drip status, drip record, era, care unit, sex, race group and ICU day (228 cells, 24 suppressed) |
| `importance_arm*_*.csv` | standardised coefficients (arm A) and mean absolute SHAP (arm B), top 20 |
| `sensitivities_armB_lt54.csv` | the main analysis and five sensitivities: training on 2011 to 2016 only, measured rows only, windows of 6 h or more, anchor-year admissions only, arm B refitted on the repeat-excluded < 54 endpoint |
| `figures/` | calibration and decision curves, ROC and precision-recall, importance, per outcome |

The run's own clock, from the file timestamps the zip carries: the check tables were copied into `results/` at
20:56:46; the cohort stage had written its tables by 20:56:50; the modeling stage ran from the preparation table
(20:57:04) to the sensitivities table (21:30:34), 33.5 minutes, of which the cross-validation took 9.6 minutes for
< 54 and 16.5 for > 300, the evaluation with its bootstraps 2.2, the figures and importance 0.7 and the five
sensitivities 4.5; the zip is stamped 21:30. The data stage's own times are printed by the runner and were not kept
with this run (`docs/runbook.md` records the .20 run's).
