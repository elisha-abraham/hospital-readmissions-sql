-- =====================================================================
-- 03_data_quality_audit.sql : what is wrong with the raw data?
--
-- Runs against the staging table, before anything is cleaned. Each
-- check states the question, and the finding recorded under it is what
-- the query returned on the full file. The findings drive the cleaning
-- rules in 04_build_clean_model.sql.
-- =====================================================================

USE readmissions;

-- ---------------------------------------------------------------------
-- A1. Is there one row per hospital stay?
-- Finding: 101,766 rows, 101,766 distinct encounter_id, 71,518 patients.
--          encounter_id is a valid primary key. Patients repeat, so
--          the grain is the stay, not the patient.
-- ---------------------------------------------------------------------
SELECT COUNT(*)                     AS row_count,
       COUNT(DISTINCT encounter_id) AS distinct_encounters,
       COUNT(DISTINCT patient_nbr)  AS distinct_patients
FROM stg_encounters;

-- ---------------------------------------------------------------------
-- A2. How much is missing, and how is "missing" written?
-- The file has no empty cells. Missing values hide behind markers:
-- '?' in most columns, 'Unknown/Invalid' in gender, 'None' in the two
-- lab-result columns.
-- Finding: weight is missing for 96.9% of stays, medical_specialty for
--          49.1%, payer_code for 39.6%, race for 2.2%. The diagnosis
--          columns are almost complete. 'None' in a1c_result (83.3%)
--          and max_glu_serum (94.7%) means the test was not ordered.
-- ---------------------------------------------------------------------
SELECT 'weight'            AS column_name, '?' AS marker, SUM(weight = '?')            AS marked_rows, ROUND(100 * AVG(weight = '?'), 1)            AS pct_of_rows FROM stg_encounters
UNION ALL
SELECT 'medical_specialty', '?',               SUM(medical_specialty = '?'), ROUND(100 * AVG(medical_specialty = '?'), 1) FROM stg_encounters
UNION ALL
SELECT 'payer_code',        '?',               SUM(payer_code = '?'),        ROUND(100 * AVG(payer_code = '?'), 1)        FROM stg_encounters
UNION ALL
SELECT 'race',              '?',               SUM(race = '?'),              ROUND(100 * AVG(race = '?'), 1)              FROM stg_encounters
UNION ALL
SELECT 'diag_1',            '?',               SUM(diag_1 = '?'),            ROUND(100 * AVG(diag_1 = '?'), 2)            FROM stg_encounters
UNION ALL
SELECT 'diag_2',            '?',               SUM(diag_2 = '?'),            ROUND(100 * AVG(diag_2 = '?'), 2)            FROM stg_encounters
UNION ALL
SELECT 'diag_3',            '?',               SUM(diag_3 = '?'),            ROUND(100 * AVG(diag_3 = '?'), 2)            FROM stg_encounters
UNION ALL
SELECT 'gender',            'Unknown/Invalid', SUM(gender = 'Unknown/Invalid'), ROUND(100 * AVG(gender = 'Unknown/Invalid'), 3) FROM stg_encounters
UNION ALL
SELECT 'a1c_result',        'None',            SUM(a1c_result = 'None'),     ROUND(100 * AVG(a1c_result = 'None'), 1)     FROM stg_encounters
UNION ALL
SELECT 'max_glu_serum',     'None',            SUM(max_glu_serum = 'None'),  ROUND(100 * AVG(max_glu_serum = 'None'), 1)  FROM stg_encounters
ORDER BY pct_of_rows DESC;

