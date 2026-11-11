-- =====================================================================
-- Hospital readmissions among patients with diabetes
-- 01_create_schema.sql : database, staging table, lookups, clean model
--
-- Author   : Elisha Abraham
-- Engine   : MySQL 8.0
-- Run order: 01 -> 02 -> 03 -> 04 -> 05 -> 06
--
-- Design in one line: load the raw file untouched into a text-only
-- staging table, audit it there, then build typed, constrained tables
-- from it. The raw file is never edited, so every cleaning decision
-- lives in SQL and can be re-run or challenged.
-- =====================================================================

DROP DATABASE IF EXISTS readmissions;
CREATE DATABASE readmissions CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE readmissions;

-- ---------------------------------------------------------------------
-- 1. Staging: the CSV exactly as it arrives, every column as text.
--    Text columns mean a bad value can never make the load fail or be
--    silently coerced; problems are found by the audit in script 03.
--    Three source columns are renamed: "change" is a reserved word in
--    MySQL, and "A1Cresult" / "diabetesMed" are made snake_case.
-- ---------------------------------------------------------------------
CREATE TABLE stg_encounters (
    encounter_id              VARCHAR(20),
    patient_nbr               VARCHAR(20),
    race                      VARCHAR(20),
    gender                    VARCHAR(20),
    age                       VARCHAR(10),
    weight                    VARCHAR(10),
    admission_type_id         VARCHAR(5),
    discharge_disposition_id  VARCHAR(5),
    admission_source_id       VARCHAR(5),
    time_in_hospital          VARCHAR(5),
    payer_code                VARCHAR(5),
    medical_specialty         VARCHAR(40),
    num_lab_procedures        VARCHAR(5),
    num_procedures            VARCHAR(5),
    num_medications           VARCHAR(5),
    number_outpatient         VARCHAR(5),
    number_emergency          VARCHAR(5),
    number_inpatient          VARCHAR(5),
    diag_1                    VARCHAR(10),
    diag_2                    VARCHAR(10),
    diag_3                    VARCHAR(10),
    number_diagnoses          VARCHAR(5),
    max_glu_serum             VARCHAR(10),
    a1c_result                VARCHAR(10),
    metformin                 VARCHAR(10),
    repaglinide               VARCHAR(10),
    nateglinide               VARCHAR(10),
    chlorpropamide            VARCHAR(10),
    glimepiride               VARCHAR(10),
    acetohexamide             VARCHAR(10),
    glipizide                 VARCHAR(10),
    glyburide                 VARCHAR(10),
    tolbutamide               VARCHAR(10),
    pioglitazone              VARCHAR(10),
    rosiglitazone             VARCHAR(10),
    acarbose                  VARCHAR(10),
    miglitol                  VARCHAR(10),
    troglitazone              VARCHAR(10),
    tolazamide                VARCHAR(10),
    examide                   VARCHAR(10),
    citoglipton               VARCHAR(10),
    insulin                   VARCHAR(10),
    glyburide_metformin       VARCHAR(10),
    glipizide_metformin       VARCHAR(10),
    glimepiride_pioglitazone  VARCHAR(10),
    metformin_rosiglitazone   VARCHAR(10),
    metformin_pioglitazone    VARCHAR(10),
    med_change                VARCHAR(5),
    diabetes_med              VARCHAR(5),
    readmitted                VARCHAR(5)
);

-- ---------------------------------------------------------------------
-- 2. Lookup tables.
--    The source ships one file (IDS_mapping.csv) holding three code
--    lists stacked on top of each other. They are small, so they are
--    transcribed here. "description" keeps the source wording; the
--    "_group" column is my own roll-up, added because 26 discharge
--    codes are too many to compare and several hold a handful of rows.
-- ---------------------------------------------------------------------
CREATE TABLE admission_types (
    admission_type_id  TINYINT UNSIGNED NOT NULL PRIMARY KEY,
    description        VARCHAR(40)      NOT NULL,
    admission_group    VARCHAR(20)      NOT NULL
);

