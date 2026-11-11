-- =====================================================================
-- 02_load_staging.sql : load the raw CSV into the staging table
--
-- Run from the project root with the mysql command-line client so the
-- relative path below resolves:
--
--   mysql --local-infile=1 -u root -p < sql/02_load_staging.sql
--
-- LOAD DATA LOCAL needs local_infile switched on at both ends:
--   server : SET GLOBAL local_infile = 1;   (once, as an admin user)
--   client : the --local-infile=1 flag shown above
-- In MySQL Workbench, use an absolute path and add OPT_LOCAL_INFILE=1
-- under Connection > Advanced > Others.
-- =====================================================================

USE readmissions;

TRUNCATE TABLE stg_encounters;

-- Lines are split on \n and any trailing \r is trimmed from the last
-- field. The source file uses Windows line endings (\r\n), but Git can
-- convert them on checkout; handling both keeps the load portable.
LOAD DATA LOCAL INFILE 'data/raw/diabetic_data.csv'
INTO TABLE stg_encounters
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ','
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(encounter_id, patient_nbr, race, gender, age, weight,
 admission_type_id, discharge_disposition_id, admission_source_id, time_in_hospital,
 payer_code, medical_specialty, num_lab_procedures, num_procedures, num_medications,
 number_outpatient, number_emergency, number_inpatient, diag_1, diag_2, diag_3,
 number_diagnoses, max_glu_serum, a1c_result,
 metformin, repaglinide, nateglinide, chlorpropamide, glimepiride, acetohexamide,
 glipizide, glyburide, tolbutamide, pioglitazone, rosiglitazone, acarbose, miglitol,
 troglitazone, tolazamide, examide, citoglipton, insulin,
 glyburide_metformin, glipizide_metformin, glimepiride_pioglitazone,
 metformin_rosiglitazone, metformin_pioglitazone,
 med_change, diabetes_med, @readmitted_raw)
SET readmitted = TRIM(TRAILING '\r' FROM @readmitted_raw);

-- The file documentation states 101,766 rows. Any other count means
-- the load was cut short or the delimiter settings are wrong.
SELECT COUNT(*)                                   AS rows_loaded,
       IF(COUNT(*) = 101766, 'OK', 'ROW COUNT MISMATCH') AS load_check
FROM stg_encounters;
