Aggregate outputs only. The runner (pipeline/run_bigquery.py --step pipeline) writes every check table of 01 and 02
here as CSV (01_cohort_labels_table01.csv is table 1 of 01, table21 table 21; 02_features_check01.csv is the leakage
assertion), and the notebook copies them to MyDrive/hypo_tutorial/results/ next to its own tables and figures (stages 2
and 3) before packing the folder into one zip (stage 4). Nothing in here may carry a subject_id, hadm_id, stay_id, a
timestamp or note text: those stay in the parquet and predictions folders on your own Drive.
