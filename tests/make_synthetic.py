"""
Build an invented MIMIC-IV-shaped DuckDB database for the ICU glycemic-harm
pipeline. Nothing here is real data: six invented patients, each stay
planted to exercise one rule (era filter, ICU length-of-stay filter, the
at-risk rule from both sources, the de-duplication of a dose charted in eMAR
and inputevents, a Rewritten drip row, a drip with a rate change, a feed
interruption, dextrose 50% after a low value, the CMS816 repeat-result rule
and its boundaries, censoring at ICU discharge and at death, two ICU stays in
one admission, history from an earlier admission only, garbage values) and,
since release .22, the availability cases of the second review of 12 October
2026: records charted before a landmark but entered after it (a flowsheet
segment, a rate change, an eMAR Stopped, an eMAR dose), an eMAR start with
16 hours of silence before its Stopped, a rate-less segment crossing a
landmark, a repeat result charted after the landmark but entered before it.
Entry times (storetime) follow table 20 of the release .20 run: an
inputevents or procedureevents row is entered two to five minutes after its
START, a chart value or eMAR row three to five minutes after its charttime.

Every table has exactly the columns of the official MIMIC-IV v3.1 schema, so
the SQL files run on it unchanged (tests/run_pipeline.py). tests/prefix_invariance.py
rebuilds each landmark's prefix from it.

Expected output when the SQL files run on it (tests/run_pipeline.py --results-dir out/):
  01 table 1 (split from the two era DECLAREs: 2017 - 2019 'test', 2020 - 2022 'test_shifted', the rest 'train'):
              train        1 row  (patient 3, 2014 - 2016) / 1 pos<54 / 1 pos<54 excluded / 0 / 0 / 0 pos>300 / 1 row with a drip
                           (the eMAR start closed by the 16 h cap), 0 running / 1 short window (death at 14 h)
              test         4 rows (patient 1; patient 5's late-entered glargine adds none) / 3 pos<54 (the contradicted 35 and 50
                           count in the primary label) / 2 excluded / 2 pos<40 / 1 CMS816 / 1 pos>300 (the 320 the old repeat
                           rule cancelled stands) / 0 short windows; 3 rows with a drip in the last 24 h (k=1 the first evening's
                           drip, k=2 the 3 units/h segment whose rate change was entered after t_2, k=3 the segment that change
                           opened), 1 running at t_k (k=2)
              test_shifted 4 rows (patients 2 and 6) / 1 pos<54 / 1 / 0 / 0 / 1 pos>300 / 1 short window;
                           3 rows with a drip in the last 24 h, 2 running at t_k (patient 6: the eMAR-only interval at the
                           first stay's landmark, the rate-less flowsheet segment crossing the second stay's)
  01 table 15: 2014 - 2016 one eMAR interval closed by the cap at 16 h; 2020 - 2022 two intervals, one closed by the cap
              (patient 2: its Stopped is charted 19 h after the last confirmation) and one by Stopped (patient 6, 12.9 h);
              1 row running on the eMAR alone, 0 rows with an eMAR interval open but declined
  01 table 18: band < 40: 2 results, 1 flagged; band 40 - 53: 9 results, 4 flagged (two on patient 1, the 300 s and the 81
              boundary cases on patient 5), 3 of them with the contradicting result entered after the low; nothing at or above 54
  01 table 21: 1 of 2 drip segments running at t_k by clinical time was entered after t_k; 2 of 8 in the look-back;
              1 of 7 eMAR infusion events; 1 of 2 rate changes in the look-back written after t_k
  02: rows_violating_leakage_rule 0, distinct_keys = rows_total = 9; Table 1b: glucose stream 2 results stored before their
      charttime (the 160 charted 10:05 and entered 09:58 around t_1; the 100 charted 10:02 and entered 09:58 around t_4),
      2 straddling landmark rows; lab panel 0. Profile: max_bolus_units_24h 12 (the 155,911,922,996-unit dose is capped
      away), max_drip_rate 4 among rows with no drip running and 3 among rows with one (the Rewritten row at 99 units/h
      and the Bolus-status row at 60 units/h are not segments; the rate-less Continuous IV row crossing its landmark has
      no rate at t_k), pct_running_with_rate_known 33.3 (one of the three running rows, patient 1 k=2 at 3 units/h)
  features, the planted rows (tests/prefix_invariance.py compares every input of every landmark against its prefix):
      patient 1 k=2: drip_running_at_tk 1, drip_rate_at_tk 3, drip_hours_24h 4.0, drip_units_24h 12; k=3: drip_hours_24h 1.0,
      hrs_since_drip_stop 23; k=4: glucose_last 50 (the repeat charted after t_4 is not a feature), glucose_min_24h 35
      patient 3 k=1: drip_hours_24h 16.0, hrs_since_drip_stop 6, nothing running
      patient 6 first stay: stay_has_inputevents_drip false (its first segment was entered after t_1), drip_running_emar_at_tk 1,
      drip_hours_24h 13.0; second stay: drip_running_at_tk 1, drip_hours_24h 20.0, drip_rate_at_tk NULL, drip_units_24h NULL,
      rrt_at_tk 1 (CRRT chartings entered before t_1), rrt_hours_24h 8.0
"""
import sys
from pathlib import Path
import duckdb, pandas as pd
from datetime import datetime as dt, timedelta as td

HERE = Path(__file__).resolve().parent
DB = HERE / "synthetic_mimic.duckdb"                 # what tests/run_pipeline.py reads (not committed: build it with this script)

def T(s):  # 'YYYY-MM-DD HH:MM' or 'YYYY-MM-DD HH:MM:SS' -> datetime
    return dt.strptime(s, "%Y-%m-%d %H:%M:%S" if s.count(":") == 2 else "%Y-%m-%d %H:%M")

patients = pd.DataFrame([
    # subject_id, gender, anchor_age, anchor_year, anchor_year_group, dod
    (1001, "F", 70, 2150, "2017 - 2019", None),
    (1002, "M", 55, 2160, "2020 - 2022", None),
    (1003, "F", 80, 2155, "2014 - 2016", dt(2155, 7, 3).date()),
    (1004, "M", 40, 2130, "2005 - 2007", None),     # excluded by era (not a MIMIC-IV era string)
    (1005, "M", 62, 2158, "2017 - 2019", None),
    (1006, "F", 68, 2170, "2020 - 2022", None),
], columns=["subject_id", "gender", "anchor_age", "anchor_year", "anchor_year_group", "dod"])

def adm(subject_id, hadm_id, admit, disch, death=None, atype="EW EMER.", aloc="EMERGENCY ROOM",
        dloc="HOME", ins="Medicare", lang="English", mar="MARRIED", race="WHITE", ed=True, expire=0):
    return dict(subject_id=subject_id, hadm_id=hadm_id, admittime=T(admit), dischtime=T(disch),
                deathtime=T(death) if death else None, admission_type=atype, admit_provider_id="P001",
                admission_location=aloc, discharge_location=dloc, insurance=ins, language=lang,
                marital_status=mar, race=race,
                edregtime=T(admit) - td(hours=2) if ed else None, edouttime=T(admit) if ed else None,
                hospital_expire_flag=expire)

admissions = pd.DataFrame([
    adm(1001, 10001, "2149-01-01 10:00", "2149-01-05 12:00"),                       # prior admission (history source)
    adm(1001, 10002, "2150-03-01 08:00", "2150-03-08 12:00"),                       # index admission, ICU 03-01 10:00 to 03-06 10:00
    adm(1002, 20001, "2160-05-10 14:00", "2160-05-14 10:00", atype="URGENT"),       # ICU 05-10 16:00 to 05-13 10:00
    adm(1003, 30001, "2155-07-01 10:00", "2155-07-03 02:00", death="2155-07-03 02:00", dloc="DIED", expire=1),
    adm(1004, 40001, "2130-04-01 08:00", "2130-04-06 08:00"),                       # excluded era
    adm(1005, 50001, "2158-02-01 09:00", "2158-02-01 20:00"),                       # LOS 11 h, no ICU
    adm(1005, 50002, "2158-09-01 09:00", "2158-09-05 09:00"),                       # an 18 h ICU stay (excluded) and one with no hypoglycemic agent
    adm(1006, 60000, "2169-03-01 09:00", "2169-03-04 09:00"),                       # prior admission
    adm(1006, 60001, "2170-01-10 12:00", "2170-01-16 18:00"),                       # two ICU stays
])

