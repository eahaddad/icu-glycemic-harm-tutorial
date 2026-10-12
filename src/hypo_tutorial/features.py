"""
Feature preparation, fitted on the training rows and applied unchanged to every
other split. Everything learned here (percentile cut-points, medians, category
lists, scaling) comes from the training rows only, so the test eras cannot leak
into the inputs through a preprocessing statistic.

Steps, in order:

1. Winsorise every numeric input at the training-set 0.1 and 99.9 percentiles.
   00 sections H2 and H7 found impossible extremes in the raw tables (heart rates
   of 10,000,000, a lactate of 1,276,103, a 930-unit insulin day); the SQL
   removed the impossible values it could name and left the long tails to this
   step, which pulls them to the training percentiles rather than dropping rows.
2. Missing indicators for every input with a missing value in training. In an
   ICU, "no lactate was drawn" is clinical information, not noise; the indicator
   lets both models use it. The logistic arm then takes the training median in
   place of the missing value; the tree arm keeps the NaN (LightGBM routes
   missing values on its own).
3. One-hot encoding of the categorical inputs from the training categories, with
   categories under MIN_CATEGORY_ROWS pooled into "other" and unseen test
   categories mapped to the same bin, so a care unit that opened in 2020 cannot
   crash or silently zero the matrix.
4. Standardisation (training mean and SD) for the logistic arm only, so its
   coefficients are comparable and its L2 penalty treats every input alike.

The class is deliberately plain pandas and numpy: a reader should be able to
check each statistic against the training rows by hand.
"""
import numpy as np
import pandas as pd

from .columns import CATEGORICAL, input_columns

MIN_CATEGORY_ROWS = 50       # categories rarer than this in training are pooled into "other"
WINSOR_LOW, WINSOR_HIGH = 0.001, 0.999


class FeaturePrep:
    def __init__(self, min_category_rows=MIN_CATEGORY_ROWS):
        self.min_category_rows = min_category_rows
        self.numeric_, self.categorical_, self.binary_ = [], [], []
        self.low_, self.high_, self.median_, self.mean_, self.sd_ = {}, {}, {}, {}, {}
        self.categories_, self.indicator_cols_ = {}, []
        self.columns_ = None                      # the final matrix columns, fixed at fit time

    # ----------------------------------------------------------------- fit
    def fit(self, train):
        inputs = input_columns(train)
        self.categorical_ = [c for c in CATEGORICAL if c in inputs]
        rest = [c for c in inputs if c not in self.categorical_]
        # 0/1 columns (flags, counts that are only ever 0 or 1) need no winsorising or scaling
        self.binary_ = [c for c in rest if set(pd.unique(train[c].dropna())) <= {0, 1, True, False}]
        self.numeric_ = [c for c in rest if c not in self.binary_]
        for c in self.numeric_:
            col = pd.to_numeric(train[c], errors="coerce").astype(float)
            self.low_[c], self.high_[c] = col.quantile(WINSOR_LOW), col.quantile(WINSOR_HIGH)
            clipped = col.clip(self.low_[c], self.high_[c])
            self.median_[c] = float(clipped.median()) if clipped.notna().any() else 0.0
            self.mean_[c] = float(clipped.mean()) if clipped.notna().any() else 0.0
            sd = float(clipped.std()) if clipped.notna().sum() > 1 else 1.0
            self.sd_[c] = sd if sd and np.isfinite(sd) and sd > 0 else 1.0
        # indicators for every input that is ever missing in training (binary columns included)
        self.indicator_cols_ = [c for c in self.numeric_ + self.binary_ if train[c].isna().any()]
        for c in self.categorical_:
            counts = train[c].fillna("missing").astype(str).value_counts()
            keep = sorted(counts[counts >= self.min_category_rows].index.tolist())
            self.categories_[c] = keep
        self.columns_ = list(self._transform(train.head(2), for_tree=True).columns)
        return self

    # ----------------------------------------------------------- transform
    def transform(self, df, for_tree):
        """for_tree=True: winsorised values with NaN kept (LightGBM). for_tree=False: medians in
        place of NaN, missing indicators, standardised (logistic regression)."""
        out = self._transform(df, for_tree)
        # the column set and order are those of the training fit, whatever this split contains
        return out.reindex(columns=self.columns_, fill_value=0.0)

    def _transform(self, df, for_tree):
        parts = []
        num = pd.DataFrame(index=df.index)
        for c in self.numeric_:
            col = pd.to_numeric(df[c], errors="coerce").astype(float).clip(self.low_[c], self.high_[c])
            if not for_tree:
                col = (col.fillna(self.median_[c]) - self.mean_[c]) / self.sd_[c]
            num[c] = col
        parts.append(num)
        binary = pd.DataFrame(index=df.index)
        for c in self.binary_:
            col = pd.to_numeric(df[c], errors="coerce").astype(float)
            binary[c] = col if for_tree else col.fillna(0.0)
        parts.append(binary)
        ind = pd.DataFrame({f"{c}__missing": df[c].isna().astype(float) for c in self.indicator_cols_}, index=df.index)
        parts.append(ind)
        for c in self.categorical_:
            vals = df[c].fillna("missing").astype(str)
            vals = vals.where(vals.isin(self.categories_[c]), "other")
            dummies = pd.get_dummies(vals, prefix=c, dtype=float)
            for cat in self.categories_[c] + ["other"]:
                if f"{c}_{cat}" not in dummies:
                    dummies[f"{c}_{cat}"] = 0.0
            parts.append(dummies[[f"{c}_{cat}" for cat in self.categories_[c] + ["other"]]])
        return pd.concat(parts, axis=1)

    # ------------------------------------------------------------ reporting
    def summary(self):
        """One row per numeric input: the cut-points and the median a reader can check."""
        return pd.DataFrame({
            "column": self.numeric_,
            "winsor_low": [self.low_[c] for c in self.numeric_],
            "winsor_high": [self.high_[c] for c in self.numeric_],
            "train_median": [self.median_[c] for c in self.numeric_],
            "has_missing_indicator": [c in self.indicator_cols_ for c in self.numeric_],
        })
