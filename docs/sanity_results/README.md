# Sanity results (00_sanity_itemids.sql on MIMIC-IV v3.1, BigQuery, 11 October 2026)

One CSV per statement of `sql/00_sanity_itemids.sql`, in statement order, exactly as BigQuery returned them (the console's script job export). Every table is an aggregate over the full database: counts, shares, percentiles and dictionary rows; no patient-level value. `docs/sanity_findings.md` states the hypothesis each section tested and the verdict; these files are the evidence behind it, so a reader can check a number without re-running a section (a full run costs about 100 GB of query bytes).

| File | Section | Rows |
| --- | --- | --- |
| `00_A_B_B2.csv` | A_B_B2 | 70 |
| `01_C.csv` | C | 2 |
| `02_D.csv` | D | 31 |
| `03_D2.csv` | D2 | 35 |
| `04_E.csv` | E | 5 |
| `05_F.csv` | F | 3 |
| `06_G.csv` | G | 5 |
| `07_H1.csv` | H1 | 39 |
| `08_H2.csv` | H2 | 17 |
| `09_H3.csv` | H3 | 8 |
| `10_H4.csv` | H4 | 13 |
| `11_H5.csv` | H5 | 26 |
| `12_H6.csv` | H6 | 6 |
| `13_H7.csv` | H7 | 24 |
| `14_I.csv` | I | 6 |
| `15_J.csv` | J | 21 |
| `16_K.csv` | K | 169 |
| `17_K1.csv` | K1 | 8 |
| `18_K2.csv` | K2 | 16 |
| `19_L.csv` | L | 4 |
| `20_L2.csv` | L2 | 1 |
| `21_M.csv` | M | 1 |
| `22_N.csv` | N | 8 |
| `23_N2.csv` | N2 | 1 |
| `24_O.csv` | O | 41 |
| `25_O2.csv` | O2 | 2 |
| `26_O3.csv` | O3 | 1 |
| `27_O4.csv` | O4 | 1 |
| `28_P.csv` | P | 49 |
| `29_P2.csv` | P2 | 5 |