# ---------------- ICU stays ----------------
icustays = pd.DataFrame([
    (1001, 10002, 200011, "Medical Intensive Care Unit (MICU)", "Medical Intensive Care Unit (MICU)", T("2150-03-01 10:00"), T("2150-03-06 10:00"), 5.0),
    (1002, 20001, 200010, "Medical Intensive Care Unit (MICU)", "Medical Intensive Care Unit (MICU)", T("2160-05-10 16:00"), T("2160-05-13 10:00"), 2.75),
    (1003, 30001, 200030, "Medical Intensive Care Unit (MICU)", "Medical Intensive Care Unit (MICU)", T("2155-07-01 12:00"), T("2155-07-03 02:00"), 1.58),
    (1004, 40001, 200040, "Surgical Intensive Care Unit (SICU)", "Surgical Intensive Care Unit (SICU)", T("2130-04-01 10:00"), T("2130-04-05 10:00"), 4.0),
    (1005, 50002, 200050, "Medical Intensive Care Unit (MICU)", "Medical Intensive Care Unit (MICU)", T("2158-09-01 10:00"), T("2158-09-02 04:00"), 0.75),   # 18 h: excluded
    (1005, 50002, 200051, "Medical Intensive Care Unit (MICU)", "Medical Intensive Care Unit (MICU)", T("2158-09-02 12:00"), T("2158-09-05 09:00"), 2.9),    # no hypoglycemic agent
    (1006, 60001, 200060, "Cardiac Vascular Intensive Care Unit (CVICU)", "Cardiac Vascular Intensive Care Unit (CVICU)", T("2170-01-10 13:00"), T("2170-01-12 13:00"), 2.0),
    (1006, 60001, 200061, "Cardiac Vascular Intensive Care Unit (CVICU)", "Cardiac Vascular Intensive Care Unit (CVICU)", T("2170-01-14 06:00"), T("2170-01-16 06:00"), 2.0),
], columns=["subject_id", "hadm_id", "stay_id", "first_careunit", "last_careunit", "intime", "outtime", "los"])

# ---------------- eMAR ----------------
emar_rows, detail_rows = [], []
_seq = [0]
def give(subject_id, hadm_id, when, medication, event_txt, dose=None, unit=None, route="SC",
         infusion_rate=None, extra_detail_rows=0, store=None):
    _seq[0] += 1
    emar_id = f"{subject_id}-{_seq[0]}"
    emar_rows.append(dict(subject_id=subject_id, hadm_id=hadm_id, emar_id=emar_id, emar_seq=_seq[0],
                          poe_id=f"{subject_id}-poe", pharmacy_id=_seq[0], enter_provider_id="P001",
                          charttime=T(when), medication=medication, event_txt=event_txt,
                          scheduletime=T(when), storetime=T(store) if store else T(when) + td(minutes=3)))
    base = dict(subject_id=subject_id, emar_id=emar_id, emar_seq=_seq[0], parent_field_ordinal=None,
                administration_type=("Insulin SC Sliding Scale" if medication == "Insulin Lispro" else
                                     "Insulin SC Fixed Dose" if "insulin" in medication.lower() and infusion_rate is None else
                                     "Continuous Med" if infusion_rate else "Bolus"),
                pharmacy_id=_seq[0], barcode_type=None, reason_for_no_barcode=None,
                complete_dose_not_given=None, dose_due=dose, dose_due_unit=unit, dose_given=None,
                dose_given_unit=None, will_remainder_of_dose_be_given=None, product_amount_given=None,
                product_unit=None, product_code=None, product_description=None,
                product_description_other=None, prior_infusion_rate=None, infusion_rate=None,
                infusion_rate_adjustment=None, infusion_rate_adjustment_amount=None,
                infusion_rate_unit=None, route=None,
                infusion_complete=None, completion_interval=None, new_iv_bag_hung=None,
                continued_infusion_in_other_location=None, restart_interval=None, side=None,
                site=None, non_formulary_visual_verification=None)
    base["infusion_rate"] = infusion_rate         # on MIMIC-IV the rate sits on the parent row
    base["infusion_rate_unit"] = "units/hour" if infusion_rate else None
    detail_rows.append(base)                      # parent row: order-level summary, NO dose_given
    given = dose is not None or infusion_rate is not None
    if given:                                     # child row(s): what was actually given
        n_children = 1 + extra_detail_rows
        for i in range(n_children):
            d = dict(base); d["parent_field_ordinal"] = f"1.{i+1}"
            d["dose_given"] = dose if dose is None else str(float(dose) / n_children)
            d["dose_given_unit"] = unit; d["product_description"] = medication
            d["route"] = None if "insulin" in medication.lower() else route   # route is never populated for insulin
            d["infusion_rate"] = None; d["infusion_rate_unit"] = None
            detail_rows.append(d)

# Patient 1 / hadm 10002 (ICU 03-01 10:00 to 03-06 10:00): glargine nightly, lispro TID,
# one held lispro, sliding-scale checks with nothing due, a lost event text, a barcode-sized dose,
# metoprolol, a D50 rescue after the low value
for day in range(1, 8):
    give(1001, 10002, f"2150-03-0{day} 21:00", "Insulin Glargine", "Administered", "24", "UNIT")
    for hh in ("08:00", "12:00", "18:00"):
        evt = "Not Given" if (day == 3 and hh == "12:00") else ("Not Given per Sliding Scale" if (day == 2 and hh in ("12:00", "18:00")) else "Administered")
        if day == 5 and hh == "12:00":
            evt = None                     # event text lost, but a dose was charted (00 section G pattern)
        given = evt is None or evt == "Administered"
        dose = "4" if given else None
        if day == 5 and hh == "08:00":
            dose = "155911922996"          # barcode-sized dose_given (first real 01 run); the cap must drop it
        give(1001, 10002, f"2150-03-0{day} {hh}", "Insulin Lispro", evt, dose, "UNIT" if given else None,
             extra_detail_rows=1 if (day == 1 and hh == "08:00") else 0)
    give(1001, 10002, f"2150-03-0{day} 09:00", "Metoprolol Tartrate", "Administered", "25", "mg", route="PO")
