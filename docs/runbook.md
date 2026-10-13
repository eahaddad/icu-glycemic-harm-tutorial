# Runbook: the whole tutorial from a clean start

This is the order to do things in, what each step should print, how long and how much it costs, and what
went wrong on the first real runs so that it does not go wrong on yours. Follow it top to bottom once. A
second pass (after a change to a SQL file or a notebook) is the short list at the end.

Three rules before anything else:

1. **One Google account.** The account you link on PhysioNet for BigQuery, the account you sign into
   Colab with, and the account you pick in the Drive dialog of every notebook must be the same one. The
   first real run lost an hour because a notebook mounted a second Google account's Drive, which was
   empty, and stopped with `features.parquet` missing. The setup cell prints what it found on Drive; if
   that line says NONE and you have run the data stage before, you picked the wrong account.
2. **One release.** The notebook and the code belong together: the setup cell holds the release string
   and refuses code whose `RELEASE` file says otherwise. Open the notebook from the repository (GitHub) and
   name the same repository in the setup cell's `REPO`; the code is cloned from it. Without GitHub, the
   repository as `hypo-harm-tutorial.zip` does the same job: the notebook asks for the zip once and keeps
   it on your Drive.
3. **Nothing row-level leaves your Drive.** `parquet/` and `predictions/` hold MIMIC-IV identifiers and
   stay in your Google Drive. What you share is the results zip the last cell makes (aggregate tables and
   figures) and the notebook with its outputs cleared. No MIMIC-IV row, note or value goes into a chat assistant or any third-party
   API; the only models that touch the data are the ones that run in your own Colab session.

## 0. Before Colab (one afternoon, once)

1. A PhysioNet account, credentialed (CITI "Data or Specimens Only Research" course, the credentialing
   application, the MIMIC-IV data use agreement signed). This can take days to be approved; start it first.
2. In your PhysioNet profile, cloud settings, enter the Google account from rule 1. Then on the MIMIC-IV
   v3.1 project page (physionet.org/content/mimiciv/3.1/), in the files section, request access with
   Google BigQuery. Access arrives as membership of a Google group; it is usually quick, sometimes hours.
   Until it has arrived, every query against `physionet-data` fails with "Access Denied", which is step 2's
   first error below.
3. A Google Cloud project with no billing account (a "sandbox"): console.cloud.google.com, the project
   picker at the top, New project, any name. Copy the **project id** (lowercase, often with a number, for
   example `glucose-tutorial-123456`), not the display name. Open console.cloud.google.com/bigquery once with
   the project selected so the API is on. Use a project that has never held BigQuery data: the sandbox's
   10 GiB of storage is a lifetime allowance for the project, not a monthly one.
4. Google Drive with about 100 MB free on that account (the parquet files are 28 MB, the results a few MB).
5. The repository's address (https://github.com/<account>/<repository>); the notebook opens from it and
   clones the code from it. Only if you were handed the repository as `hypo-harm-tutorial.zip` instead:
   unzip it once into a folder you keep (`notebooks/hypo_harm_tutorial.ipynb` is what you upload to
   Colab; the zip itself is what the notebook asks for).

Cost: nothing. Query bytes are free up to 1 TiB a month; the whole tutorial uses about 48 GiB (29.1 extract measured before release .20 plus about 3 for the entry-time columns, 11.4 pipeline, 3.0 pull).

## 1. The notebook, stage by stage (the modeling stage took 32 minutes in the evidence run, 19 on a faster machine in the previous release; the data stage adds minutes on a first run)

Open colab.research.google.com, File, Open notebook, the GitHub tab, paste the repository's address and
pick `notebooks/hypo_harm_tutorial.ipynb` (from a zip instead: File, Upload notebook, the same file from
the unzipped folder). Runtime, Change runtime type: CPU. Nothing in this tutorial uses a GPU; a GPU
runtime only spends your compute units. In the setup cell paste your project id into `PROJECT` and the
repository's address into `REPO` (leave `REPO` empty when you run from the zip); leave `RUN_DATA_STAGE` at
`auto`. Then Runtime, Run all, and watch the cells below in order (Colab shows no cell numbers; the first
line of each code cell names it).

### Stage 0, setup (one cell)

Mounts Drive (pick the account from rule 1), clones the code from `REPO` and checks its release against
the notebook's (`code cloned from ..., release ...`); with `REPO` empty it takes the zip from
`MyDrive/hypo_tutorial/` instead, or opens a file picker for it the first time. Then it installs
`lightgbm==4.7.0` and `shap==0.53.0` when Colab's versions differ, and prints three lines you check:
`MyDrive/hypo_tutorial holds: ...`, `parquet files: ...` (NONE on a first run), and `data stage: will run
on BigQuery` or `skipped, features.parquet is present`.

