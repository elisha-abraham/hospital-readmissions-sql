-- =====================================================================
-- 04_build_clean_model.sql : build typed tables from the staging table
--
-- Every cleaning rule applied here was justified by a check in
-- 03_data_quality_audit.sql. The script is re-runnable: it empties the
-- clean tables and rebuilds them from staging.
--
-- Cleaning decisions
--   1. '?' means missing in this file. It becomes NULL.
--   2. weight is dropped: it is missing for 96.9% of stays.
--   3. payer_code (39.6% missing) and medical_specialty (49.1% missing)
--      are kept but left NULL where missing; they are not used for
--      conclusions.
--   4. A patient with more than one recorded race or gender gets the
--      value recorded most often, and is flagged.
--   5. 'None' in the two lab-result columns means the test was not
--      done, which is information, not missing data. It is relabelled
--      'Not measured' and a1c_measured is added as a flag.
--   6. Primary diagnosis codes are rolled up into nine groups.
--   7. The 23 one-column-per-drug fields are unpivoted into one row
--      per drug actually given.
-- =====================================================================

USE readmissions;

SET FOREIGN_KEY_CHECKS = 0;
TRUNCATE TABLE encounter_medications;
TRUNCATE TABLE encounters;
TRUNCATE TABLE patients;
SET FOREIGN_KEY_CHECKS = 1;

-- ---------------------------------------------------------------------
-- 1. Patients
--    The source repeats race and gender on every stay, and for a few
--    patients the values disagree between stays. Each patient gets the
--    value seen on most of their stays; ties go to the earliest stay.
-- ---------------------------------------------------------------------
INSERT INTO patients (patient_nbr, race, gender, encounter_count, demographics_conflict)
WITH race_votes AS (
    SELECT patient_nbr,
           race,
           ROW_NUMBER() OVER (PARTITION BY patient_nbr
                              ORDER BY COUNT(*) DESC, MIN(CAST(encounter_id AS UNSIGNED))) AS pick
    FROM stg_encounters
    WHERE race <> '?'
    GROUP BY patient_nbr, race
),
gender_votes AS (
    SELECT patient_nbr,
           gender,
           ROW_NUMBER() OVER (PARTITION BY patient_nbr
                              ORDER BY COUNT(*) DESC, MIN(CAST(encounter_id AS UNSIGNED))) AS pick
    FROM stg_encounters
    WHERE gender IN ('Female', 'Male')
    GROUP BY patient_nbr, gender
),
per_patient AS (
    SELECT patient_nbr,
           COUNT(*) AS encounter_count,
           (COUNT(DISTINCT NULLIF(race, '?')) > 1
            OR COUNT(DISTINCT CASE WHEN gender IN ('Female', 'Male') THEN gender END) > 1) AS demographics_conflict
    FROM stg_encounters
    GROUP BY patient_nbr
)
SELECT CAST(p.patient_nbr AS UNSIGNED),
       r.race,
       g.gender,
       p.encounter_count,
       p.demographics_conflict
FROM per_patient p
LEFT JOIN race_votes   r ON r.patient_nbr = p.patient_nbr AND r.pick = 1
LEFT JOIN gender_votes g ON g.patient_nbr = p.patient_nbr AND g.pick = 1;