-- ---------------------------------------------------------------------
-- A3. Do the columns that should be numbers contain only numbers, and
--     are they inside the ranges the documentation gives?
-- Finding: every count is zero, so all eleven columns cast safely.
--          Length of stay runs from 1 to 14 days, as documented.
-- ---------------------------------------------------------------------
SELECT SUM(encounter_id       NOT REGEXP '^[0-9]+$') AS bad_encounter_id,
       SUM(patient_nbr        NOT REGEXP '^[0-9]+$') AS bad_patient_nbr,
       SUM(time_in_hospital   NOT REGEXP '^[0-9]+$') AS bad_time_in_hospital,
       SUM(num_lab_procedures NOT REGEXP '^[0-9]+$') AS bad_num_lab_procedures,
       SUM(num_procedures     NOT REGEXP '^[0-9]+$') AS bad_num_procedures,
       SUM(num_medications    NOT REGEXP '^[0-9]+$') AS bad_num_medications,
       SUM(number_outpatient  NOT REGEXP '^[0-9]+$') AS bad_number_outpatient,
       SUM(number_emergency   NOT REGEXP '^[0-9]+$') AS bad_number_emergency,
       SUM(number_inpatient   NOT REGEXP '^[0-9]+$') AS bad_number_inpatient,
       SUM(number_diagnoses   NOT REGEXP '^[0-9]+$') AS bad_number_diagnoses,
       SUM(admission_type_id  NOT REGEXP '^[0-9]+$') AS bad_admission_type_id
FROM stg_encounters;

SELECT MIN(CAST(time_in_hospital AS UNSIGNED)) AS min_stay_days,
       MAX(CAST(time_in_hospital AS UNSIGNED)) AS max_stay_days,
       MAX(CAST(num_medications AS UNSIGNED))  AS max_medications,
       MAX(CAST(number_inpatient AS UNSIGNED)) AS max_prior_inpatient,
       MAX(CAST(number_emergency AS UNSIGNED)) AS max_prior_emergency,
       MAX(CAST(number_diagnoses AS UNSIGNED)) AS max_diagnoses
FROM stg_encounters;

-- ---------------------------------------------------------------------
-- A4. Do the categorical columns hold only the documented values?
-- Finding: yes. readmitted has exactly '<30', '>30' and 'NO'; age has
--          ten 10-year bands; no stray spellings or mixed case.
-- ---------------------------------------------------------------------
SELECT 'readmitted'   AS column_name, readmitted   AS value, COUNT(*) AS row_count FROM stg_encounters GROUP BY readmitted
UNION ALL
SELECT 'gender',        gender,        COUNT(*) FROM stg_encounters GROUP BY gender
UNION ALL
SELECT 'age',           age,           COUNT(*) FROM stg_encounters GROUP BY age
UNION ALL
SELECT 'a1c_result',    a1c_result,    COUNT(*) FROM stg_encounters GROUP BY a1c_result
UNION ALL
SELECT 'max_glu_serum', max_glu_serum, COUNT(*) FROM stg_encounters GROUP BY max_glu_serum
UNION ALL
SELECT 'med_change',    med_change,    COUNT(*) FROM stg_encounters GROUP BY med_change
UNION ALL
SELECT 'diabetes_med',  diabetes_med,  COUNT(*) FROM stg_encounters GROUP BY diabetes_med
ORDER BY column_name, row_count DESC;

-- ---------------------------------------------------------------------
-- A5. Does every code in the data exist in its lookup table?
-- Finding: no orphans. Every admission type, discharge disposition and
--          admission source code has a description.
-- ---------------------------------------------------------------------
SELECT 'admission_type_id' AS code_column, s.admission_type_id AS code, COUNT(*) AS row_count
FROM stg_encounters s
LEFT JOIN admission_types t ON t.admission_type_id = CAST(s.admission_type_id AS UNSIGNED)
WHERE t.admission_type_id IS NULL
GROUP BY s.admission_type_id
UNION ALL
SELECT 'discharge_disposition_id', s.discharge_disposition_id, COUNT(*)
FROM stg_encounters s
LEFT JOIN discharge_dispositions d ON d.discharge_disposition_id = CAST(s.discharge_disposition_id AS UNSIGNED)
WHERE d.discharge_disposition_id IS NULL
GROUP BY s.discharge_disposition_id
UNION ALL
SELECT 'admission_source_id', s.admission_source_id, COUNT(*)
FROM stg_encounters s
LEFT JOIN admission_sources a ON a.admission_source_id = CAST(s.admission_source_id AS UNSIGNED)
WHERE a.admission_source_id IS NULL
GROUP BY s.admission_source_id;

