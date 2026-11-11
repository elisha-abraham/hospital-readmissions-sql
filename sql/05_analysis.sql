-- =====================================================================
-- 05_analysis.sql : who comes back within 30 days?
--
-- Every query reads v_index_stays, the analysis cohort: 99,343 stays
-- that ended with the patient alive and not in hospice.
--
-- "Readmission rate" always means the share of index stays followed by
-- another inpatient admission within 30 days of discharge.
--
-- Results that feed charts are saved as views named rpt_*, so the
-- chart script and any BI tool read exactly what is shown here.
-- =====================================================================

USE readmissions;

-- ---------------------------------------------------------------------
-- Q1. How big is the problem?
-- Finding: 11,314 of 99,343 index stays were followed by a readmission
--          within 30 days: 11.39%, or about 1 discharge in 9. Almost
--          half (47.13%) were readmitted at some point.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW rpt_headline AS
SELECT COUNT(*)                                AS index_stays,
       COUNT(DISTINCT patient_nbr)             AS patients,
       SUM(readmitted_30d)                     AS readmitted_within_30_days,
       ROUND(100 * AVG(readmitted_30d), 2)     AS readmission_rate_pct,
       ROUND(100 * AVG(readmitted <> 'NO'), 2) AS readmitted_any_time_pct
FROM v_index_stays;

SELECT * FROM rpt_headline;

-- Sensitivity check. Stays by the same patient are not independent,
-- and frequent attenders weigh heavily in the figure above. Counting
-- only each patient's first recorded stay gives one row per patient.
-- Finding: 8.97% (6,277 of 69,973). The headline rate is pulled up by
--          repeat attenders, which is itself the first finding.
SELECT COUNT(*)                            AS first_stays,
       SUM(readmitted_30d)                 AS readmitted_within_30_days,
       ROUND(100 * AVG(readmitted_30d), 2) AS readmission_rate_pct
FROM v_index_stays
WHERE encounter_seq = 1;

-- ---------------------------------------------------------------------
-- Q2. Is the problem spread evenly, or concentrated in a few patients?
-- Finding: patients with three or more stays are 8.7% of patients
--          (6,123 of 69,990) but account for 25.4% of stays and 52.3%
--          of all 30-day readmissions. Part of this is by construction,
--          since a readmission is itself another stay, but the working
--          conclusion holds: a small group of repeat attenders drives
--          most of the problem.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW rpt_patient_concentration AS
WITH per_patient AS (
    SELECT patient_nbr,
           COUNT(*)            AS stays,
           SUM(readmitted_30d) AS readmissions
    FROM v_index_stays
    GROUP BY patient_nbr
)
SELECT CASE WHEN stays = 1 THEN '1 stay'
            WHEN stays = 2 THEN '2 stays'
            WHEN stays <= 4 THEN '3-4 stays'
            ELSE '5 or more stays'
       END                                                              AS patient_group,
       MIN(stays)                                                       AS sort_key,
       COUNT(*)                                                         AS patients,
       ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)                 AS pct_of_patients,
       SUM(stays)                                                       AS stays,
       ROUND(100 * SUM(stays) / SUM(SUM(stays)) OVER (), 1)             AS pct_of_stays,
       SUM(readmissions)                                                AS readmissions_30d,
       ROUND(100 * SUM(readmissions) / SUM(SUM(readmissions)) OVER (), 1) AS pct_of_readmissions
FROM per_patient
GROUP BY patient_group;

SELECT * FROM rpt_patient_concentration ORDER BY sort_key;