give(1001, 10002, "2150-03-04 03:30", "Dextrose 50%", "Administered", "25", "g", route="IV")
# octreotide on the eMAR (drug_class 'octreotide' in 01): inside k=2's look-back (03-03 10:00), outside k=3's
give(1001, 10002, "2150-03-03 08:00", "Octreotide Acetate", "Administered", "100", "mcg")
# Patient 2 / hadm 20001 (ICU 05-10 16:00 to 05-13 10:00): the drip is in inputevents; eMAR records
# its Started / Stopped (concordance), an IV push for hyperkalemia before the ICU, levofloxacin,
# and one lispro dose that inputevents also charts 10 minutes later (must count once)
give(1002, 20001, "2160-05-10 18:00", "Insulin", "Started", None, None, route="IV DRIP", infusion_rate="4")
# the eMAR Stopped is charted five hours after the flowsheet segment ended (12:00), past the first landmark
# (05-11 16:00): the interval is open at t_1 but the stay has flowsheet drips, so the rule declines it (01 table 7:
# "none (emar interval open, flowsheet stay)"); drip_running_at_tk stays 0 for that row
give(1002, 20001, "2160-05-11 17:00", "Insulin", "Stopped", None, None, route="IV DRIP")
# a Confirmed row inside the drip (01 table 13: an infusion check, inside an inputevents segment; patient 6's pump
# confirmation below is outside any drip and is kept apart by its medication text). Since the first ICU run it is
# drip evidence, never a bolus: patient 2's eMAR interval runs 18:00 to 12:00 beside the inputevents segments
give(1002, 20001, "2160-05-10 22:00", "Insulin", "Confirmed", None, None, route="IV DRIP", infusion_rate="4")
give(1002, 20001, "2160-05-11 09:00", "Levofloxacin", "Administered", "750", "mg", route="IV")
give(1002, 20001, "2160-05-10 15:30", "Insulin (Regular) for Hyperkalemia", "Administered", "10", "UNIT", route="IV")
give(1002, 20001, "2160-05-12 12:00", "Insulin Lispro", "Administered", "4", "UNIT")
# Patient 3 / hadm 30001 (ICU 07-01 12:00, dies 07-03 02:00): sulfonylurea
give(1003, 30001, "2155-07-01 12:00", "GlipiZIDE", "Administered", "5", "mg", route="PO")
give(1003, 30001, "2155-07-02 12:00", "GlipiZIDE", "Administered", "5", "mg", route="PO")
# second review, case 3: an eMAR insulin infusion Started 07-01 14:00 with no further event until a Stopped 24 h later.
# No flowsheet drip in the stay, so the eMAR state is the drip record. At t_1 (07-02 12:00) the only visible event is
# the start: the cap closes the interval at 14:00 + 16 h = 07-02 06:00, so the row has a drip in its look-back
# (16.0 h, stopped 6 h before t_1) and nothing running. The Stopped charted at 14:00 the next day is after t_1 and,
# had it been visible, could only have shortened the interval (LEAST of the stop and the cap): it never reopens it
give(1003, 30001, "2155-07-01 14:00", "Insulin", "Started", None, None, route="IV DRIP", infusion_rate="2")
give(1003, 30001, "2155-07-02 14:00", "Insulin", "Stopped", None, None, route="IV DRIP")
# Patient 4 (excluded era) and patient 5 / 50002 (no hypoglycemic agent)
give(1004, 40001, "2130-04-02 08:00", "Insulin Glargine", "Administered", "10", "UNIT")
give(1005, 50002, "2158-09-03 09:00", "Metoprolol Tartrate", "Administered", "25", "mg", route="PO")
# second review, eligibility through a late entry: a glargine dose CHARTED 09-03 09:00, three hours before stay 200051's
# first landmark (09-03 12:00), but ENTERED at 13:00, after it. The dose is outside the look-back of t_2 (09-04 12:00),
# so under the availability rule the stay has no at-risk row at all (test rows stay 4); a rule on charttime alone
# would have made t_1 at risk through a dose the EHR did not yet hold
give(1005, 50002, "2158-09-03 09:00", "Insulin Glargine", "Administered", "10", "UNIT", store="2158-09-03 13:00")
# Patient 6 / hadm 60001 (ICU stays 01-10 13:00 to 01-12 13:00 and 01-14 06:00 to 01-16 06:00):
# glargine, a pump confirmation, prednisone, a held dose in the second stay
give(1006, 60001, "2170-01-10 21:00", "Insulin Glargine", "Administered", "18", "UNIT")
give(1006, 60001, "2170-01-11 21:00", "Insulin Glargine", "Administered", "18", "UNIT")
give(1006, 60001, "2170-01-11 09:00", "Insulin Pump (Self Administering Medication)", "Confirmed", None, None)
# an insulin drip the eMAR records and inputevents does not (the 2020-2022 pattern of 01 table 12): Started at
# 00:00, one Confirmed at 03:00, never Stopped. 01 view 2b closes it INFUSION_CAP_HOURS after the last event
# (03:00 + 16 h = 19:00), so it is running at the stay's first landmark (01-11 13:00): the test_shifted rows with a
# drip go from 2 to 3 and rows with a drip running at t_k from 0 to 1; no row is added (glargine already made it at risk)
give(1006, 60001, "2170-01-11 00:00", "Insulin", "Started", None, None, route="IV DRIP", infusion_rate="3")
give(1006, 60001, "2170-01-11 03:00", "Insulin", "Confirmed", None, None, route="IV DRIP", infusion_rate="3")
# the review of 12 October 2026 (second round), case 2: a Stopped CHARTED five minutes before the landmark (12:55)
# but ENTERED half an hour after it (13:30). At t_1 the EHR showed no Stopped, so the state rebuilt at t_1
# (emar_drips_at_landmark) keeps the interval open and the row stays "running on the eMAR alone"; the record as
# it stands at the end (emar_insulin_infusions, table 15) closes it at 12:55 by Stopped
give(1006, 60001, "2170-01-11 12:55", "Insulin", "Stopped", None, None, route="IV DRIP", store="2170-01-11 13:30")
give(1006, 60001, "2170-01-11 09:00", "PredniSONE", "Administered", "40", "mg", route="PO")
give(1006, 60001, "2170-01-14 21:00", "Insulin Glargine", "Administered", "18", "UNIT")
give(1006, 60001, "2170-01-14 21:30", "Insulin Lispro", "Hold Dose", None, None)
give(1006, 60001, "2170-01-15 21:00", "Insulin Glargine", "Administered", "18", "UNIT")

emar = pd.DataFrame(emar_rows)
emar_detail = pd.DataFrame(detail_rows)

