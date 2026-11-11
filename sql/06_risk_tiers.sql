-- =====================================================================
-- 06_risk_tiers.sql : turning the findings into a discharge-day score
--
-- Goal: a points score a ward can add up on the day of discharge from
-- facts already in the record, so that follow-up goes first to the
-- patients most likely to return.
--
-- Method
--   1. Split patients 70/30. The split is by patient, so no patient's
--      stays appear on both sides.
--   2. Derive the points from the 70% (training patients) only.
--   3. Freeze the rules in a view.
--   4. Test the frozen rules on the 30% the rules have never seen.
-- =====================================================================

USE readmissions;

-- ---------------------------------------------------------------------
-- Step 1. The split.
-- CRC32() of the patient number is used as a repeatable coin toss:
-- the same patient always lands on the same side, on any machine.
-- Finding: 49,189 training patients (69,752 stays, 11.35% readmitted)
--          and 20,801 held-out patients (29,591 stays, 11.49%).
-- ---------------------------------------------------------------------
SELECT IF(CRC32(patient_nbr) % 10 < 7, 'Training (70%)', 'Held out (30%)') AS sample,
       COUNT(DISTINCT patient_nbr)                                         AS patients,
       COUNT(*)                                                            AS stays,
       ROUND(100 * AVG(readmitted_30d), 2)                                 AS readmission_rate_pct
FROM v_index_stays
GROUP BY sample;

-- ---------------------------------------------------------------------
-- Step 2a. Points for inpatient history, the strongest single signal.
-- Rule used throughout: one point for every 1.4-fold step in risk,
-- that is points = ROUND( LN(relative risk) / LN(1.4) ).
-- Finding: 1 stay -> 1 point, 2 -> 2, 3 or 4 -> 3, 5 or more -> 4.
-- ---------------------------------------------------------------------
WITH training AS (
    SELECT readmitted_30d, LEAST(number_inpatient, 5) AS prior_stays
    FROM v_index_stays
    WHERE CRC32(patient_nbr) % 10 < 7
),
rates AS (
    SELECT prior_stays,
           COUNT(*)                                       AS stays,
           CAST(SUM(readmitted_30d) AS DOUBLE) / COUNT(*) AS p
    FROM training
    GROUP BY prior_stays
)
SELECT IF(prior_stays = 5, '5 or more', CAST(prior_stays AS CHAR))          AS prior_inpatient_stays,
       stays,
       ROUND(100 * p, 2)                                                    AS rate_pct,
       ROUND(p / FIRST_VALUE(p) OVER (ORDER BY prior_stays), 2)             AS relative_risk_vs_none,
       ROUND(LN(p / FIRST_VALUE(p) OVER (ORDER BY prior_stays)) / LN(1.4))  AS points
FROM rates
ORDER BY prior_stays;

-- ---------------------------------------------------------------------
-- Step 2b. Points for the other four factors.
-- These overlap with inpatient history: a patient with many past
-- admissions also tends to have emergency visits and a long list of
-- diagnoses. Scoring each factor on its raw relative risk would count
-- the same risk twice. So each level is compared with its reference
-- level inside every band of inpatient history, and the bands are
-- pooled with the Mantel-Haenszel formula. The result is the relative
-- risk for patients with the same inpatient history.
-- Finding: rehabilitation facility 3 points; transfer to another
--          facility 2; every other non-home destination 1; two or more
--          emergency visits 1; six or more diagnoses 1; a stay of five
--          days or longer 1.
-- ---------------------------------------------------------------------
WITH training AS (
    SELECT readmitted_30d,
           number_emergency,
           discharge_group,
           number_diagnoses,
           time_in_hospital,
           CASE WHEN number_inpatient >= 5 THEN 4
                WHEN number_inpatient >= 3 THEN 3
                ELSE number_inpatient END AS inpatient_band
    FROM v_index_stays
    WHERE CRC32(patient_nbr) % 10 < 7
),
exposures AS (
    SELECT 'Emergency visits (past year)' AS factor,
           IF(number_emergency >= 2, '2 or more', '0-1') AS level,
           (number_emergency < 2)                        AS is_reference,
           inpatient_band, readmitted_30d
    FROM training
    UNION ALL
    SELECT 'Discharge destination', discharge_group, (discharge_group = 'Home'), inpatient_band, readmitted_30d
    FROM training
    UNION ALL
    SELECT 'Diagnoses recorded', IF(number_diagnoses >= 6, '6 or more', '1-5'), (number_diagnoses < 6), inpatient_band, readmitted_30d
    FROM training
    UNION ALL
    SELECT 'Length of stay', IF(time_in_hospital >= 5, '5 days or more', '1-4 days'), (time_in_hospital < 5), inpatient_band, readmitted_30d
    FROM training
),
cells AS (
    SELECT factor, level, is_reference, inpatient_band,
           COUNT(*)            AS n,
           SUM(readmitted_30d) AS r
    FROM exposures
    GROUP BY factor, level, is_reference, inpatient_band
),
paired AS (
    -- each level next to its reference level, band by band
    SELECT x.factor, x.level,
           CAST(x.n AS DOUBLE)   AS n1, CAST(x.r AS DOUBLE)   AS r1,
           CAST(ref.n AS DOUBLE) AS n0, CAST(ref.r AS DOUBLE) AS r0
    FROM cells x
    JOIN cells ref
      ON ref.factor = x.factor
     AND ref.inpatient_band = x.inpatient_band
     AND ref.is_reference
    WHERE NOT x.is_reference
)
SELECT factor,
       level,
       SUM(n1)                                                                    AS stays,
       ROUND(100 * SUM(r1) / SUM(n1), 2)                                          AS rate_pct,
       ROUND(SUM(r1 * n0 / (n1 + n0)) / SUM(r0 * n1 / (n1 + n0)), 2)              AS adjusted_relative_risk,
       GREATEST(0, ROUND(LN(SUM(r1 * n0 / (n1 + n0)) / SUM(r0 * n1 / (n1 + n0))) / LN(1.4))) AS points