-- How few patients account for a quarter, half and 80% of all 30-day
-- readmissions? Patients are ranked from most readmissions to fewest
-- and a running total is taken down the list.
-- Finding: 924 patients (1.3%) account for a quarter of all 30-day
--          readmissions, 3,148 patients (4.5%) for half, and 6,543
--          patients (9.3%) for 80%.
WITH per_patient AS (
    SELECT patient_nbr, SUM(readmitted_30d) AS readmissions
    FROM v_index_stays
    GROUP BY patient_nbr
),
ranked AS (
    SELECT readmissions,
           ROW_NUMBER() OVER (ORDER BY readmissions DESC, patient_nbr)  AS patient_rank,
           COUNT(*)     OVER ()                                         AS total_patients,
           SUM(readmissions) OVER (ORDER BY readmissions DESC, patient_nbr
                                   ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_readmissions,
           SUM(readmissions) OVER ()                                    AS total_readmissions
    FROM per_patient
)
SELECT t.share_of_readmissions,
       MIN(r.patient_rank)                                        AS patients_needed,
       ROUND(100 * MIN(r.patient_rank) / MAX(r.total_patients), 1) AS pct_of_all_patients
FROM ranked r
JOIN (SELECT 0.25 AS share_of_readmissions UNION ALL SELECT 0.50 UNION ALL SELECT 0.80) t
  ON r.running_readmissions >= t.share_of_readmissions * r.total_readmissions
GROUP BY t.share_of_readmissions
ORDER BY t.share_of_readmissions;

-- ---------------------------------------------------------------------
-- Q3. Which stays carry the highest risk?
-- One tidy table: a row per segment, with the readmission rate, a 95%
-- Wilson confidence interval, and the rate as a multiple of the cohort
-- average. The Wilson interval is used instead of the textbook
-- p +/- 1.96*SE because it stays inside 0-100% and behaves well for
-- small groups.
-- Finding: prior hospital use is the strongest signal. The rate climbs
--          from 8.59% with no inpatient stay in the past year to
--          37.13% with five or more. Discharge destination is second:
--          27.70% after discharge to a rehabilitation facility against
--          9.30% for patients sent home. Sex and race show no
--          difference worth acting on.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW rpt_segment_rates AS
WITH segments AS (
    SELECT 'Prior inpatient stays (past year)' AS dimension, 1 AS dimension_order,
           CASE WHEN number_inpatient >= 5 THEN '5 or more' ELSE CAST(number_inpatient AS CHAR) END AS segment,
           LEAST(number_inpatient, 5) AS segment_order,
           readmitted_30d
    FROM v_index_stays
    UNION ALL
    SELECT 'Prior emergency visits (past year)', 2,
           CASE WHEN number_emergency >= 3 THEN '3 or more' ELSE CAST(number_emergency AS CHAR) END,
           LEAST(number_emergency, 3),
           readmitted_30d
    FROM v_index_stays
    UNION ALL
    SELECT 'Discharge destination', 3, discharge_group, 0, readmitted_30d
    FROM v_index_stays
    UNION ALL
    SELECT 'Length of stay', 4,
           CASE WHEN time_in_hospital <= 2 THEN '1-2 days'
                WHEN time_in_hospital <= 4 THEN '3-4 days'
                WHEN time_in_hospital <= 7 THEN '5-7 days'
                ELSE '8-14 days' END,
           CASE WHEN time_in_hospital <= 2 THEN 1 WHEN time_in_hospital <= 4 THEN 2 WHEN time_in_hospital <= 7 THEN 3 ELSE 4 END,
           readmitted_30d
    FROM v_index_stays
    UNION ALL
    SELECT 'Number of diagnoses', 5,
           CASE WHEN number_diagnoses <= 5 THEN '1-5' WHEN number_diagnoses <= 8 THEN '6-8' ELSE '9 or more' END,
           CASE WHEN number_diagnoses <= 5 THEN 1 WHEN number_diagnoses <= 8 THEN 2 ELSE 3 END,
           readmitted_30d
    FROM v_index_stays
    UNION ALL
    SELECT 'Age band', 6, age_band, age_lower, readmitted_30d
    FROM v_index_stays
    UNION ALL
    SELECT 'Primary diagnosis', 7, primary_diagnosis_group, 0, readmitted_30d
    FROM v_index_stays
    UNION ALL
    SELECT 'Sex', 8, COALESCE(gender, 'Not recorded'), 0, readmitted_30d
    FROM v_index_stays
    UNION ALL
    SELECT 'Race', 9, COALESCE(race, 'Not recorded'), 0, readmitted_30d
    FROM v_index_stays
),
rates AS (
    SELECT dimension,
           dimension_order,
           segment,
           MIN(segment_order)                              AS segment_order,
           COUNT(*)                                        AS stays,
           SUM(readmitted_30d)                             AS readmissions,
           CAST(SUM(readmitted_30d) AS DOUBLE) / COUNT(*)  AS p
    FROM segments
    GROUP BY dimension, dimension_order, segment
)
SELECT dimension,
       dimension_order,
       segment,
       segment_order,
       stays,
       readmissions,
       ROUND(100 * p, 2) AS rate_pct,
       -- Wilson score interval with z = 1.96 (z^2 = 3.8416, z^2/2 = 1.9208, z^2/4 = 0.9604)
       GREATEST(0, ROUND(100 * (p + 1.9208 / stays - 1.96 * SQRT(p * (1 - p) / stays + 0.9604 / (stays * stays))) / (1 + 3.8416 / stays), 2)) AS ci_low_pct,
       ROUND(100 * (p + 1.9208 / stays + 1.96 * SQRT(p * (1 - p) / stays + 0.9604 / (stays * stays))) / (1 + 3.8416 / stays), 2) AS ci_high_pct,
       ROUND(p / (SELECT CAST(SUM(readmitted_30d) AS DOUBLE) / COUNT(*) FROM v_index_stays), 2) AS ratio_to_average
FROM rates;

SELECT dimension, segment, stays, readmissions, rate_pct, ci_low_pct, ci_high_pct, ratio_to_average
FROM rpt_segment_rates
ORDER BY dimension_order, segment_order, rate_pct DESC;

-- ---------------------------------------------------------------------
-- Q4. Do inpatient history and emergency history add to each other?
-- Conditional aggregation pivots emergency history into columns.
-- Finding: yes. At every level of inpatient history, patients who also
--          had an emergency visit in the past year return more often.
-- ---------------------------------------------------------------------
SELECT CASE WHEN number_inpatient = 0 THEN '0'
            WHEN number_inpatient = 1 THEN '1'
            ELSE '2 or more' END                                                   AS prior_inpatient_stays,
       SUM(number_emergency = 0)                                                   AS stays_no_emergency_visit,
       ROUND(100 * AVG(CASE WHEN number_emergency = 0  THEN readmitted_30d END), 2) AS rate_no_emergency_visit,
       SUM(number_emergency >= 1)                                                  AS stays_with_emergency_visit,
       ROUND(100 * AVG(CASE WHEN number_emergency >= 1 THEN readmitted_30d END), 2) AS rate_with_emergency_visit
FROM v_index_stays
GROUP BY prior_inpatient_stays
ORDER BY prior_inpatient_stays;

-- ---------------------------------------------------------------------
-- Q5. The revolving door: what happens after a patient has already
--     bounced back once?
-- LAG() looks at the outcome of the same patient's previous stay.
-- Sequence relies on encounter_id order (audit check A7).
-- Finding: 21.56% of stays that follow a 30-day readmission are
--          themselves followed by another one, against 8.97% of first
--          stays: 2.4 times the rate. Group 2 (483 stays) is the set
--          of ordering exceptions found in audit check A7 and is too
--          small and irregular to interpret.
-- ---------------------------------------------------------------------
WITH sequenced AS (
    SELECT encounter_id,
           LAG(readmitted) OVER (PARTITION BY patient_nbr ORDER BY encounter_seq) AS previous_stay_outcome
    FROM encounters
)
SELECT CASE WHEN s.previous_stay_outcome IS NULL  THEN '1. First recorded stay'
            WHEN s.previous_stay_outcome = 'NO'   THEN '2. Previous stay not followed by readmission'
            WHEN s.previous_stay_outcome = '>30'  THEN '3. Previous stay followed by readmission after 30 days'
            ELSE                                       '4. Previous stay followed by readmission within 30 days'
       END                                   AS stay_history,
       COUNT(*)                              AS stays,
       SUM(i.readmitted_30d)                 AS readmitted_within_30_days,
       ROUND(100 * AVG(i.readmitted_30d), 2) AS readmission_rate_pct
FROM v_index_stays i
JOIN sequenced s ON s.encounter_id = i.encounter_id
GROUP BY stay_history
ORDER BY stay_history;

-- ---------------------------------------------------------------------
-- Q6. HbA1c testing: how often is long-term glucose control checked
--     during a stay, and is testing linked to readmission?
-- 'Not measured' means no HbA1c result was recorded during the stay.
-- A recent outpatient result would not appear here.
-- ---------------------------------------------------------------------

-- Q6a. Testing rate by primary diagnosis.
-- Finding: HbA1c was measured on 16.9% of stays overall, and on only
--          31.6% of stays where diabetes itself was the main reason
--          for admission.
CREATE OR REPLACE VIEW rpt_hba1c_by_diagnosis AS
SELECT primary_diagnosis_group,
       COUNT(*)                                                                         AS stays,
       SUM(a1c_measured)                                                                AS stays_tested,
       ROUND(100 * AVG(a1c_measured), 1)                                                AS pct_tested,
       ROUND(100 * SUM(a1c_measured AND readmitted_30d) / SUM(a1c_measured), 2)         AS rate_tested_pct,
       ROUND(100 * SUM(NOT a1c_measured AND readmitted_30d) / SUM(NOT a1c_measured), 2) AS rate_not_tested_pct
FROM v_index_stays
WHERE primary_diagnosis_group <> 'Unknown'
GROUP BY primary_diagnosis_group;

SELECT *, ROUND(rate_tested_pct - rate_not_tested_pct, 2) AS difference_points
FROM rpt_hba1c_by_diagnosis
ORDER BY pct_tested DESC;

-- Q6b. Crude comparison: tested against not tested, with the relative
-- risk and its 95% confidence interval (log method).
-- Finding: 9.94% against 11.68%; relative risk 0.85 (95% CI 0.81 to
--          0.89). Tested stays were followed by 15% fewer readmissions.
WITH counts AS (
    SELECT CAST(SUM(a1c_measured) AS DOUBLE)                        AS n_tested,
           CAST(SUM(a1c_measured AND readmitted_30d) AS DOUBLE)     AS r_tested,
           CAST(SUM(NOT a1c_measured) AS DOUBLE)                    AS n_untested,
           CAST(SUM(NOT a1c_measured AND readmitted_30d) AS DOUBLE) AS r_untested
    FROM v_index_stays
)
SELECT n_tested                                                    AS stays_tested,
       ROUND(100 * r_tested / n_tested, 2)                         AS rate_tested_pct,
       n_untested                                                  AS stays_not_tested,
       ROUND(100 * r_untested / n_untested, 2)                     AS rate_not_tested_pct,
       ROUND((r_tested / n_tested) / (r_untested / n_untested), 3) AS relative_risk,
       ROUND(EXP(LN((r_tested / n_tested) / (r_untested / n_untested))
                 - 1.96 * SQRT(1 / r_tested - 1 / n_tested + 1 / r_untested - 1 / n_untested)), 3) AS rr_ci_low,
       ROUND(EXP(LN((r_tested / n_tested) / (r_untested / n_untested))
                 + 1.96 * SQRT(1 / r_tested - 1 / n_tested + 1 / r_untested - 1 / n_untested)), 3) AS rr_ci_high
FROM counts;

-- Q6c. Chi-square test of independence for the same 2x2 table, written
-- out by hand: expected count = row total * column total / grand total.
-- With 1 degree of freedom, a statistic above 10.83 means p < 0.001.
WITH observed AS (
    SELECT a1c_measured, readmitted_30d, COUNT(*) AS observed_n
    FROM v_index_stays
    GROUP BY a1c_measured, readmitted_30d
),
expected AS (
    SELECT observed_n,
           CAST(SUM(observed_n) OVER (PARTITION BY a1c_measured) AS DOUBLE)
             * SUM(observed_n) OVER (PARTITION BY readmitted_30d)
             / SUM(observed_n) OVER ()                               AS expected_n
    FROM observed
)
SELECT ROUND(SUM(POW(observed_n - expected_n, 2) / expected_n), 2)  AS chi_square,
       1                                                            AS degrees_of_freedom,
       IF(SUM(POW(observed_n - expected_n, 2) / expected_n) > 10.83, 'p < 0.001', 'p >= 0.001') AS significance
FROM expected;

-- Q6d. Is the difference just case mix? Tested patients might simply
-- be different patients. The Mantel-Haenszel relative risk compares
-- tested with untested stays inside each stratum of primary diagnosis
-- and inpatient history, then pools the strata.
-- Finding: the pooled relative risk is 0.92 across 28 strata. Case mix
--          explains a little under half of the crude gap (0.85 moves
--          to 0.92); a smaller difference remains. This is still
--          observational: it shows that testing travels with fewer
--          readmissions, not that ordering the test prevents them.
WITH strata AS (
    SELECT primary_diagnosis_group,
           LEAST(number_inpatient, 2)                               AS inpatient_history_band,
           CAST(SUM(a1c_measured) AS DOUBLE)                        AS n_tested,
           CAST(SUM(a1c_measured AND readmitted_30d) AS DOUBLE)     AS r_tested,
           CAST(SUM(NOT a1c_measured) AS DOUBLE)                    AS n_untested,
           CAST(SUM(NOT a1c_measured AND readmitted_30d) AS DOUBLE) AS r_untested,
           COUNT(*)                                                 AS n_total
    FROM v_index_stays
    GROUP BY primary_diagnosis_group, inpatient_history_band
)
SELECT COUNT(*)                                                                         AS strata_pooled,
       ROUND(SUM(r_tested * n_untested / n_total) / SUM(r_untested * n_tested / n_total), 3) AS mantel_haenszel_relative_risk
FROM strata
WHERE n_tested > 0 AND n_untested > 0;

-- ---------------------------------------------------------------------
-- Q7. Diabetes medication during the stay.
-- The long medication table turns these into simple joins.
-- ---------------------------------------------------------------------

-- Q7a. Insulin: not given, held steady, or dose changed.
-- Finding: stays where the insulin dose was changed, in either
--          direction, are followed by more readmissions (13.3% up,
--          14.2% down) than stays with no insulin (10.2%). A dose
--          change marks unstable control; it is a risk marker, not
--          evidence that changing the dose causes readmission.
SELECT COALESCE(m.dose_change, 'No insulin') AS insulin_during_stay,
       COUNT(*)                              AS stays,
       ROUND(100 * AVG(i.readmitted_30d), 2) AS readmission_rate_pct
FROM v_index_stays i
LEFT JOIN encounter_medications m
       ON m.encounter_id = i.encounter_id
      AND m.medication = 'insulin'
GROUP BY insulin_during_stay
ORDER BY readmission_rate_pct DESC;

-- Q7b. Number of different diabetes drugs given during the stay.
-- Finding: no dose-response. Stays with exactly one drug, usually
--          insulin alone, have the highest rate (12.58%); stays with
--          none have the lowest (9.87%). The count of drugs is not a
--          useful risk signal, so it is left out of the score.
WITH drugs_per_stay AS (
    SELECT encounter_id, COUNT(*) AS drug_count
    FROM encounter_medications
    GROUP BY encounter_id
)
SELECT CASE WHEN d.drug_count IS NULL THEN '0'
            WHEN d.drug_count >= 3    THEN '3 or more'
            ELSE CAST(d.drug_count AS CHAR) END AS diabetes_drugs_given,
       COUNT(*)                                 AS stays,
       ROUND(100 * AVG(i.readmitted_30d), 2)    AS readmission_rate_pct
FROM v_index_stays i
LEFT JOIN drugs_per_stay d ON d.encounter_id = i.encounter_id
GROUP BY diabetes_drugs_given
ORDER BY diabetes_drugs_given;

-- Q7c. The ten most used diabetes drugs and how often the dose moved.
-- Finding: insulin is given on more stays than all other diabetes
--          drugs combined and is the only one adjusted often (43.2% of
--          stays where it is given).
SELECT m.medication,
       COUNT(*)                                       AS stays_given,
       ROUND(100 * AVG(m.dose_change <> 'Steady'), 1) AS pct_dose_changed,
       ROUND(100 * AVG(i.readmitted_30d), 2)          AS readmission_rate_pct
FROM encounter_medications m
JOIN v_index_stays i ON i.encounter_id = m.encounter_id
GROUP BY m.medication
ORDER BY stays_given DESC
LIMIT 10;