# ---------------- ICU dictionary ----------------
d_items = pd.DataFrame([
    (220621, "Glucose (serum)", "Glucose (serum)", "chartevents", "Labs", "mg/dL", "Numeric", 70, 100),
    (225664, "Glucose finger stick (range 70-100)", "Glucose finger stick", "chartevents", "Labs", "mg/dL", "Numeric", 70, 100),
    (226537, "Glucose (whole blood)", "Glucose (whole blood)", "chartevents", "Labs", "mg/dL", "Numeric", 70, 100),
    (220045, "Heart Rate", "HR", "chartevents", "Routine Vital Signs", "bpm", "Numeric", None, None),
    (220179, "Non Invasive Blood Pressure systolic", "NBPs", "chartevents", "Routine Vital Signs", "mmHg", "Numeric", None, None),
    (220050, "Arterial Blood Pressure systolic", "ABPs", "chartevents", "Routine Vital Signs", "mmHg", "Numeric", None, None),
    (220210, "Respiratory Rate", "RR", "chartevents", "Routine Vital Signs", "insp/min", "Numeric", None, None),
    (220277, "O2 saturation pulseoxymetry", "SpO2", "chartevents", "Routine Vital Signs", "%", "Numeric", None, None),
    (223761, "Temperature Fahrenheit", "Temperature F", "chartevents", "Routine Vital Signs", "°F", "Numeric", None, None),
    (223762, "Temperature Celsius", "Temperature C", "chartevents", "Routine Vital Signs", "°C", "Numeric", None, None),
    (226512, "Admission Weight (Kg)", "Admission Weight", "chartevents", "General", "kg", "Numeric", None, None),
    (224639, "Daily Weight", "Daily Weight", "chartevents", "General", "kg", "Numeric", None, None),
    (220739, "GCS - Eye Opening", "GCS - Eye", "chartevents", "Neurological", None, "Text", None, None),
    (223900, "GCS - Verbal Response", "GCS - Verbal", "chartevents", "Neurological", None, "Text", None, None),
    (223901, "GCS - Motor Response", "GCS - Motor", "chartevents", "Neurological", None, "Text", None, None),
    (223258, "Insulin - Regular", "Insulin - Regular", "inputevents", "Medications", "units", "Solution", None, None),
    (223262, "Insulin - Humalog", "Insulin - Humalog", "inputevents", "Medications", "units", "Solution", None, None),
    (223260, "Insulin - Glargine", "Insulin - Glargine", "inputevents", "Medications", "units", "Solution", None, None),
    (225916, "TPN w/ Lipids", "TPN w/ Lipids", "inputevents", "Nutrition - Parenteral", "mL", "Solution", None, None),
    (225970, "Nutren 2.0 (Full)", "Nutren 2.0", "inputevents", "Nutrition - Enteral", "mL", "Solution", None, None),
    (227979, "Boost Glucose Control (Full)", "Boost Glucose Control", "inputevents", "Nutrition - Enteral", "mL", "Solution", None, None),
    (225947, "Dextrose PN", "Dextrose PN", "inputevents", "Nutrition - Parenteral", "grams", "Solution", None, None),
    (220950, "Dextrose 10%", "D10W", "inputevents", "Fluids/Intake", "mL", "Solution", None, None),
    (220952, "Dextrose 50%", "D50W", "inputevents", "Fluids/Intake", "mL", "Solution", None, None),
    (221906, "Norepinephrine", "Norepinephrine", "inputevents", "Medications", "mg", "Solution", None, None),
    (225792, "Invasive Ventilation", "Invasive Ventilation", "procedureevents", "Ventilation", None, "Process", None, None),
    (225794, "Non-invasive Ventilation", "Non-invasive Ventilation", "procedureevents", "Ventilation", None, "Process", None, None),
    # dialysis, antibiotics and octreotide: 01 finds these by label / category, never by number, so the ids
    # below only need to be distinct here; 00 sections O, P and P2 print the real dictionary rows
    (225802, "Dialysis - CRRT", "Dialysis - CRRT", "procedureevents", "Dialysis", None, "Process", None, None),
    (225441, "Hemodialysis", "Hemodialysis", "procedureevents", "4-Procedures", None, "Process", None, None),
    (224270, "Dialysis Catheter", "Dialysis Catheter", "procedureevents", "Access Lines - Invasive", None, "Process", None, None),
    (225436, "CRRT Filter Change", "CRRT Filter Change", "procedureevents", "Dialysis", None, "Process", None, None),
    (227290, "CRRT mode", "CRRT mode", "chartevents", "Dialysis", None, "Text", None, None),
    (224154, "Dialysate Rate", "Dialysate Rate", "chartevents", "Dialysis", "mL/hour", "Numeric", None, None),
    (226499, "Hemodialysis Output", "Hemodialysis Output", "chartevents", "Dialysis", "mL", "Numeric", None, None),
    (225798, "Vancomycin", "Vancomycin", "inputevents", "Antibiotics", "dose", "Solution", None, None),
    (225893, "Piperacillin/Tazobactam (Zosyn)", "Zosyn", "inputevents", "Antibiotics", "dose", "Solution", None, None),
    (229999, "Octreotide", "Octreotide", "inputevents", "Medications", "mcg", "Solution", None, None),
], columns=["itemid", "label", "abbreviation", "linksto", "category", "unitname", "param_type", "lownormalvalue", "highnormalvalue"])

# ---------------- inputevents ----------------
ie = []
_oid = [0]
def infuse(subject_id, hadm_id, stay_id, start, end, itemid, amount=None, amountuom=None, rate=None, rateuom=None,
           status="FinishedRunning", category="Continuous Med", orderid=None, store=None):
    # storetime: entered two minutes after the START unless given (table 20 of the release .20 run: insulin
    # segments are entered a median 1 minute after their start and 67 minutes before their end)
    _oid[0] += 1
    ie.append(dict(subject_id=subject_id, hadm_id=hadm_id, stay_id=stay_id, caregiver_id=1,
                   starttime=T(start), endtime=T(end), storetime=T(store) if store else T(start) + td(minutes=2), itemid=itemid,
                   amount=amount, amountuom=amountuom, rate=rate, rateuom=rateuom,
                   orderid=orderid or _oid[0], linkorderid=orderid or _oid[0],
                   ordercategoryname="01-Drips" if rate else "02-Fluids (Crystalloids)" if itemid in (220950,) else "03-IV Fluid Bolus",
                   secondaryordercategoryname=None, ordercomponenttypedescription="Main order parameter",
                   ordercategorydescription=category, patientweight=80.0, totalamount=None, totalamountuom=None,
                   isopenbag=0, continueinnextdept=0, statusdescription=status, originalamount=amount, originalrate=rate))
