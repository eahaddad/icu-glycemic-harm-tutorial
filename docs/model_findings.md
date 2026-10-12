# The models: the runs, the findings, and the numbers the deck quotes

The numbers to quote are those of the release .20 run (12 October 2026, the section "The release .20 run"
below and `docs/model_results/`), the rerun after the review corrected the pipeline. The earlier sections
are the record of how they were reached: the first run (release .8) and its verdicts, the second (.12) that
tested the Platt diagnosis, the third (.14) that exposed the row-order dependence, the .16 evidence run, the
review and its corrections. The verdicts did not change between runs; the third decimal did, for the
reasons each section gives.

## The first real run of the models (notebook 02, release .8, 11 October 2026)

The author ran `notebooks/02_tabular_arms.ipynb` (release 2026-10-11.8) in Colab on the sixth-run cohort
(`docs/cohort_findings.md`: 128,131 landmark rows; train 88,552 rows, 1,223 glucose < 54 events, 8,480
> 300; test 2017 to 2019 21,743 rows, 219 and 2,109; test_shifted 2020 to 2022 17,836 rows, 187 and
1,614) and sent back `headline_metrics.csv`, `subgroups.csv`, `operating_points.csv`,
`sensitivities_armB_lt54.csv`, `cv_path_armA_*.csv` and `cv_folds_armB_*.csv`. The figures folder came
back empty (Drive had not synced the PNGs when the folder was downloaded; release .9 flushes Drive).
Every number below is an aggregate from those files. As in the cohort document, each table was read as a
hypothesis with a verdict, and each verdict names what it changed in the files.

One caveat on precision, resolved by the second run below. Release .8 fitted the calibration slope and
intercept with scikit-learn's default L-BFGS tolerance, which stops early (`tests/test_evaluate.py` shows
the gradient it leaves), so the slope, intercept and `+Platt` rows in this first section are read to two
decimals; the release .12 run (section "The second run") has the exact values, and `docs/model_results/`
holds its complete output. The AUROC, AUPRC, Brier, O/E, ECE, operating points and subgroup numbers of the
raw arms are exact in both runs.

## Tuning (training rows only)

Arm A chose C = 0.03 for both outcomes, an interior point of the grid 0.003 to 1.0, with a flat path
(< 54: cross-validated log loss 0.06169 at 0.003, 0.06124 at 0.03, 0.06171 at 1.0). Arm B stopped at
173 to 196 rounds per fold for < 54 (refit with 187) and 291 to 554 for > 300 (refit with 384), far
from the 3,000-round ceiling and above the point where a fold had too few trees to learn.

Against the entropy of the training base rate (what a model that predicts the event rate for every row
scores): < 54 has 0.0729 nats per row and arm B's mean validation log loss was 0.0598 (18% lower), arm
A's 0.0612 (16% lower); > 300 has 0.3157 and the arms scored 0.2153 (32% lower) and 0.2227 (29%
lower). Both arms learn something; the trees learn a little more.

## Headline (test eras never used for tuning)

Glucose < 54 mg/dL in the next 24 h (the primary outcome):

| era | arm | AUROC | AUPRC | Brier | O/E | slope | intercept |
|---|---|---|---|---|---|---|---|
| 2017 - 2019 (test) | A | 0.840 [0.813, 0.866] | 0.064 [0.049, 0.084] | 0.010 | 0.92 [0.80, 1.04] | 0.92 | -0.37 |
| | A+Platt | 0.840 | 0.064 | 0.010 | 0.91 | 0.97 | -0.19 |
| | B | 0.864 [0.842, 0.886] | 0.078 [0.061, 0.106] | 0.010 | 0.96 [0.84, 1.10] | 1.04 | 0.11 |
| | B+Platt | 0.864 | 0.078 | 0.010 | 0.84 [0.73, 0.95] | 1.00 | -0.19 |
| 2020 - 2022 (test_shifted) | A | 0.824 [0.793, 0.854] | 0.065 [0.049, 0.094] | 0.010 | 1.15 [0.99, 1.34] | 0.92 | -0.17 |
| | A+Platt | 0.824 | 0.065 | 0.010 | 1.14 | 0.97 | 0.02 |
| | B | 0.858 [0.833, 0.881] | 0.074 [0.056, 0.106] | 0.010 | 1.15 [1.01, 1.33] | 1.02 | 0.22 |
| | B+Platt | 0.858 | 0.074 | 0.010 | 1.01 [0.88, 1.16] | 0.99 | -0.02 |

Glucose > 300 mg/dL in the next 24 h:

| era | arm | AUROC | AUPRC | Brier | O/E | slope | intercept |
|---|---|---|---|---|---|---|---|
| 2017 - 2019 | A | 0.882 [0.873, 0.891] | 0.505 [0.466, 0.553] | 0.064 | 0.99 | 1.07 | 0.09 |
| | B | 0.895 [0.886, 0.903] | 0.543 [0.511, 0.576] | 0.061 | 1.03 | 1.08 | 0.16 |
| 2020 - 2022 | A | 0.870 [0.860, 0.881] | 0.473 [0.443, 0.505] | 0.062 | 0.97 | 1.04 | 0.02 |
| | B | 0.882 [0.873, 0.892] | 0.508 [0.477, 0.541] | 0.059 | 0.96 | 1.05 | 0.02 |

Intervals are 2.5 and 97.5 percentiles of 1,000 subject-level bootstrap draws. The Platt rows for
> 300 moved nothing (O/E within 0.03, AUROC identical) and are left out of the table.

### Verdicts

Discrimination. Arm B's AUROC of 0.864 on 2017 to 2019 and 0.858 on 2020 to 2022 are within each
other's intervals; arm A is 0.02 to 0.03 lower in both eras. AUPRC is the number that moves at a 1%
event rate: 0.078 against a prevalence of 0.0101, a 7.7-fold concentration of events in the ranking
(arm A 6.4-fold); for > 300, 0.543 against 0.097, 5.6-fold. The interval widths (about ±0.02 on
AUROC with 219 events) are what 219 events allow; nothing here is precise to the third decimal.

Calibration on the primary era. The raw LightGBM is calibrated: O/E 0.96, slope 1.04, intercept
0.11, all with intervals covering 1 and 0. The logistic regression over-predicts a little (O/E 0.92,
slope 0.92: its predictions are too spread). The expected calibration error is 0.001 to 0.003 for every
variant, which says little at a 1% base rate (the row-weighted gap between observed and predicted
risk is bounded by the risk itself); the reliability tables and plots carry that information in the
release .11 run.