INSERT INTO admission_types VALUES
    (1, 'Emergency',     'Emergency'),
    (2, 'Urgent',        'Urgent'),
    (3, 'Elective',      'Elective'),
    (4, 'Newborn',       'Other'),
    (5, 'Not Available', 'Unknown'),
    (6, 'NULL',          'Unknown'),
    (7, 'Trauma Center', 'Emergency'),
    (8, 'Not Mapped',    'Unknown');

CREATE TABLE discharge_dispositions (
    discharge_disposition_id  TINYINT UNSIGNED NOT NULL PRIMARY KEY,
    description               VARCHAR(110)     NOT NULL,
    discharge_group           VARCHAR(40)      NOT NULL,
    -- A patient who died or left for hospice cannot be readmitted, so
    -- these stays must leave the denominator of any readmission rate.
    is_death_or_hospice       BOOLEAN          NOT NULL
);

INSERT INTO discharge_dispositions VALUES
    (1,  'Discharged to home',                                                                      'Home',                              FALSE),
    (2,  'Discharged/transferred to another short term hospital',                                   'Transferred to another facility',   FALSE),
    (3,  'Discharged/transferred to SNF',                                                           'Skilled nursing or long-term care', FALSE),
    (4,  'Discharged/transferred to ICF',                                                           'Skilled nursing or long-term care', FALSE),
    (5,  'Discharged/transferred to another type of inpatient care institution',                    'Transferred to another facility',   FALSE),
    (6,  'Discharged/transferred to home with home health service',                                 'Home with home health',             FALSE),
    (7,  'Left AMA',                                                                                'Left against medical advice',       FALSE),
    (8,  'Discharged/transferred to home under care of Home IV provider',                           'Home with home health',             FALSE),
    (9,  'Admitted as an inpatient to this hospital',                                               'Other or unknown',                  FALSE),
    (10, 'Neonate discharged to another hospital for neonatal aftercare',                           'Transferred to another facility',   FALSE),
    (11, 'Expired',                                                                                 'Died or hospice',                   TRUE),
    (12, 'Still patient or expected to return for outpatient services',                             'Other or unknown',                  FALSE),
    (13, 'Hospice / home',                                                                          'Died or hospice',                   TRUE),
    (14, 'Hospice / medical facility',                                                              'Died or hospice',                   TRUE),
    (15, 'Discharged/transferred within this institution to Medicare approved swing bed',           'Skilled nursing or long-term care', FALSE),
    (16, 'Discharged/transferred/referred another institution for outpatient services',             'Other or unknown',                  FALSE),
    (17, 'Discharged/transferred/referred to this institution for outpatient services',             'Other or unknown',                  FALSE),
    (18, 'NULL',                                                                                    'Other or unknown',                  FALSE),
    (19, 'Expired at home. Medicaid only, hospice.',                                                'Died or hospice',                   TRUE),
    (20, 'Expired in a medical facility. Medicaid only, hospice.',                                  'Died or hospice',                   TRUE),
    (21, 'Expired, place unknown. Medicaid only, hospice.',                                         'Died or hospice',                   TRUE),
    (22, 'Discharged/transferred to another rehab fac including rehab units of a hospital',         'Rehabilitation facility',           FALSE),
    (23, 'Discharged/transferred to a long term care hospital',                                     'Skilled nursing or long-term care', FALSE),
    (24, 'Discharged/transferred to a nursing facility certified under Medicaid but not Medicare',  'Skilled nursing or long-term care', FALSE),
    (25, 'Not Mapped',                                                                              'Other or unknown',                  FALSE),
    (26, 'Unknown/Invalid',                                                                         'Other or unknown',                  FALSE),
    (27, 'Discharged/transferred to a federal health care facility',                                'Transferred to another facility',   FALSE),
    (28, 'Discharged/transferred/referred to a psychiatric hospital or psychiatric unit',           'Transferred to another facility',   FALSE),
    (29, 'Discharged/transferred to a Critical Access Hospital (CAH)',                              'Transferred to another facility',   FALSE),
    (30, 'Discharged/transferred to another type of health care institution not defined elsewhere', 'Transferred to another facility',   FALSE);