# Patient 1: a six-hour drip on the first ICU evening (2 units/h, Stopped). It makes stay 200011 a flowsheet stay, so
# its later landmarks are at risk only through the eMAR subcutaneous doses: the fifth ICU run's flowsheet-first join
# dropped such rows (it tested the exposure's source without NOT is_drip), and this case fails on exactly that
# (test rows 4 -> 1). k = 1 (03-02 10:00) sees the drip in its look-back, stopped 16 h before the landmark.
infuse(1001, 10002, 200011, "2150-03-01 12:00", "2150-03-01 18:00", 223258, amount=12, amountuom="units", rate=2, rateuom="units/hour", status="Stopped", orderid=4001)
# second review, case 1 (eligibility and predictors) and the rate-change end rule. A segment at 3 units/h from 06:00,
# closed by a rate change at 09:00 (entered 06:02), and the segment the change opened, 1 unit/h from 09:00 to 11:00,
# entered at 10:30, after t_2 (03-03 10:00). At t_2 the EHR held the first segment with no end written (the change
# is written with the second segment, so end_storetime = 10:30): the row is running at 3 units/h, 4 h in the
# look-back, 12 units; the second segment is invisible. At t_3 (03-04 10:00) both are known: the first ended at
# 09:00 (outside the look-back), the second overlaps it by one hour (10:00 to 11:00), stopped 23 h before t_3.
# tests/prefix_invariance.py rebuilds t_2's prefix with the second segment absent and the first segment open
infuse(1001, 10002, 200011, "2150-03-03 06:00", "2150-03-03 09:00", 223258, amount=9, amountuom="units", rate=3, rateuom="units/hour", status="ChangeDose/Rate", orderid=4002)
infuse(1001, 10002, 200011, "2150-03-03 09:00", "2150-03-03 11:00", 223258, amount=2, amountuom="units", rate=1, rateuom="units/hour", status="Stopped", orderid=4002, store="2150-03-03 10:30")
# Patient 2: the drip, two segments (rate 4 then 2), plus a Rewritten row at 99 units/h that must be ignored
infuse(1002, 20001, 200010, "2160-05-10 18:00", "2160-05-11 02:00", 223258, amount=32, amountuom="units", rate=4, rateuom="units/hour", status="ChangeDose/Rate", orderid=5001)
# a bolus given from the drip: Bolus status, rate 60 units/h over 30 min, amount 3 units -> a 3-unit bolus, never a 60 units/h segment
infuse(1002, 20001, 200010, "2160-05-10 20:00", "2160-05-10 20:30", 223258, amount=3, amountuom="units", rate=60, rateuom="units/hour", status="Bolus", orderid=5001)
infuse(1002, 20001, 200010, "2160-05-11 02:00", "2160-05-11 12:00", 223258, amount=20, amountuom="units", rate=2, rateuom="units/hour", status="Stopped", orderid=5001)
infuse(1002, 20001, 200010, "2160-05-10 18:00", "2160-05-11 02:00", 223258, amount=792, amountuom="units", rate=99, rateuom="units/hour", status="Rewritten", orderid=5001)
# an ICU-flowsheet-only Humalog bolus (no eMAR row within 60 min) and a duplicate of the eMAR lispro dose 10 min later
infuse(1002, 20001, 200010, "2160-05-12 08:00", "2160-05-12 08:01", 223262, amount=6, amountuom="units", category="Drug Push")
infuse(1002, 20001, 200010, "2160-05-12 12:10", "2160-05-12 12:11", 223262, amount=4, amountuom="units", category="Drug Push")
# norepinephrine 17:00 to 05:00
infuse(1002, 20001, 200010, "2160-05-10 17:00", "2160-05-11 05:00", 221906, amount=4.8, amountuom="mg", rate=0.1, rateuom="mcg/kg/min")
# Patient 1: enteral feed with an interruption (stops 03-04 02:00, restarts 14:00), D50 after the 48 mg/dL value
infuse(1001, 10002, 200011, "2150-03-02 12:00", "2150-03-03 12:00", 225970, amount=960, amountuom="mL", rate=40, rateuom="mL/hour", status="ChangeDose/Rate")
# a garbage feed rate (00 section N: maxima of 60,000 mL/h) inside k=3's look-back: must not count as feeding
infuse(1001, 10002, 200011, "2150-03-04 12:00", "2150-03-04 13:00", 225970, amount=60000, amountuom="mL", rate=60000, rateuom="mL/hour")
infuse(1001, 10002, 200011, "2150-03-03 12:00", "2150-03-04 02:00", 225970, amount=840, amountuom="mL", rate=60, rateuom="mL/hour", status="Stopped")
infuse(1001, 10002, 200011, "2150-03-04 14:00", "2150-03-06 10:00", 225970, amount=2640, amountuom="mL", rate=60, rateuom="mL/hour")
infuse(1001, 10002, 200011, "2150-03-04 03:30", "2150-03-04 03:35", 220952, amount=50, amountuom="mL", category="Bolus")
# Patient 6, first stay: an insulin drip segment on the flowsheet that STARTS after t_1 (01-11 13:00). The eMAR-only
# interval (Started 00:00, Confirmed 03:00, closed by the cap at 19:00) is running at t_1; before release .20 the
# flowsheet-first flag was a stay-level fact, so this later segment made the stay a flowsheet stay and the eMAR
# interval was declined at t_1 (a record charted in the future changing an earlier row). The flag is now evaluated
# at each landmark from segments started before t_k, so at t_1 the eMAR interval counts and the row is "running on
# the eMAR alone", as documented above.
infuse(1006, 60001, 200060, "2170-01-11 16:00", "2170-01-11 20:00", 223258, amount=8, amountuom="units", rate=2, rateuom="units/hour", status="Stopped", orderid=6001)
# second review, case 1 (the flag): a flowsheet segment that STARTS before t_1 (10:00 to 12:00) but is ENTERED after it
# (14:00). At t_1 the flowsheet showed no segment, so the flag stays false, the eMAR interval counts and the row is
# still "running on the eMAR alone"; a flag read off starttime alone would have declined the eMAR interval here
infuse(1006, 60001, 200060, "2170-01-11 10:00", "2170-01-11 12:00", 223258, amount=4, amountuom="units", rate=2, rateuom="units/hour", status="Stopped", orderid=6002, store="2170-01-11 14:00")
# Patient 6: dextrose 10% in the first stay, TPN in the second
infuse(1006, 60001, 200060, "2170-01-11 00:00", "2170-01-11 20:00", 220950, amount=1000, amountuom="mL", rate=50, rateuom="mL/hour")
infuse(1006, 60001, 200061, "2170-01-14 08:00", "2170-01-16 06:00", 225916, amount=2760, amountuom="mL", rate=60, rateuom="mL/hour")
# the TPN's dextrose component: a gram row without a rate, parenteral by category, never a "dextrose fluid"
infuse(1006, 60001, 200061, "2170-01-14 08:00", "2170-01-15 08:00", 225947, amount=150, amountuom="grams", category="Continuous Med")
# a rate-less "Continuous IV" insulin drip (00 K2: 2,245 such rows): 48 units over 24 h = 2 units/h, a drip, not a bolus.
# Second review, case 4: it CROSSES the landmark (01-15 06:00), so at t_1 the row is visible (entered 10:02), running,
# and its amount-derived rate is unknown (the amount is the segment's total, written when it ends): drip_running_at_tk 1,
# drip_hours_24h 20.0, drip_rate_at_tk NULL. tests/prefix_invariance.py changes the amount and checks that nothing at
# t_1 moves
infuse(1006, 60001, 200061, "2170-01-14 10:00", "2170-01-15 10:00", 223258, amount=48, amountuom="units", category="Continuous IV")
# an enteral formula whose label says "Glucose": enteral by category, running at stay 200060's landmark
infuse(1006, 60001, 200060, "2170-01-11 08:00", "2170-01-11 16:00", 227979, amount=320, amountuom="mL", rate=40, rateuom="mL/hour")
# Patient 4 (excluded era) has a drip too
infuse(1004, 40001, 200040, "2130-04-02 08:00", "2130-04-03 08:00", 223258, amount=48, amountuom="units", rate=2, rateuom="units/hour")
# Patient 2: vancomycin every 12 h from 05-10 17:00 (the stay's first antibiotic start, inside k=1's look-back
# and outside k=2's), one Rewritten row that must not count as a second agent
for start, end in [("2160-05-10 17:00", "2160-05-10 18:00"), ("2160-05-11 05:00", "2160-05-11 06:00"),
                   ("2160-05-11 17:00", "2160-05-11 18:00"), ("2160-05-12 05:00", "2160-05-12 06:00"),
                   ("2160-05-12 17:00", "2160-05-12 18:00")]:
    infuse(1002, 20001, 200010, start, end, 225798, amount=1, amountuom="dose", category="Continuous IV")
infuse(1002, 20001, 200010, "2160-05-11 05:00", "2160-05-11 06:00", 225893, amount=1, amountuom="dose", category="Continuous IV", status="Rewritten")
# Patient 6, second stay: an octreotide infusion charted only in the ICU flowsheet (01 icu_octreotide),
# running across the landmark 01-15 06:00
infuse(1006, 60001, 200061, "2170-01-14 12:00", "2170-01-15 12:00", 229999, amount=1200, amountuom="mcg", rate=50, rateuom="mcg/hour")
inputevents = pd.DataFrame(ie)

# ---------------- procedureevents ----------------
def proc(subject_id, hadm_id, stay_id, start, end, itemid, category, orderid, store=None):
    return dict(subject_id=subject_id, hadm_id=hadm_id, stay_id=stay_id, caregiver_id=1, starttime=T(start), endtime=T(end),
                storetime=T(store) if store else T(start) + td(minutes=5), itemid=itemid, value=(T(end) - T(start)).total_seconds() / 60, valueuom="min",
                location=None, locationcategory=None, orderid=orderid, linkorderid=orderid, ordercategoryname=category,
                ordercategorydescription="ProcessDuration", patientweight=80.0, isopenbag=0, continueinnextdept=0,
                statusdescription="FinishedRunning", originalamount=None, originalrate=None)
procedureevents = pd.DataFrame([
    proc(1002, 20001, 200010, "2160-05-10 16:30", "2160-05-12 09:00", 225792, "Ventilation", 9001),
    # CRRT from 05-11 10:00 to 05-12 20:00: running at both landmarks of stay 200010 (6 h of overlap at k=1, 24 h at k=2)
    proc(1002, 20001, 200010, "2160-05-11 10:00", "2160-05-12 20:00", 225802, "Dialysis", 9002),
    # a 4 h intermittent hemodialysis session in stay 200060's look-back, finished before the landmark 01-11 13:00
    proc(1006, 60001, 200060, "2170-01-11 08:00", "2170-01-11 12:00", 225441, "Dialysis", 9003),
    # 00 O: "Dialysis Catheter" is an access line in for days and "CRRT Filter Change" a zero-length event; neither is dialysis
    proc(1002, 20001, 200010, "2160-05-10 17:00", "2160-05-13 09:00", 224270, "Access Lines - Invasive", 9004),
    proc(1002, 20001, 200010, "2160-05-12 02:00", "2160-05-12 02:00", 225436, "Dialysis", 9005),
])