The Platt recalibration hurt arm B. Fitted on the out-of-fold training predictions and applied to
the refit model, it raised every prediction and pushed the primary era from O/E 0.96 to 0.84 (the
model now says 1.20% where 1.01% happened). From the two sets of slopes and intercepts the fitted
transform must have been close to logit(p') = 0.30 + 1.04 logit(p), that is, Platt learned that the
out-of-fold predictions under-predicted the training events by 12 to 15% and corrected for a bias the
refit model does not have. The mechanism is the usual one: out-of-fold predictions come from five
models trained on 80% of the rows and stopped early on their own fold; the refit model is a different
model, and a correction learned on one does not transfer to the other without a check. For arm A the
transform shrank the logits (0.95) and shifted them down (-0.19), which repaired the slope (0.92 to
0.97) and left the intercept where it was. Decision: the raw arm B is the primary model; the Platt
variant stays in the tables as the negative result it is; release .11 writes `oof_calibration_*.csv`
(the out-of-fold O/E, slope and intercept and the fitted Platt parameters) so the reasoning above is
tested rather than inferred, with the prediction that B's out-of-fold O/E is about 1.12 to 1.15 and
the Platt intercept about +0.30.

The documentation-shift era. In 2020 to 2022 both arms kept their discrimination (B 0.858, A 0.824)
and under-predicted by 15% (O/E 1.15, intervals excluding 1 for arm B). The subgroup table says where:
rows with no drip in the look-back O/E 1.08; rows whose drip is on the flowsheet 1.34; rows whose drip
is known from the eMAR alone 1.42; rows with a drip running at the landmark 1.58 (predicted 1.66%,
observed 2.62%). The eMAR-only rows carry no rate or dose for the infusion (`drip_units_24h`,
`max_drip_rate` are NULL there by construction) and the 2020 to 2022 flowsheet rows sit in stays
whose inputevents stop on a date (cohort table 17), so the model reads a lighter drip than the patient
had, and the companion inputevents features (vasopressors, feeds, dextrose) are missing in the same
stays. This is the shape expected from `docs/cohort_findings.md`: the charting change moves the level
of risk, not the ranking. The Platt variant's O/E of 1.01 on this era is the upward shift happening to
cancel the drift; it is luck, not calibration, and the table says so.

## Operating points (arm B, primary outcome)

| era | rows flagged | threshold | sensitivity | PPV | events caught of total |
|---|---|---|---|---|---|
| 2017 - 2019 | top 5% | 4.0% | 0.40 | 0.081 | 88 of 219 |
| | top 10% | 2.2% | 0.56 | 0.056 | 122 of 219 |
| | top 20% | 1.1% | 0.74 | 0.037 | 162 of 219 |
| 2020 - 2022 | top 5% | 3.4% | 0.35 | 0.074 | 66 of 187 |
| | top 10% | 1.9% | 0.53 | 0.056 | 100 of 187 |
| | top 20% | 1.0% | 0.75 | 0.039 | 140 of 187 |

Read as a daily alert on the at-risk ICU days: flagging the riskiest tenth catches 56% of the next
day's < 54 events at one event per 18 alerts; the riskiest fifth catches three quarters at one per 27.
Acting on every at-risk day is one per 100. Whether 18 reviews per prevented-or-caught event is a
good trade is the decision-curve question, and the thresholds that matter (0.5 to 10%) are the ones the
curve is drawn over; the curve itself (`decision_curves.csv`) comes with the release .11 results.
For > 300 the same operating points are 0.34 / 0.53 / 0.76 sensitivity at PPV 0.67 / 0.51 / 0.37.

## Sensitivities (arm B, < 54)

| analysis | 2017 - 2019 AUROC | 2020 - 2022 AUROC |
|---|---|---|
| main | 0.864 [0.842, 0.886] | 0.858 [0.833, 0.881] |
| train on 2011 to 2016 only | 0.855 [0.832, 0.878] | 0.842 [0.814, 0.869] |
| measured rows only (a glucose result in the label window) | 0.862 [0.838, 0.882] | 0.858 [0.832, 0.880] |
| windows of 6 h or more | 0.860 [0.835, 0.881] | 0.855 [0.831, 0.880] |

Dropping 2008 to 2010 (a third of the training rows, the era whose low-glucose rate stood apart) costs
0.01 to 0.02 of AUROC, inside the intervals: the era helps more than it hurts, and TRAIN_ERAS stays at
all three. Excluding the 1,079 unmeasured rows (negatives by construction) and the short windows
changes nothing, so neither inflates the headline.

## Subgroups (arm B, < 54, raw predictions)

| subgroup | level | 2017 - 2019 rows / events / AUROC / O/E | 2020 - 2022 rows / events / AUROC / O/E |
|---|---|---|---|
| drip running at t_k | no | 19,779 / 182 / 0.878 / 0.97 | 16,384 / 149 / 0.860 / 1.08 |
| | yes | 1,964 / 37 / 0.689 / 0.91 | 1,452 / 38 / 0.783 / 1.58 |
| drip record (24 h look-back) | no drip | 16,894 / 157 / 0.888 / 1.02 | 14,566 / 131 / 0.855 / 1.08 |
| | flowsheet | 4,593 / 54 / 0.769 / 0.79 | 1,436 / 28 / 0.817 / 1.34 |
| | eMAR only | 256 / under 10 | 1,834 / 28 / 0.872 / 1.42 |
| ICU day | day 2 | 5,069 / 49 / 0.853 / 0.85 | 3,527 / 45 / 0.881 / 1.32 |
| | days 3 - 4 | 5,203 / 47 / 0.877 / 0.94 | 3,981 / 44 / 0.863 / 1.53 |
| | days 5 - 8 | 4,931 / 52 / 0.874 / 1.23 | 4,065 / 34 / 0.893 / 1.13 |
| | day 9 + | 6,540 / 71 / 0.854 / 0.91 | 6,263 / 64 / 0.818 / 0.93 |
| sex | F | 8,501 / 96 / 0.888 / 1.00 | 6,432 / 74 / 0.839 / 1.23 |
| | M | 13,242 / 123 / 0.845 / 0.94 | 11,404 / 113 / 0.870 / 1.11 |
| first care unit | CVICU | 5,974 / 61 / 0.821 / 0.96 | 4,526 / 51 / 0.863 / 1.30 |
| | MICU | 3,668 / 58 / 0.825 / 1.14 | 3,005 / 22 / 0.907 / 0.79 |
| | MICU/SICU | 2,048 / 38 / 0.865 / 1.31 | 1,694 / 27 / 0.834 / 1.31 |
| | SICU | 1,892 / 11 / 0.908 / 0.51 | 1,603 / 19 / 0.767 / 1.07 |
| | TSICU | 2,249 / 17 / 0.922 / 0.89 | 1,551 / 17 / 0.789 / 1.50 |
| | CCU | 1,481 / 17 / 0.828 / 0.94 | 1,151 / 19 / 0.838 / 1.32 |
| race (the raw labels with 10 or more events) | WHITE | 11,623 / 115 / 0.862 / 0.98 | 7,821 / 64 / 0.824 / 0.99 |
| | BLACK/AFRICAN AMERICAN | 1,316 / 16 / 0.856 / 1.08 | 998 / 21 / 0.874 / 1.76 |
| | UNKNOWN | 4,610 / 46 / 0.841 / 0.97 | 3,411 / 25 / 0.908 / 0.85 |

The one finding that changes how the model should be described: among rows with an insulin infusion
running at the landmark, arm B's AUROC is 0.69 on the primary era (0.78 on the shifted one, 37 and 38
events), against 0.88 on the rows without one; arm A is 0.65 and 0.74 there. The global 0.86 is carried
by separating patients on a drip (1.9 to 2.6% event rate) from patients off one (0.9%), and by the
glucose history; within the drip rows the ranking is weak. That is the subgroup where iatrogenic
hypoglycemia is most likely and where an alert would be acted on, so the deck reports it next to the
headline, as TRIPOD+AI asks for subgroup performance where the model would be used. The units confirm
the pattern from the other side: the CVICU and MICU, where infusion protocols are routine after
surgery and in sepsis, sit at 0.82, the SICU and TSICU at 0.91 to 0.92 (with 11 to 17 events each,
so wide intervals). Sex and race show no gap the event counts can support (F 0.888 against M 0.845
reverses in the other era). ICU day shows the model is as good on day 2 as on day 9 and later.

What the raw subgroup table also showed, and the fix. `subgroups.csv` as written by release .8 had
460 cells, 216 of them with fewer than ten events, and it printed every self-reported race label
(MIMIC-IV carries sub-labels such as "WHITE - RUSSIAN" and "HISPANIC/LATINO - CUBAN") and every care
unit down to one row. The metrics were blank in those cells but the counts were not, and a count of
one patient in a named group is exactly what the deck's suppression rule exists to keep out of a
shared file. Release .11 changes `subgroup_table`: levels under 100 rows are pooled into one
"other" level before anything is computed, cells under 10 events (or non-events) report no count, no
rate and no metric, and race is collapsed to MIMIC's coarse groups (WHITE, BLACK, HISPANIC/LATINO,
ASIAN, OTHER, UNKNOWN) before the table is built. The `first_careunit` levels seen here include
intermediate and stepdown units (Neuro Intermediate, Neuro Stepdown, Surgery/Vascular/Intermediate,
PACU, Medicine, Surgery/Trauma), most of them in 2020 to 2022; they are what `icustays.first_careunit`
holds in v3.1 and the pooling handles the small ones. The at-risk rows in those units have low event
rates (Neuro Intermediate 5 events in 2,671 rows), which is itself worth a line in the deck.

## Context from the literature