-- ---------------------------------------------------------------------
-- 2. Encounters (hospital stays)
--    encounter_seq numbers each patient's stays in encounter_id order.
--    The file has no dates, so encounter_id is the only ordering
--    available; audit check A6 shows how far it can be trusted.
-- ---------------------------------------------------------------------
INSERT INTO encounters (
    encounter_id, patient_nbr, encounter_seq, age_band, age_lower,
    admission_type_id, discharge_disposition_id, admission_source_id, time_in_hospital,
    payer_code, medical_specialty, num_lab_procedures, num_procedures, num_medications,
    number_outpatient, number_emergency, number_inpatient,
    diag_1, diag_2, diag_3, primary_diagnosis_group, number_diagnoses,
    max_glu_serum, a1c_result, a1c_measured, med_changed, on_diabetes_med,
    readmitted, readmitted_30d
)
WITH typed AS (
    SELECT CAST(encounter_id AS UNSIGNED)                                  AS encounter_id,
           CAST(patient_nbr AS UNSIGNED)                                   AS patient_nbr,
           age                                                             AS age_band,
           -- '[70-80)' -> 70
           CAST(SUBSTRING(age, 2, LOCATE('-', age) - 2) AS UNSIGNED)       AS age_lower,
           CAST(admission_type_id AS UNSIGNED)                             AS admission_type_id,
           CAST(discharge_disposition_id AS UNSIGNED)                      AS discharge_disposition_id,
           CAST(admission_source_id AS UNSIGNED)                           AS admission_source_id,
           CAST(time_in_hospital AS UNSIGNED)                              AS time_in_hospital,
           NULLIF(payer_code, '?')                                         AS payer_code,
           NULLIF(medical_specialty, '?')                                  AS medical_specialty,
           CAST(num_lab_procedures AS UNSIGNED)                            AS num_lab_procedures,
           CAST(num_procedures AS UNSIGNED)                                AS num_procedures,
           CAST(num_medications AS UNSIGNED)                               AS num_medications,
           CAST(number_outpatient AS UNSIGNED)                             AS number_outpatient,
           CAST(number_emergency AS UNSIGNED)                              AS number_emergency,
           CAST(number_inpatient AS UNSIGNED)                              AS number_inpatient,
           NULLIF(diag_1, '?')                                             AS diag_1,
           NULLIF(diag_2, '?')                                             AS diag_2,
           NULLIF(diag_3, '?')                                             AS diag_3,
           -- Numeric form of the primary diagnosis for the range join.
           -- V and E codes are not numeric and stay NULL here.
           CASE WHEN diag_1 REGEXP '^[0-9]' THEN CAST(diag_1 AS DECIMAL(6,2)) END AS diag_1_num,
           CAST(number_diagnoses AS UNSIGNED)                              AS number_diagnoses,
           CASE max_glu_serum WHEN 'None' THEN 'Not measured' WHEN 'Norm' THEN 'Normal' ELSE max_glu_serum END AS max_glu_serum,
           CASE a1c_result    WHEN 'None' THEN 'Not measured' WHEN 'Norm' THEN 'Normal' ELSE a1c_result    END AS a1c_result,
           (a1c_result <> 'None')                                          AS a1c_measured,
           (med_change = 'Ch')                                             AS med_changed,
           (diabetes_med = 'Yes')                                          AS on_diabetes_med,
           readmitted
    FROM stg_encounters
)
SELECT t.encounter_id,
       t.patient_nbr,
       ROW_NUMBER() OVER (PARTITION BY t.patient_nbr ORDER BY t.encounter_id) AS encounter_seq,
       t.age_band,
       t.age_lower,
       t.admission_type_id,
       t.discharge_disposition_id,
       t.admission_source_id,
       t.time_in_hospital,
       t.payer_code,
       t.medical_specialty,
       t.num_lab_procedures,
       t.num_procedures,
       t.num_medications,
       t.number_outpatient,
       t.number_emergency,
       t.number_inpatient,
       t.diag_1,
       t.diag_2,
       t.diag_3,
       CASE WHEN t.diag_1 IS NULL THEN 'Unknown'
            ELSE COALESCE(g.diagnosis_group, 'Other')
       END                                                                 AS primary_diagnosis_group,
       t.number_diagnoses,
       t.max_glu_serum,
       t.a1c_result,
       t.a1c_measured,
       t.med_changed,
       t.on_diabetes_med,
       t.readmitted,
       (t.readmitted = '<30')                                              AS readmitted_30d
FROM typed t
LEFT JOIN icd9_groups g
       ON t.diag_1_num >= g.code_from
      AND t.diag_1_num <  g.code_to;

