"""Independent check of the SQL results.

Everything in results/ was produced by MySQL. This script recomputes the
same figures a second way, from the raw CSV with pandas, and compares.
Two separate implementations agreeing is the evidence that the SQL does
what its comments say.

    python scripts/cross_check.py

Exits with status 1 if any figure disagrees.
"""
from __future__ import annotations

import sys
import zlib
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data" / "raw" / "diabetic_data.csv"
RESULTS = ROOT / "results"

DEATH_OR_HOSPICE = {11, 13, 14, 19, 20, 21}
DISCHARGE_GROUPS = {
    1: "Home",
    6: "Home with home health", 8: "Home with home health",
    3: "Skilled nursing or long-term care", 4: "Skilled nursing or long-term care",
    15: "Skilled nursing or long-term care", 23: "Skilled nursing or long-term care",
    24: "Skilled nursing or long-term care",
    22: "Rehabilitation facility",
    7: "Left against medical advice",
    2: "Transferred to another facility", 5: "Transferred to another facility",
    10: "Transferred to another facility", 27: "Transferred to another facility",
    28: "Transferred to another facility", 29: "Transferred to another facility",
    30: "Transferred to another facility",
}
ICD9_RANGES = [
    (140, 240, "Neoplasms"), (250, 251, "Diabetes"), (390, 460, "Circulatory"), (460, 520, "Respiratory"),
    (520, 580, "Digestive"), (580, 630, "Genitourinary"), (710, 740, "Musculoskeletal"), (785, 786, "Circulatory"),
    (786, 787, "Respiratory"), (787, 788, "Digestive"), (788, 789, "Genitourinary"), (800, 1000, "Injury"),
]

# Figures printed by the SQL scripts that are not saved in a results file.
SQL_PRINTED = {
    "AUC, held-out patients": 0.651,
    "AUC, training patients": 0.645,
    "Chi-square, HbA1c tested vs readmitted": 42.26,
    "Relative risk, HbA1c tested vs not": 0.851,
    "Mantel-Haenszel relative risk": 0.915,
    "Patients accounting for half of readmissions": 3148,
    "First-stay readmission rate (%)": 8.97,
}

checks: list[tuple[str, float, float]] = []


def record(name: str, sql_value: float, pandas_value: float) -> None:
    checks.append((name, float(sql_value), float(pandas_value)))


def diagnosis_group(code: str) -> str:
    if code == "?":
        return "Unknown"
    if not code[0].isdigit():
        return "Other"
    value = float(code)
    for low, high, group in ICD9_RANGES:
        if low <= value < high:
            return group
    return "Other"


def auc(scores: pd.Series, outcome: pd.Series) -> float:
    ranks = scores.rank(method="average")
    n1, n0 = outcome.sum(), (1 - outcome).sum()
    return (ranks[outcome == 1].sum() - n1 * (n1 + 1) / 2) / (n1 * n0)


