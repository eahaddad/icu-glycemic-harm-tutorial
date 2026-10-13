"""
Run the five BigQuery SQL files against the synthetic DuckDB database.

The BigQuery text is rewritten mechanically (table prefixes, the DECLARE
variables, a handful of functions DuckDB spells differently) and then
transpiled with sqlglot. The point is to execute the real join / window /
label logic end to end on planted cases, not to produce a DuckDB port.

Build the database first with tests/make_synthetic.py. Needs duckdb and sqlglot
(requirements.txt, the two test-only lines).

    python tests/run_pipeline.py                      # print every check table
    python tests/run_pipeline.py --results-dir out/   # and save each one as CSV
"""
import re, sys, argparse
from pathlib import Path
import duckdb, sqlglot
from sqlglot import exp

HERE = Path(__file__).resolve().parent
SQL_DIR = HERE.parent / "sql"
DB = HERE / "synthetic_mimic.duckdb"
FILES = ["00_sanity_itemids.sql", "00b_extract.sql", "01_cohort_labels.sql", "02_features.sql"]

def struct_unnest_to_values(text):
    """UNNEST([STRUCT(a AS x, b AS y), ...])  ->  (VALUES (a, b), ...) AS t(x, y)"""
    pat = re.compile(r"UNNEST\(\[\s*(STRUCT\(.*?\))\s*\]\)", re.S)
    def repl(m):
        structs = re.findall(r"STRUCT\((.*?)\)", m.group(1), re.S)
        rows, names = [], None
        for s in structs:
            parts = [p.strip() for p in s.split(",")]
            vals, cols = [], []
            for p in parts:
                v, _, c = p.partition(" AS ")
                vals.append(v.strip()); cols.append(c.strip())
            names = names or cols
            rows.append("(" + ", ".join(vals) + ")")
        return "(VALUES " + ", ".join(rows) + ") AS _v(" + ", ".join(names) + ")"
    return pat.sub(repl, text)

def rewrite_bigquery(text):
    text = text.replace("`physionet-data.", "`").replace("`YOUR_PROJECT.", "`")
    # any DECLARE <name> <type> DEFAULT <value>; becomes a literal substitution
    for name, value in re.findall(r"DECLARE\s+(\w+)\s+\w+\s+DEFAULT\s+([^;]+);", text):
        text = re.sub(r"DECLARE\s+" + name + r"\s+\w+\s+DEFAULT\s+[^;]+;", "", text)
        text = re.sub(r"\b" + name + r"\b", value.strip(), text)
    text = struct_unnest_to_values(text)
    text = text.replace("FARM_FINGERPRINT", "hash")
    text = re.sub(r"FORMAT\('(%\.\df)',", r"printf('\1',", text)
    text = re.sub(r"APPROX_QUANTILES\((.+?), 100\)\[OFFSET\((\d+)\)\]", lambda m: f"quantile_cont({m.group(1)}, {int(m.group(2)) / 100})", text)   # the argument may be an expression
    # the ARRAY(...) subquery for the last-three-glucose line (BigQuery-only syntax)
    text = re.sub(r"ARRAY_TO_STRING\(ARRAY\(\s*SELECT printf\('%\.2f', v\)\s*FROM UNNEST\(\[glucose_last, glucose_prev, glucose_prev2\]\) AS v WITH OFFSET AS pos\s*WHERE v IS NOT NULL\s*ORDER BY pos\s*\), ', '\)",
                  "array_to_string(list_transform(list_filter([glucose_last, glucose_prev, glucose_prev2], x -> x IS NOT NULL), x -> printf('%.2f', x)), ', ')", text)
    text = re.sub(r"CROSS JOIN UNNEST\(GENERATE_ARRAY\(1, (\d+)\)\) AS k", lambda m: f"CROSS JOIN (SELECT UNNEST(range(1, {int(m.group(1)) + 1})) AS k) AS _k", text)
    # DATETIME literals (the 1900 floor, the 9999 ceiling) are left to sqlglot, which maps BigQuery DATETIME to a plain
    # DuckDB TIMESTAMP; release .22 rewrote them to TIMESTAMP literals, which sqlglot reads as BigQuery's zoned TIMESTAMP
    # and emits as TIMESTAMPTZ, and DuckDB refuses to COALESCE those with TIMESTAMP_NS columns (the second review's run)
    # BigQuery-only DDL and metadata used by 00b_extract.sql: clustering has no DuckDB equivalent,
    # and the __TABLES__ view becomes a duckdb_tables() lookup (sizes print as 0)
    text = re.sub(r"\nCLUSTER BY [^\n]+ AS\n", "\nAS\n", text)
    text = text.replace("`hypo_tutorial.__TABLES__`",
                        "(SELECT table_name AS table_id, estimated_size AS row_count, 0 AS size_bytes FROM duckdb_tables() WHERE schema_name = 'hypo_tutorial' AND database_name = current_database()) AS __t")
    return text

def to_duckdb(stmt):
    out = stmt.sql(dialect="duckdb")
    # sqlglot renders BigQuery raw regex strings with doubled backslashes; DuckDB literals are not escape-processed
    out = out.replace("\\\\b", "\\b")
    return out

