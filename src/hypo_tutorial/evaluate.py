"""
Evaluation: discrimination, calibration and clinical utility, each with a
subject-level bootstrap interval, plus the subgroup and operating-point tables.

What is reported and why (TRIPOD+AI asks for all three families):

  Discrimination   AUROC and AUPRC. AUROC is the usual headline; at a 1% event
                   rate AUPRC is the number that moves when a model learns
                   something about the rare class, so both are reported.
  Calibration      calibration-in-the-large (observed / expected event ratio),
                   calibration slope and intercept from a logistic regression of
                   the outcome on the model's logit (slope < 1 means the model is
                   too extreme, intercept != 0 means it is off overall), the Brier
                   score, and a reliability table in ten quantile bins (what the
                   calibration plot draws). Van Calster et al. call calibration
                   the Achilles heel of predictive analytics for a reason: a model
                   that says 5% when the truth is 2% harms patients even with a
                   perfect AUROC.
  Clinical utility Decision curve analysis (Vickers and Elkin 2006): the net
                   benefit of acting on the model at each threshold probability,
                   against acting on everyone and on no one. For an alert that
                   triggers a glucose recheck or an insulin review, the relevant
                   thresholds are low (0.5 to 10%), so the curve is drawn there.
  Operating points Sensitivity, positive predictive value and alerts per 100 rows
                   when the top 5 / 10 / 20% of rows by risk are flagged: what a
                   unit would see if the model ran once a day.

Bootstrap. Rows from one subject are correlated, so the interval resamples
SUBJECTS with replacement (cluster bootstrap), not rows. 1,000 replicates by
default; the smoke run uses fewer.

How the bootstrap is computed. Drawing subjects with replacement and stacking
their rows is the same thing as giving every row an integer weight (how many
times its subject was drawn): a subject drawn twice contributes its rows twice
to every sum. So each draw computes the weighted version of each metric over the
original rows, with the rows sorted by predicted risk once up front, instead of
building a resampled table and refitting with scikit-learn. The weighted
functions below reproduce scikit-learn's definitions exactly (ties in the
predictions included, see the tests) and the calibration slope and intercept
come from a two-parameter Newton-Raphson fit, which is the same maximum-
likelihood problem scikit-learn solves with L-BFGS. The point estimates in the
first column of every table are still scikit-learn's own functions, so a reader
can check the fast path against the reference on any table: release .8 refitted
scikit-learn in every draw and spent about 100 ms per draw on a test era, this
version spends a few.
"""
import numpy as np
import pandas as pd
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import average_precision_score, brier_score_loss, roc_auc_score

from .models import logit, _clip

THRESHOLDS = np.round(np.arange(0.005, 0.1001, 0.005), 3)
ALERT_RATES = [0.05, 0.10, 0.20]


# ------------------------------------------------------------ point metrics
def auroc(y, p):
    return roc_auc_score(y, p) if 0 < y.sum() < len(y) else np.nan


def auprc(y, p):
    return average_precision_score(y, p) if 0 < y.sum() < len(y) else np.nan


def brier(y, p):
    return brier_score_loss(y, _clip(p))


def oe_ratio(y, p):
    """Observed over expected events: 1.0 is calibrated in the large."""
    return float(y.sum() / max(_clip(p).sum(), 1e-9))


def calibration_slope_intercept(y, p):
    """Logistic regression of the outcome on logit(p): slope and intercept (Cox 1958 recalibration).
    tol is tightened from scikit-learn's default 1e-4: with the default, L-BFGS stops a few
    iterations early and the intercept can be off in the third decimal (tests/test_evaluate.py
    shows the gradient left at the default stop); at 1e-8 it agrees with the exact Newton fit
    used inside the bootstrap to 1e-6."""
    if not (0 < y.sum() < len(y)):
        return np.nan, np.nan
    m = LogisticRegression(C=1e6, solver="lbfgs", max_iter=20000, tol=1e-8).fit(logit(p).reshape(-1, 1), y)
    return float(m.coef_[0][0]), float(m.intercept_[0])


METRICS = {"auroc": auroc, "auprc": auprc, "brier": brier, "oe_ratio": oe_ratio}