-- ---------------------------------------------------------------------
-- A6. Is a patient described the same way on every stay?
-- Finding: 123 patients have more than one recorded race and 3 have
--          more than one recorded gender. That is 0.2% of patients:
--          too few to matter for rates, but enough to break a naive
--          "one row per patient" join, so script 04 resolves them.
-- ---------------------------------------------------------------------
SELECT SUM(race_values > 1)   AS patients_with_conflicting_race,
       SUM(gender_values > 1) AS patients_with_conflicting_gender
FROM (
    SELECT patient_nbr,
           COUNT(DISTINCT NULLIF(race, '?'))                                        AS race_values,
           COUNT(DISTINCT CASE WHEN gender IN ('Female', 'Male') THEN gender END)   AS gender_values
    FROM stg_encounters
    GROUP BY patient_nbr
) per_patient;

-- ---------------------------------------------------------------------
-- A7. The file has no dates. Can encounter_id stand in for time order?
-- Logic: if a patient has a later stay in the file, the earlier stay
-- was followed by a return to hospital, so it should not be marked
-- 'NO' (not readmitted). Each earlier stay marked 'NO' is evidence
-- that encounter_id order is not time order.
-- Finding: 30,248 stays have a later stay by the same patient. Only
--          490 of them (1.62%) are marked 'NO'. encounter_id order
--          agrees with the readmission flags 98.4% of the time, so it
--          is used to sequence stays, and the limit is stated wherever
--          sequence matters.
-- ---------------------------------------------------------------------
WITH ordered AS (
    SELECT patient_nbr,
           readmitted,
           ROW_NUMBER() OVER (PARTITION BY patient_nbr ORDER BY CAST(encounter_id AS UNSIGNED)) AS stay_number,
           COUNT(*)     OVER (PARTITION BY patient_nbr)                                         AS stays_for_patient
    FROM stg_encounters
)
SELECT COUNT(*)                                AS stays_with_a_later_stay,
       SUM(readmitted = 'NO')                  AS marked_not_readmitted,
       ROUND(100 * AVG(readmitted = 'NO'), 2)  AS pct_inconsistent
FROM ordered
WHERE stay_number < stays_for_patient;

-- ---------------------------------------------------------------------
-- A8. Which stays can never be followed by a readmission?
-- Finding: 2,423 stays ended in death (1,652) or discharge to hospice
--          (771). None of the deaths is flagged as readmitted, which
--          is a reassuring consistency check. 86 hospice discharges
--          are flagged: hospice patients can return to hospital, but
--          they are an end-of-life population with different goals of
--          care. All 2,423 are excluded from the analysis cohort, as
--          in the study that published the data.
-- ---------------------------------------------------------------------
SELECT d.description,
       COUNT(*)                     AS stays,
       SUM(s.readmitted <> 'NO')    AS flagged_as_readmitted
FROM stg_encounters s
JOIN discharge_dispositions d ON d.discharge_disposition_id = CAST(s.discharge_disposition_id AS UNSIGNED)
WHERE d.is_death_or_hospice = TRUE
GROUP BY d.description
ORDER BY stays DESC;

-- ---------------------------------------------------------------------
-- A9. Are any medication columns empty?
-- Finding: examide and citoglipton were never given in 101,766 stays,
--          and five other drugs appear on fewer than five stays. They
--          carry no information; the long medication table built in
--          script 04 simply has no rows for them.
-- ---------------------------------------------------------------------
SELECT SUM(examide <> 'No')                  AS examide_given,
       SUM(citoglipton <> 'No')              AS citoglipton_given,
       SUM(acetohexamide <> 'No')            AS acetohexamide_given,
       SUM(troglitazone <> 'No')             AS troglitazone_given,
       SUM(glimepiride_pioglitazone <> 'No') AS glimepiride_pioglitazone_given,
       SUM(metformin_rosiglitazone <> 'No')  AS metformin_rosiglitazone_given,
       SUM(metformin_pioglitazone <> 'No')   AS metformin_pioglitazone_given,
       SUM(insulin <> 'No')                  AS insulin_given,
       SUM(metformin <> 'No')                AS metformin_given
FROM stg_encounters;
