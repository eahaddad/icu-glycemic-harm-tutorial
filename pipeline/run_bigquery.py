"""
Run the pipeline on BigQuery through the API and pull the final tables out as parquet.

This is the student path: MIMIC-IV v3.1 already sits on BigQuery for every
credentialed user, so nothing is downloaded or installed. Each SQL file runs as
one script job in the student's own sandbox project (the YOUR_PROJECT placeholder
is filled from --project, no file is edited), every SELECT inside it comes back
as a CSV (01's check tables as 01_cohort_labels_table01.csv ... table21.csv,
named after their "-- Table N." headers; the other files' by statement index,
02_features_check01.csv ...), every statement's billed bytes are printed (the README's cost table),
and the final tables are pulled into parquet files that the analysis notebooks
read. After the pull, BigQuery is not needed again: the sandbox's 60-day table
expiry and lifetime storage quota stop mattering.

    # authenticate first: in Colab  from google.colab import auth; auth.authenticate_user()
    #                     elsewhere gcloud auth application-default login
    python pipeline/run_bigquery.py --project MY_PROJECT --step extract     # 00b, once per project
    python pipeline/run_bigquery.py --project MY_PROJECT --step pipeline    # 01, 02 (views; repeatable)
    python pipeline/run_bigquery.py --project MY_PROJECT --step pipeline --only 02_features.sql   # one file, after a change to it
    python pipeline/run_bigquery.py --project MY_PROJECT --step pull        # the three final objects -> parquet files
    python pipeline/run_bigquery.py --project MY_PROJECT --step cost        # the month's billed bytes and the dataset's storage

What each step costs (measured 11 October 2026, README cost table). extract:
29.1 GiB of query bytes by the per-column rule (free tier 1 TiB a month) and
2.47 GiB of the sandbox's lifetime 10 GiB storage (2.78 GiB since the entry-time
columns of release .20, by the extract's own size table), so it refuses to run when
the src_* tables already exist unless --force is given. pipeline: 01 4.5 GiB
with thirteen check tables (about 5.5 with fifteen) and 02 5.4 GiB per run
(two of its check queries recompute the features view), no storage beyond the
params row, landmark_grid and cohort_landmarks (tens of MB). pull: 2.98 GiB (features 2.94),
then the results travel through the BigQuery Storage Read API when the project
allows it (reads of query results are free) and otherwise through the plain
REST read, which is free and slower. The measured numbers print at the end of
each step.

The pull writes three parquet files (params, cohort_landmarks, features); the
notebook reads those and nothing else, so after the pull BigQuery is not needed again.

Privacy: the parquet files hold row-level MIMIC-IV data and stay with the
credentialed user (own Drive, never shared). The CSVs in results/ are the
aggregate check tables.
"""
import argparse, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SQL_DIR = ROOT / "sql"
STEPS = {"extract": ["00b_extract.sql"], "pipeline": ["01_cohort_labels.sql", "02_features.sql"]}
FINAL = ["params", "cohort_landmarks", "features"]                 # tables and views, in this order

def client_for(project):
    from google.cloud import bigquery
    return bigquery.Client(project=project)

SPENT = ("This project's BigQuery sandbox storage is spent. The sandbox grants a lifetime 10 GiB of storage per "
         "project that deleting tables never refunds, so {project} cannot store anything again without billing. "
         "Create a new project (console.cloud.google.com, project picker, New project), open the BigQuery console "
         "in it once, and run again with its id. PhysioNet access is on your Google account, not the project. "
         "If a fresh project fails the same way, enable billing on it: the extract costs about $0.02 per GB-month, "
         "under $0.10 a month, and the 1 TiB of free query bytes still applies.")

def storage_probe(client, project):
    """Fail in seconds, not after a 16 GiB scan: write and drop a one-row table. The sandbox refuses the write
    when the project's lifetime storage is gone."""
    from google.api_core.exceptions import BadRequest, Forbidden
    try:
        client.query(f"CREATE SCHEMA IF NOT EXISTS `{project}.hypo_tutorial`;\n"
                     f"CREATE OR REPLACE TABLE `{project}.hypo_tutorial.quota_probe` AS SELECT 1 AS ok;\n"
                     f"DROP TABLE `{project}.hypo_tutorial.quota_probe`;").result()
    except (BadRequest, Forbidden) as e:
        if "free storage" in str(e) or "QueryUsagePerDay" in str(e) or "QueryUsagePerUserPerDay" in str(e):
            sys.exit(explain(e, project))
        raise