# ------------------------------------------------- weighted metrics (bootstrap)
class Weighted:
    """The same metrics as above for a weighted sample of the SAME rows, where the weight of a row
    is how many times its subject was drawn. Rows are sorted by predicted risk once; after that
    every draw is a handful of O(n) numpy passes.

    AUROC   the Mann-Whitney form: the share of (event, non-event) pairs where the event has the
            higher prediction, ties counting one half, each pair weighted by the product of the two
            row weights. This is exactly what roc_auc_score returns, ties included.
    AUPRC   scikit-learn's average_precision_score: thresholds at the distinct predictions in
            descending order, AP = sum over thresholds of (recall gain) x precision.
    Brier   the weighted mean squared error on the clipped probabilities, as brier_score_loss.
    O/E     weighted observed over weighted expected events.
    Slope and intercept  maximum-likelihood logistic regression of the outcome on logit(p) by
            Newton-Raphson on two parameters, with the same negligible ridge on the slope that
            scikit-learn's C=1e6 applies and no penalty on the intercept."""

    RIDGE = 1e-6                      # 1 / C of calibration_slope_intercept, on the slope only

    def __init__(self, y, p):
        self.y = np.asarray(y, dtype=float)
        p = np.asarray(p, dtype=float)
        self.p = _clip(p)                 # Brier, O/E and the logit use the clipped probabilities, as the point functions do
        self.x = logit(self.p)
        # distinct prediction levels in descending order, from the unclipped predictions so the
        # tie structure is the one roc_auc_score and average_precision_score see; level_of[i] is row i's level
        uniq, level_of = np.unique(-p, return_inverse=True)
        self.n_levels = len(uniq)
        self.level_of = np.asarray(level_of).ravel()

    def _by_level(self, w):
        """Weighted events and non-events at each prediction level (descending)."""
        a = np.bincount(self.level_of, weights=w * self.y, minlength=self.n_levels)
        b = np.bincount(self.level_of, weights=w * (1.0 - self.y), minlength=self.n_levels)
        return a, b

    def auroc(self, w, ab=None):
        a, b = self._by_level(w) if ab is None else ab
        w1, w0 = a.sum(), b.sum()
        if w1 <= 0 or w0 <= 0:
            return np.nan
        below = w0 - np.cumsum(b)                      # non-event weight at strictly lower predictions
        return float((np.sum(a * below) + 0.5 * np.sum(a * b)) / (w1 * w0))

    def auprc(self, w, ab=None):
        a, b = self._by_level(w) if ab is None else ab
        w1 = a.sum()
        if w1 <= 0 or b.sum() <= 0:
            return np.nan
        tp, fp = np.cumsum(a), np.cumsum(b)
        flagged = tp + fp
        precision = np.divide(tp, flagged, out=np.zeros_like(tp), where=flagged > 0)
        recall = tp / w1
        gain = np.diff(np.concatenate([[0.0], recall]))
        return float(np.sum(gain * precision))

    def brier(self, w):
        return float(np.sum(w * (self.p - self.y) ** 2) / np.sum(w))

    def oe_ratio(self, w):
        return float(np.sum(w * self.y) / max(np.sum(w * self.p), 1e-9))

    def calibration_slope_intercept(self, w, max_iter=50, tol=1e-10):
        """Newton-Raphson for (intercept a, slope b) maximising sum_i w_i log-lik(y_i; a + b x_i)
        minus RIDGE/2 b^2. Concave problem, so Newton converges from the identity start (0, 1);
        the step is halved when it would lower the objective (it does not, in practice)."""
        x, y = self.x, self.y
        if np.sum(w * y) <= 0 or np.sum(w * (1 - y)) <= 0:
            return np.nan, np.nan

        def objective(a, b):
            eta = a + b * x
            return float(np.sum(w * (y * eta - np.logaddexp(0.0, eta))) - 0.5 * self.RIDGE * b * b)

        a, b = 0.0, 1.0
        obj = objective(a, b)
        for _ in range(max_iter):
            eta = a + b * x
            mu = 1.0 / (1.0 + np.exp(-eta))
            r = w * (y - mu)
            v = w * mu * (1.0 - mu)
            g0, g1 = r.sum(), np.sum(r * x) - self.RIDGE * b
            h00, h01, h11 = v.sum(), np.sum(v * x), np.sum(v * x * x) + self.RIDGE
            det = h00 * h11 - h01 * h01
            if det <= 0:
                break
            da, db = (h11 * g0 - h01 * g1) / det, (h00 * g1 - h01 * g0) / det
            step = 1.0
            while step > 1e-4:
                new = objective(a + step * da, b + step * db)
                if new >= obj - 1e-12:
                    break
                step /= 2
            a, b, obj = a + step * da, b + step * db, new
            if abs(step * da) < tol and abs(step * db) < tol:
                break
        return float(b), float(a)


