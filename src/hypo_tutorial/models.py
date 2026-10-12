"""
The two tabular arms and how they are tuned.

Arm A, logistic regression (L2). The baseline every clinical prediction paper is
expected to carry: linear, inspectable, usually well calibrated. Its one knob,
the inverse penalty C, is chosen by grouped cross-validation on log loss.

Arm B, gradient-boosted trees (LightGBM). The strongest tabular learner in the
clinical-ML literature for this kind of mixed feature table. Its number of
trees is set by early stopping on the validation fold's log loss inside the same
grouped cross-validation, and the final model is refit on all training rows
with the mean of the per-fold best iterations. The other settings are fixed
conservative values written below; tuning them on the test eras would be the
leak this file exists to prevent.

Why grouped folds. A patient contributes one row per ICU day (up to 28), and
those rows share the patient's labs, history and treatment pattern. Folds that
split a patient across train and validation reward memorising patients and
report an optimistic loss; StratifiedGroupKFold keeps every subject in one fold
and keeps the event rate even across folds.

Why log loss. Both arms output probabilities that are read as risks and judged on
calibration, so the tuning criterion is the proper scoring rule for
probabilities, not AUROC (which is blind to calibration) and not accuracy
(meaningless at a 1% event rate).

Out-of-fold predictions. Each fold's model scores the rows it did not see, so
every training row gets an honest prediction; these feed the Platt recalibration
(a logistic regression of the outcome on the model's logit, fitted on the
out-of-fold predictions and applied to the test eras) and the training-set
calibration plot.
"""
import numpy as np
import pandas as pd
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import log_loss
from sklearn.model_selection import StratifiedGroupKFold

C_GRID = [0.003, 0.01, 0.03, 0.1, 0.3, 1.0]
# L-BFGS stops on a gradient tolerance; at scikit-learn's default (1e-4) two Colab sessions reached fits that differed
# in the fourth decimal of the predictions, enough to move the > 300 operating points by a few events between the
# release .8 and .12 runs. A tighter tolerance makes the fit a property of the data, not of the machine.
LR_TOL = 1e-6

LGBM_PARAMS = dict(
    objective="binary", learning_rate=0.03, num_leaves=31, min_child_samples=100,
    feature_fraction=0.8, bagging_fraction=0.8, bagging_freq=1, lambda_l2=1.0,
    max_bin=255, verbosity=-1,
    n_jobs=0,          # 0 = OpenMP's default, every core the runtime has; a fixed 4 oversubscribed Colab's 2 vCPUs
                       # (measured on 61k rows x 207 columns, 2 cores: 21 s for the five folds and the refit at 0, 32 s at 4)
    deterministic=True, force_row_wise=True,   # the same numbers on any core count (LightGBM asks for one of the force_* with it); no time cost measured
)
# Everything in this file runs on the CPU. The LightGBM wheel on PyPI is a CPU build (the GPU build is
# compiled from source), and on 90k rows by 200 columns the GPU build is not faster anyway; scikit-
# learn's solvers and the bootstrap in evaluate.py are numpy. A GPU runtime in Colab does nothing here.
LGBM_MAX_ROUNDS, LGBM_EARLY_STOP = 3000, 100


def folds(y, groups, n_splits=5, seed=2026):
    """Subject-grouped, outcome-stratified folds. Falls back to fewer folds when the data is tiny
    (a development sample), never to ungrouped folds."""
    n_splits = max(2, min(n_splits, int(pd.Series(groups).nunique()), int(np.sum(y)), int(np.sum(1 - y))))
    skf = StratifiedGroupKFold(n_splits=n_splits, shuffle=True, random_state=seed)
    return list(skf.split(np.zeros(len(y)), y, groups))


def _clip(p):
    return np.clip(np.asarray(p, dtype=float), 1e-6, 1 - 1e-6)


def logit(p):
    p = _clip(p)
    return np.log(p / (1 - p))


# ------------------------------------------------------------------ arm A
def fit_logistic(X, y, groups, c_grid=C_GRID, n_splits=5, seed=2026):
    """Grouped CV over C on log loss; returns (fitted model on all rows, out-of-fold predictions,
    DataFrame of the CV path). X must already be imputed and standardised (FeaturePrep, for_tree=False)."""
    splits = folds(y, groups, n_splits, seed)
    path = []
    oof_by_c = {}
    for C in c_grid:
        oof = np.full(len(y), np.nan)
        for tr, va in splits:
            m = LogisticRegression(C=C, penalty="l2", solver="lbfgs", max_iter=5000, tol=LR_TOL)
            m.fit(X.iloc[tr], y[tr])
            oof[va] = m.predict_proba(X.iloc[va])[:, 1]
        oof_by_c[C] = oof
        path.append({"C": C, "cv_log_loss": log_loss(y, _clip(oof))})
    path = pd.DataFrame(path)
    best_c = float(path.loc[path["cv_log_loss"].idxmin(), "C"])
    model = LogisticRegression(C=best_c, penalty="l2", solver="lbfgs", max_iter=5000, tol=LR_TOL).fit(X, y)
    return model, oof_by_c[best_c], path.assign(chosen=path["C"] == best_c)