# ---------------- microbiologyevents ----------------
# one row per organism / antibiotic tested, so a specimen is several rows (01 collapses to one per micro_specimen_id);
# the urine specimen has only a collection date (charttime NULL): usable at k=2 (05-12 16:00) by the date rule,
# not at k=1 (05-11 16:00), whose landmark falls on the collection day
_mid = [0]
def micro(subject_id, hadm_id, specimen_id, chartdate, charttime, spec_type, org=None, ab=None):
    _mid[0] += 1
    return dict(microevent_id=_mid[0], subject_id=subject_id, hadm_id=hadm_id, micro_specimen_id=specimen_id,
                order_provider_id="P001", chartdate=T(chartdate), charttime=T(charttime) if charttime else None,
                spec_itemid=70012, spec_type_desc=spec_type, test_seq=1, storedate=T(chartdate) + td(days=2),
                storetime=T(chartdate) + td(days=2), test_itemid=90039, test_name="Blood Culture, Routine" if "BLOOD" in spec_type else "URINE CULTURE",
                org_itemid=80002 if org else None, org_name=org, isolate_num=1 if org else None, quantity=None,
                ab_itemid=90004 if ab else None, ab_name=ab, dilution_text="<=0.5" if ab else None,
                dilution_comparison="<=" if ab else None, dilution_value=0.5 if ab else None,
                interpretation="S" if ab else None, comments=None)
microbiologyevents = pd.DataFrame([
    micro(1002, 20001, 7001, "2160-05-10 00:00", "2160-05-10 16:30", "BLOOD CULTURE", "STAPH AUREUS COAG +", "VANCOMYCIN"),
    micro(1002, 20001, 7001, "2160-05-10 00:00", "2160-05-10 16:30", "BLOOD CULTURE", "STAPH AUREUS COAG +", "OXACILLIN"),
    micro(1002, 20001, 7002, "2160-05-11 00:00", None, "URINE"),
    # the routine admission MRSA screen (00 P: 64,759 specimens): a screen, not a work-up; must not count at k=1
    micro(1002, 20001, 7005, "2160-05-10 00:00", "2160-05-10 16:45", "MRSA SCREEN"),
    micro(1005, 50002, 7003, "2158-09-03 00:00", "2158-09-03 08:00", "URINE"),                 # not an at-risk stay: never counted
    micro(1001, None, 7004, "2149-06-01 00:00", "2149-06-01 10:00", "SWAB"),                   # no hadm_id: outpatient, excluded
])

# ---------------- labs ----------------
d_labitems = pd.DataFrame([
    (50931, "Glucose", "Blood", "Chemistry"), (50809, "Glucose", "Blood", "Blood Gas"), (52569, "Glucose", "Blood", "Chemistry"),
    (50912, "Creatinine", "Blood", "Chemistry"), (51006, "Urea Nitrogen", "Blood", "Chemistry"), (50862, "Albumin", "Blood", "Chemistry"),
    (50983, "Sodium", "Blood", "Chemistry"), (50971, "Potassium", "Blood", "Chemistry"), (50882, "Bicarbonate", "Blood", "Chemistry"),
    (50813, "Lactate", "Blood", "Blood Gas"), (51301, "White Blood Cells", "Blood", "Hematology"), (51222, "Hemoglobin", "Blood", "Hematology"),
    (51221, "Hematocrit", "Blood", "Hematology"), (51265, "Platelet Count", "Blood", "Hematology"), (50878, "Asparate Aminotransferase (AST)", "Blood", "Chemistry"),
    (50861, "Alanine Aminotransferase (ALT)", "Blood", "Chemistry"), (50885, "Bilirubin, Total", "Blood", "Chemistry"), (51237, "INR(PT)", "Blood", "Hematology"),
    (50902, "Chloride", "Blood", "Chemistry"), (50868, "Anion Gap", "Blood", "Chemistry"), (50893, "Calcium, Total", "Blood", "Chemistry"),
    (50960, "Magnesium", "Blood", "Chemistry"), (50970, "Phosphate", "Blood", "Chemistry"), (50852, "% Hemoglobin A1c", "Blood", "Chemistry"),
], columns=["itemid", "label", "fluid", "category"])

lab_rows = []
_lid = [0]
def lab(subject_id, hadm_id, itemid, chart, value, store_minutes=30, uom="mg/dL"):
    _lid[0] += 1
    lab_rows.append(dict(labevent_id=_lid[0], subject_id=subject_id, hadm_id=hadm_id, specimen_id=_lid[0], itemid=itemid,
                         order_provider_id="P001", charttime=T(chart), storetime=T(chart) + td(minutes=store_minutes),
                         value=str(value), valuenum=float(value), valueuom=uom, ref_range_lower=None, ref_range_upper=None,
                         flag=None, priority="ROUTINE", comments=None))

# Patient 1 glucose stream (lab 50931); landmarks 03-02 10:00, 03-03 10:00, 03-04 10:00, 03-05 10:00
for chart, v in [("2150-03-01 09:00", 180), ("2150-03-02 06:00", 142), ("2150-03-03 06:00", 88),
                 ("2150-03-03 06:04", 92),      # a NORMAL value 4 min after a normal value: the rule before release .20
                                                # cancelled the 88 (it had no "low" condition); now nothing is cancelled
                 ("2150-03-02 14:03", 290),     # 3 min after the 320 fingerstick (chartevents, k=1's window): the old rule
                                                # cancelled the 320 and k=1 lost its > 300 label; now the 320 stands
                 ("2150-03-04 03:00", 48),      # < 54, window of k=2
                 ("2150-03-04 06:00", 110),
                 ("2150-03-05 06:00", 35),      # < 40 but...
                 ("2150-03-05 06:03", 95),      # ...a repeat > 80 within 5 min cancels it (CMS816's exclusion)
                 ("2150-03-06 06:00", 38),      # confirmed < 40 (CMS816 event), window of k=4
                 ("2150-03-07 06:00", 120)]:
    lab(1001, 10002, 50931, chart, v)
# the feature-side availability case (the review of 12 October 2026): a 45 at 09:50, stored at 09:52, ten minutes
# before t_3 (03-04 10:00), contradicted by a 100 at 09:54 that is stored only at 10:30. The label side cancels the
# 45 (k=2's window; k=2 still has the 48). The feature side at t_3 must KEEP the 45 as glucose_last: at 10:00 the
# clinician had seen a 45 and no repeat; the code before release .20 dropped it through the flag, which is
# look-ahead. The 100 itself is a straddling result for t_3 (charted before, stored after: Table 1b counts it).
lab(1001, 10002, 50931, "2150-03-04 09:50", 45, store_minutes=2)
lab(1001, 10002, 50931, "2150-03-04 09:54", 100, store_minutes=36)
# second review, case 5: a 50 at 09:59 (entered at once) and a repeat 100 CHARTED at 10:02, after t_4 (03-05 10:00),
# but ENTERED at 09:58. The repeat fails the both-times rule at t_4 (its charttime is after the landmark), so
# glucose_last at k = 4 is the 50; the 100 is a straddling value for t_4 (Table 1b) and k = 4's first label-window result
lab(1001, 10002, 50931, "2150-03-05 09:59", 50, store_minutes=0)
lab(1001, 10002, 50931, "2150-03-05 10:02", 100, store_minutes=-4)
# creatinine: the second draw is stored AFTER t_2 (03-03 10:00) -> must not be visible at k=2
lab(1001, 10002, 50912, "2150-03-02 06:00", 1.4, store_minutes=40)
lab(1001, 10002, 50912, "2150-03-03 09:30", 2.1, store_minutes=120)
lab(1001, 10002, 50862, "2150-03-02 06:00", 2.8, uom="g/dL")
lab(1001, 10002, 50971, "2150-03-02 06:00", 4.7, uom="mEq/L")
lab(1001, None,  50852, "2149-06-01 10:00", 7.8, uom="%")        # outpatient HbA1c, hadm_id NULL
# Patient 2: lab glucose duplicated into the ICU chart (220621) at the same time/value
lab(1002, 20001, 50931, "2160-05-10 15:00", 310)
lab(1002, 20001, 50912, "2160-05-10 15:00", 1.1)
lab(1002, 20001, 50971, "2160-05-10 15:00", 5.6, uom="mEq/L")
lab(1002, 20001, 50813, "2160-05-10 15:00", 3.2, uom="mmol/L")
# Patient 3: the 45 falls in the (14 h) window of k=1, which ends at death
lab(1003, 30001, 50931, "2155-07-02 03:00", 60)
lab(1003, 30001, 50931, "2155-07-02 20:00", 45)
lab(1003, 30001, 50912, "2155-07-01 11:00", 1.9)
# Patient 6
for chart, v in [("2170-01-11 06:00", 130), ("2170-01-12 06:00", 95), ("2170-01-15 06:00", 160)]:
    lab(1006, 60001, 50931, chart, v)