RESERVED = set("""ALL AND ANY ARRAY AS ASC ASSERT_ROWS_MODIFIED AT BETWEEN BY CASE CAST COLLATE CONTAINS CREATE CROSS CUBE CURRENT
DEFAULT DEFINE DESC DISTINCT ELSE END ENUM ESCAPE EXCEPT EXCLUDE EXISTS EXTRACT FALSE FETCH FOLLOWING FOR FROM FULL GROUP GROUPING
GROUPS HASH HAVING IF IGNORE IN INNER INTERSECT INTERVAL INTO IS JOIN LATERAL LEFT LIKE LIMIT LOOKUP MERGE NATURAL NEW NO NOT NULL
NULLS OF ON OR ORDER OUTER OVER PARTITION PRECEDING PROTO QUALIFY RANGE RECURSIVE RESPECT RIGHT ROLLUP ROWS SELECT SET SOME STRUCT
TABLESAMPLE THEN TO TREAT TRUE UNBOUNDED UNION UNNEST USING WHEN WHERE WINDOW WITH WITHIN""".split())

def check_reserved(fname, sql_dir=SQL_DIR):
    """BigQuery refuses reserved keywords as unquoted identifiers; sqlglot does not, so check explicitly."""
    names = set()
    for stmt in sqlglot.parse(Path(sql_dir, fname).read_text(), read="bigquery"):
        if stmt is None: continue
        for cte in stmt.find_all(exp.CTE): names.add(cte.alias)
        for a in stmt.find_all(exp.Alias): names.add(a.alias)
        for t in stmt.find_all(exp.TableAlias): names.add(t.name)
        for c in stmt.find_all(exp.Column): names.add(c.name)
    bad = sorted(n for n in names if n and n.upper() in RESERVED)
    if bad:
        print(f"{fname}: RESERVED KEYWORD USED AS IDENTIFIER: {bad}"); sys.exit(1)
    print(f"{fname}: no reserved keywords used as identifiers")

def check_names(text, n_selects):
    """The same naming as pipeline/run_bigquery.py: a file whose SELECT statements each carry a '-- Table N.'
    header (01) names its results table01 ... table21; any other file numbers them by statement index."""
    names = re.findall(r"^-- Table (\w+)\.", text, flags=re.M)
    return [f"table{n.zfill(2)}" for n in names] if len(names) == n_selects else None

def run_file(con, fname, sql_dir=SQL_DIR, show_rows=40, results_dir=None, timing=False):
    """Run one BigQuery file on DuckDB. Returns [(statement index, DataFrame)] for the SELECT statements;
    with results_dir, each one is also written as <file stem>_<table or check tag>.csv (all of them are aggregate tables)."""
    import time
    check_reserved(fname, sql_dir)
    print("\n" + "=" * 100 + f"\n{fname}\n" + "=" * 100)
    text = rewrite_bigquery(Path(sql_dir, fname).read_text())
    stmts = [s for s in sqlglot.parse(text, read="bigquery") if s is not None]
    names = check_names(Path(sql_dir, fname).read_text(), sum(1 for s in stmts if isinstance(s, (exp.Select, exp.Union))))
    results, n_select = [], 0
    for i, s in enumerate(stmts):
        try:
            dk = to_duckdb(s)
        except Exception as e:
            print(f"[{i}] TRANSPILE FAILED: {e}"); sys.exit(1)
        t0 = time.time()
        try:
            res = con.execute(dk)
            if isinstance(s, exp.Select) or isinstance(s, exp.Union):
                df = res.fetchdf()
                print(f"\n[{i}] result ({len(df)} rows)" + (f"  {time.time() - t0:.1f}s" if timing else ""))
                with __import__("pandas").option_context("display.width", 250, "display.max_columns", 60, "display.max_colwidth", 60):
                    print(df.head(show_rows).to_string())
                results.append((i, df))
                if results_dir is not None:
                    Path(results_dir).mkdir(parents=True, exist_ok=True)
                    tag = names[n_select] if names else f"check{i:02d}"
                    df.to_csv(Path(results_dir, f"{Path(fname).stem}_{tag}.csv"), index=False)
                n_select += 1
            else:
                print(f"[{i}] {type(s).__name__} ok" + (f"  {time.time() - t0:.1f}s" if timing else ""))
        except Exception as e:
            print(f"[{i}] EXECUTION FAILED: {e}\n--- duckdb sql ---\n{dk[:3000]}"); sys.exit(1)
    return results

if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", default=str(DB), help="synthetic DuckDB file (default: the one make_synthetic.py writes)")
    ap.add_argument("--results-dir", default=None, help="also save every check table as CSV here")
    args = ap.parse_args()
    con = duckdb.connect(args.db)
    # a fresh project has no hypo_tutorial dataset; start from the same state (a table left by an
    # older version of the files cannot be replaced by a view, on DuckDB or on BigQuery)
    con.execute("DROP SCHEMA IF EXISTS hypo_tutorial CASCADE")
    for f in FILES:
        run_file(con, f, results_dir=args.results_dir)
    con.close()