# --------------------------------------------------------------- bootstrap
def bootstrap(y, p, groups, n_boot=1000, seed=2026, metrics=METRICS):
    """Point estimate (scikit-learn) and 2.5 / 97.5 percentile interval (subject bootstrap, weighted
    draws) for each metric. Metrics without a weighted form in `Weighted` are computed on the stacked
    resample, as release .8 did for all of them."""
    y, p, groups = np.asarray(y), np.asarray(p, dtype=float), np.asarray(groups)
    rng = np.random.default_rng(seed)
    subjects, inverse = np.unique(groups, return_inverse=True)
    inverse = inverse.ravel()
    point = {k: f(y, p) for k, f in metrics.items()}
    slope, intercept = calibration_slope_intercept(y, p)
    point["cal_slope"], point["cal_intercept"] = slope, intercept
    weighted = Weighted(y, p)
    fast = {k: getattr(weighted, k) for k in metrics if hasattr(weighted, k)}
    slow = {k: f for k, f in metrics.items() if k not in fast}
    by_subject = [np.flatnonzero(inverse == i) for i in range(len(subjects))] if slow else None
    draws = {k: [] for k in point}
    for _ in range(n_boot):
        pick = rng.integers(0, len(subjects), len(subjects))
        w = np.bincount(pick, minlength=len(subjects))[inverse].astype(float)
        ab = weighted._by_level(w)
        for k, f in fast.items():
            draws[k].append(f(w, ab) if k in ("auroc", "auprc") else f(w))
        if slow:
            idx = np.concatenate([by_subject[i] for i in pick])
            for k, f in slow.items():
                draws[k].append(f(y[idx], p[idx]))
        s, a = weighted.calibration_slope_intercept(w)
        draws["cal_slope"].append(s); draws["cal_intercept"].append(a)
    rows = []
    for k, v in point.items():
        d = np.array(draws[k], dtype=float)
        d = d[np.isfinite(d)]
        lo, hi = (np.percentile(d, [2.5, 97.5]) if len(d) else (np.nan, np.nan))
        rows.append({"metric": k, "estimate": v, "ci_low": lo, "ci_high": hi})
    out = pd.DataFrame(rows)
    out.attrs["n_rows"], out.attrs["n_events"], out.attrs["n_subjects"] = len(y), int(y.sum()), len(subjects)
    return out


# ------------------------------------------------------------- calibration
def reliability_table(y, p, bins=10):
    """Mean predicted and observed risk per predicted-risk decile (quantile bins)."""
    df = pd.DataFrame({"y": np.asarray(y), "p": np.asarray(p, dtype=float)})
    try:
        df["bin"] = pd.qcut(df["p"], q=bins, labels=False, duplicates="drop")
    except ValueError:
        df["bin"] = 0
    g = df.groupby("bin", observed=True)
    out = pd.DataFrame({"rows": g.size(), "events": g["y"].sum(), "mean_predicted": g["p"].mean(), "observed": g["y"].mean()})
    return out.reset_index()


def ece(y, p, bins=10):
    """Expected calibration error over quantile bins: the row-weighted mean |observed - predicted|."""
    t = reliability_table(y, p, bins)
    return float((t["rows"] / t["rows"].sum() * (t["observed"] - t["mean_predicted"]).abs()).sum())


# --------------------------------------------------------- decision curves
def net_benefit(y, p, thresholds=THRESHOLDS):
    """Net benefit of acting when p >= threshold, against treat-all and treat-none (Vickers 2006):
    NB = TP/N - FP/N * t/(1-t)."""
    y, p = np.asarray(y), np.asarray(p, dtype=float)
    n, prev = len(y), y.mean()
    rows = []
    for t in thresholds:
        flag = p >= t
        tp, fp = np.sum(flag & (y == 1)), np.sum(flag & (y == 0))
        rows.append({"threshold": t, "net_benefit_model": tp / n - fp / n * t / (1 - t),
                     "net_benefit_all": prev - (1 - prev) * t / (1 - t), "net_benefit_none": 0.0,
                     "flagged_per_100": 100 * flag.mean()})
    return pd.DataFrame(rows)