lab(1006, 60001, 50852, "2170-01-11 06:00", 9.1, uom="%")
# Patient 4 / 5 some labs
lab(1004, 40001, 50931, "2130-04-02 06:00", 45)
lab(1005, 50002, 50931, "2158-09-03 06:00", 120)
# second review, case 6, the boundaries of the repeat-result rule (01 table 18, band 40 - 53; no landmark row reads
# these, patient 5 has no at-risk row): a 45 contradicted by an 85 at exactly 300 s is flagged; a 44 with an 85 at
# 301 s is not; a 43 with an 80 (not above 80) at 60 s is not; a 42 with an 81 at 60 s is
lab(1005, 50002, 50931, "2158-09-03 14:00:00", 45); lab(1005, 50002, 50931, "2158-09-03 14:05:00", 85)
lab(1005, 50002, 50931, "2158-09-03 16:00:00", 44); lab(1005, 50002, 50931, "2158-09-03 16:05:01", 85)
lab(1005, 50002, 50931, "2158-09-03 18:00:00", 43); lab(1005, 50002, 50931, "2158-09-03 18:01:00", 80)
lab(1005, 50002, 50931, "2158-09-03 20:00:00", 42); lab(1005, 50002, 50931, "2158-09-03 20:01:00", 81)
labevents = pd.DataFrame(lab_rows)

# ---------------- diagnoses ----------------
d_icd_diagnoses = pd.DataFrame([
    ("E1122", 10, "Type 2 diabetes mellitus with diabetic chronic kidney disease"),
    ("N183", 10, "Chronic kidney disease, stage 3 unspecified"),
    ("I509", 10, "Heart failure, unspecified"),
    ("25000", 9, "Diabetes mellitus without mention of complication, type II or unspecified type, not stated as uncontrolled"),
    ("2510", 9, "Hypoglycemic coma"),
    ("E11649", 10, "Type 2 diabetes mellitus with hypoglycemia without coma"),
    ("I10", 10, "Essential (primary) hypertension"),
], columns=["icd_code", "icd_version", "long_title"])
diagnoses_icd = pd.DataFrame([
    (1001, 10001, 1, "E1122", 10), (1001, 10001, 2, "N183", 10), (1001, 10001, 3, "I509", 10),
    (1001, 10002, 1, "E11649", 10),      # CURRENT admission code: must never be used as history
    (1006, 60000, 1, "25000", 9), (1006, 60000, 2, "2510", 9), (1006, 60000, 3, "I10", 10),
    (1006, 60001, 1, "E11649", 10),
], columns=["subject_id", "hadm_id", "seq_num", "icd_code", "icd_version"])

# ---------------- transfers / services / omr ----------------
tr = []
_tid = [0]
def xfer(subject_id, hadm_id, eventtype, careunit, intime, outtime):
    _tid[0] += 1
    tr.append(dict(subject_id=subject_id, hadm_id=hadm_id, transfer_id=_tid[0], eventtype=eventtype, careunit=careunit,
                   intime=T(intime), outtime=T(outtime) if outtime else None))
xfer(1001, 10002, "ED", "Emergency Department", "2150-03-01 06:00", "2150-03-01 08:00")
xfer(1001, 10002, "admit", "Medicine", "2150-03-01 08:00", "2150-03-01 10:00")
xfer(1001, 10002, "transfer", "Medical Intensive Care Unit (MICU)", "2150-03-01 10:00", "2150-03-06 10:00")
xfer(1001, 10002, "transfer", "Medicine", "2150-03-06 10:00", "2150-03-08 12:00")
xfer(1001, 10002, "discharge", None, "2150-03-08 12:00", None)
xfer(1002, 20001, "ED", "Emergency Department", "2160-05-10 12:00", "2160-05-10 16:00")
xfer(1002, 20001, "admit", "Medical Intensive Care Unit (MICU)", "2160-05-10 16:00", "2160-05-13 10:00")
xfer(1002, 20001, "transfer", "Medicine", "2160-05-13 10:00", "2160-05-14 10:00")
xfer(1002, 20001, "discharge", None, "2160-05-14 10:00", None)
xfer(1003, 30001, "admit", "Medicine", "2155-07-01 10:00", "2155-07-01 12:00")
xfer(1003, 30001, "transfer", "Medical Intensive Care Unit (MICU)", "2155-07-01 12:00", "2155-07-03 02:00")
xfer(1003, 30001, "discharge", None, "2155-07-03 02:00", None)
xfer(1006, 60001, "admit", "Med/Surg", "2170-01-10 12:00", "2170-01-10 13:00")
xfer(1006, 60001, "transfer", "Cardiac Vascular Intensive Care Unit (CVICU)", "2170-01-10 13:00", "2170-01-12 13:00")
xfer(1006, 60001, "transfer", "Med/Surg", "2170-01-12 13:00", "2170-01-14 06:00")
xfer(1006, 60001, "transfer", "Cardiac Vascular Intensive Care Unit (CVICU)", "2170-01-14 06:00", "2170-01-16 06:00")
xfer(1006, 60001, "transfer", "Med/Surg", "2170-01-16 06:00", "2170-01-16 18:00")
xfer(1006, 60001, "discharge", None, "2170-01-16 18:00", None)
transfers = pd.DataFrame(tr)

services = pd.DataFrame([
    (1001, 10002, T("2150-03-01 08:00"), None, "MED"),
    (1002, 20001, T("2160-05-10 14:00"), None, "MED"),
    (1003, 30001, T("2155-07-01 10:00"), None, "MED"),
    (1006, 60001, T("2170-01-10 12:00"), None, "CSURG"),
    (1006, 60001, T("2170-01-14 15:00"), "CSURG", "MED"),
], columns=["subject_id", "hadm_id", "transfertime", "prev_service", "curr_service"])

omr = pd.DataFrame([
    (1001, dt(2150, 2, 1).date(), 1, "BMI (kg/m2)", "31.2"),
    (1001, dt(2150, 2, 1).date(), 2, "Weight (Lbs)", "180"),
    (1001, dt(2150, 2, 1).date(), 3, "Blood Pressure", "120/80"),
    (1001, dt(2150, 3, 5).date(), 1, "Weight (Lbs)", "176"),      # during the stay: only visible from k with DATE(t_k) > 03-05
    (1006, dt(2169, 12, 1).date(), 1, "BMI (kg/m2)", "27.0"),
    (1006, dt(2170, 1, 5).date(), 1, "BMI", "26.5"),            # the second spelling (00 H4), and the later date
    (1006, dt(2170, 1, 5).date(), 2, "Weight", "150"),          # pounds under the short name
], columns=["subject_id", "chartdate", "seq_num", "result_name", "result_value"])

# ---------------- chartevents ----------------
ce = []
def chart(subject_id, hadm_id, stay_id, chart_time, itemid, value, uom, store=None):
    ce.append(dict(subject_id=subject_id, hadm_id=hadm_id, stay_id=stay_id, caregiver_id=1, charttime=T(chart_time),
                   storetime=T(store) if store else T(chart_time) + td(minutes=5), itemid=itemid, value=str(value),
                   valuenum=float(value) if isinstance(value, (int, float)) else None,   # text items (CRRT mode) have no valuenum
                   valueuom=uom, warning=0))