def main() -> None:
    df = pd.read_csv(RAW, dtype=str, keep_default_na=False)
    for column in ["encounter_id", "discharge_disposition_id", "number_inpatient", "number_emergency",
                   "number_diagnoses", "time_in_hospital"]:
        df[column] = df[column].astype("int64")
    df = df.sort_values(["patient_nbr", "encounter_id"])
    df["encounter_seq"] = df.groupby("patient_nbr").cumcount() + 1

    cohort = df[~df.discharge_disposition_id.isin(DEATH_OR_HOSPICE)].copy()
    cohort["y"] = (cohort.readmitted == "<30").astype(int)
    cohort["discharge_group"] = cohort.discharge_disposition_id.map(DISCHARGE_GROUPS).fillna("Other or unknown")
    cohort["diagnosis_group"] = cohort.diag_1.map(diagnosis_group)
    cohort["tested"] = (cohort.A1Cresult != "None").astype(int)
    cohort["training"] = cohort.patient_nbr.map(lambda p: zlib.crc32(p.encode()) % 10 < 7)

    # ---- headline ----
    headline = pd.read_csv(RESULTS / "rpt_headline.csv").iloc[0]
    record("Index stays", headline.index_stays, len(cohort))
    record("Patients", headline.patients, cohort.patient_nbr.nunique())
    record("Readmitted within 30 days", headline.readmitted_within_30_days, cohort.y.sum())
    record("Readmission rate (%)", headline.readmission_rate_pct, round(100 * cohort.y.mean(), 2))
    record("Readmitted at any time (%)", headline.readmitted_any_time_pct, round(100 * (cohort.readmitted != "NO").mean(), 2))
    first = cohort[cohort.encounter_seq == 1]
    record("First-stay readmission rate (%)", SQL_PRINTED["First-stay readmission rate (%)"], round(100 * first.y.mean(), 2))

    # ---- segments ----
    segments = pd.read_csv(RESULTS / "rpt_segment_rates.csv", dtype={"segment": str})
    inpatient = cohort.assign(k=cohort.number_inpatient.clip(upper=5).map(lambda v: "5 or more" if v == 5 else str(v)))
    for dimension, frame, key in [
        ("Prior inpatient stays (past year)", inpatient, "k"),
        ("Discharge destination", cohort, "discharge_group"),
        ("Primary diagnosis", cohort, "diagnosis_group"),
    ]:
        mine = frame.groupby(key).y.agg(["size", "sum"])
        for _, row in segments[segments.dimension == dimension].iterrows():
            record(f"{dimension} = {row.segment}: stays", row.stays, mine.loc[row.segment, "size"])
            record(f"{dimension} = {row.segment}: readmissions", row.readmissions, mine.loc[row.segment, "sum"])

    # ---- concentration ----
    per_patient = cohort.groupby("patient_nbr").y.agg(stays="size", readmissions="sum")
    ordered = per_patient.readmissions.sort_values(ascending=False).cumsum()
    needed = int((ordered >= 0.5 * per_patient.readmissions.sum()).values.argmax()) + 1
    record("Patients accounting for half of readmissions", SQL_PRINTED["Patients accounting for half of readmissions"], needed)

    # ---- HbA1c ----
    hba1c = pd.read_csv(RESULTS / "rpt_hba1c_by_diagnosis.csv")
    tested_by_group = cohort.groupby("diagnosis_group").tested.sum()
    for _, row in hba1c.iterrows():
        record(f"HbA1c tested, {row.primary_diagnosis_group}", row.stays_tested, tested_by_group[row.primary_diagnosis_group])
    n1, r1 = cohort.tested.sum(), cohort[cohort.tested == 1].y.sum()
    n0, r0 = (1 - cohort.tested).sum(), cohort[cohort.tested == 0].y.sum()
    record("Relative risk, HbA1c tested vs not", SQL_PRINTED["Relative risk, HbA1c tested vs not"], round((r1 / n1) / (r0 / n0), 3))
    observed = pd.crosstab(cohort.tested, cohort.y)
    expected = observed.sum(axis=1).values.reshape(-1, 1) * observed.sum(axis=0).values.reshape(1, -1) / observed.values.sum()
    chi_square = ((observed.values - expected) ** 2 / expected).sum()
    record("Chi-square, HbA1c tested vs readmitted", SQL_PRINTED["Chi-square, HbA1c tested vs readmitted"], round(chi_square, 2))
    strata = cohort.assign(band=cohort.number_inpatient.clip(upper=2)).groupby(["diagnosis_group", "band"])
    numerator = denominator = 0.0
    for _, part in strata:
        s_n1, s_n0 = part.tested.sum(), (1 - part.tested).sum()
        if s_n1 == 0 or s_n0 == 0:
            continue
        numerator += part[part.tested == 1].y.sum() * s_n0 / len(part)
        denominator += part[part.tested == 0].y.sum() * s_n1 / len(part)
    record("Mantel-Haenszel relative risk", SQL_PRINTED["Mantel-Haenszel relative risk"], round(numerator / denominator, 3))

    # ---- risk score ----
    points = (
        cohort.number_inpatient.map(lambda v: 4 if v >= 5 else 3 if v >= 3 else v)
        + (cohort.number_emergency >= 2).astype(int)
        + cohort.discharge_group.map(lambda g: {"Home": 0, "Rehabilitation facility": 3, "Transferred to another facility": 2}.get(g, 1))
        + (cohort.number_diagnoses >= 6).astype(int)
        + (cohort.time_in_hospital >= 5).astype(int)
    )
    cohort["score"] = points
    cohort["tier"] = pd.cut(cohort.score, [-1, 1, 3, 5, 99], labels=["Low", "Moderate", "High", "Very high"]).astype(str)
    held_out = cohort[~cohort.training]
    tiers = pd.read_csv(RESULTS / "rpt_risk_tiers.csv")
    mine = held_out.groupby("tier").y.agg(["size", "sum"])
    for _, row in tiers.iterrows():
        record(f"Tier {row.risk_tier}: held-out stays", row.stays, mine.loc[row.risk_tier, "size"])
        record(f"Tier {row.risk_tier}: held-out readmissions", row.readmissions, mine.loc[row.risk_tier, "sum"])
    record("AUC, held-out patients", SQL_PRINTED["AUC, held-out patients"], round(auc(held_out.score, held_out.y), 3))
    trained = cohort[cohort.training]
    record("AUC, training patients", SQL_PRINTED["AUC, training patients"], round(auc(trained.score, trained.y), 3))

    # ---- report ----
    failures = 0
    width = max(len(name) for name, _, _ in checks)
    print(f"{'Figure':<{width}}  {'MySQL':>12}  {'pandas':>12}")
    for name, sql_value, pandas_value in checks:
        agrees = abs(sql_value - pandas_value) < 1e-9
        failures += not agrees
        print(f"{name:<{width}}  {sql_value:>12g}  {pandas_value:>12g}  {'ok' if agrees else 'MISMATCH'}")
    print(f"\n{len(checks) - failures} of {len(checks)} figures agree.")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