QUOTA = ("A custom daily query quota on this project stopped the script (QueryUsagePerDay or QueryUsagePerUserPerDay: "
         "a cost control someone set, the default is 200 TiB a day). Raise it: IAM & Admin, Quotas & System Limits, "
         "filter the BigQuery API, select 'Query usage per day', Edit, enter a value in TiB (1 is plenty for this "
         "tutorial) or tick Unlimited, Submit. Or wait for the reset at midnight US Pacific. The statements that "
         "completed were saved; re-run the step afterwards (views cost nothing to recreate).")

def explain(err, project):
    text = str(err)
    if "free storage" in text:
        return SPENT.format(project=project)
    if "QueryUsagePerDay" in text or "QueryUsagePerUserPerDay" in text:
        return QUOTA
    return text

def check_names(text, n_selects):
    """File names for a script's SELECT results, in order. A file whose SELECT statements each carry a
    '-- Table N.' header (01) names them table01 ... table21, so a view added to the file does not rename
    every result; any other file (00, 00b, 02) numbers them by statement index (check09, check01 ...)."""
    import re
    names = re.findall(r"^-- Table (\w+)\.", text, flags=re.M)
    if len(names) == n_selects:
        return [f"table{n.zfill(2)}" for n in names]
    return None

def run_script(client, project, fname, results_dir):
    """One SQL file as one BigQuery script job. Returns [(statement index, DataFrame)] for its SELECTs
    and prints bytes billed per statement, read from the script's child jobs. If a statement fails, the
    results of the statements before it are still saved, then the failure is explained and the run stops."""
    from google.api_core.exceptions import BadRequest, Forbidden
    text = Path(SQL_DIR, fname).read_text().replace("`YOUR_PROJECT.", f"`{project}.")
    print("\n" + "=" * 100 + f"\n{fname}\n" + "=" * 100)
    t0 = time.time()
    parent = client.query(text)
    failure = None
    try:
        parent.result()                                 # waits for the whole script
    except (BadRequest, Forbidden) as e:
        failure = e
    children = sorted(client.list_jobs(parent_job=parent.job_id, max_results=200), key=lambda j: j.created)
    names = check_names(text, sum(1 for j in children if j.statement_type == "SELECT"))
    results, total, n_select = [], 0, 0
    for i, job in enumerate(children):
        gib = (job.total_bytes_billed or 0) / 2**30
        total += gib
        head = " ".join((job.query or "").split())[:70]
        if job.error_result:
            print(f"[{i:2d}] FAILED {' ' * 17} {gib:7.2f} GiB  {head}\n     {job.error_result.get('message', '')[:300]}")
            continue
        print(f"[{i:2d}] {job.statement_type or '':24s} {gib:7.2f} GiB  {head}")
        if job.statement_type == "SELECT":
            df = job.result().to_dataframe()
            results.append((i, df))
            with __import__("pandas").option_context("display.width", 250, "display.max_columns", 60, "display.max_colwidth", 60):
                print(df.head(40).to_string())
            if results_dir is not None:
                Path(results_dir).mkdir(parents=True, exist_ok=True)
                tag = names[n_select] if names else f"check{i:02d}"
                df.to_csv(Path(results_dir, f"{Path(fname).stem}_{tag}.csv"), index=False)
            n_select += 1
    print(f"{fname}: {len(children)} statements, {total:.1f} GiB billed, {time.time() - t0:,.0f}s"
          + (f", {len(results)} check tables saved before the failure" if failure else ""))
    if failure:
        sys.exit(f"\n{fname} did not finish. {explain(failure, project)}")
    return results

def pull(client, project, parquet_dir):
    from google.api_core.exceptions import NotFound
    parquet_dir = Path(parquet_dir); parquet_dir.mkdir(parents=True, exist_ok=True)
    total_rows, pulled = 0, 0
    for name in FINAL:
        t0 = time.time()
        try:
            # ORDER BY: BigQuery returns a view's rows in no fixed order, and two pulls of the same view gave files whose
            # rows were shuffled; the grouped folds of the modeling stage follow the row order, so the trees and the
            # third decimal of the AUROC moved between two runs on the same data. A keyed order makes the file a
            # function of the data alone.
            order = "ORDER BY subject_id, stay_id, k" if name in ("cohort_landmarks", "features") else ""
            job = client.query(f"SELECT * FROM `{project}.hypo_tutorial.{name}` {order}")
            df = job.result().to_dataframe()            # the query's bytes are billed; reading its result is not
        except NotFound:
            print(f"  {name:20s} not built: run --step pipeline first")
            continue
        pulled += 1
        path = parquet_dir / f"{name}.parquet"
        df.to_parquet(path, index=False)
        total_rows += len(df)
        print(f"  {name:20s} {len(df):>10,} rows  {path.stat().st_size / 2**20:8.1f} MB  "
              f"{(job.total_bytes_billed or 0) / 2**30:6.2f} GiB billed  {time.time() - t0:5.0f}s")
    print(f"{pulled} parquet files, {total_rows:,} rows in total, under {parquet_dir}")

