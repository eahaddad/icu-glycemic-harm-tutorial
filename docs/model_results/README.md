# The evidence run: release .23 of the notebook, 13 October 2026

This folder is the `results/` folder exactly as `notebooks/hypo_harm_tutorial.ipynb` wrote it when I ran it in Colab
on MIMIC-IV v3.1 on 13 October 2026 (01:23 to 01:55), the way I ask you to run it: the notebook opened from this
repository, the code cloned from it at its release commit into an empty Drive folder, `RUN_DATA_STAGE = auto` (so the
cohort and feature SQL, the pull, the cohort stage and the models ran, on the extract an earlier release had written),
`EXTRACT_FORCE` off, and the zip packed by the notebook's last cell. It is the run every number in the deck and in the
documents under `docs/` comes from; the deck is built from these files by a script, so a figure on a slide can be
traced to a file here.

Every file is an aggregate. No row, identifier or timestamp from MIMIC-IV appears anywhere in the folder, the subgroup
table pools levels under 100 rows and blanks cells under 10 events, and that is why the folder can sit in a public
repository. The row-level parquet files and the predictions file the same run wrote stay on my Drive, and yours stay
on yours.

What is new in this run against the previous release's: the third review found two faults, and both are corrected
here. A bolus charted in both the flowsheet and the eMAR used to be reduced to its eMAR copy once and for all, so a
landmark that fell between the flowsheet entry and the later eMAR entry saw neither; now the flowsheet copy stays
visible until its eMAR copy has been entered. And two eMAR sessions opening in the same minute were ordered by start
time alone, which BigQuery resolves as it pleases; they are now ordered by session as well. The cohort gained eight
landmark rows from the two corrections (127,277 against 127,269; test 21,702 against 21,697, the shift group 17,813
against 17,811, train 87,762 against 87,761) and no events in any split; the shift group's "rows with a drip record in
the look-back" is 3,257, the value one of the two previous runs had given. Arm A's < 54 AUROCs are unchanged to three
decimals (0.836 and 0.826), arm B's primary-group AUROC is unchanged at 0.864 and its shift-group AUROC is 0.850 against
0.851. `docs/model_findings.md` sets the two releases' runs side by side. This run also adds the sixth sensitivity,
arm B refitted without any drip input.

Two things to know about the folder. `00b_extract_check09.csv` is the extract's size table, written by the extract step
of release .20 on 12 October 2026, which no later release has rerun: the extract is written once per project and the
runner refuses to write it again, so a run that skips the extract does not rewrite the table. The zip of this run had
56 files and this folder has 57. The table lists the dataset as it stood at that moment, so its `cohort_landmarks` row
is the cohort table of that earlier release, not of this run; table 1 below is this run's cohort.

| file | what it holds |
|---|---|
| `00b_extract_check09.csv` | the extract's size table: rows and GiB per `src_*` table (2.78 GiB in all), from the .20 extract step |
| `01_cohort_labels_table01.csv` to `table21.csv` | tables 1 to 21 of `sql/01_cohort_labels.sql`, named after their `-- Table N.` headers (table01 the cohort per split; table07 monitoring density by drip record; table13 what a Confirmed row is; table15 the eMAR intervals and the cap; table18 the repeat rule; table19 rows per split by years after the anchor; table20 entry lags per record kind; table21 what the availability rule withholds per record kind) |
| `02_features_check01.csv` to `check03.csv` | the leakage assertion (0 of 127,277 rows), Table 1b (entry time against nominal time: 11.35% of ICU glucose results, 941 straddling rows), the profile by drip status |
| `eda_*.csv` | the cohort stage: rates per split, era and ICU day, censoring, missingness (one row per input, 145), monitoring density |
| `run_settings.json` | release, rows, training eras, bootstrap draws, library versions of the run |
| `model_splits.csv` | rows, subjects, events and rates per split |
| `feature_prep_cutpoints.csv` | winsorising cut-points and training medians of the numeric inputs |
| `cv_path_armA_*.csv`, `cv_folds_armB_*.csv` | the tuning tables: log loss per C (0.01 chosen for both outcomes); best iteration per fold and the refit rounds (194 for < 54, 323 for > 300) |
| `oof_calibration_*.csv` | how the out-of-fold training predictions were calibrated and what the Platt step learned from them |
| `metrics_by_arm_outcome_era.csv` | every metric with its 1,000-draw subject bootstrap interval |
| `headline_metrics.csv` | the same, one line per arm, outcome and era |
| `reliability_tables.csv` | observed against predicted risk per decile |
| `decision_curves.csv` | net benefit per threshold against acting on every row and on none |
| `operating_points.csv` | sensitivity, PPV and alerts per 100 rows at 5, 10 and 20% alert rates |
| `subgroups.csv` | discrimination and O/E by drip status, drip record, era, care unit, sex, race group and ICU day (228 cells, 24 suppressed) |
| `importance_arm*_*.csv` | standardised coefficients (arm A) and mean absolute SHAP (arm B), top 20 |
| `sensitivities_armB_lt54.csv` | the main analysis and six sensitivities: training on 2011 to 2016 only, measured rows only, windows of 6 h or more, anchor-year admissions only, arm B refitted on the repeat-excluded < 54 endpoint, and arm B refitted without the drip inputs, scored on every row and on the drip rows alone |
| `figures/` | calibration and decision curves, ROC and precision-recall, importance, per outcome |

The run's own clock, from the file timestamps the zip carries: the check tables were copied into `results/` at
01:23:18 and the cohort stage wrote its tables within the same minute; the modeling stage ran from the preparation
table to the sensitivities table in 31.7 minutes, of which the cross-validation took 8.3 minutes for < 54 and 13.9 for
> 300, the evaluation with its bootstraps 2.1, the figures and importance 0.7 and the six sensitivities 6.7 (the sixth
refits arm B, which is most of that); the last file is stamped 01:55:12. Colab's free CPU runtime, and a slower machine
than the previous release's runs had. The data stage's own times are printed by the runner and are not kept with a run;
`docs/runbook.md` records the ones I measured.

When you have run the notebook yourself, compare your `01_cohort_labels_table01.csv` with this one first: MIMIC-IV
v3.1 does not change, so the counts should match to the row. Then `headline_metrics.csv` to two decimals. If table 1
matches and an AUROC differs in the third decimal, the fold assignment or a library version moved it, and
`docs/model_findings.md`, "Reproducibility", says what I measured about that; if table 1 differs, something in the
SQL or the extract differs, and that is worth telling me about.
