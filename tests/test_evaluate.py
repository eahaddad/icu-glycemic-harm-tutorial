"""
Checks that the weighted bootstrap in src/hypo_tutorial/evaluate.py gives the same numbers as the
reference computations it replaces.

1. On random predictions WITH ties and random integer weights (0 to 3 per row), every weighted
   metric equals scikit-learn's function on the table with each row repeated weight times:
   AUROC, AUPRC, Brier, O/E to 1e-10, calibration slope and intercept to 1e-5 (L-BFGS tolerance).
2. The whole bootstrap, with the same seed, gives the same intervals as the release .8
   implementation (kept below as `bootstrap_release_8`), which stacked the resampled rows and
   refitted scikit-learn in every draw.

    python tests/test_evaluate.py          # prints the largest differences and a timing
    python -m pytest tests/test_evaluate.py
"""
import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from hypo_tutorial import evaluate as E                                   # noqa: E402
from sklearn.linear_model import LogisticRegression                      # noqa: E402
from sklearn.metrics import average_precision_score, brier_score_loss, roc_auc_score  # noqa: E402


def _sample(seed=3, n_subjects=1500, prevalence=0.03, decimals=2):
    """Clustered rows, 1% to 3% events, predictions rounded so ties are common."""
    rng = np.random.default_rng(seed)
    rows_per = rng.choice(np.arange(1, 9), n_subjects)
    groups = np.repeat(np.arange(n_subjects), rows_per)
    n = len(groups)
    true_logit = rng.normal(np.log(prevalence / (1 - prevalence)), 1.2, n)
    y = (rng.random(n) < 1 / (1 + np.exp(-true_logit))).astype(int)
    p = np.round(1 / (1 + np.exp(-(true_logit + rng.normal(0, 0.8, n)))), decimals)
    p = np.clip(p, 0.0, 1.0)
    return y, p, groups


def bootstrap_release_8(y, p, groups, n_boot=1000, seed=2026, metrics=E.METRICS):
    """Release .8: stack the drawn subjects' rows and call the point functions on the stack."""
    y, p, groups = np.asarray(y), np.asarray(p, dtype=float), np.asarray(groups)
    rng = np.random.default_rng(seed)
    subjects, inverse = np.unique(groups, return_inverse=True)
    by_subject = [np.flatnonzero(inverse == i) for i in range(len(subjects))]
    point = {k: f(y, p) for k, f in metrics.items()}
    slope, intercept = E.calibration_slope_intercept(y, p)
    point["cal_slope"], point["cal_intercept"] = slope, intercept
    draws = {k: [] for k in point}
    for _ in range(n_boot):
        pick = rng.integers(0, len(subjects), len(subjects))
        idx = np.concatenate([by_subject[i] for i in pick])
        yb, pb = y[idx], p[idx]
        for k, f in metrics.items():
            draws[k].append(f(yb, pb))
        s, a = E.calibration_slope_intercept(yb, pb)
        draws["cal_slope"].append(s); draws["cal_intercept"].append(a)
    rows = []
    for k, v in point.items():
        d = np.array(draws[k], dtype=float)
        d = d[np.isfinite(d)]
        lo, hi = (np.percentile(d, [2.5, 97.5]) if len(d) else (np.nan, np.nan))
        rows.append({"metric": k, "estimate": v, "ci_low": lo, "ci_high": hi})
    return pd.DataFrame(rows)


def test_weighted_metrics_match_sklearn_on_repeated_rows():
    y, p, _ = _sample()
    rng = np.random.default_rng(11)
    W = E.Weighted(y, p)
    worst = {}
    for trial in range(5):
        w = rng.integers(0, 4, len(y)).astype(float)
        idx = np.repeat(np.arange(len(y)), w.astype(int))          # the stacked table
        yd, pd_ = y[idx], p[idx]
        ab = W._by_level(w)
        ref = {"auroc": roc_auc_score(yd, pd_), "auprc": average_precision_score(yd, pd_),
               "brier": brier_score_loss(yd, E._clip(pd_)), "oe_ratio": E.oe_ratio(yd, pd_)}
        got = {"auroc": W.auroc(w, ab), "auprc": W.auprc(w, ab), "brier": W.brier(w), "oe_ratio": W.oe_ratio(w)}
        for k in ref:
            worst[k] = max(worst.get(k, 0.0), abs(ref[k] - got[k]))
            assert abs(ref[k] - got[k]) < 1e-10, (k, ref[k], got[k])
        # the identity (1, 0) is not the answer, so the Newton fit has work to do
        s_ref, a_ref = E.calibration_slope_intercept(yd, pd_)
        s, a = W.calibration_slope_intercept(w)
        worst["cal_slope"] = max(worst.get("cal_slope", 0.0), abs(s - s_ref))
        worst["cal_intercept"] = max(worst.get("cal_intercept", 0.0), abs(a - a_ref))
        assert abs(s - s_ref) < 1e-5 and abs(a - a_ref) < 1e-5, (s, s_ref, a, a_ref)
    # sample_weight is scikit-learn's own weighted path; it must agree too
    w = rng.integers(0, 4, len(y)).astype(float)
    assert abs(W.auroc(w) - roc_auc_score(y, p, sample_weight=w)) < 1e-10
    assert abs(W.auprc(w) - average_precision_score(y, p, sample_weight=w)) < 1e-10
    return worst


