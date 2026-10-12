"""
hypo_tutorial: the modeling code behind stage 3 of notebooks/hypo_harm_tutorial.ipynb.

Four small modules, read in this order:
    columns.py   which columns are labels, which are bookkeeping, which are inputs
    features.py  the feature preparation fitted on the training rows only
    models.py    the two tabular arms (logistic regression, gradient-boosted trees)
    evaluate.py  discrimination, calibration, clinical utility, all with
                 subject-level bootstrap intervals

Nothing here touches BigQuery or MIMIC files: the input is the parquet the data
step pulled (features.parquet), the outputs are aggregate tables and figures.
The row-level predictions the notebook writes stay next to the parquet, on the
student's own Drive, never in results/.
"""
from . import columns, features, models, evaluate   # noqa: F401

__version__ = "2026-10-11"
