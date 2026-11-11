# Data notes

## Source

`raw/diabetic_data.csv` and `raw/IDS_mapping.csv` are the unmodified files from the UCI Machine Learning Repository:

Clore, J., Cios, K., DeShazo, J., & Strack, B. (2014). *Diabetes 130-US Hospitals for Years 1999-2008* [Dataset]. https://doi.org/10.24432/C5230J. Licence: CC BY 4.0.

The records come from the Health Facts database: ten years of inpatient care at 130 US hospitals and delivery networks. A stay is in the file if it was an inpatient admission, diabetes was recorded as a diagnosis, the stay lasted 1 to 14 days, and laboratory tests and medications were recorded. The data are de-identified; there are no names, dates or hospital identifiers.

SHA-256 of the downloaded archive: `F82AC129DA2DDD2299391FF6FBAE3A6A58B3EDCF59AC9D7BD480C00FE453112A`

## Raw file at a glance

| | |
|---|---|
| Rows | 101,766 hospital stays |
| Patients | 71,518 |
| Columns | 50 |
| Missing-value markers | `?`, `None` (lab columns), `Unknown/Invalid` (gender) |
| Outcome | `readmitted`: `<30`, `>30` or `NO` |

## Clean model

Built by `sql/04_build_clean_model.sql`.

### `patients`: one row per patient

| Column | Meaning |
|---|---|
| `patient_nbr` | Patient identifier (primary key) |
| `race`, `gender` | Most frequent recorded value across the patient's stays; NULL if never recorded |
| `encounter_count` | Stays in the file |
| `demographics_conflict` | TRUE if the source recorded more than one race or gender |

### `encounters`: one row per hospital stay

| Column | Meaning |
|---|---|
| `encounter_id` | Stay identifier (primary key) |
| `patient_nbr` | Patient (foreign key) |
| `encounter_seq` | Position of the stay among the patient's stays, by `encounter_id` |
| `age_band`, `age_lower` | Ten-year age band and its lower bound |
| `admission_type_id`, `discharge_disposition_id`, `admission_source_id` | Codes; descriptions and groups are in the lookup tables |
| `time_in_hospital` | Length of stay in days (1 to 14) |
| `num_lab_procedures`, `num_procedures`, `num_medications` | Counts during the stay |
| `number_outpatient`, `number_emergency`, `number_inpatient` | Visits in the year before the stay |
| `diag_1`, `diag_2`, `diag_3` | ICD-9 diagnosis codes; `diag_1` is the primary diagnosis |
| `primary_diagnosis_group` | `diag_1` rolled up into nine groups, plus `Unknown` |
| `number_diagnoses` | Diagnoses recorded |
| `max_glu_serum` | Glucose serum test: `Not measured`, `Normal`, `>200`, `>300` |
| `a1c_result` | HbA1c: `Not measured`, `Normal` (under 7%), `>7` (7 to 8%), `>8` |
| `a1c_measured` | TRUE if an HbA1c result was recorded during the stay |
| `med_changed` | TRUE if any diabetes medication was changed |
| `on_diabetes_med` | TRUE if any diabetes medication was prescribed |
| `readmitted` | `<30`, `>30` or `NO` |
| `readmitted_30d` | TRUE if readmitted within 30 days |

### `encounter_medications`: one row per diabetes drug given during a stay

| Column | Meaning |
|---|---|
| `encounter_id` | Stay (foreign key) |
| `medication` | Drug name |
| `dose_change` | `Steady`, `Up` or `Down` |

### Lookup tables

`admission_types`, `discharge_dispositions` and `admission_sources` keep the source wording in `description` and add a grouping column. `discharge_dispositions.is_death_or_hospice` marks the stays excluded from the analysis. `icd9_groups` holds the code ranges for the diagnosis groups.

### Views

| View | Rows | Purpose |
|---|---|---|
| `v_index_stays` | 99,343 | The analysis cohort: stays that ended with the patient alive and not in hospice |
| `v_risk_scores` | 99,343 | Points, score, tier and the training / held-out flag for each index stay |
| `rpt_*` | | Result tables exported to `results/` |
