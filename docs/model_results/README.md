# The evidence run: release .22 of the notebook, 12 October 2026

(Release .23 changed the two-source dose rule and the eMAR tiebreak; until its rerun replaces this folder, every
number here, in the deck and in the documents is the .22 evidence run's, and `docs/model_findings.md`, "The third
review", says what the .23 run has to show.)

The `results/` folder as `notebooks/hypo_harm_tutorial.ipynb` wrote it in Colab on MIMIC-IV v3.1 on 12 October
2026 (23:12 to 23:32), the notebook opened from this repository, the code cloned from it at its release commit, an
empty Drive folder, `RUN_DATA_STAGE = auto` (so the cohort and feature SQL, the pull, the cohort stage and the models
ran, on the extract the release .20 run had written), packed by the notebook's last cell. It is the path a peer
takes. It replaces the release .20 run after the second
review of 12 October 2026 (`docs/model_findings.md`, `docs/review_response_2.md`): the unfiltered < 54 primary label
with the repeat-excluded label as a sensitivity endpoint, the availability rule on every record (entered and charted
before the landmark), the per-landmark drip, eMAR and dialysis records, the deterministic tiebreakers, table 21 and the
extended table 20 are all in it. Every file is an aggregate: no row, identifier or timestamp from MIMIC-IV appears
anywhere in it, and the subgroup table pools levels under 100 rows and blanks cells under 10 events.
`docs/model_findings.md` reads these tables; every number in the deck is read from here by the script that builds it.
The rows were pulled in a fixed order and sorted before the folds were drawn. The other run of the same release
(21:30, another Colab machine) reproduced every cohort count except one landmark row of the shift group and every
AUROC to two decimals (arm B moved by 0.001, arm A not at all); `docs/model_findings.md`, "The release .22 run",
records that comparison and the likely source of the one row.

Two things to know about the folder. `00b_extract_check09.csv` is the extract's size table from the .20 extract
step (16:45 the same day), which release .22 did not rerun: the extract is unchanged between the two releases, and a
run that skips the extract does not rewrite the table, so the zip of this run had 56 files and this folder has 57.
The same release had been run once before (20:56 to 21:30, from a Drive zip of the code, on a slower Colab machine);
that run is the reproduction described in `docs/model_findings.md` and its zip had also carried the .20 run's
`check15` to `check34`, because the notebook packs the Drive folder as it stands; the next release empties the check
tables from the Drive folder before copying a run's in.

| file | what it holds |
|---|---|
| `00b_extract_check09.csv` | the extract's size table: rows and GiB per `src_*` table (2.78 GiB in all), from the .20 extract step |
| `01_cohort_labels_table01.csv` to `table21.csv` | tables 1 to 21 of `sql/01_cohort_labels.sql`, named after their `-- Table N.` headers (table01 the cohort per split; table07 monitoring density by drip record; table13 what a Confirmed row is; table15 the eMAR intervals and the cap; table18 the repeat rule; table19 rows per split by years after the anchor; table20 entry lags per record kind; table21 what the availability rule withholds per record kind) |
| `02_features_check01.csv` to `check03.csv` | the leakage assertion (0 of 127,269 rows), Table 1b (entry time against nominal time: 11.35% of ICU glucose results, 941 straddling rows), the profile by drip status |
| `eda_*.csv` | the cohort stage: rates per split, era and ICU day, censoring, missingness (one row per input, 145), monitoring density |
| `run_settings.json` | release, rows, training eras, bootstrap draws, library versions of the run |
| `model_splits.csv` | rows, subjects, events and rates per split |
| `feature_prep_cutpoints.csv` | winsorising cut-points and training medians of the 109 numeric inputs |
| `cv_path_armA_*.csv`, `cv_folds_armB_*.csv` | the tuning tables: log loss per C (0.01 chosen for < 54, 0.03 for > 300); best iteration per fold and the refit rounds (153 and 411) |
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
23:12:56; the cohort stage had written its tables within the same minute; the modeling stage ran from the
preparation table to the sensitivities table in 19.1 minutes, of which the cross-validation took 5.4 minutes for
< 54 and 9.6 for > 300, the evaluation with its bootstraps 1.2, the figures and importance 0.5 and the five
sensitivities 2.4; the zip is stamped 23:32. The data stage's own times are printed by the runner and were not kept
with this run (`docs/runbook.md` records the .20 run's).