# Patient 1 fingersticks (every 6 h, plus the > 300 in k=1's window), weight, GCS, vitals
for chart_time, v in [("2150-03-01 12:00", 190), ("2150-03-01 18:00", 170), ("2150-03-02 00:00", 150),
                      ("2150-03-02 14:00", 320),   # > 300 in the window of k=1
                      ("2150-03-02 20:00", 210), ("2150-03-03 14:00", 120), ("2150-03-03 20:00", 100),
                      ("2150-03-04 14:00", 130), ("2150-03-04 20:00", 140), ("2150-03-05 14:00", 150)]:
    chart(1001, 10002, 200011, chart_time, 225664, v, "mg/dL")
# a nominal time that trails the entry time: entered at 09:58, charted as 10:05, around t_1 = 10:00. Under a
# storetime-only rule this value entered k=1's feature row and the leakage assertion flagged it (the first real
# run found 948 such rows); under the both-times rule it is k=1's first label-window result and nothing more.
# 02 Table 1b must report it: glucose stream, 1 stored before its charttime, 7 minutes, 1 straddling landmark row.
chart(1001, 10002, 200011, "2150-03-02 10:05", 225664, 160, "mg/dL", store="2150-03-02 09:58")
chart(1001, 10002, 200011, "2150-03-01 10:30", 226512, 80, "kg")
chart(1001, 10002, 200011, "2150-03-03 05:00", 224639, 79, "kg")
for chart_time, e, v, m in [("2150-03-01 12:00", 4, 5, 6), ("2150-03-03 12:00", 3, 4, 6)]:
    chart(1001, 10002, 200011, chart_time, 220739, e, None)
    chart(1001, 10002, 200011, chart_time, 223900, v, None)
    chart(1001, 10002, 200011, chart_time, 223901, m, None)
for h in range(11, 24):
    chart(1001, 10002, 200011, f"2150-03-01 {h:02d}:00", 220045, 80, "bpm")
    chart(1001, 10002, 200011, f"2150-03-01 {h:02d}:00", 220179, 120, "mmHg")
# Patient 2: lab glucose duplicated into the chart, fingersticks, vitals, garbage
chart(1002, 20001, 200010, "2160-05-10 15:00", 220621, 310, "mg/dL")    # duplicate of the lab result
for chart_time, v in [("2160-05-10 17:00", 320), ("2160-05-11 00:00", 250), ("2160-05-11 06:00", 180),
                      ("2160-05-11 20:00", 52),    # < 54 in the window of k=1
                      ("2160-05-12 04:00", 90), ("2160-05-12 20:00", 110)]:
    chart(1002, 20001, 200010, chart_time, 225664, v, "mg/dL")
for h in range(16, 24):
    chart(1002, 20001, 200010, f"2160-05-10 {h:02d}:00", 220045, 90 + h, "bpm")
    chart(1002, 20001, 200010, f"2160-05-10 {h:02d}:00", 220179, 100 + h, "mmHg")
    chart(1002, 20001, 200010, f"2160-05-10 {h:02d}:00", 220210, 18, "insp/min")
    chart(1002, 20001, 200010, f"2160-05-10 {h:02d}:00", 220277, 95, "%")
chart(1002, 20001, 200010, "2160-05-11 08:00", 223761, 100.4, "°F")
chart(1002, 20001, 200010, "2160-05-10 16:10", 226512, 92, "kg")
# garbage that 00 section H2 showed is real: must be excluded by the bounds
chart(1002, 20001, 200010, "2160-05-11 16:30", 225664, 0, None)            # a 0 inside k=1's label window: not a < 40 event
chart(1002, 20001, 200010, "2160-05-11 17:00", 225664, 1653550, None)      # not a > 300 either
chart(1002, 20001, 200010, "2160-05-10 20:30", 220045, 10000000, "bpm")    # hr_mean must stay 109.5
chart(1002, 20001, 200010, "2160-05-10 20:30", 220277, -951234, "%")       # spo2_min must stay 95
# Patient 6: fingersticks in both stays (the 350 is > 300 in the window of stay 2, k=1)
for chart_time, v, stay in [("2170-01-11 06:00", 130, 200060), ("2170-01-11 18:00", 95, 200060), ("2170-01-12 06:00", 70, 200060),
                            ("2170-01-14 12:00", 180, 200061), ("2170-01-15 12:00", 350, 200061), ("2170-01-15 20:00", 220, 200061)]:
    chart(1006, 60001, stay, chart_time, 225664, v, "mg/dL")
# Patient 3 and 5 fingersticks
chart(1003, 30001, 200030, "2155-07-02 14:00", 225664, 70, "mg/dL")
chart(1005, 50002, 200051, "2158-09-03 12:00", 225664, 120, "mg/dL")
# ---- dialysis charting, the second RRT source (00 O, O2) ----
# Patient 6, second stay: CRRT settings charted hourly 01-14 22:00 to 01-15 08:00 with NO procedureevents interval
# -> one charting-only interval [22:00, 09:00] that covers the landmark 01-15 06:00 (8 h inside its look-back)
for h in list(range(22, 24)) + list(range(0, 9)):
    day = "2170-01-14" if h >= 22 else "2170-01-15"
    chart(1006, 60001, 200061, f"{day} {h:02d}:00", 227290, "CVVHDF", None)
    chart(1006, 60001, 200061, f"{day} {h:02d}:00", 224154, 1000, "mL/hour")
# Patient 2: CRRT settings charted inside the procedureevents CRRT interval (05-11 10:00 to 14:00): must merge into
# the same interval (source 'both'), so k=1 still shows 6.0 h, never 6 + 5
for h in range(10, 15):
    chart(1002, 20001, 200010, f"2160-05-11 {h:02d}:00", 224154, 1200, "mL/hour")
# Patient 6, first stay: the per-session hemodialysis output charted at the end of the 08:00-12:00 session (merges, 4.0 h stays)
chart(1006, 60001, 200060, "2170-01-11 12:00", 226499, 2500, "mL")
# Patient 1: a hemodialysis output with no interval at all, 03-03 09:00 -> k=2 gets rrt_24h = 1, ihd_24h = 1, ~0 hours
chart(1001, 10002, 200011, "2150-03-03 09:00", 226499, 1800, "mL")
chartevents = pd.DataFrame(ce)

# ---------------- write ----------------
import os
if os.path.exists(DB):
    os.remove(DB)
con = duckdb.connect(str(DB))
con.execute("CREATE SCHEMA mimiciv_3_1_hosp; CREATE SCHEMA mimiciv_3_1_icu;")
hosp = dict(patients=patients, admissions=admissions, emar=emar, emar_detail=emar_detail, labevents=labevents,
            d_labitems=d_labitems, diagnoses_icd=diagnoses_icd, d_icd_diagnoses=d_icd_diagnoses, transfers=transfers,
            services=services, omr=omr, microbiologyevents=microbiologyevents)
icu = dict(icustays=icustays, d_items=d_items, chartevents=chartevents, inputevents=inputevents, procedureevents=procedureevents)
for name, df in hosp.items():
    con.register("df_", df); con.execute(f"CREATE TABLE mimiciv_3_1_hosp.{name} AS SELECT * FROM df_"); con.unregister("df_")
for name, df in icu.items():
    con.register("df_", df); con.execute(f"CREATE TABLE mimiciv_3_1_icu.{name} AS SELECT * FROM df_"); con.unregister("df_")
for sch, tabs in (("mimiciv_3_1_hosp", hosp), ("mimiciv_3_1_icu", icu)):
    for name in tabs:
        n = con.execute(f"SELECT COUNT(*) FROM {sch}.{name}").fetchone()[0]
        print(f"{sch}.{name:16s} {n:4d} rows")
con.close()
print("wrote", DB)
