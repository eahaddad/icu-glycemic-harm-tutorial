import sys
"""
Prefix invariance of the pipeline on the synthetic database (the second review of 12 October 2026):
adding records that were not available at a landmark must leave that landmark's eligibility and
predictors unchanged; its labels may change.

For every landmark of the grid (at risk or not), a copy of the database is built that holds only the
records the EHR held at t_k: event rows with storetime < t_k (chartevents, labevents, inputevents,
procedureevents, the eMAR), microbiology rows collected before t_k (the pipeline counts a culture at its
collection time, see 01 view 5b), outpatient measurements dated before DATE(t_k). The pipeline runs on
the copy, and the landmark's row must be identical to the row the full database gives: at risk in both
or in neither, and every model input equal (NaN equal to NaN). Bookkeeping that reads the future
(labels, label_window_n_glucose) is not compared.

A second check covers the reviewer's case 4: the completed amount of a rate-less segment that crosses
a landmark is changed, and the landmark's predictors must not move.

    python tests/prefix_invariance.py
"""
import io, sys, contextlib, shutil
from pathlib import Path
import duckdb, pandas as pd

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE.parent / "src"))
from run_pipeline import run_file, FILES, DB
from hypo_tutorial import columns as C

WORK = HERE / "prefix_work"


def run_pipeline(db_path):
    con = duckdb.connect(str(db_path))
    con.execute("DROP SCHEMA IF EXISTS hypo_tutorial CASCADE")
    # the pipeline's own printout is kept quiet, but a statement that fails must be seen: run_file exits the process
    # on a failure, so its captured output is replayed first (release .23; the second review's run died silently)
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            for f in FILES:
                run_file(con, f)
    except SystemExit:
        sys.stdout.write(buf.getvalue()[-4000:])
        raise SystemExit(f"the pipeline failed on {db_path}; the last statement and its error are above")
    grid = con.execute("SELECT stay_id, k, t_k FROM hypo_tutorial.landmark_grid ORDER BY stay_id, k").fetchdf()
    feat = con.execute("SELECT * FROM hypo_tutorial.features ORDER BY stay_id, k").fetchdf()
    con.close()
    return grid, feat


def prefix_copy(src, dst, t_k):
    shutil.copy(src, dst)
    con = duckdb.connect(str(dst))
    t = t_k.strftime("%Y-%m-%d %H:%M:%S")
    # a segment closed by a rate change has its end written when the next segment is entered (01 icu_insulin,
    # end_storetime): in the prefix the change is not yet written, so the segment is still open. MIMIC-IV cannot
    # hold an open row, so the prefix copy gives it an end just after t_k, which is what the EHR showed at t_k
    con.execute(f"""
        UPDATE mimiciv_3_1_icu.inputevents AS a SET endtime = TIMESTAMP '{t}' + INTERVAL 1 MINUTE
        WHERE a.statusdescription = 'ChangeDose/Rate' AND a.storetime < TIMESTAMP '{t}' AND a.endtime < TIMESTAMP '{t}'
          AND EXISTS (SELECT 1 FROM mimiciv_3_1_icu.inputevents AS b
                      WHERE b.stay_id = a.stay_id AND b.itemid = a.itemid AND b.starttime = a.endtime
                        AND b.storetime >= TIMESTAMP '{t}' AND COALESCE(b.statusdescription, '') != 'Rewritten'
                        AND (b.rate IS NOT NULL OR LOWER(COALESCE(b.ordercategorydescription, '')) LIKE '%continuous%'))""")
    for tab in ["mimiciv_3_1_icu.chartevents", "mimiciv_3_1_icu.inputevents", "mimiciv_3_1_icu.procedureevents", "mimiciv_3_1_hosp.labevents"]:
        con.execute(f"DELETE FROM {tab} WHERE storetime >= TIMESTAMP '{t}'")
    con.execute(f"DELETE FROM mimiciv_3_1_hosp.emar_detail WHERE emar_id IN (SELECT emar_id FROM mimiciv_3_1_hosp.emar WHERE storetime >= TIMESTAMP '{t}')")
    con.execute(f"DELETE FROM mimiciv_3_1_hosp.emar WHERE storetime >= TIMESTAMP '{t}'")
    con.execute(f"DELETE FROM mimiciv_3_1_hosp.microbiologyevents WHERE COALESCE(charttime, chartdate) >= TIMESTAMP '{t}'")
    con.execute(f"DELETE FROM mimiciv_3_1_hosp.omr WHERE chartdate >= DATE '{t[:10]}'")
    con.close()