# --------------------------------------------------------- operating points
def operating_points(y, p, alert_rates=ALERT_RATES):
    """Flag the top share of rows by predicted risk: sensitivity, PPV, alerts per 100 rows, the
    threshold that share implies."""
    y, p = np.asarray(y), np.asarray(p, dtype=float)
    rows = []
    for r in alert_rates:
        thr = np.quantile(p, 1 - r)
        flag = p >= thr
        tp = np.sum(flag & (y == 1))
        rows.append({"alert_rate": r, "threshold": thr, "alerts_per_100_rows": 100 * flag.mean(),
                     "sensitivity": tp / max(y.sum(), 1), "ppv": tp / max(flag.sum(), 1),
                     "events_caught": int(tp), "events_total": int(y.sum())})
    return pd.DataFrame(rows)


# --------------------------------------------------------------- subgroups
MIN_SUBGROUP_ROWS = 100       # levels with fewer rows are pooled into one "other" level before anything is computed
MIN_SUBGROUP_EVENTS = 10      # a cell with fewer events, or fewer non-events, reports no count and no metric


def subgroup_table(df, y_col, p_col, by, min_events=MIN_SUBGROUP_EVENTS, min_rows=MIN_SUBGROUP_ROWS):
    """AUROC, AUPRC, event rate and O/E per level of `by`, written to be shared as it is.

    Two disclosure rules, the same ones the deck follows. Levels with fewer than `min_rows` rows are
    pooled into "other (levels under N rows)" before anything is computed, so a one-patient care unit
    or a race label carried by five rows never gets its own line. A cell with fewer than `min_events`
    events (or non-events) keeps its row count but reports no event count, rate or metric: a count of
    3 events in a named subgroup is a small cell, and 3 events say nothing reliable about
    discrimination anyway. `suppressed` marks those cells. The first real run (release .8) reported
    every raw level with its counts, 460 cells of which 216 had under ten events; this is the fix."""
    work = df[[by, y_col, p_col]].copy()
    key = work[by].astype(object).where(work[by].notna(), "missing").astype(str)
    counts = key.value_counts()
    small = counts[counts < min_rows].index
    pooled = f"other (levels under {min_rows} rows)"
    key = key.where(~key.isin(small), pooled)
    rows = []
    for level, g in work.groupby(key, observed=True):
        y, p = g[y_col].to_numpy(), g[p_col].to_numpy(dtype=float)
        n_events = int(y.sum())
        enough = n_events >= min_events and (len(y) - n_events) >= min_events
        rows.append({by: level, "rows": len(g), "events": n_events if enough else np.nan,
                     "event_rate": y.mean() if enough else np.nan,
                     "auroc": auroc(y, p) if enough else np.nan, "auprc": auprc(y, p) if enough else np.nan,
                     "oe_ratio": oe_ratio(y, p) if enough else np.nan, "mean_predicted": p.mean(),
                     "suppressed": not enough, "pooled_small_levels": int(len(small)) if level == pooled else 0})
    return pd.DataFrame(rows).sort_values("rows", ascending=False).reset_index(drop=True)


RACE_GROUPS = {"WHITE": "WHITE", "BLACK": "BLACK", "HISPANIC": "HISPANIC/LATINO", "ASIAN": "ASIAN",
               "UNKNOWN": "UNKNOWN", "UNABLE TO OBTAIN": "UNKNOWN", "PATIENT DECLINED TO ANSWER": "UNKNOWN"}


def race_group(race):
    """MIMIC-IV's self-reported race strings carry sub-labels ("WHITE - RUSSIAN", "HISPANIC/LATINO -
    PUERTO RICAN", "BLACK/CAPE VERDEAN"); the subgroup table uses the five coarse groups most MIMIC
    papers report plus UNKNOWN, so every level has enough rows to be shown. Everything else (American
    Indian / Alaska Native, Pacific Islander, multiple, Portuguese, South American, other) is OTHER."""
    s = pd.Series(race).fillna("UNKNOWN").astype(str).str.upper().str.strip()
    out = pd.Series("OTHER", index=s.index)
    for prefix, group in RACE_GROUPS.items():
        out = out.where(~s.str.startswith(prefix), group)
    return out


def icu_day_bucket(k):
    return pd.cut(pd.Series(k), [0, 1, 3, 7, 100], labels=["day 2", "days 3-4", "days 5-8", "day 9+"]).astype(str)
