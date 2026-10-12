"""
Column roles in hypo_tutorial.features (sql/02_features.sql).

Three kinds of column leave the SQL, and the model may see only one of them:

  LABELS       the five outcomes, computed from the 24 h AFTER the landmark (y_lt54_excl_24h
               is the sensitivity endpoint: < 54 after the CMS816 repeat-result exclusion)
  BOOKKEEPING  identifiers, times, the split, the era and the anchor offset, reporting-only columns and
               the drip-record flags. None of these describes the patient at t_k
               in a way a model should learn from: ids and times would memorise
               patients; `label_window_n_glucose` counts results in the label
               window (future information); `race`, `insurance`, `language` and
               `marital_status` are kept for the subgroup tables and kept out of
               the inputs on purpose (a glucose-harm model has no business
               learning them); the drip-record flags say which TABLE recorded a
               drip, and because the eMAR-only drips sit mostly in 2020-2022
               they would teach the model the era, not the patient.
  everything else is an input, numeric or categorical.

The list is written out rather than derived so that a new column added to the
SQL lands in the inputs only when someone decides it should.
"""

LABELS = ["y_lt54_24h", "y_lt54_excl_24h", "y_lt40_24h", "y_cms816_24h", "y_gt300_24h"]

# the two outcomes the arms are trained on; the other three are reported descriptively
# (y_lt54_excl_24h is also the endpoint of one sensitivity analysis in the notebook)
OUTCOMES = {"lt54": "y_lt54_24h", "gt300": "y_gt300_24h"}

BOOKKEEPING = [
    "subject_id", "hadm_id", "stay_id", "k", "t_k", "window_end", "split", "anchor_year_group", "years_after_anchor",
    "window_hours", "race", "insurance", "language", "marital_status", "label_window_n_glucose",
    "max_feature_time",
    # which record saw the drip (02 header): subgroup tables, never inputs
    "drip_inputevents_24h", "drip_emar_24h", "drip_running_inputevents_at_tk", "drip_running_emar_at_tk",
    "stay_has_inputevents_drip", "emar_interval_open_at_tk",
] + LABELS

# string columns among the inputs; everything else that is not bookkeeping is numeric or 0/1
CATEGORICAL = ["gender", "admission_type", "admission_location", "first_careunit", "careunit_tk", "service_tk"]

# the subgroup columns the evaluation reports on (bookkeeping or inputs alike)
SUBGROUPS = ["drip_running_at_tk", "anchor_year_group", "first_careunit", "gender", "race", "icu_day_bucket"]


def input_columns(df):
    """Every column that is neither a label nor bookkeeping, in the table's order."""
    return [c for c in df.columns if c not in BOOKKEEPING]


def check_roles(df):
    """Fail loudly if the table carries a column nobody classified: a new SQL column must be
    placed in a role by hand (see the module docstring)."""
    known = set(BOOKKEEPING) | set(CATEGORICAL)
    unknown_strings = [c for c in df.columns if c not in known and df[c].dtype.kind in ("O", "U", "S")
                       or (c not in known and str(df[c].dtype) in ("str", "string"))]
    if unknown_strings:
        raise ValueError(f"string columns with no role: {unknown_strings}; add them to CATEGORICAL or BOOKKEEPING")
    return True