CREATE TABLE admission_sources (
    admission_source_id  TINYINT UNSIGNED NOT NULL PRIMARY KEY,
    description          VARCHAR(70)      NOT NULL,
    source_group         VARCHAR(20)      NOT NULL
);

INSERT INTO admission_sources VALUES
    (1,  'Physician Referral',                                        'Referral'),
    (2,  'Clinic Referral',                                           'Referral'),
    (3,  'HMO Referral',                                              'Referral'),
    (4,  'Transfer from a hospital',                                  'Transfer'),
    (5,  'Transfer from a Skilled Nursing Facility (SNF)',            'Transfer'),
    (6,  'Transfer from another health care facility',                'Transfer'),
    (7,  'Emergency Room',                                            'Emergency room'),
    (8,  'Court/Law Enforcement',                                     'Other'),
    (9,  'Not Available',                                             'Unknown'),
    (10, 'Transfer from critical access hospital',                    'Transfer'),
    (11, 'Normal Delivery',                                           'Other'),
    (12, 'Premature Delivery',                                        'Other'),
    (13, 'Sick Baby',                                                 'Other'),
    (14, 'Extramural Birth',                                          'Other'),
    (15, 'Not Available',                                             'Unknown'),
    (17, 'NULL',                                                      'Unknown'),
    (18, 'Transfer From Another Home Health Agency',                  'Transfer'),
    (19, 'Readmission to Same Home Health Agency',                    'Other'),
    (20, 'Not Mapped',                                                'Unknown'),
    (21, 'Unknown/Invalid',                                           'Unknown'),
    (22, 'Transfer from hospital inpatient, same facility, separate claim', 'Transfer'),
    (23, 'Born inside this hospital',                                 'Other'),
    (24, 'Born outside this hospital',                                'Other'),
    (25, 'Transfer from Ambulatory Surgery Center',                   'Transfer'),
    (26, 'Transfer from Hospice',                                     'Transfer');

-- ---------------------------------------------------------------------
-- 3. ICD-9 diagnosis groups.
--    717 distinct primary diagnosis codes are useless for comparison,
--    so they are rolled up into the nine groups used by Strack et al.
--    (2014), the paper that published this dataset. A range table is
--    used instead of a long CASE expression so the mapping is data:
--    it can be read, audited and corrected without touching queries.
--    Ranges are [code_from, code_to): the upper bound is exclusive.
--    Codes outside every range, and V/E codes, fall into 'Other'.
-- ---------------------------------------------------------------------
CREATE TABLE icd9_groups (
    code_from        DECIMAL(6,2) NOT NULL,
    code_to          DECIMAL(6,2) NOT NULL,
    diagnosis_group  VARCHAR(20)  NOT NULL,
    PRIMARY KEY (code_from),
    CONSTRAINT chk_icd9_range CHECK (code_from < code_to)
);

INSERT INTO icd9_groups VALUES
    (140, 240, 'Neoplasms'),
    (250, 251, 'Diabetes'),
    (390, 460, 'Circulatory'),
    (460, 520, 'Respiratory'),
    (520, 580, 'Digestive'),
    (580, 630, 'Genitourinary'),
    (710, 740, 'Musculoskeletal'),
    (785, 786, 'Circulatory'),
    (786, 787, 'Respiratory'),
    (787, 788, 'Digestive'),
    (788, 789, 'Genitourinary'),
    (800, 1000, 'Injury');

-- ---------------------------------------------------------------------
-- 4. Clean model: one row per patient, one row per hospital stay, and
--    one row per diabetes medication given during a stay.
-- ---------------------------------------------------------------------
CREATE TABLE patients (
    patient_nbr          INT UNSIGNED      NOT NULL PRIMARY KEY,
    race                 VARCHAR(20)       NULL,
    gender               VARCHAR(10)       NULL,
    encounter_count      SMALLINT UNSIGNED NOT NULL,
    -- TRUE when the source recorded more than one gender or more than
    -- one race for the same patient; the stored value is the most
    -- frequent one (see script 04).
    demographics_conflict BOOLEAN          NOT NULL
);