def cost(client, project):
    """What the project has used: the month's billed bytes against the free 1 TiB, and the dataset's
    storage against the sandbox's lifetime 10 GiB. Costs a few MB of query bytes itself."""
    month = client.query(f"""
        SELECT ROUND(SUM(total_bytes_billed) / POW(1024, 4), 3) AS tib_billed_this_month, COUNT(*) AS statements
        FROM `{project}.region-us.INFORMATION_SCHEMA.JOBS_BY_USER`
        WHERE creation_time >= TIMESTAMP_TRUNC(CURRENT_TIMESTAMP(), MONTH)
          AND job_type = 'QUERY' AND COALESCE(statement_type, '') != 'SCRIPT'""").result().to_dataframe()
    tib = float(month["tib_billed_this_month"].iloc[0] or 0)
    print(f"query bytes billed this month: {tib:.3f} TiB of the free 1 TiB ({int(month['statements'].iloc[0])} statements)")
    try:
        storage = client.query(f"SELECT table_id, row_count, ROUND(size_bytes / POW(1024, 3), 3) AS gib "
                               f"FROM `{project}.hypo_tutorial.__TABLES__` ORDER BY size_bytes DESC").result().to_dataframe()
        print(storage.to_string(index=False))
        print(f"storage in hypo_tutorial: {storage['gib'].sum():.2f} GiB (a sandbox project has a lifetime 10 GiB)")
    except Exception as e:                       # no dataset yet
        print(f"no hypo_tutorial dataset yet ({type(e).__name__})")

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--project", required=True, help="your Google Cloud project id (the sandbox project)")
    ap.add_argument("--step", required=True, choices=["extract", "pipeline", "pull", "cost"])
    ap.add_argument("--results-dir", default=str(ROOT / "results"), help="check tables as CSV go to <results-dir>/checks")
    ap.add_argument("--parquet-dir", default=str(ROOT / "results" / "parquet"), help="pull: where the parquet files go")
    ap.add_argument("--force", action="store_true", help="extract: rewrite src_* even if they exist (spends lifetime storage)")
    ap.add_argument("--only", nargs="+", metavar="FILE", default=None,
                    help="pipeline: run only these files (e.g. --only 02_features.sql after a change to it; "
                         "the objects it reads from earlier files must already exist in the project)")
    args = ap.parse_args()
    client = client_for(args.project)
    if args.step == "extract":
        if not args.force:
            from google.api_core.exceptions import NotFound

            def exists(table):
                try:
                    client.get_table(f"{args.project}.hypo_tutorial.{table}")
                    return True
                except NotFound:
                    return False
            # 00b writes src_chartevents early and src_microbiologyevents last: both present = a complete extract,
            # the first alone = a run that stopped partway (a dropped Colab session, a quota message)
            first, last = exists("src_chartevents"), exists("src_microbiologyevents")
            if first and last:
                # release .20 added storetime to src_inputevents (and the other extracts): an extract without it
                # predates the current SQL and 01 would fail on the missing column
                fields = {f.name for f in client.get_table(f"{args.project}.hypo_tutorial.src_inputevents").schema}
                if "storetime" not in fields:
                    sys.exit("the src_* tables in this project are from a release before .20 (src_inputevents has no "
                             "storetime column, which 01 and 02 now read). Run this step again with --force: it rewrites "
                             "every src_* table (about 2.8 GiB of a sandbox's lifetime 10 GiB; nothing on a project "
                             "with billing). In the notebook, set EXTRACT_FORCE to True for one run.")
                sys.exit("src_* tables already exist in this project; 00b must not run twice on a sandbox "
                         "(each run spends about 2.8 GiB of the lifetime 10 GiB). Skip to --step pipeline. "
                         "Use --force only if you mean to rewrite them.")
            if first and not last:
                sys.exit("a previous extract stopped partway (src_chartevents exists, src_microbiologyevents does not). "
                         "Run this step again with --force: it rewrites every src_* table, which this project can afford "
                         "once more (about 2.8 GiB of the lifetime 10 GiB per run).")
        storage_probe(client, args.project)
    if args.step in STEPS:
        files = list(STEPS[args.step])
        if args.only:
            unknown = [f for f in args.only if f not in files]
            if unknown:
                sys.exit(f"--only names files that the {args.step} step does not run: {unknown} (it runs {files})")
            files = [f for f in files if f in args.only]
        for fname in files:
            run_script(client, args.project, fname, Path(args.results_dir, "extract" if args.step == "extract" else "checks"))
    elif args.step == "pull":
        pull(client, args.project, args.parquet_dir)
    else:
        cost(client, args.project)

if __name__ == "__main__":
    main()