# ------------------------------------------------------------------ arm B
def fit_lightgbm(X, y, groups, params=LGBM_PARAMS, n_splits=5, seed=2026, max_rounds=LGBM_MAX_ROUNDS,
                 early_stop=LGBM_EARLY_STOP):
    """Grouped CV with early stopping on the validation log loss; the final model is refit on all
    rows with the mean best iteration. Returns (model, out-of-fold predictions, per-fold table)."""
    import lightgbm as lgb
    splits = folds(y, groups, n_splits, seed)
    params = dict(params, seed=seed)
    small = len(y) < 2000                              # a development sample: let leaves form
    if small:
        params = dict(params, min_child_samples=1, min_data_in_bin=1)
    oof = np.full(len(y), np.nan)
    rows = []
    for i, (tr, va) in enumerate(splits):
        dtr = lgb.Dataset(X.iloc[tr], y[tr])
        dva = lgb.Dataset(X.iloc[va], y[va], reference=dtr)
        booster = lgb.train(params, dtr, num_boost_round=max_rounds, valid_sets=[dva],
                            callbacks=[lgb.early_stopping(early_stop, verbose=False), lgb.log_evaluation(0)])
        oof[va] = booster.predict(X.iloc[va], num_iteration=booster.best_iteration)
        rows.append({"fold": i, "best_iteration": booster.best_iteration,
                     "valid_log_loss": booster.best_score["valid_0"]["binary_logloss"]})
    table = pd.DataFrame(rows)
    n_rounds = max(10, int(round(table["best_iteration"].mean())))
    model = lgb.train(params, lgb.Dataset(X, y), num_boost_round=n_rounds)
    return model, oof, table.assign(final_rounds=n_rounds)


def predict(model, X):
    """One call for both arms."""
    if hasattr(model, "predict_proba"):
        return model.predict_proba(X)[:, 1]
    return model.predict(X)


# ------------------------------------------------------------ recalibration
class Platt:
    """Logistic recalibration p' = sigmoid(a + b * logit(p)), fitted on out-of-fold training
    predictions. b (the slope) near 1 and a near 0 mean the raw model was already calibrated;
    the fitted values are reported next to the test-set calibration slope and intercept."""

    def fit(self, p_oof, y):
        # tol 1e-8: scikit-learn's default 1e-4 stops L-BFGS early on this two-parameter problem and
        # leaves the intercept off in the third decimal (see tests/test_evaluate.py)
        self.m = LogisticRegression(C=1e6, solver="lbfgs", max_iter=20000, tol=1e-8).fit(logit(p_oof).reshape(-1, 1), y)
        self.intercept_, self.slope_ = float(self.m.intercept_[0]), float(self.m.coef_[0][0])
        return self

    def transform(self, p):
        return self.m.predict_proba(logit(p).reshape(-1, 1))[:, 1]


# ------------------------------------------------------------ importance
def logistic_coefficients(model, columns, top=20):
    coef = pd.Series(model.coef_[0], index=columns)
    out = coef.reindex(coef.abs().sort_values(ascending=False).index).head(top)
    return out.rename("standardised_coefficient").reset_index().rename(columns={"index": "feature"})


def lightgbm_shap(model, X, top=20, sample=5000, seed=2026):
    """Mean absolute SHAP value per feature on a sample of rows (TreeExplainer is exact for trees,
    the sample only bounds the time). Returns (summary table, shap values, the sampled X)."""
    import shap
    Xs = X.sample(n=min(sample, len(X)), random_state=seed) if len(X) > sample else X
    explainer = shap.TreeExplainer(model)
    values = explainer.shap_values(Xs)
    if isinstance(values, list):                   # older shap returns [class0, class1]
        values = values[1]
    mean_abs = pd.Series(np.abs(values).mean(axis=0), index=Xs.columns).sort_values(ascending=False)
    summary = mean_abs.head(top).rename("mean_abs_shap").reset_index().rename(columns={"index": "feature"})
    return summary, values, Xs