### Stage 1, data (four cells; only when the setup cell said the data stage will run)

| cell | what it does | what you should see |
|---|---|---|
| `# 1.1 Sign in` | `auth.authenticate_user()` with the PhysioNet-linked account, then `--step cost` | the month's query bytes and the dataset's storage, both 0 on a fresh project |
| `# 1.2 Extract` | `00b_extract.sql` once, the `src_*` tables (on a project whose extract predates release .20 the runner says so: set `EXTRACT_FORCE` in the setup cell for one run, which rewrites them) | one line per statement with bytes billed; the first real run billed 29.1 GiB and stored 2.47 GiB, and release .20 stores 2.78 GiB (the entry-time columns); the last statement prints rows and GiB per table. Minutes, not hours. On a project that already holds the extract the cell prints "already in this project; going on" |
| `# 1.3 Pipeline` | `01` (39 statements: the params row, the views, the two landmark tables, twenty-one check tables) and `02` (4 statements) | bytes per statement; about 6 GiB and a few minutes for each file (the .20 run: 6.0 GiB and 100 s for `01`, 5.4 GiB and 40 s for `02`; the per-landmark views of release .22 add compute, not bytes; less when BigQuery's result cache serves a repeated statement); `02`'s first check table must say `rows_violating_leakage_rule 0` |
| `# 1.4 Pull` | `params`, `cohort_landmarks`, `features` to parquet, copied to Drive with the check tables | `3 parquet files, 254,555 rows` (the .23 run: the params row and 127,277 rows in each of the two tables), then `... MB of parquet and 25 check tables under MyDrive/hypo_tutorial/` and the three file sizes. Since release .23 this cell clears an earlier run's check tables from `MyDrive/hypo_tutorial/results/` before it copies the new ones in, so the count is 25 whatever the folder held before (26 when the extract's size table is there too) (the first .22 zip had carried the .20 run's `check15` to `check34` next to its own `table01` to `table21`) |

When the data stage is skipped, each of the four cells prints `data stage skipped` and nothing else.

Numbers to compare with (MIMIC-IV v3.1 as of October 2026; `docs/cohort_findings.md` has the rest):
`results/01_cohort_labels_table01.csv` (table 1 of `01`; since release .22 the check tables are named after
their `-- Table N.` headers, `table01` to `table21`, so a view added to the file no longer renames them)
must show, for the release .23 run, train 87,762 rows / 26,434 stays / 20,221 patients / 1,234 glucose < 54
(1,216 after the repeat-result exclusion, `pos_lt54_excl`) / 8,466 > 300, test 21,702 / 6,210 / 5,214 / 226
(218) / 2,115, test_shifted 17,813 / 4,414 / 3,882 / 190 (186) / 1,622; 127,277 rows in all; `rows_with_drip_24h`
18,790 / 4,831 / 3,257. Against the .22 evidence run that is eight more rows and no more events: the corrected
two-source dose rule admits a landmark whose only visible exposure was a flowsheet bolus with an eMAR twin entered
later, and the eMAR tiebreak settles the shift group's drip row, which the two .22 runs had given as 3,256 and
3,257. (The .20 run had 128,135: the at-risk rule has read only exposure records entered before the landmark
and rebuilt the eMAR state per landmark since .22, which removed 866 rows; the unfiltered primary label added
the contradicted lows to the event counts.)
`02_features_check01.csv` must be 0. `01` prints 21 check tables and `02` three (`02_features_check01.csv`
to `check03.csv`).

If the pipeline or the pull fails halfway (a dropped Colab session, a quota message), fix the cause and run
that cell again: both are written to be repeated. The extract is the exception: a complete extract refuses to
run twice (it would spend another 2.78 GiB of the lifetime storage) and the cell goes on, and an extract that
stopped partway is recognised by the runner, which tells you to run it again with `--force` (add it to the
`run_step('extract')` call once); the project can afford that once.

### Stage 2, cohort and labels (eight cells, under a minute)

`# 2.0` loads the parquet and prints `landmark rows 127,277   feature rows 127,277 x 172 columns` (172 =
145 inputs and 27 bookkeeping columns, the 5 labels among them). `2.1` to `2.6` recompute the cohort tables (they must equal
`table01`), the censoring profile, the leakage assertion on every row (0), missingness and monitoring
density. `2.7` writes the `eda_*.csv` tables next to the check tables.

### Stage 3, the models (nine cells; 31.7 minutes in the evidence run by the timestamps of its result files, of which the sixth sensitivity's refit is several; the two .22 runs took 19.1 and 33.5 for five sensitivities)

| cell | what it does | what you should see |
|---|---|---|
| `# 3.1` | loads, checks column roles, defines the splits | `127,277 rows, 29,317 subjects, 145 input columns, 27 bookkeeping columns` and the three-split table |
| `# 3.2` | fits the feature preparation on the training rows | the matrix size and the cut-point table |
| `# 3.3` | fits arm A (logistic, C by grouped CV) and arm B (LightGBM, early stopping) for both outcomes; Platt on the out-of-fold predictions | `arm A: C = 0.01` for both outcomes (the .22 runs chose 0.03 for > 300: the cross-validated log loss at 0.01 and 0.03 differs in the fifth decimal, so the choice is a coin the folds toss); arm B 194 trees (< 54; the folds stopped at 179, 164, 255, 186, 186) and 323 (> 300; the .22 runs gave 153 and 411 or 402: the stopping rounds follow the fold assignment, which eight rows in a different place change); 22 minutes in the evidence run (8.3 for the < 54 cross-validation, 13.9 for > 300; 15 on the faster .22 machine; the preparation is refitted inside every fold since release .20), the slowest part |
| `# 3.4` | evaluation on both test eras with 16 bootstraps of 1,000 subject draws, subgroups, operating points, decision curves | the headline table; one to two minutes (2.1 in the evidence run, 1.2 on the faster .22 machine) |
| `# 3.5` to `# 3.8` | figures, importance, subgroup prints, six sensitivities (the fifth refits arm B on the repeat-excluded endpoint, the sixth refits the preparation and arm B without the drip inputs, a few minutes more) | PNGs under `results/figures/`; a line `drip inputs removed for sensitivity 6: ...` naming the columns; the sensitivities table with its two `without the drip inputs (refit)` rows per era (the figures and importance took 0.7 minutes in the evidence run, the six sensitivities 6.7; the five of .22 took 2.4 on a faster machine) |
| `# 3.9` | library versions, `run_settings.json` | the version dict |

Headline to compare with (`docs/model_results/headline_metrics.csv`, the release .23 evidence run): arm B AUROC
0.864 on the patients anchored in 2017 to 2019 and 0.850 on those anchored in 2020 to 2022 for glucose < 54;
0.893 and 0.878 for > 300; arm A 0.836 and 0.826 (< 54), 0.881 and 0.869 (> 300). The fifth sensitivity, arm B
refitted on the repeat-excluded endpoint, gives 0.863 and 0.852; the sixth, arm B refitted without the drip
inputs, 0.860 and 0.855 on every row and 0.700 and 0.733 on the rows with an infusion running (0.705 and 0.730
with the drip inputs, `subgroups.csv`).
What a second run reproduces, measured on the previous release (release .22 run twice on 12 October 2026 on the
same extract, on two Colab machines): every cohort count except one landmark row of the shift group
(`rows_with_drip_24h` 3,256 against 3,257 in table 1; one row's running flag in `02_features_check03`), arm A's
AUROC to four decimals, arm B's to 0.001 (0.864 / 0.851 against 0.863 / 0.852 for < 54, 0.892 / 0.880 either way
for > 300), the C choice and the < 54 tree count exactly, the > 300 tree count to within 2% (411 against 402), the
< 54 fold log losses to seven decimals. Release .23 breaks the tie behind the one row, and I have run it once; a
second .23 run that matches table 1 to the row is the measurement still to make, and if yours does, tell me.
The p99 columns of table 20 differ by a few minutes because `APPROX_QUANTILES` is approximate. So compare your
table 1 to the row and your AUROCs to two decimals; the third decimal is not a reproduction failure.
`run_settings.json` records your library versions.

### Stage 4, pack (one cell)

`# 4.` packs `results/` into one zip on the runtime's disk (the check tables, the cohort tables, the model
tables and figures), copies it to Drive, flushes Drive, and downloads it to your computer:
`results_<release>_<stamp>.zip: 56 files, ... MB` and a browser download (57 when the Drive folder holds the extract's size table from an extract run in the same folder). That zip is the thing you share
or hand in. Do not download the `results/` folder from the Drive website right after the run: on the first
real run the `figures/` folder came back empty because Drive had not finished syncing.

## 4. Sharing and handing in

- Share: the `results_*.zip` from stage 4 (tables and figures, all aggregates with small cells suppressed),
  `docs/`, and the notebook after Edit, Clear all outputs (the repository's notebook carries no outputs;
  keep it that way).
- Never share: anything under `parquet/` or `predictions/`, a screenshot of a row grid, a notebook saved
  with outputs that show rows, or any value from the data pasted into a chat assistant.
- The repository itself contains no data; only code, documentation and aggregate tables.

## 5. Running it again after a change

- A change to `01_cohort_labels.sql` or `02_features.sql`: set `RUN_DATA_STAGE` to `always` and run all;
  the extract cell sees the existing extract and goes on, the pipeline and the pull run again (about 12 GiB
  of query bytes, less with the result cache), then stages 2 to 4. To re-run one SQL file alone, add
  `'--only', '02_features.sql'` to the `run_step('pipeline', ...)` call.
- A change to `00b_extract.sql`: a new sandbox project, `RUN_DATA_STAGE` at `always`, run all.
- A change to the modeling code or to a stage 2 or 3 cell: run all with `RUN_DATA_STAGE` at `auto`; the
  data stage skips itself. No BigQuery.
- A new release of the repository: open the notebook from the repository again, so the two carry the
  same release (rule 2); the setup cell stops with a clear message when they do not. From a zip, pick the
  new zip when the setup cell asks; it copies it to Drive.

## 6. When it does not work

| what you see | why | what to do |
|---|---|---|
| `parquet files: NONE` and `data stage: will run on BigQuery` on an account that has run it before | the Drive dialog picked a different Google account | Runtime, Disconnect and delete runtime; run the setup cell again and pick the right account. (On a truly first run, NONE is expected and the data stage runs.) |
| `this notebook is release ... but the repository is at release ...` | the notebook was opened from an older copy (an upload, a Drive copy) than the repository it clones | File, Open notebook, GitHub tab: open the notebook from the repository again |
| `could not clone ...` | the `REPO` address is wrong, or the repository is private | check the address in `REPO`; a private repository cannot be cloned from Colab without a token, so make it public or run from the zip |
| `hypo-harm-tutorial.zip is not on Drive yet, or is an older release than ...` and a file picker | `REPO` is empty and the zip on Drive is from an earlier release than the notebook, or this is the first run | pick the zip from your computer; the notebook copies it to Drive |
| `ModuleNotFoundError: No module named 'hypo_tutorial'` | a notebook from before release .14 (the tutorial was three notebooks that assumed one another had unpacked the code) | use the single notebook from the current release; its setup cell fetches the code itself |
| `Access Denied: ... physionet-data` from the extract or pipeline | the signed-in account is not the one linked on PhysioNet, or the BigQuery access request has not propagated | check the account you picked at `auth.authenticate_user()` matches your PhysioNet cloud settings; wait for the access email; run the cell again |
| the extract cell prints `already in this project; going on` | you ran it before on this project | nothing; the pipeline runs next |
| the extract stops: `a previous extract stopped partway` | an earlier run was interrupted after some tables were written | add `'--force'` to the `run_step('extract')` call, run the cell again, once, then remove it |
| `exceeded quota for free storage` or the runner's storage refusal | the sandbox's lifetime 10 GiB is spent in this project | a new sandbox project (step 0.3) in `PROJECT`, `RUN_DATA_STAGE` at `always`, run all |
| a Colab "runtime disconnected" during a cell | idle timeout or a long cell on the free tier | reconnect, run the setup cell (and the sign-in cell if the data stage is running) again, then the cell that was interrupted and the ones after it; nothing needs undoing (see the extract rows above if it was the extract) |
| the `figures/` folder is empty in a download from Drive | Drive had not synced when you downloaded | use the zip from stage 4, or wait for the Drive sync icon to finish |
| `pip` fails to install lightgbm or shap in the setup cell | a transient network error in Colab | run the cell again |
| a cohort number differs from the list in step 1 | a different MIMIC-IV version or a changed DECLARE | the SQL names `mimiciv_3_1` explicitly; compare `params.parquet` (the DECLAREs the run used) with `docs/cohort_findings.md` |
| the evaluation cell (`# 3.4`) is slow | release .8, whose bootstrap refitted scikit-learn in every draw | use the current release; the same cell took 1.2 to 2.2 minutes in the .22 and .23 runs. A GPU runtime does not help: nothing here runs on a GPU |
| the model numbers differ from the documented run in the third decimal | a parquet pulled before release .15 (no fixed row order, so different folds), or different library versions | re-run with the current release: it sorts the rows before the folds, and `run_settings.json` records the versions; two decimals of agreement is what two installations of the same data should show |
| `PerformanceWarning: DataFrame is highly fragmented` from `features.py` during stage 3 | pandas noting that the feature matrix is built a column at a time | nothing; it is a speed notice, not an error, and the values are the same. A later release builds the matrix in one step |
| the subgroup table shows `other (levels under 100 rows)` and blank counts | by design: small levels are pooled and cells under 10 events carry no count, so the file can be shared as it is | nothing; the deck uses the same rule |