-- ---------------------------------------------------------------------
-- 3. Medications: unpivot 23 wide columns into one row per drug given.
--    The source stores 'No', 'Steady', 'Up' or 'Down' for each drug on
--    each stay. 'No' rows are not kept: a missing row means not given.
--    This turns "which drugs was this patient on?" into a simple join
--    instead of 23 column comparisons.
-- ---------------------------------------------------------------------
INSERT INTO encounter_medications (encounter_id, medication, dose_change)
SELECT CAST(encounter_id AS UNSIGNED), 'metformin',                metformin                FROM stg_encounters WHERE metformin                <> 'No' UNION ALL
SELECT CAST(encounter_id AS UNSIGNED), 'repaglinide',              repaglinide              FROM stg_encounters WHERE repaglinide              <> 'No' UNION ALL
SELECT CAST(encounter_id AS UNSIGNED), 'nateglinide',              nateglinide              FROM stg_encounters WHERE nateglinide              <> 'No' UNION ALL
SELECT CAST(encounter_id AS UNSIGNED), 'chlorpropamide',           chlorpropamide           FROM stg_encounters WHERE chlorpropamide           <> 'No' UNION ALL
SELECT CAST(encounter_id AS UNSIGNED), 'glimepiride',              glimepiride              FROM stg_encounters WHERE glimepiride              <> 'No' UNION ALL
SELECT CAST(encounter_id AS UNSIGNED), 'acetohexamide',            acetohexamide            FROM stg_encounters WHERE acetohexamide            <> 'No' UNION ALL
SELECT CAST(encounter_id AS UNSIGNED), 'glipizide',                glipizide                FROM stg_encounters WHERE glipizide                <> 'No' UNION ALL
SELECT CAST(encounter_id AS UNSIGNED), 'glyburide',                glyburide                FROM stg_encounters WHERE glyburide                <> 'No' UNION ALL
SELECT CAST(encounter_id AS UNSIGNED), 'tolbutamide',              tolbutamide              FROM stg_encounters WHERE tolbutamide              <> 'No' UNION ALL
SELECT CAST(encounter_id AS UNSIGNED), 'pioglitazone',             pioglitazone             FROM stg_encounters WHERE pioglitazone             <> 'No' UNION ALL
SELECT CAST(encounter_id AS UNSIGNED), 'rosiglitazone',            rosiglitazone            FROM stg_encounters WHERE rosiglitazone            <> 'No' UNION ALL
SELECT CAST(encounter_id AS UNSIGNED), 'acarbose',                 acarbose                 FROM stg_encounters WHERE acarbose                 <> 'No' UNION ALL
SELECT CAST(encounter_id AS UNSIGNED), 'miglitol',                 miglitol                 FROM stg_encounters WHERE miglitol                 <> 'No' UNION ALL
SELECT CAST(encounter_id AS UNSIGNED), 'troglitazone',             troglitazone             FROM stg_encounters WHERE troglitazone             <> 'No' UNION ALL
SELECT CAST(encounter_id AS UNSIGNED), 'tolazamide',               tolazamide               FROM stg_encounters WHERE tolazamide               <> 'No' UNION ALL
SELECT CAST(encounter_id AS UNSIGNED), 'examide',                  examide                  FROM stg_encounters WHERE examide                  <> 'No' UNION ALL
SELECT CAST(encounter_id AS UNSIGNED), 'citoglipton',              citoglipton              FROM stg_encounters WHERE citoglipton              <> 'No' UNION ALL
SELECT CAST(encounter_id AS UNSIGNED), 'insulin',                  insulin                  FROM stg_encounters WHERE insulin                  <> 'No' UNION ALL
SELECT CAST(encounter_id AS UNSIGNED), 'glyburide-metformin',      glyburide_metformin      FROM stg_encounters WHERE glyburide_metformin      <> 'No' UNION ALL
SELECT CAST(encounter_id AS UNSIGNED), 'glipizide-metformin',      glipizide_metformin      FROM stg_encounters WHERE glipizide_metformin      <> 'No' UNION ALL
SELECT CAST(encounter_id AS UNSIGNED), 'glimepiride-pioglitazone', glimepiride_pioglitazone FROM stg_encounters WHERE glimepiride_pioglitazone <> 'No' UNION ALL
SELECT CAST(encounter_id AS UNSIGNED), 'metformin-rosiglitazone',  metformin_rosiglitazone  FROM stg_encounters WHERE metformin_rosiglitazone  <> 'No' UNION ALL
SELECT CAST(encounter_id AS UNSIGNED), 'metformin-pioglitazone',   metformin_pioglitazone   FROM stg_encounters WHERE metformin_pioglitazone   <> 'No';

-- ---------------------------------------------------------------------
-- 4. Analysis cohort: index stays.
--    An "index stay" is a stay that can be followed by a readmission.
--    Stays that ended in death or hospice are removed, because those
--    patients could not return and would dilute every rate.
--    All analysis in script 05 reads from this view, so the cohort
--    rule is written once.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_index_stays AS
SELECT e.encounter_id,
       e.patient_nbr,
       e.encounter_seq,
       p.encounter_count        AS patient_encounter_count,
       p.race,
       p.gender,
       e.age_band,
       e.age_lower,
       aty.admission_group,
       src.source_group         AS admission_source_group,
       dd.discharge_group,
       e.time_in_hospital,
       e.num_lab_procedures,
       e.num_procedures,
       e.num_medications,
       e.number_outpatient,
       e.number_emergency,
       e.number_inpatient,
       e.diag_1,
       e.primary_diagnosis_group,
       e.number_diagnoses,
       e.max_glu_serum,
       e.a1c_result,
       e.a1c_measured,
       e.med_changed,
       e.on_diabetes_med,
       e.readmitted,
       e.readmitted_30d
FROM encounters e
JOIN patients               p   ON p.patient_nbr = e.patient_nbr
JOIN admission_types        aty ON aty.admission_type_id = e.admission_type_id
JOIN admission_sources      src ON src.admission_source_id = e.admission_source_id
JOIN discharge_dispositions dd  ON dd.discharge_disposition_id = e.discharge_disposition_id
WHERE dd.is_death_or_hospice = FALSE;

-- ---------------------------------------------------------------------
-- 5. Reconciliation: the clean model must account for every raw row.
-- ---------------------------------------------------------------------
SELECT 'staging rows'                AS check_name, COUNT(*) AS n, 101766 AS expected FROM stg_encounters
UNION ALL
SELECT 'encounters',                   COUNT(*), 101766 FROM encounters
UNION ALL
SELECT 'patients',                     COUNT(*), 71518  FROM patients
UNION ALL
SELECT 'medication rows',              COUNT(*), 120054 FROM encounter_medications
UNION ALL
SELECT 'index stays (analysis cohort)', COUNT(*), 99343 FROM v_index_stays
UNION ALL
SELECT 'stays that ended in death or hospice', COUNT(*), 2423
FROM encounters e
JOIN discharge_dispositions dd ON dd.discharge_disposition_id = e.discharge_disposition_id
WHERE dd.is_death_or_hospice = TRUE;