def row_for(feat, stay_id, k):
    r = feat[(feat.stay_id == stay_id) & (feat.k == k)]
    return None if r.empty else r.iloc[0]


def compare(base_row, test_row, inputs, label):
    if (base_row is None) != (test_row is None):
        return [f"{label}: at risk in {'the full database only' if test_row is None else 'the prefix only'}"]
    if base_row is None:
        return []
    bad = []
    for c in inputs:
        a, b = base_row[c], test_row[c]
        same = (pd.isna(a) and pd.isna(b)) or (a == b)
        if not same:
            bad.append(f"{label}: {c} = {a!r} in the full database, {b!r} in the prefix")
    return bad


if __name__ == "__main__":
    WORK.mkdir(exist_ok=True)
    base_db = WORK / "base.duckdb"
    shutil.copy(DB, base_db)
    grid, feat = run_pipeline(base_db)
    inputs = C.input_columns(feat)
    print(f"{len(grid)} landmarks on the grid, {len(feat)} at risk, {len(inputs)} inputs compared")
    failures = []
    for _, L in grid.iterrows():
        t_k = pd.Timestamp(L.t_k).tz_localize(None) if pd.Timestamp(L.t_k).tzinfo else pd.Timestamp(L.t_k)
        db = WORK / f"prefix_{L.stay_id}_{L.k}.duckdb"
        prefix_copy(DB, db, t_k)
        _, feat_p = run_pipeline(db)
        label = f"stay {L.stay_id} k={L.k} ({t_k})"
        problems = compare(row_for(feat, L.stay_id, L.k), row_for(feat_p, L.stay_id, L.k), inputs, label)
        at_risk = row_for(feat, L.stay_id, L.k) is not None
        print(f"  {label}: {'at risk' if at_risk else 'not at risk'}, {'identical' if not problems else str(len(problems)) + ' differences'}")
        failures += problems
        db.unlink()

    # case 4: the completed amount of the rate-less segment crossing stay 200061's landmark changes afterwards
    db = WORK / "amount.duckdb"
    shutil.copy(DB, db)
    con = duckdb.connect(str(db))
    n = con.execute("SELECT COUNT(*) FROM mimiciv_3_1_icu.inputevents WHERE stay_id = 200061 AND itemid = 223258 AND rate IS NULL AND ordercategorydescription = 'Continuous IV'").fetchone()[0]
    assert n == 1, n
    con.execute("UPDATE mimiciv_3_1_icu.inputevents SET amount = amount * 2, originalamount = originalamount * 2 WHERE stay_id = 200061 AND itemid = 223258 AND rate IS NULL AND ordercategorydescription = 'Continuous IV'")
    con.close()
    _, feat_a = run_pipeline(db)
    problems = compare(row_for(feat, 200061, 1), row_for(feat_a, 200061, 1), inputs, "stay 200061 k=1, amount doubled")
    print(f"  stay 200061 k=1 with the crossing segment's amount doubled: {'identical' if not problems else str(len(problems)) + ' differences'}")
    failures += problems
    db.unlink()
    base_db.unlink()

    if failures:
        print("\nFAILED:\n  " + "\n  ".join(failures))
        sys.exit(1)
    print("\nprefix invariance holds on every landmark of the grid")