CREATE TABLE encounters (
    encounter_id              INT UNSIGNED      NOT NULL,
    patient_nbr               INT UNSIGNED      NOT NULL,
    encounter_seq             SMALLINT UNSIGNED NOT NULL COMMENT 'Position of this stay among the patient''s stays, ordered by encounter_id',
    age_band                  VARCHAR(8)        NOT NULL,
    age_lower                 TINYINT UNSIGNED  NOT NULL COMMENT 'Lower bound of the 10-year age band',
    admission_type_id         TINYINT UNSIGNED  NOT NULL,
    discharge_disposition_id  TINYINT UNSIGNED  NOT NULL,
    admission_source_id       TINYINT UNSIGNED  NOT NULL,
    time_in_hospital          TINYINT UNSIGNED  NOT NULL COMMENT 'Length of stay in days',
    payer_code                CHAR(2)           NULL,
    medical_specialty         VARCHAR(40)       NULL,
    num_lab_procedures        SMALLINT UNSIGNED NOT NULL,
    num_procedures            TINYINT UNSIGNED  NOT NULL,
    num_medications           SMALLINT UNSIGNED NOT NULL,
    number_outpatient         SMALLINT UNSIGNED NOT NULL COMMENT 'Outpatient visits in the year before this stay',
    number_emergency          SMALLINT UNSIGNED NOT NULL COMMENT 'Emergency visits in the year before this stay',
    number_inpatient          SMALLINT UNSIGNED NOT NULL COMMENT 'Inpatient stays in the year before this stay',
    diag_1                    VARCHAR(6)        NULL,
    diag_2                    VARCHAR(6)        NULL,
    diag_3                    VARCHAR(6)        NULL,
    primary_diagnosis_group   VARCHAR(20)       NOT NULL,
    number_diagnoses          TINYINT UNSIGNED  NOT NULL,
    max_glu_serum             VARCHAR(12)       NOT NULL,
    a1c_result                VARCHAR(12)       NOT NULL,
    a1c_measured              BOOLEAN           NOT NULL,
    med_changed               BOOLEAN           NOT NULL,
    on_diabetes_med           BOOLEAN           NOT NULL,
    readmitted                VARCHAR(3)        NOT NULL,
    readmitted_30d            BOOLEAN           NOT NULL,
    PRIMARY KEY (encounter_id),
    UNIQUE KEY uq_patient_seq (patient_nbr, encounter_seq),
    KEY idx_discharge (discharge_disposition_id),
    CONSTRAINT fk_enc_patient    FOREIGN KEY (patient_nbr)              REFERENCES patients (patient_nbr),
    CONSTRAINT fk_enc_adm_type   FOREIGN KEY (admission_type_id)        REFERENCES admission_types (admission_type_id),
    CONSTRAINT fk_enc_discharge  FOREIGN KEY (discharge_disposition_id) REFERENCES discharge_dispositions (discharge_disposition_id),
    CONSTRAINT fk_enc_adm_source FOREIGN KEY (admission_source_id)      REFERENCES admission_sources (admission_source_id),
    CONSTRAINT chk_readmitted    CHECK (readmitted IN ('<30', '>30', 'NO')),
    CONSTRAINT chk_stay_length   CHECK (time_in_hospital BETWEEN 1 AND 14),
    CONSTRAINT chk_readmit_flag  CHECK (readmitted_30d = (readmitted = '<30'))
);

CREATE TABLE encounter_medications (
    encounter_id  INT UNSIGNED NOT NULL,
    medication    VARCHAR(30)  NOT NULL,
    dose_change   VARCHAR(6)   NOT NULL,
    PRIMARY KEY (encounter_id, medication),
    KEY idx_medication (medication),
    CONSTRAINT fk_med_encounter FOREIGN KEY (encounter_id) REFERENCES encounters (encounter_id),
    CONSTRAINT chk_dose_change  CHECK (dose_change IN ('Steady', 'Up', 'Down'))
);