FROM paired
GROUP BY factor, level
ORDER BY factor, adjusted_relative_risk DESC;

-- ---------------------------------------------------------------------
-- Step 3. Freeze the rules.
-- The points below are copied from the two tables above. From here on
-- nothing is tuned: the held-out patients only test these rules.
--
--   Inpatient stays in the past year   1 -> 1, 2 -> 2, 3-4 -> 3, 5+ -> 4
--   Emergency visits in the past year  2 or more -> 1
--   Discharge destination              rehabilitation facility -> 3
--                                      another facility -> 2
--                                      any other non-home -> 1
--   Diagnoses recorded                 6 or more -> 1
--   Length of stay                     5 days or more -> 1
--
--   Tier        Score
--   Low         0-1
--   Moderate    2-3
--   High        4-5
--   Very high   6-10
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_risk_scores AS
SELECT scored.*,
       CASE WHEN scored.risk_score >= 6 THEN 'Very high'
            WHEN scored.risk_score >= 4 THEN 'High'
            WHEN scored.risk_score >= 2 THEN 'Moderate'
            ELSE 'Low' END                                   AS risk_tier,
       CASE WHEN scored.risk_score >= 6 THEN 4
            WHEN scored.risk_score >= 4 THEN 3
            WHEN scored.risk_score >= 2 THEN 2
            ELSE 1 END                                       AS risk_tier_order
FROM (
    SELECT pts.*,
           pts.points_inpatient + pts.points_emergency + pts.points_discharge
             + pts.points_diagnoses + pts.points_length_of_stay AS risk_score
    FROM (
        SELECT encounter_id,
               patient_nbr,
               readmitted_30d,
               (CRC32(patient_nbr) % 10 < 7)                 AS in_training_sample,
               CASE WHEN number_inpatient >= 5 THEN 4
                    WHEN number_inpatient >= 3 THEN 3
                    ELSE number_inpatient END                AS points_inpatient,
               IF(number_emergency >= 2, 1, 0)               AS points_emergency,
               CASE discharge_group
                    WHEN 'Home'                            THEN 0
                    WHEN 'Rehabilitation facility'         THEN 3
                    WHEN 'Transferred to another facility' THEN 2
                    ELSE 1 END                               AS points_discharge,
               IF(number_diagnoses >= 6, 1, 0)               AS points_diagnoses,
               IF(time_in_hospital >= 5, 1, 0)               AS points_length_of_stay
        FROM v_index_stays
    ) pts
) scored;

-- ---------------------------------------------------------------------
-- Step 4a. Does the score rank patients correctly on unseen data?
-- For each score: the readmission rate among training patients (where
-- the rules came from) beside the rate among held-out patients (where
-- they did not). If the rules had only memorised the training data,
-- the held-out column would not climb.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW rpt_score_calibration AS
SELECT LEAST(risk_score, 8)                                                                 AS risk_score_capped,
       SUM(in_training_sample)                                                              AS training_stays,
       ROUND(100 * SUM(in_training_sample AND readmitted_30d) / SUM(in_training_sample), 2) AS training_rate_pct,
       SUM(NOT in_training_sample)                                                          AS held_out_stays,
       ROUND(100 * SUM(NOT in_training_sample AND readmitted_30d) / SUM(NOT in_training_sample), 2) AS held_out_rate_pct