def test_bootstrap_matches_release_8():
    y, p, groups = _sample(seed=5)
    t = time.perf_counter(); new = E.bootstrap(y, p, groups, n_boot=200); t_new = time.perf_counter() - t
    t = time.perf_counter(); old = bootstrap_release_8(y, p, groups, n_boot=200); t_old = time.perf_counter() - t
    m = new.merge(old, on="metric", suffixes=("_new", "_old"))
    diff = pd.DataFrame({"metric": m.metric,
                         "estimate": (m.estimate_new - m.estimate_old).abs(),
                         "ci_low": (m.ci_low_new - m.ci_low_old).abs(),
                         "ci_high": (m.ci_high_new - m.ci_high_old).abs()})
    assert (diff.estimate < 1e-12).all()
    assert (diff[["ci_low", "ci_high"]] < 1e-5).all().all(), diff
    return diff, t_new, t_old


def test_default_lbfgs_tolerance_is_loose():
    """Why calibration_slope_intercept and Platt set tol=1e-8: at scikit-learn's default tol=1e-4
    the gradient of the log-likelihood is still of order 1 when L-BFGS stops, and the intercept is
    off in the third decimal. The exact Newton fit has a gradient of order 1e-12."""
    y, p, _ = _sample(seed=9)
    x = E.logit(p).reshape(-1, 1)

    def gradient(m):
        mu = m.predict_proba(x)[:, 1]
        return float(abs((y - mu).sum())), float(abs(((y - mu) * x[:, 0]).sum()))

    loose = LogisticRegression(C=1e6, solver="lbfgs", max_iter=20000, tol=1e-4).fit(x, y)
    tight = LogisticRegression(C=1e6, solver="lbfgs", max_iter=20000, tol=1e-8).fit(x, y)
    s, a = E.Weighted(y, p).calibration_slope_intercept(np.ones(len(y)))
    report = pd.DataFrame([
        {"solver": "lbfgs tol=1e-4 (scikit-learn default, release .8)", "slope": float(loose.coef_[0][0]),
         "intercept": float(loose.intercept_[0]), "grad_intercept": gradient(loose)[0], "grad_slope": gradient(loose)[1]},
        {"solver": "lbfgs tol=1e-8 (release .9 point estimate)", "slope": float(tight.coef_[0][0]),
         "intercept": float(tight.intercept_[0]), "grad_intercept": gradient(tight)[0], "grad_slope": gradient(tight)[1]},
        {"solver": "Newton-Raphson (release .9 bootstrap draws)", "slope": s, "intercept": a,
         "grad_intercept": np.nan, "grad_slope": np.nan},
    ])
    assert abs(float(tight.coef_[0][0]) - s) < 1e-5 and abs(float(tight.intercept_[0]) - a) < 1e-5
    assert gradient(loose)[0] > 100 * gradient(tight)[0]          # the default stop is far from the optimum
    return report


if __name__ == "__main__":
    worst = test_weighted_metrics_match_sklearn_on_repeated_rows()
    print("largest |weighted - scikit-learn on repeated rows| over 5 weight draws:")
    for k, v in worst.items():
        print(f"  {k:>14}: {v:.2e}")
    diff, t_new, t_old = test_bootstrap_matches_release_8()
    print("\nlargest |weighted draws - stacked rows and scikit-learn refit| over a 200-draw bootstrap, same seed:")
    print(diff.to_string(index=False, float_format=lambda v: f"{v:.2e}"))
    print(f"\n200 draws: weighted {t_new:.2f} s, stacked + refit {t_old:.2f} s ({t_old / t_new:.0f}x)")
    print("\ncalibration slope and intercept by solver (same data):")
    print(test_default_lbfgs_tolerance_is_loose().to_string(index=False, float_format=lambda v: f"{v:.6f}"))
    print("OK")