Mathioudakis et al. (JAMA Network Open, 2021) built the closest published design: a rolling 24-hour
risk of hypoglycemia after each glucose measurement in insulin-treated inpatients, about 55,000
admissions at five Johns Hopkins hospitals, gradient boosting, basal insulin dose, glucose variability
and prior hypoglycemia as the strongest predictors (the Endocrine News summary; the article pages
could not be fetched from this session, so its C statistics are not quoted here and should be read
from the paper before the deck cites them). Fralick et al. (Internal and Emergency Medicine
2023;18:325-328) ran such a model prospectively on general wards and report about 40% less
hypoglycemia, with the remark that most published models were never evaluated in routine care.
Karasneh et al. (Expert Review of Endocrinology and Metabolism 2024;19:459-466) report an AUROC of
0.99 for CatBoost predicting any hypoglycemic episode during an ICU stay, with no prediction horizon
and features that are not fixed to a time before the event; the gap between that number and 0.86
here is the difference between a leaky stay-level label and a landmark design, and it is the contrast
the leakage slides should draw.

## The second run (release .12, 11 October 2026, 23:07 to 23:18 Colab time)

The second run, under release .12, produced the zip the notebook's last cell packs: 26 files, all aggregates,
now shipped in `docs/model_results/`. The run used 1,000 bootstrap draws on Python 3.13.16, numpy 2.1.3,
pandas 2.2.3, scikit-learn 1.6.1, lightgbm 4.7.0, shap 0.53.0 and matplotlib 3.10.0 (`run_settings.json`).
From the file timestamps: the two arms for both outcomes took seven minutes (the > 300 fit the longer
half, 384 rounds and arm A's six-point CV path on 9.6% events), the evaluation with its 16 bootstraps
about one minute, figures, importance and the three sensitivities two more; eleven minutes in all against
the half hour the release .8 bootstrap alone would have taken.

Reproduction against the first run. Arm B is identical to the last digit in every shared table (the
sensitivities agree to six decimals), as `deterministic=True` promises. Arm A is identical for < 54 and
moved for > 300: AUPRC by 0.001, O/E by 0.001 to 0.002, and the operating points by two to five events
of 2,109 (sensitivity at the 10% alert rate 0.5159 against 0.5149). Two Colab sessions reached slightly
different L-BFGS stops at scikit-learn's default tolerance; release .13 sets `tol=1e-6` on both logistic
fits so the fit is a property of the data, not of the machine. The exact calibration rows differ from
the .8 table by up to 0.019 in slope and 0.083 in intercept (arm A, 2020 to 2022: 0.923 / -0.165 then,
0.941 / -0.082 now), more than the fixture suggested; the .8 values should not be quoted.

Exact calibration rows, < 54, 1,000-draw intervals:

| era | arm | O/E | slope | intercept |
|---|---|---|---|---|
| 2017 - 2019 | A | 0.917 [0.802, 1.041] | 0.924 [0.845, 1.006] | -0.374 [-0.696, -0.039] |
| | A+Platt | 0.913 [0.797, 1.035] | 0.953 [0.871, 1.038] | -0.272 [-0.603, 0.070] |
| | B | 0.963 [0.842, 1.095] | 1.041 [0.953, 1.132] | 0.111 [-0.247, 0.448] |
| | B+Platt | 0.836 [0.731, 0.952] | 1.019 [0.933, 1.108] | -0.125 [-0.470, 0.194] |
| 2020 - 2022 | A | 1.154 [0.990, 1.338] | 0.941 [0.836, 1.055] | -0.082 [-0.543, 0.412] |
| | A+Platt | 1.140 [0.978, 1.323] | 0.971 [0.862, 1.088] | 0.022 [-0.451, 0.525] |
| | B | 1.155 [1.005, 1.327] | 1.016 [0.928, 1.117] | 0.216 [-0.143, 0.625] |
| | B+Platt | 1.006 [0.875, 1.156] | 0.995 [0.908, 1.093] | -0.014 [-0.358, 0.370] |

The Platt diagnosis, tested. `oof_calibration_lt54.csv` says what the first run could only infer: arm B's
out-of-fold predictions under-predicted the training rows by 15% (O/E 1.153, mean prediction 1.20%
against a 1.38% event rate, slope 1.022, intercept 0.232), and Platt is exactly that regression, so it
learned logit(p') = 0.232 + 1.022 logit(p), an upward shift. The prediction written before the run was
an O/E of 1.12 to 1.15 and an intercept near +0.30: the O/E landed at the top of the range, the
intercept at 0.23, the mechanism as stated. Arm A's out-of-fold predictions were calibrated in the large
(O/E 1.000) with a slope of 0.970, so its Platt step is a small shrink and does little. For > 300 both
arms' out-of-fold O/E sit at 1.00 to 1.03 and Platt changes nothing. Why the fold models under-predict
rows they did not see while the refit model does not: a boosted model fits its training rows' event rate
exactly (each leaf's value is set by the residuals it holds), and a model that has partly memorised its
positives assigns the rows it never saw a little less risk across the board; the model refit on all
88,552 rows with the same number of trees memorises less, and on the test era its O/E is 0.96. The
lesson for the deck is unchanged and now measured: recalibration fitted on one model and applied to
another is a hypothesis to test, not a step to assume.

Decision curves (`decision_curves.csv`, arm B, < 54). Net benefit is positive at every threshold from
0.5% to 10% on both eras and above the treat-all line at every threshold: at 0.5%, 0.73 against 0.51 per
100 rows (2017 to 2019); at 1%, the prevalence, where acting on every row is worth nothing, 0.57; at 2%,
0.39 with 11% of rows flagged; at 5%, 0.17 with 3.6% flagged; at 10%, 0.05 with 1.2% flagged. Arm A sits
below arm B by 0.01 to 0.06 per 100 rows across the range. A reader who would act on a risk of 1% or more
gains from the model against both default strategies; above 5% little is left because few rows carry
that much risk.

Reliability deciles (arm B, 2017 to 2019): the top decile predicts 5.71% and sees 5.61%, the ninth 1.59%
against 1.84%, the eighth 0.90% against 1.24%, and the bottom six deciles (0.14% to 0.45%) see 0 to
0.23%, a little less than predicted. On 2020 to 2022 the top decile predicts 4.93% and sees 5.61%, the
ninth 1.32% against 2.24%: the era's under-prediction sits in the upper deciles, where the drip rows are,
as the subgroup table said.

Importance (`importance_arm*_lt54.csv`). Arm B's mean |SHAP| ranks the minimum glucose of the last 24 h
first by a wide margin, then the stay's minimum glucose, weight, bolus insulin units, the stay's maximum
glucose, the 24 h glucose SD, HbA1c, basal insulin units, creatinine, the last glucose, the drip rate,
the count of prior values under 70, lactate, prior diabetes, the minimum systolic pressure and albumin.
Arm A's standardised coefficients carry the same story with signs a clinician would expect: lower
minimum glucose, no feed running, lower weight, basal and bolus insulin, a running drip, invasive
ventilation, octreotide and prior hypoglycaemia raise the risk; a running enteral or parenteral feed and
hours since the drip stopped lower it. This is the predictor set Mathioudakis et al. report (basal
insulin dose, glucose variability, prior hypoglycaemia) plus the ICU-specific feeds and infusions, and
nothing in it reads from the label window.

Subgroups as shipped (`subgroups.csv`, 228 cells, 24 suppressed, every shown cell has 11 or more events
and every level 121 or more rows). Race in MIMIC's coarse groups, arm B, < 54, AUROC on 2017 to 2019 then
2020 to 2022: WHITE 0.866 (123 events) and 0.826 (72); BLACK 0.882 (23) and 0.871 (29); HISPANIC/LATINO
0.810 (12) and 0.902 (17); UNKNOWN 0.844 (46) and 0.913 (38); ASIAN under 10 events then 0.710 (18, O/E
2.20); OTHER under 10 then 0.756 (13). With 12 to 29 events a cell, a difference of 0.1 is inside the
noise, and the group lowest in one era is among the highest in the other; the honest statement is that
these counts show no gap and could not show a moderate one. The units repeat the first run's pattern; the
four small units (Medicine, Neurology, Surgery/Trauma, Medicine/Cardiology Intermediate, 211 and 189 rows)
are pooled into one line.

Figures (`figures/`): the calibration and decision panels and the importance bars read as intended; the
precision-recall panel's axis was taken by the first rows' PPV spike, so release .13 scales it to the
curve past 2% recall and draws the prevalence line. Nothing else changed in the figures.

## The third run (release .14, 12 October 2026) and the row-order finding

The release .14 run came back with the six cohort tables and the 26 model files (the SQL check tables
were missing: the pipeline and pull had been re-run under .13, then `results/` was cleared, and the .14
notebook saw the parquet and skipped the data stage, so the check tables were never rewritten). The
cohort tables match the sixth-run SQL tables exactly (train 88,552 rows / 26,538 stays / 24,714
admissions / 20,280 subjects / 1,223 and 8,480 events; test 21,743 / 6,215 / 5,750 / 5,219 / 219 and
2,109; test_shifted 17,836 / 4,416 / 4,096 / 3,884 / 187 and 1,614; 2008 to 2010 at 1.64% against
1.01 to 1.16% in the other eras; 23.55% of windows shorter than 24 h, 8.50% shorter than 6 h; among
rows with a drip running, 0.8% have no glucose result in the label window against 5.7% of the others).

The model numbers did not reproduce the .12 run, and the reason is worth more than the difference. Arm
B's AUROC moved by 0.0025, its calibration intercept by 0.09, the operating-point sensitivities by up to
0.027; the per-fold best iterations went from 173 to 196 rounds to 169 to 240; arm A's cross-validated
path moved in the fifth decimal and its chosen C stayed at 0.03. The cut-points and the split counts
were identical, so the rows were the same rows. What differed was their order: the parquet had been
pulled again between the two runs, BigQuery returns a view's rows in no fixed order, and the
subject-grouped folds are assigned from the row order, so a reshuffled file gives different folds,
different early-stopping points, and slightly different trees. `deterministic=True` had held in the .8
to .12 comparison only because both runs read the same file. Release .15 fixes it twice over: both
pulls (`run_bigquery.py`, and the file route's runner of the development tooling) order `cohort_landmarks` and `features` by
subject, stay and k, and the modeling stage sorts the rows on that key after loading, so the folds and
everything after them depend on the data alone. Verified on the fixture: the notebook run on a shuffled
copy of the parquet gives the same headline, fold and operating-point tables, byte for byte, as the run
on the sorted one. The run that follows this fix is the one the deck quotes; the .12 and .14 numbers
agree with it to two decimals and differ in the third, which is itself a sentence for the deck's
limitations slide (a bootstrap interval of ±0.02 on 219 events, and a fold-assignment effect of 0.002).

## The evidence run of release .16 (12 October 2026), superseded by the .20 run below

One run of the single notebook with `RUN_DATA_STAGE = always`: the extract found in place, the pipeline and
the pull run again (the parquet now in a fixed order), the cohort stage, the models, one zip of 52 files.
Every table is in `docs/model_results/`; its SQL check tables equal the sixth-run tables of
`docs/cohort_findings.md` (table 1 per split, leakage 0 of 128,131 rows with 128,131 distinct keys, Table
1b 11.49% / 7 / 24 minutes / 947 straddling rows, the 2020 to 2022 flowsheet gap at 37.7% / 40.6%). Python
3.13.16, numpy 2.1.3, pandas 2.2.3, scikit-learn 1.6.1, lightgbm 4.7.0, shap 0.53.0. From the timestamps:
stage 3 took 27 minutes in this run (the fits 23, the evaluation two), against eleven in the .12 run; the
logistic fits at `tol=1e-6` take more L-BFGS iterations and Colab's machines vary, so the runbook says ten
to thirty.

Headline, glucose < 54 mg/dL in the next 24 h (1,000-draw subject bootstrap intervals):

| era | arm | AUROC | AUPRC | Brier | O/E | slope | intercept |
|---|---|---|---|---|---|---|---|
| 2017 - 2019 | A | 0.840 [0.813, 0.866] | 0.064 [0.049, 0.084] | 0.010 | 0.926 [0.810, 1.051] | 0.920 [0.841, 1.004] | -0.377 [-0.701, -0.041] |
| | A+Platt | 0.840 | 0.064 | 0.010 | 0.920 [0.804, 1.043] | 0.950 [0.869, 1.037] | -0.272 [-0.606, 0.074] |
| | B | 0.863 [0.840, 0.885] | 0.079 [0.061, 0.106] | 0.010 | 0.964 [0.845, 1.092] | 1.029 [0.945, 1.118] | 0.068 [-0.305, 0.399] |
| | B+Platt | 0.863 | 0.079 | 0.010 | 0.825 [0.724, 0.935] | 1.024 [0.940, 1.113] | -0.121 [-0.478, 0.193] |
| 2020 - 2022 | A | 0.825 [0.793, 0.855] | 0.066 [0.050, 0.094] | 0.010 | 1.156 [0.990, 1.338] | 0.936 [0.832, 1.048] | -0.100 [-0.558, 0.403] |
| | A+Platt | 0.825 | 0.066 | 0.010 | 1.140 [0.977, 1.324] | 0.966 [0.859, 1.082] | 0.006 [-0.463, 0.519] |
| | B | 0.855 [0.830, 0.878] | 0.076 [0.056, 0.112] | 0.010 | 1.180 [1.024, 1.350] | 1.007 [0.921, 1.103] | 0.203 [-0.162, 0.609] |
| | B+Platt | 0.855 | 0.076 | 0.010 | 1.010 [0.877, 1.156] | 1.002 [0.917, 1.098] | 0.019 [-0.332, 0.406] |

Glucose > 300 mg/dL: arm B 0.894 [0.885, 0.902] and 0.882 [0.873, 0.891], AUPRC 0.541 and 0.510, O/E 1.024
and 0.967; arm A 0.882 [0.872, 0.891] and 0.870 [0.860, 0.881], AUPRC 0.505 and 0.472. The Platt rows
change nothing there.

Tuning: C = 0.03 for both outcomes; arm B 206 trees for < 54 (per-fold best 158 to 236) and 394 for > 300
(335 to 526). Out-of-fold calibration: arm A O/E 1.001, slope 0.968; arm B O/E 1.168 (mean prediction 1.18%
against 1.38%), slope 1.005, intercept 0.184, which is the Platt transform that over-corrects the refit
model on the primary era (O/E 0.825). Raw arm B is the primary model.

Operating points, arm B, < 54: flag the riskiest 5 / 10 / 20% of at-risk ICU days and catch 38 / 55 / 77% of
the next day's events on 2017 to 2019 (83 / 121 / 169 of 219) at PPV 0.076 / 0.056 / 0.039, one event per
13 / 18 / 26 alerts; on 2020 to 2022, 37 / 51 / 78% (69 / 95 / 145 of 187) at 0.077 / 0.053 / 0.041. For
> 300: 34 / 53 / 76% at PPV 0.66 / 0.51 / 0.37.

Decision curve, arm B, < 54, net benefit per 100 rows against acting on every row: 0.72 against 0.51 at a
0.5% threshold, 0.58 against 0.01 at 1% (the prevalence), 0.36 against -1.01 at 2% (11% of rows flagged),
0.16 at 5% (3.7% flagged), 0.04 at 10% (1.3% flagged); the shifted era 0.74, 0.61, 0.32, 0.10, 0.04.

Reliability, arm B, < 54, 2017 to 2019: the top decile predicts 5.80% and sees 5.56%, the ninth 1.57%
against 2.21%, the eighth 0.89% against 1.15%. On 2020 to 2022: 4.86% against 5.33%, 1.27% against 2.80%,
0.75% against 0.78%; the era's under-prediction (O/E 1.18) sits in the eighth and ninth deciles.

Subgroups, arm B, < 54, AUROC on 2017 to 2019 then 2020 to 2022 (events in brackets): drip running at the
landmark 0.702 (37) and 0.774 (38) against 0.876 (182) and 0.857 (149) without; arm A 0.654 and 0.741 on
the drip rows. By the record that saw the drip: no drip 0.884 / 0.854, flowsheet 0.777 / 0.797, eMAR only
under 10 events / 0.863 (28). O/E on 2020 to 2022: no drip 1.11, flowsheet 1.37, eMAR only 1.39, drip running
1.60. Sex: F 0.882 (96) / 0.831 (74), M 0.847 (123) / 0.870 (113). Race groups: WHITE 0.864 (123) / 0.823
(72), BLACK 0.880 (23) / 0.858 (29), HISPANIC/LATINO 0.810 (12) / 0.899 (17), UNKNOWN 0.839 (46) / 0.903
(38), ASIAN under 10 / 0.724 (18), OTHER under 10 / 0.759 (13). Units: CVICU 0.822 (61) / 0.854 (51), MICU
0.832 (58) / 0.894 (22), MICU/SICU 0.869 (38) / 0.837 (27), SICU 0.919 (11) / 0.762 (19), TSICU 0.907 (17) /
0.788 (17), CCU 0.815 (17) / 0.828 (19). ICU day: day 2 0.850 / 0.877, days 3 to 4 0.869 / 0.852, days 5 to 8
0.883 / 0.897, day 9 and later 0.851 / 0.817. 228 cells, 24 suppressed, every shown cell 11 or more events.

Sensitivities, arm B, < 54, 2017 to 2019 then 2020 to 2022: main 0.863 / 0.855; train on 2011 to 2016 only
0.857 / 0.847; measured rows only 0.862 / 0.855; windows of 6 h or more 0.860 / 0.852.

Importance, < 54: arm B's mean |SHAP| ranks the minimum glucose of the last 24 h (0.320), the stay's minimum
(0.195), bolus insulin units (0.147), weight (0.146), the stay's maximum glucose (0.142), the 24 h glucose SD
(0.104), creatinine (0.097) and HbA1c (0.087); arm A's standardised coefficients lead with the minimum
glucose (-0.41), prior diabetes (+0.34), weight (-0.31), basal insulin units (+0.27), a running enteral feed
(-0.26) and the last glucose (-0.26).

Against the earlier runs: arm B's AUROC 0.863 here against 0.864 (.12) and 0.865 (.14) on the primary era,
0.855 against 0.858 and 0.856 on the shifted one, the fold-assignment effect the third run exposed, now
fixed by the row order; the intervals of ±0.02 cover all three. The
verdicts stand as written in the first section.

## What changed in the files

- Release .9: the bootstrap computes each draw as integer row weights (21 times faster, same numbers;
  `tests/test_evaluate.py`); `calibration_slope_intercept` and `Platt` use tol 1e-8; LightGBM uses the
  runtime's cores; the data notebook flushes Drive after the pull and lists the parquet; notebook 02
  stops if the parquet is not on the mounted Drive.
- Release .10: LightGBM `deterministic=True, force_row_wise=True`.
- Release .11: `subgroup_table` pools levels under 100 rows and suppresses counts under 10 events;
  `race_group` collapses MIMIC's race labels; notebook 02 writes `oof_calibration_*.csv`; its closing
  section carries the three readings above.
- Release .12: the runbook (`docs/runbook.md`); the runner recognises an extract that stopped partway;
  notebook 02 pins the library versions and packs `results/` into a zip from the runtime; notebook 01
  checks the Drive account.
- Release .13: `docs/model_results/` (the .12 run's output, the evidence behind the deck); logistic fits
  at `tol=1e-6`; the precision-recall axis.
- Release .22 (the second review's corrections, the section "The second review" below): the primary label
  counts every documented result below 54 and `y_lt54_excl_24h` carries the repeat-excluded definition as a
  sensitivity endpoint (the notebook's fifth sensitivity refits arm B on it); the CMS816 endpoint keeps the
  exclusion; nothing is removed on the feature side. Availability on every record: `landmark_grid`,
  `emar_insulin_events`, `emar_drips_at_landmark`, `drips_at_landmark` and `rrt_at_landmark` in `01`, storetime
  and `end_storetime` through `icu_insulin`, `icu_nutrition`, `icu_rrt`, `icu_antibiotics`, `icu_octreotide`,
  `sc_doses` and `emar_cohort`, the at-risk rule and every `02` join gated by entry time, the flowsheet flag by
  the first segment both started and entered, amount-derived rates only for complete segments, the eMAR cap
  binding over a late Stopped; deterministic tiebreakers on every last-value window; tables 20 and 21; the check
  tables named after their headers (`table01` to `table21`); the SQL tests in the repository
  (`tests/make_synthetic.py`, `run_pipeline.py`, `prefix_invariance.py`) with duckdb and sqlglot pinned.
- Release .21: the evidence folder replaced by the release .20 run (56 files) and every number in the README,
  the runbook, the design notes, this file and the deck regenerated from it; the code is the .20 code.
- Release .20: the review's corrections (the section above): the repeat rule low-only, exact and
  endpoint-specific, with `repeat_storetime`; the feature-side exclusion conditioned on availability;
  storetime kept for every chartevents row, inputevents, procedureevents and the eMAR, and the
  both-times rule on vitals, weight and GCS; the flowsheet-first flag per landmark; `years_after_anchor`
  on every row with 01 tables 18 to 20 and the anchor-year-only sensitivity; the preparation refitted
  inside every fold; the extract guard for a pre-.20 extract and `EXTRACT_FORCE`; the split relabelled
  everywhere; the validation called development-informed.
- Release .19: the repository is the thing a peer opens, so the setup cell clones the code from the GitHub
  repository named in its `REPO` field and checks the release marker against the notebook's (the zip on
  Drive remains the fallback when `REPO` is empty); the README was rewritten as the landing page a grader
  reads first, with the long form (the SQL files, the runner, the rules, the models, the cost model) moved
  to `docs/design.md`. The clone path, the release-mismatch stop and the bad-address stop were exercised
  under a simulated Colab against a local repository.
- Release .18 (the submission): the repository carries the graded path only. Out: the optional file route
  (`pipeline/run_local.py`, `mimic_csv_schema.py`, `download_physionet.py`, `notebooks/00_data_physionet_files.ipynb`),
  the development harness (`tests/make_synthetic.py`, `run_pipeline.py`, `make_synthetic_features.py`) and the
  notebook builder (`tests/build_notebook.py`), which stay with the author as tooling and still check every
  release before it ships; `tests/test_evaluate.py` stays. The deck (30 slides, speaker notes on every slide,
  the code link to be pasted into the title slide's notes) and the code PDF are submitted beside the repository,
  not inside it; neither names the author, the project id or a link that identifies them.
  The code of the graded path is the .16 code.
- Release .17: the deck and the code PDF first built, under `docs/deck/`; the release marker moved.
- Release .16 (the evidence run): `docs/model_results/` replaced by this run's 52 files.
- Release .16: the LLM-embedding extension removed from the release (the `03_serialize.sql` file,
  the `--with-serialize` flags, the notebook switch and its two cells), so the grader sees one path;
  the idea stays as one paragraph of future work.
- Release .15: a fixed row order for the parquet (both pulls) and in the modeling stage, after the
  third run showed the folds following the pull order.
- Release .14: one notebook instead of three (`notebooks/hypo_harm_tutorial.ipynb`, written by
  a builder script): setup, data (skipped when the parquet is on Drive), cohort, models, pack.
  The three-notebook split had each notebook assuming another had unpacked the code; the cohort
  notebook's harness cell failed in a fresh runtime for that reason on 12 October.

## The review of 12 October 2026 and release .20: four faults corrected, two claims relabelled

An independent review of the repository at release .19 (the full SQL, notebook, modeling and evaluation
code, the development history and the aggregate results) made nine points. Each was checked against the
code line by line; the verdicts, in the reviewer's order, and what release .20 does about them:

1. **The glucose repeat-test rule was wrong. Confirmed, corrected.** `glucose_events` flagged any result
   whose next result was >= 80 within 5 whole minutes, with no condition that the result itself was
   low, and every file then dropped the flagged rows. So a 110 followed by a 120 three minutes later was
   removed from the glucose history, and a 350 followed by a 320 was removed from the > 300 label. The
   rule is now: a result below 54 contradicted by any result above 80 charted within 300 seconds
   (CMS816's exclusion, "a subsequent glucose > 80 mg/dL within five minutes", which CMS defines for its
   < 40 measure; this tutorial extends it to the < 54 outcome on the same reasoning, that an immediately
   contradicted low is a contaminated draw or a meter error, and says so). Results at or above 54 are
   never cancelled; > 300 is never cancelled. 01 table 18 counts, per value band, what the new rule
   cancels and what the old rule flagged, so the size of the fault is a number in the rerun.
2. **The flag leaked the future into the features. Confirmed, corrected.** The flag was computed from the
   admission's whole stream, and `02` dropped flagged results from the features, so a 45 at 07:59 could
   be removed from the 08:00 landmark by a repeat at 08:02 that nobody had seen at 08:00. The assertion
   on `max_feature_time` could not catch it, because the future result decided whether an earlier row
   survived instead of appearing as a timestamp. `glucose_events` now carries `repeat_storetime`, the
   time the contradicting result became visible, and the features drop a cancelled low only when that
   time precedes the landmark: at the landmark the clinician had seen the low and no repeat, and so
   does the model. The label side still uses the flag in full, as it should. The fixture plants both
   cases (a 45 at 09:50 stored at 09:52, contradicted at 09:54 by a result stored at 10:30, landmark
   10:00: the 45 is `glucose_last`, the label window before it does not count the 45).
3. **Availability timestamps were missing for most predictors. Confirmed in fact; the fix is split by the
   kind of record.** The extract kept `storetime` only for the glucose items. It now keeps it for every
   chartevents row and for inputevents, procedureevents and the eMAR, and `02` applies the both-times
   rule (charttime and storetime before t_k) to the vitals, weight and GCS exactly as to labs and
   glucose. It does not apply a storetime rule to interval records, and the reason is stated rather
   than assumed: an inputevents segment or a procedure interval is stored when it is finalised, at or
   after its end, while the fact the feature uses (an infusion started at this time at this rate) was
   visible at the bedside from its start; `02` reads a running segment clipped at the landmark and
   never its end or its total amount. A storetime rule on intervals would delete every running
   infusion from the features, the most important real-time fact in the table, and make the model
   blind to it. On the rate-less "Continuous IV" rows, `amount / hours` is the set rate (a rate change
   closes a segment and opens another), so a segment crossing the landmark contributes its rate and
   its clipped duration, not its completed amount. 01 table 20 measures, per record kind, the lag
   between entry and the time the feature uses (the share stored after it, and its percentiles), which
   is the evidence a reader needs to judge the distinction. eMAR doses keep their administration
   charttime for both the at-risk rule and the dose features; the same table reports their entry lag.
4. **The flowsheet-first flag used the whole stay. Confirmed, corrected.** `stay_has_inputevents_drip`
   was true for every landmark of a stay with any inputevents drip segment, so a segment charted on day
   four decided, on day one, that an eMAR interval open at the landmark should be declined. The flag is
   now evaluated per landmark from segments started before t_k; appending a later record no longer
   changes an earlier row. The fixture plants it (an eMAR-only interval running at t_1 and a flowsheet
   segment starting three hours after t_1: the row stays "running on the eMAR alone").
5. **The split is patient-disjoint but not a strict temporal holdout. Confirmed, relabelled.** The split
   is by the patient's `anchor_year_group`, and a patient's later admissions keep the group whatever
   calendar year they fall in (table 17 shows admissions up to five years after the anchor). "Trained on
   2008 to 2016, tested on 2017 to 2019" was too strong; every document now says "patients anchored in".
   Every row carries `years_after_anchor` (admittime year minus anchor year, exact under MIMIC's date
   shift), 01 table 19 tabulates it per split, and the notebook's fourth sensitivity scores the test
   rows whose admission is in the anchor year itself. A conservative admission-period split (an
   admission's calendar range is the group's three years shifted by the offset; keep only rows whose
   range lies inside one period) is the strict version and is future work: with three-year groups only
   the anchor-year admissions are certain, so it drops most later admissions, and patient-disjointness
   conflicts with it whenever a patient spans two periods.
6. **Preprocessing was fitted outside the cross-validation. Confirmed, corrected.** One `FeaturePrep`
   fitted on all training rows fed the folds, so validation-fold values reached the cut-points,
   medians, rare-level pooling and scaling (unsupervised statistics; the labels never did). `models.py`
   now refits the preparation inside every fold on that fold's training rows; the final models and the
   test eras use the preparation fitted on all training rows, as before. The reviewer's second remark
   stands and is now written in the module docstring: the out-of-fold predictions are produced by the
   same folds that choose C and the stopping round, so they are mildly optimistic; they feed the Platt
   step, which is reported as a negative result, and the raw models are primary. A nested scheme is the
   strict version.
7. **The test groups took part in development. Confirmed, relabelled.** The cohort runs looked at event
   rates and monitoring density in every era, the test groups included, when the infusion cap, the
   drip-source rule and the primary test group were decided. Those were data-quality decisions, not
   model tuning, and the models were never fitted on the test rows; but "never trained on" is not
   "untouched". The results are now called a development-informed internal validation, in the deck's
   limitations and here. A held-out random subset of patients frozen before any development is what a
   stronger claim needs; MIMIC-IV offers no second untouched database.
8. **Diagnosis history is restricted correctly.** Agreed; no change.
9. **The evaluation arithmetic is right; the data validity was the open question.** Agreed. The cohort,
   the models, the tables and the deck's numbers are regenerated by a rerun of release .20: the extract
   again (the storetime columns; `EXTRACT_FORCE` in the setup cell, `--force` in the runner), the
   pipeline, the pull, the models: the section "The release .20 run" holds its numbers.

Not raised by the review but changed with it: the runner recognises an extract from before release
.20 (no `storetime` on `src_inputevents`) and says what to do; the notebook's `years_after_anchor`
is bookkeeping, never an input.

## The release .20 run (12 October 2026): the numbers the deck quotes

The rerun after the review: the extract rewritten with the entry-time columns (`EXTRACT_FORCE`), the pipeline,
the pull and the models in one Colab run, 56 files. From the file timestamps: the pipeline finished at 16:45,
the cohort stage at 16:49, the fits and the evaluation at 17:21, the sensitivities at 17:24, so stage 3 took
about 35 minutes with the preparation now refitted inside every fold (27 on the .16 run). Same library
versions as .16 (Python 3.13.16, numpy 2.1.3, pandas 2.2.3, scikit-learn 1.6.1, lightgbm 4.7.0, shap 0.53.0).
The extract stores 2.78 GiB (src_chartevents 1.27, src_emar 0.76, src_labevents 0.45, src_inputevents 0.26,
src_procedureevents 0.03, src_microbiologyevents 0.01), against 2.47 before the entry-time columns.

### The cohort after the corrections (table 1, against .16)

| split | rows | stays | < 54 | < 40 | CMS816 | > 300 | drip in 24 h | running at t_k |
|---|---|---|---|---|---|---|---|---|
| train (anchored 2008 - 2016) | 88,554 (+2) | 26,538 | 1,223 | 325 | 313 | 8,512 (+32) | 19,019 (+11) | 8,296 (+9) |
| test (anchored 2017 - 2019) | 21,744 (+1) | 6,215 | 218 (-1) | 56 (-1) | 50 (-1) | 2,116 (+7) | 4,853 (+4) | 1,968 (+4) |
| shift test (anchored 2020 - 2022) | 17,837 (+1) | 4,417 (+1) | 187 | 49 | 45 | 1,624 (+10) | 3,272 (+2) | 1,454 (+2) |

128,135 rows (+4), 37,170 stays, 29,384 patients. The four added rows and the added drip rows are the
landmark-time flowsheet flag: eMAR intervals now count at landmarks before a stay's first flowsheet segment.
The 49 added > 300 events are high values the old repeat flag had removed. The one lost < 54 event is a low
contradicted by a repeat within 300 seconds that was not the next result. Leakage assertion 0 of 128,135;
Table 1b: 11.35% of ICU glucose results carry a charttime later than their storetime (the value was entered,
then given a nominal time a median 7 min later, p90 24), 949 landmark rows with such a value straddling the
landmark; the lab panel 245 of 7.3 million. (Releases .20 and .21 stated this direction backwards in the
deck and the README; the table's column is `stored_before_charttime`.)

### What the three new tables said

Table 18, the repeat rule. The rule before release .20 had flagged 36,816 results at or above 54 (837 in 54 to
79, 34,311 in 80 to 300, 1,668 above 300) that no definition of the exclusion covers, and dropped them from the glucose
history, the monitoring counts and the > 300 label. The corrected rule cancels 71 results below 40 and 88 in
40 to 53 (the old rule had caught 67 and 87 of them, looking only at the next result) and nothing at or above
54. In 91 of the 159 cancelled lows the contradicting result was stored later than the low itself, which is
the window in which the old feature-side exclusion could look ahead.

Table 19, the split. Of the training rows, 46,158 (52%) are admissions in the patient's anchor year;
15,529 (18%) are admissions that certainly fall in 2017 or later (the group's three years shifted by the
offset lie wholly past 2016), and 4,711 (5%) certainly in 2020 or later; patients anchored in 2008 to 2010
contribute admissions up to 15 years after the anchor. Of the primary test rows, 77.7% are anchor-year
admissions (146 of 218 events); of the shift test rows, 92.5% (161 of 187). This is the measured size of the
reviewer's point: the split is patient-disjoint and approximately temporal, with about a sixth of the training
rows from the test groups' calendar years.

Table 20, entry lags. Point observations are entered late: vitals a median 22 minutes after their charttime
(p90 96, p99 255; 21% more than an hour later), the ICU glucose items a median 26 (p90 88), GCS 29 (p90
153), weight 21 (p90 186, p99 4,151: weights are entered days late). The both-times rule on vitals, weight
and GCS therefore removes, near each landmark, the values the chart did not yet hold; a feature built on
charttime alone would have used them. Interval records are not what the review assumed and not quite what
the correction assumed either: insulin drip segments are stored a median 1 minute after their start (p90 83,
p99 616) and a median 67 minutes before their end (10.5% after the end), so the row exists in the database
while the infusion runs; the eMAR's insulin events a median 1 minute after their charttime (p90 74). A
storetime rule on segments is therefore feasible and release .22 applies it (the section on the second
review below); the release .20 argument that the clipped-segment rule read only the start and the rate was
wrong, since `running_at_tk`, `seg_end`, `hrs_since_drip_stop` and the amount-derived rates all read the
segment's end.

### Headline (arm, outcome, group; AUROC [95% bootstrap], AUPRC, O/E, slope)

| group | arm | AUROC | AUPRC | Brier | O/E | slope | intercept |
|---|---|---|---|---|---|---|---|
| < 54, anchored 2017 - 2019 | A | 0.839 [0.812, 0.865] | 0.064 [0.049, 0.083] | 0.010 | 0.920 [0.805, 1.044] | 0.918 | -0.393 |
| | B | 0.865 [0.842, 0.887] | 0.077 [0.059, 0.105] | 0.010 | 0.954 [0.839, 1.079] | 1.046 [0.964, 1.132] | 0.118 |
| | B+Platt | 0.865 | 0.077 | 0.010 | 0.838 [0.736, 0.947] | 1.028 | -0.092 |
| < 54, anchored 2020 - 2022 | A | 0.826 [0.795, 0.855] | 0.066 | 0.010 | 1.160 [0.990, 1.337] | 0.936 | -0.098 |
| | B | 0.855 [0.830, 0.880] | 0.081 [0.059, 0.120] | 0.010 | 1.141 [0.984, 1.310] | 1.017 | 0.206 |
| | B+Platt | 0.855 | 0.081 | 0.010 | 1.003 [0.866, 1.152] | 1.000 | 0.002 |
| > 300, anchored 2017 - 2019 | A | 0.883 [0.873, 0.892] | 0.506 | 0.064 | 0.988 | 1.065 | 0.085 |
| | B | 0.895 [0.887, 0.903] | 0.543 [0.512, 0.575] | 0.061 | 1.021 | 1.089 | 0.165 |
| > 300, anchored 2020 - 2022 | A | 0.868 [0.857, 0.878] | 0.473 | 0.062 | 0.968 | 1.036 | 0.012 |
| | B | 0.880 [0.870, 0.889] | 0.511 [0.478, 0.540] | 0.060 | 0.962 | 1.046 | 0.011 |

Against .16: every AUROC within 0.002 (B < 54: 0.865 against 0.863; 0.855 against 0.855; > 300: 0.895
against 0.894, 0.880 against 0.882; A 0.839 / 0.826 / 0.883 / 0.868 against 0.840 / 0.825 / 0.882 / 0.870),
every interval overlapping almost entirely. The four corrections changed the labels (49 highs restored, one
low cancelled), the features (vitals under the entry-time rule, the feature-side exclusion, four drip rows)
and the folds (the preparation refitted per fold: 175 and 369 trees against 206 and 394), and none of it
moved the discrimination; the shift group's under-prediction eased from 18% to 14% (B; A 16%). Arm A chose
C = 0.03 for both outcomes again.

Calibration: raw arm B on the primary group, top decile 5.71% predicted against 5.66% observed; O/E 0.95,
slope 1.05. Out-of-fold: arm B's fold models under-predict the training rows by 14% (O/E 1.141, mean
prediction 1.21% against 1.38%), Platt intercept 0.204, slope 1.017, and the step again over-corrects the
primary group (O/E 0.838); arm A's out-of-fold O/E is 1.004. The verdict stands: raw arm B is the primary
model, the recalibration a negative result. On the shift group the drift sits in the ninth and tenth deciles
(1.31% predicted against 2.07% observed, 5.01% against 5.83%).

Operating points, arm B, < 54, primary group: the riskiest 5% of rows catch 40% of events (87 of 218) at a
PPV of 0.080, one event per 13 alerts; 10% catch 56% (123) at 0.057, one per 18; 20% catch 74% (162) at
0.037, one per 27. Shift group 36 / 56 / 75%. For > 300: 34 / 53 / 75% at PPV 0.67 / 0.52 / 0.37. Decision
curve, per 100 ICU days against acting on everyone: 0.73 against 0.50 at 0.5%, 0.58 against 0.00 at 1%, 0.38
against -1.00 at 2% (11% flagged), 0.14 against -4.20 at 5% (3.8%), 0.03 at 10% (1.3%); above acting on
everyone and on no one at every threshold from 0.5 to 10%.

Subgroups (arm B, < 54): rows with an infusion running at the landmark, AUROC 0.687 (37 events, 1.9%
event rate) on the primary group and 0.776 (38 events, 2.6%) on the shift group; without one, 0.880 and
0.858; arm A 0.650 / 0.739 and 0.859 / 0.830. Units on the primary group: CVICU 0.825 (61 events), MICU
0.840 (58), MICU/SICU 0.860 (38), TSICU 0.911 (17), SICU 0.905 (11), CCU 0.816 (17). The shift group by
record (rows, events, AUROC, O/E): no drip in the look-back 14,565 / 131 / 0.852 / 1.07; drip on the
flowsheet 1,436 / 28 / 0.817 / 1.34; drip known from the eMAR alone 1,836 / 28 / 0.869 / 1.34; infusion
running at t_k 1,453 / 38 / 0.776 / 1.51. Race groups on the primary group: WHITE 0.866 (123 events), UNKNOWN
0.847 (46), BLACK 0.868 (22), HISPANIC/LATINO 0.841 (12), ASIAN and OTHER suppressed; no supportable gap.
228 cells, 24 suppressed.

Sensitivities (arm B, < 54, primary / shift): main 0.865 / 0.855; training on 2011 to 2016 only 0.856 /
0.846; measured rows only 0.863 / 0.855; windows of 6 h or more 0.861 / 0.853; anchor-year admissions only
0.867 (16,900 rows, 146 events) / 0.869 (16,507 rows, 161 events). The last is the answer to the split
question: on the rows whose calendar period is certain, the AUROC does not fall.

Importance: arm B's mean |SHAP| ranks the 24 h minimum glucose first (0.32), then the stay minimum (0.22),
weight (0.14), bolus units (0.14), the stay maximum (0.13), glucose SD (0.12), creatinine (0.08), basal
units (0.08), HbA1c (0.07), the last glucose (0.07). Arm A's largest standardised coefficients: 24 h minimum
glucose -0.41, prior diabetes +0.34, weight -0.32, basal units +0.27, no enteral rate recorded +0.26, enteral
running -0.26, last glucose -0.26, MICU -0.26, doses from inputevents -0.25, bolus units +0.25, prior
hypoglycemia diagnosis +0.25, drip rate at t_k +0.24, invasive ventilation +0.23, hours since the drip
stopped -0.22, lows earlier in the stay +0.22, infusion running +0.21, parenteral running -0.21.

Monitoring: 11,717 rows with an infusion running at t_k; 5.7% of the rows without one have no glucose
result in the label window (6,691 of 116,418) against 0.8% with one (95 of 11,717). Censoring unchanged:
23.55% of windows under 24 h, 8.50% under 6 h.

## The second review of 12 October 2026 and release .22: the endpoint, availability on every record, a test that enforces it

The reviewer read commit b0f2c53 (release .21), the saved tables and the deck, accepted the seven corrections
of release .20, and made five points. What each one says, what was checked, and what release .22 does:

1. **The primary endpoint must keep every documented low. Agreed, done.** The release .20 label had extended
   CMS816's repeat-result exclusion from its < 40 measure to the < 54 outcome and called a contradicted low a
   false positive. The sequence low-then-normal within five minutes does not establish a measurement error:
   treatment between two draws, two sampling methods and meter error all produce it. `y_lt54_24h` now counts
   every documented result below 54 in the window; `y_lt54_excl_24h` carries the excluded definition as a
   sensitivity endpoint, which the notebook's fifth sensitivity refits arm B on and scores against; `y_cms816_24h`
   keeps CMS's own conditions (< 40, not excluded, an agent in the prior 24 h); `y_lt40_24h` counts every
   documented result below 40. The wording everywhere is "excluded by the repeat-result rule". The feature-side
   exclusion is gone rather than tightened: the features use every documented result known at the landmark,
   which makes the question of the repeat's two timestamps moot and the glucose history exactly what the chart
   showed. On the fixture, the change moves one test row's label (a 35 at 06:00 contradicted by a 95 at 06:03
   now counts) and table 1's `pos_lt54_excl` column carries the old count.

2. **Eligibility and predictors must be built from what was available at each landmark. Agreed, done, and the
   release .20 claim corrected.** The claim that the clipped-segment rule "never reads the end or the total
   amount" was wrong: `running_at_tk`, `seg_end`, `hrs_since_drip_stop` and the `amount / hours` rates all read
   the segment's end. Table 20 had shown where the entry time of a segment sits (a median 1 minute after its
   start, 67 minutes before its end), which is what the rule now follows. In `01`: `landmark_grid` (one row per
   eligible stay and day); `drips_at_landmark`, one row per landmark and drip record visible at it, an
   inputevents segment visible when both its start and its storetime precede t_k, its end known when the segment
   ended before t_k and, for a rate change, the next segment was entered before t_k (`end_storetime`, the one
   end the data timestamps), running at t_k otherwise, an amount-derived rate used only once the segment is
   complete; `emar_drips_at_landmark`, the eMAR state rebuilt at every landmark from the events charted and
   entered before it, with the cap now binding over a late Stopped in the descriptive view too; `rrt_at_landmark`,
   the dialysis record rebuilt the same way (the first run of the prefix test caught a CRRT charting entered
   after the landmark extending an interval's end). The flowsheet-source flag is true at t_k only when a segment
   had both started and been entered. The at-risk rule reads `drips_at_landmark` and `sc_doses` under the
   both-times rule, and `02` reads the same views, so eligibility and predictors agree by construction; every
   other `02` join (eMAR, feeds, dextrose, vasopressors, ventilation, antibiotics with the first known start per
   landmark, octreotide, weight, GCS, vitals) is gated by entry time. Two things the data cannot timestamp are
   stated rather than assumed: a Stopped, Paused or FinishedRunning end is taken at its nominal time, and a
   culture is counted at its collection time because the microbiology row's storetime dates the result, days
   later (table 20 now measures it). Table 21 reports, per record kind, the records in use at the landmarks by
   clinical time that had not been entered by then.

3. **Tests that enforce the rules, in the repository. Done.** `tests/make_synthetic.py` plants the reviewer's
   cases (a flowsheet segment started an hour before a landmark and entered 30 minutes after it; a rate change
   written after the landmark; an eMAR Stopped charted five minutes before a landmark and entered half an hour
   after; an eMAR start with 16 hours of silence before its Stopped; a rate-less segment crossing a landmark; a
   low at 09:59 whose repeat is charted at 10:02 and entered at 09:58; the 300 against 301 second and the 80
   against 81 mg/dL boundaries; an eMAR dose charted before a landmark and entered after it, which must not make
   the stay eligible), with entry times that follow table 20. `tests/run_pipeline.py` runs the four SQL files on
   it and the fixture's docstring states every expected number. `tests/prefix_invariance.py` is the general test:
   for each of the 11 landmarks of the grid it rebuilds the database as the EHR held it at that moment (records
   entered at or after the landmark removed, a rate change not yet written left open) and requires the landmark
   to be at risk in both or neither and all 145 inputs to be identical; it also doubles the completed amount of
   the crossing rate-less segment. It passes, and its first run found two faults: the dialysis end above, and a
   lab result and a fingerstick sharing a charttime with different values, whose order in the last-value windows
   was undefined (BigQuery returns ties in no fixed order), now broken by entry time and value. The three
   scripts need no data and no credentials; duckdb 1.5.6 and sqlglot 30.22.0 are pinned for them.

4. **The split is an exploratory internal validation. Agreed, stated.** Patient-disjoint, by anchor group rather
   than by calendar time, and development-informed; the anchor-year-only sensitivity scores the test rows alone
   and leaves the training rows' later admissions in place, which the notebook now says. A temporal claim would
   need admission-period splits with the patients who span two periods handled explicitly; an untouched one,
   patients whose records did not shape the pipeline. Raw models primary, Platt exploratory, nested calibration
   deferred: unchanged and stated.

5. **The deck must be regenerated from the rerun's files.** The deck the reviewer received was a stale copy with
   the .16 numbers; the current deck carries the .20 numbers but still had the timestamp direction backwards
   (slide 10), called < 54 a CMS hospital-harm endpoint (slide 3), read the decision curves as proof of
   benefit (slide 22) and the shift group's O/E interval as excluding 1 (slide 24). Those four are corrected in
   wording now; every number, figure and speaker note is regenerated from the release .22 result files once the
   rerun is in, with the outcome described as a documented event before 24 hours, ICU discharge or death and
   the decision curves as potential clinical utility.

What the rerun has to show before the deck is rebuilt: table 1 (the primary count rises by the contradicted
lows, `pos_lt54_excl` matches the .20 count of 1,223 / 218 / 187 up to the availability changes), table 21
(how many drip, dose, feed, ventilation and dialysis records the rule withholds at the landmarks), the
procedureevents lag in table 20 (if ventilation intervals turn out to be entered at their end rather than at
their start, `invasive_vent_at_tk` loses most of its rows and a chartevents ventilator setting would replace
it in a later release), the leakage assertion at 0, and the headline against .20.

## What is still open

- A clinician's reading of the deck's wording.
- The drip subgroup: 0.69 is a limitation to state, not to fix before the deadline. The features that
  would address it (glucose trajectory over the last 6 h, rate changes and time since the last change,
  feed interruptions timed against the infusion) are future work, and a model fitted on the drip rows
  alone is the natural comparison.
- An LLM-embedding arm (each landmark row written as a short text record, embedded by an open-weight
  model inside the student's own session, a classifier on the vectors) was drafted and removed from
  the release: it needs a GPU session, a row-level text file that must never leave the student's
  Drive, and a third evaluation; it is the comparison a follow-up would add.
- The 2020 to 2022 under-prediction by 15%: a recalibration on the shifted era itself would fix the
  level but is not available before deployment; the honest deck statement is that a model trained on
  flowsheet-complete years needs its intercept re-checked after a charting change.
- Mathioudakis et al.'s reported C statistics, to be read from the article.