FROM v_risk_scores
GROUP BY risk_score_capped;

SELECT IF(risk_score_capped = 8, '8 or more', CAST(risk_score_capped AS CHAR)) AS risk_score,
       training_stays, training_rate_pct, held_out_stays, held_out_rate_pct
FROM rpt_score_calibration
ORDER BY risk_score_capped;

-- ---------------------------------------------------------------------
-- Step 4b. Tiers on the held-out patients.
-- lift = tier rate / overall rate. The two running columns answer the
-- operational question: "if we follow up everyone from this tier
-- upward, what share of discharges is that, and what share of all
-- readmissions do we reach?"
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW rpt_risk_tiers AS
WITH tiers AS (
    SELECT risk_tier,
           risk_tier_order,
           COUNT(*)            AS stays,
           SUM(readmitted_30d) AS readmissions
    FROM v_risk_scores
    WHERE NOT in_training_sample
    GROUP BY risk_tier, risk_tier_order
)
SELECT risk_tier,
       risk_tier_order,
       stays,
       ROUND(100 * stays / SUM(stays) OVER (), 1)                                              AS pct_of_stays,
       readmissions,
       ROUND(100 * readmissions / stays, 2)                                                    AS readmission_rate_pct,
       ROUND(100 * readmissions / SUM(readmissions) OVER (), 1)                                AS pct_of_readmissions,
       ROUND((readmissions / stays) / (SUM(readmissions) OVER () / SUM(stays) OVER ()), 2)     AS lift,
       ROUND(100 * SUM(stays) OVER (ORDER BY risk_tier_order DESC) / SUM(stays) OVER (), 1)    AS cumulative_pct_of_stays,
       ROUND(100 * SUM(readmissions) OVER (ORDER BY risk_tier_order DESC) / SUM(readmissions) OVER (), 1) AS cumulative_pct_of_readmissions
FROM tiers;

SELECT risk_tier, stays, pct_of_stays, readmissions, readmission_rate_pct, pct_of_readmissions, lift,
       cumulative_pct_of_stays, cumulative_pct_of_readmissions
FROM rpt_risk_tiers
ORDER BY risk_tier_order DESC;

-- ---------------------------------------------------------------------
-- Step 4c. Discrimination: the AUC (c-statistic), computed in SQL.
-- The AUC is the probability that a randomly chosen readmitted stay
-- has a higher score than a randomly chosen stay that was not
-- readmitted. 0.5 is a coin toss, 1.0 is perfect.
-- It is the Mann-Whitney U statistic divided by (n1 * n0):
--   U = (sum of ranks of the readmitted stays) - n1 * (n1 + 1) / 2
-- Tied scores share the average of the ranks they span.
-- ---------------------------------------------------------------------
WITH ranked AS (
    SELECT in_training_sample,
           readmitted_30d,
           RANK() OVER (PARTITION BY in_training_sample ORDER BY risk_score)
             + (COUNT(*) OVER (PARTITION BY in_training_sample, risk_score) - 1) / 2 AS average_rank
    FROM v_risk_scores
)
SELECT IF(in_training_sample, 'Training (70%)', 'Held out (30%)') AS sample,
       SUM(readmitted_30d)                                        AS readmitted_stays,
       SUM(1 - readmitted_30d)                                    AS other_stays,
       ROUND((SUM(IF(readmitted_30d, average_rank, 0)) - SUM(readmitted_30d) * (SUM(readmitted_30d) + 1) / 2)
             / (SUM(readmitted_30d) * SUM(1 - readmitted_30d)), 3) AS auc
FROM ranked
GROUP BY in_training_sample;

-- ---------------------------------------------------------------------
-- Step 5. What would acting on the score be worth?
-- Per 1,000 discharges on the held-out patients: how many fall in each
-- tier and how many of those return within 30 days. The last column
-- is a scenario, not a result: readmissions avoided if a follow-up
-- programme cut the tier's readmissions by one fifth. The 20% figure
-- is an assumption, to be replaced by the effect of whichever
-- programme the hospital actually runs.
-- ---------------------------------------------------------------------
SELECT risk_tier,
       ROUND(1000 * stays / SUM(stays) OVER ())               AS discharges_per_1000,
       ROUND(1000 * readmissions / SUM(stays) OVER (), 1)     AS readmissions_per_1000,
       ROUND(0.20 * 1000 * readmissions / SUM(stays) OVER (), 1) AS avoided_per_1000_if_cut_by_20pct
FROM rpt_risk_tiers
ORDER BY risk_tier_order DESC;
