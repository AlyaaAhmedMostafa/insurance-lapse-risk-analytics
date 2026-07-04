/* ============================================================================
   MEDICAL INSURANCE — DISTRIBUTION & SALES-QUALITY DIAGNOSTICS
   + AGENT/BRANCH LAPSE OUTLIER DETECTION + PREDICTIVE MODELING
   Platform : Microsoft SQL Server (T-SQL)
   Server   : Insurance
   Source   : dbo.Policy_Data           (raw import of Policy_Data.csv)
   Output   : dbo.Policy_Data_Clean     (analysis-ready table)
              dbo.Agent_Outliers        (permanent staging table, Section 2)
              dbo.Branch_Outliers       (permanent staging table, Section 3)
              dbo.Audit_Candidates      (Section 4)
              dbo.Model_Features / dbo.Model_Coefficients / dbo.Lapse_LPM_Scores
   ----------------------------------------------------------------------------
   STORY / READING ORDER
   0. Build the clean, typed working table from the raw import
   1. Derive analytical flags on the clean table (early-lapse, tenure buckets,
      Q4 seasonality) — every later section reads from here, so this always
      runs first and defines what "early lapse" means for the rest of the script.
   2. Agent-level early-lapse outlier detection   (Agency channel)
   3. Branch-level early-lapse outlier detection   (Bancassurance channel)
   4. Combined audit-candidate register — unions Sections 2 & 3's saved
      results (no recomputation, no temp-table session dependency)
   5. Agent tenure effect (+ chi-square test of independence)
   6. Seasonality / Q4 year-end push analysis
   7. Predictive modeling — linear probability model via normal equations,
      solved in-database with Gauss-Jordan elimination
        7a. Build feature matrix (dbo.Model_Features)
        7b. Build & solve the 6x6 normal-equations system
        7c. Extract coefficients
        7d. Score every policy
        7e. Validate that risk bands actually separate real lapse rates
   ============================================================================ */

USE Insurance;
GO

/* ============================================================================
   0. BUILD CLEAN WORKING TABLE
   ============================================================================ */
IF OBJECT_ID('dbo.Policy_Data_Clean','U') IS NOT NULL DROP TABLE dbo.Policy_Data_Clean;
GO

CREATE TABLE dbo.Policy_Data_Clean (
    Policy_ID                  VARCHAR(20)   NOT NULL PRIMARY KEY,
    Issue_Date                 DATE          NULL,
    Channel                    VARCHAR(20)   NULL,
    Agent_ID                   VARCHAR(20)   NULL,
    Agent_Tenure_Years         DECIMAL(5,2)  NULL,
    Bank_Partner                VARCHAR(50)   NULL,
    Branch_ID                  VARCHAR(20)   NULL,
    Region_Type                VARCHAR(20)   NULL,
    City                       VARCHAR(50)   NULL,
    Product_Type                VARCHAR(50)   NULL,
    Plan_Name                  VARCHAR(100)  NULL,
    Policy_Term_Years          INT           NULL,
    Sum_Insured                 DECIMAL(18,2) NULL,
    Annual_Premium               DECIMAL(18,2) NULL,
    Premium_Payment_Mode        VARCHAR(20)   NULL,
    Policyholder_Age             INT           NULL,
    Gender                        VARCHAR(10)   NULL,
    Income_Segment                VARCHAR(10)   NULL,
    Occupation                    VARCHAR(50)   NULL,
    Has_Rider                     BIT           NULL,
    Pre_Existing_Disease_Flag     BIT           NULL,
    Medical_Exam_Required         BIT           NULL,
    Claim_Filed_Yr1               BIT           NULL,
    Claim_Rejected                BIT           NULL,
    Policy_Status                 VARCHAR(20)   NULL,   -- Active/Lapsed/Surrendered/Matured
    Lapse_Surrender_Date          DATE          NULL,
    Lapse_Reason                  VARCHAR(60)   NULL,
    Policy_Duration_Months        INT           NULL,
    Renewal_Count                 INT           NULL,
    Persistency_13M               VARCHAR(20)   NULL,
    Persistency_25M               VARCHAR(20)   NULL,
    Persistency_37M               VARCHAR(20)   NULL,
    Persistency_49M               VARCHAR(20)   NULL,
    Persistency_61M               VARCHAR(20)   NULL,
    -- Derived analytical fields (populated in Section 1)
    Months_To_Lapse               INT           NULL,
    Early_Lapse_3M_Flag           BIT           NULL,   -- lapsed/surrendered within 3 months of issue (mis-sell signal)
    Lapsed_Flag                   BIT           NULL,   -- Policy_Status IN ('Lapsed','Surrendered'), any timing
    Issue_Year                    INT           NULL,
    Issue_Quarter                 TINYINT       NULL,
    Is_Q4_Issue                   BIT           NULL,
    Tenure_Bucket                 VARCHAR(20)   NULL
);
GO

-- NOTE: Has_Rider / Pre_Existing_Disease_Flag / Medical_Exam_Required /
-- Claim_Filed_Yr1 / Claim_Rejected are read here as text ('True'/'False') from
-- the raw CSV import. If dbo.Policy_Data stores these as BIT/INT already,
-- remove the UPPER(...) = 'TRUE' comparisons below and pass the columns
-- through TRY_CONVERT(BIT, ...) instead, or the INSERT will fail outright.
INSERT INTO dbo.Policy_Data_Clean (
    Policy_ID, Issue_Date, Channel, Agent_ID, Agent_Tenure_Years, Bank_Partner, Branch_ID,
    Region_Type, City, Product_Type, Plan_Name, Policy_Term_Years, Sum_Insured, Annual_Premium,
    Premium_Payment_Mode, Policyholder_Age, Gender, Income_Segment, Occupation, Has_Rider,
    Pre_Existing_Disease_Flag, Medical_Exam_Required, Claim_Filed_Yr1, Claim_Rejected,
    Policy_Status, Lapse_Surrender_Date, Lapse_Reason, Policy_Duration_Months, Renewal_Count,
    Persistency_13M, Persistency_25M, Persistency_37M, Persistency_49M, Persistency_61M
)
SELECT
    Policy_ID,
    TRY_CONVERT(DATE, Issue_Date),
    Channel,
    NULLIF(Agent_ID,''),
    TRY_CONVERT(DECIMAL(5,2), Agent_Tenure_Years_At_Issue),
    NULLIF(Bank_Partner,''),
    NULLIF(Branch_ID,''),
    Region_Type,
    City,
    Product_Type,
    Plan_Name,
    TRY_CONVERT(INT, Policy_Term_Years),
    TRY_CONVERT(DECIMAL(18,2), REPLACE(Sum_Insured, ',', '')),
    TRY_CONVERT(DECIMAL(18,2), REPLACE(Annual_Premium, ',', '')),
    Premium_Payment_Mode,
    TRY_CONVERT(INT, Policyholder_Age),
    Gender,
    NULLIF(Income_Segment,''),
    Occupation,
    CASE WHEN UPPER(Has_Rider) = 'TRUE' THEN 1 WHEN UPPER(Has_Rider) = 'FALSE' THEN 0 END,
    CASE WHEN UPPER(Pre_Existing_Disease_Flag) = 'TRUE' THEN 1 WHEN UPPER(Pre_Existing_Disease_Flag) = 'FALSE' THEN 0 END,
    CASE WHEN UPPER(Medical_Exam_Required) = 'TRUE' THEN 1 WHEN UPPER(Medical_Exam_Required) = 'FALSE' THEN 0 END,
    CASE WHEN UPPER(Claim_Filed_Yr1) = 'TRUE' THEN 1 WHEN UPPER(Claim_Filed_Yr1) = 'FALSE' THEN 0 END,
    CASE WHEN UPPER(Claim_Rejected) = 'TRUE' THEN 1 WHEN UPPER(Claim_Rejected) = 'FALSE' THEN 0 END,
    Policy_Status,
    TRY_CONVERT(DATE, Lapse_Surrender_Date),
    NULLIF(Lapse_Reason,''),
    TRY_CONVERT(INT, Policy_Duration_Months),
    TRY_CONVERT(INT, Renewal_Count),
    Persistency_13M, Persistency_25M, Persistency_37M, Persistency_49M, Persistency_61M
FROM dbo.Policy_Data;
GO

/* ============================================================================
   1. DERIVED FIELDS — this defines "early lapse" for the whole script.
      Everything downstream (Sections 2-7) reads Early_Lapse_3M_Flag from
      HERE, on the clean table — not recomputed ad hoc from raw Policy_Data.
   ============================================================================ */
UPDATE dbo.Policy_Data_Clean
SET
    Lapsed_Flag    = CASE WHEN Policy_Status IN ('Lapsed','Surrendered') THEN 1 ELSE 0 END,
    Months_To_Lapse = CASE WHEN Lapse_Surrender_Date IS NOT NULL AND Issue_Date IS NOT NULL
                            THEN DATEDIFF(MONTH, Issue_Date, Lapse_Surrender_Date) END,
    Issue_Year      = YEAR(Issue_Date),
    Issue_Quarter   = DATEPART(QUARTER, Issue_Date),
    Is_Q4_Issue     = CASE WHEN DATEPART(QUARTER, Issue_Date) = 4 THEN 1 ELSE 0 END,
    Tenure_Bucket   = CASE
                          WHEN Agent_Tenure_Years IS NULL THEN 'N/A (Bancassurance)'
                          WHEN Agent_Tenure_Years < 1  THEN '<1 yr'
                          WHEN Agent_Tenure_Years < 3  THEN '1-3 yrs'
                          WHEN Agent_Tenure_Years < 5  THEN '3-5 yrs'
                          ELSE '5+ yrs'
                       END;
GO

-- Early lapse = lapsed/surrendered AND event occurred within 3 months of issue.
-- Uses actual date gap where available, else Policy_Duration_Months as fallback.
UPDATE dbo.Policy_Data_Clean
SET Early_Lapse_3M_Flag =
    CASE
        WHEN Lapsed_Flag = 1 AND Months_To_Lapse IS NOT NULL AND Months_To_Lapse <= 3 THEN 1
        WHEN Lapsed_Flag = 1 AND Months_To_Lapse IS NULL AND Policy_Duration_Months <= 3 THEN 1
        ELSE 0
    END;
GO

CREATE INDEX IX_PDC_Agent   ON dbo.Policy_Data_Clean(Agent_ID);
CREATE INDEX IX_PDC_Branch  ON dbo.Policy_Data_Clean(Branch_ID);
CREATE INDEX IX_PDC_Issue   ON dbo.Policy_Data_Clean(Issue_Date);
GO

/* ============================================================================
   2. AGENT-LEVEL EARLY-LAPSE OUTLIER DETECTION  (Agency channel)
   ----------------------------------------------------------------------------
   Method: for agents with at least @MinPolicies issued, compute the 3-month
   early-lapse rate (Early_Lapse_3M_Flag from Section 1); flag as outlier if
   the rate exceeds the population mean by >= 2 standard deviations (z-score)
   AND exceeds an absolute floor of 15% (avoids flagging agents whose one bad
   case looks extreme purely due to tiny volume).
   Result is saved to dbo.Agent_Outliers (permanent) so Section 4 can reuse it
   without recomputation or temp-table session dependency.
   ============================================================================ */
IF OBJECT_ID('dbo.Agent_Outliers','U') IS NOT NULL DROP TABLE dbo.Agent_Outliers;
GO

DECLARE @MinPolicies INT = 15;

WITH AgentStats AS (
    SELECT
        Agent_ID,
        COUNT(*)                                              AS Policies_Issued,
        SUM(CAST(Early_Lapse_3M_Flag AS INT))                  AS Early_Lapse_Count,
        CAST(SUM(CAST(Early_Lapse_3M_Flag AS INT)) AS DECIMAL(9,4)) / COUNT(*) AS Early_Lapse_Rate,
        SUM(CAST(Lapsed_Flag AS INT))                          AS Total_Lapse_Count,
        CAST(SUM(CAST(Lapsed_Flag AS INT)) AS DECIMAL(9,4)) / COUNT(*)          AS Overall_Lapse_Rate
    FROM dbo.Policy_Data_Clean
    WHERE Channel = 'Agency' AND Agent_ID IS NOT NULL
    GROUP BY Agent_ID
    HAVING COUNT(*) >= @MinPolicies
),
PopStats AS (
    SELECT AVG(Early_Lapse_Rate) AS Pop_Mean, STDEV(Early_Lapse_Rate) AS Pop_StDev
    FROM AgentStats
)
SELECT
    a.Agent_ID,
    a.Policies_Issued,
    a.Early_Lapse_Count,
    ROUND(a.Early_Lapse_Rate * 100, 2)   AS Early_Lapse_Rate_Pct,
    ROUND(a.Overall_Lapse_Rate * 100, 2) AS Overall_Lapse_Rate_Pct,
    ROUND(p.Pop_Mean * 100, 2)           AS Peer_Avg_Early_Lapse_Pct,
    ROUND((a.Early_Lapse_Rate - p.Pop_Mean) / NULLIF(p.Pop_StDev,0), 2) AS Z_Score,
    CASE
        WHEN (a.Early_Lapse_Rate - p.Pop_Mean) / NULLIF(p.Pop_StDev,0) >= 2
             AND a.Early_Lapse_Rate >= 0.15
        THEN 'AUDIT CANDIDATE - HIGH'
        WHEN (a.Early_Lapse_Rate - p.Pop_Mean) / NULLIF(p.Pop_StDev,0) >= 1.5
        THEN 'WATCHLIST'
        ELSE 'NORMAL'
    END AS Risk_Flag
INTO dbo.Agent_Outliers
FROM AgentStats a
CROSS JOIN PopStats p;

SELECT * FROM dbo.Agent_Outliers ORDER BY Z_Score DESC;
GO

/* ============================================================================
   3. BRANCH-LEVEL EARLY-LAPSE OUTLIER DETECTION  (Bancassurance channel)
      Same method as Section 2, applied to branches. Saved to
      dbo.Branch_Outliers (permanent) for reuse in Section 4.
   ============================================================================ */
IF OBJECT_ID('dbo.Branch_Outliers','U') IS NOT NULL DROP TABLE dbo.Branch_Outliers;
GO

DECLARE @MinPoliciesBranch INT = 15;

WITH BranchStats AS (
    SELECT
        Branch_ID,
        Bank_Partner,
        COUNT(*)                                               AS Policies_Issued,
        SUM(CAST(Early_Lapse_3M_Flag AS INT))                   AS Early_Lapse_Count,
        CAST(SUM(CAST(Early_Lapse_3M_Flag AS INT)) AS DECIMAL(9,4)) / COUNT(*) AS Early_Lapse_Rate,
        SUM(CAST(Lapsed_Flag AS INT))                           AS Total_Lapse_Count,
        CAST(SUM(CAST(Lapsed_Flag AS INT)) AS DECIMAL(9,4)) / COUNT(*)          AS Overall_Lapse_Rate
    FROM dbo.Policy_Data_Clean
    WHERE Channel = 'Bancassurance' AND Branch_ID IS NOT NULL
    GROUP BY Branch_ID, Bank_Partner
    HAVING COUNT(*) >= @MinPoliciesBranch
),
PopStatsB AS (
    SELECT AVG(Early_Lapse_Rate) AS Pop_Mean, STDEV(Early_Lapse_Rate) AS Pop_StDev
    FROM BranchStats
)
SELECT
    b.Branch_ID,
    b.Bank_Partner,
    b.Policies_Issued,
    b.Early_Lapse_Count,
    ROUND(b.Early_Lapse_Rate * 100, 2)   AS Early_Lapse_Rate_Pct,
    ROUND(b.Overall_Lapse_Rate * 100, 2) AS Overall_Lapse_Rate_Pct,
    ROUND(p.Pop_Mean * 100, 2)           AS Peer_Avg_Early_Lapse_Pct,
    ROUND((b.Early_Lapse_Rate - p.Pop_Mean) / NULLIF(p.Pop_StDev,0), 2) AS Z_Score,
    CASE
        WHEN (b.Early_Lapse_Rate - p.Pop_Mean) / NULLIF(p.Pop_StDev,0) >= 2
             AND b.Early_Lapse_Rate >= 0.15
        THEN 'AUDIT CANDIDATE - HIGH'
        WHEN (b.Early_Lapse_Rate - p.Pop_Mean) / NULLIF(p.Pop_StDev,0) >= 1.5
        THEN 'WATCHLIST'
        ELSE 'NORMAL'
    END AS Risk_Flag
INTO dbo.Branch_Outliers
FROM BranchStats b
CROSS JOIN PopStatsB p;

SELECT * FROM dbo.Branch_Outliers ORDER BY Z_Score DESC;
GO

/* ============================================================================
   4. COMBINED AUDIT-CANDIDATE REGISTER
      Simply unions the saved results of Sections 2 & 3 — no recomputation,
      so this is safe to run any time after Sections 2 & 3 have completed at
      least once (does NOT require the same session/connection).
   ============================================================================ */
IF OBJECT_ID('dbo.Audit_Candidates','U') IS NOT NULL DROP TABLE dbo.Audit_Candidates;
GO

SELECT 'Agent' AS Entity_Type, CAST(Agent_ID AS VARCHAR(50)) AS Entity_ID, Policies_Issued,
       Early_Lapse_Rate_Pct, Z_Score, Risk_Flag
INTO dbo.Audit_Candidates
FROM dbo.Agent_Outliers WHERE Risk_Flag <> 'NORMAL'
UNION ALL
SELECT 'Branch', CAST(Branch_ID AS VARCHAR(50)), Policies_Issued,
       Early_Lapse_Rate_Pct, Z_Score, Risk_Flag
FROM dbo.Branch_Outliers WHERE Risk_Flag <> 'NORMAL';

SELECT * FROM dbo.Audit_Candidates ORDER BY Z_Score DESC;
GO

/* ============================================================================
   5. AGENT TENURE EFFECT  (<1 yr tenure vs. rest)
      Uses the same Early_Lapse_3M_Flag definition as Sections 2-4, so results
      here are directly comparable to the outlier register above.
   ============================================================================ */
SELECT
    Tenure_Bucket,
    COUNT(*)                                                             AS Policies_Issued,
    SUM(CAST(Lapsed_Flag AS INT))                                        AS Lapsed_Count,
    ROUND(100.0 * SUM(CAST(Lapsed_Flag AS INT)) / COUNT(*), 2)           AS Overall_Lapse_Rate_Pct,
    SUM(CAST(Early_Lapse_3M_Flag AS INT))                                AS Early_Lapse_Count,
    ROUND(100.0 * SUM(CAST(Early_Lapse_3M_Flag AS INT)) / COUNT(*), 2)   AS Early_Lapse_Rate_Pct
FROM dbo.Policy_Data_Clean
WHERE Channel = 'Agency'
GROUP BY Tenure_Bucket
ORDER BY CASE Tenure_Bucket
            WHEN '<1 yr' THEN 1 WHEN '1-3 yrs' THEN 2
            WHEN '3-5 yrs' THEN 3 WHEN '5+ yrs' THEN 4 ELSE 5 END;
GO

-- Binary comparison: <1yr tenure vs everyone else, feeding the chi-square
-- test of independence below (Tenure<1yr  x  Early-Lapse Y/N).
WITH Binary AS (
    SELECT
        CASE WHEN Agent_Tenure_Years < 1 THEN 'Tenure <1yr' ELSE 'Tenure >=1yr' END AS Group_Label,
        Early_Lapse_3M_Flag
    FROM dbo.Policy_Data_Clean
    WHERE Channel = 'Agency' AND Agent_Tenure_Years IS NOT NULL
)
SELECT
    Group_Label,
    COUNT(*)                                                            AS N,
    SUM(CAST(Early_Lapse_3M_Flag AS INT))                                AS Early_Lapse_Yes,
    COUNT(*) - SUM(CAST(Early_Lapse_3M_Flag AS INT))                     AS Early_Lapse_No,
    ROUND(100.0 * SUM(CAST(Early_Lapse_3M_Flag AS INT)) / COUNT(*), 2)   AS Early_Lapse_Rate_Pct
FROM Binary
GROUP BY Group_Label;
GO

-- Chi-square statistic computed directly from the 2x2 table above.
-- df = 1; compare Chi_Square_Stat to 3.841 (p<0.05) or 6.635 (p<0.01).
WITH Binary AS (
    SELECT
        CASE WHEN Agent_Tenure_Years < 1 THEN 1 ELSE 0 END AS Is_New_Agent,
        Early_Lapse_3M_Flag
    FROM dbo.Policy_Data_Clean
    WHERE Channel = 'Agency' AND Agent_Tenure_Years IS NOT NULL
),
Cell AS (
    SELECT
        SUM(CASE WHEN Is_New_Agent=1 AND Early_Lapse_3M_Flag=1 THEN 1 ELSE 0 END) AS A,
        SUM(CASE WHEN Is_New_Agent=1 AND Early_Lapse_3M_Flag=0 THEN 1 ELSE 0 END) AS B,
        SUM(CASE WHEN Is_New_Agent=0 AND Early_Lapse_3M_Flag=1 THEN 1 ELSE 0 END) AS C,
        SUM(CASE WHEN Is_New_Agent=0 AND Early_Lapse_3M_Flag=0 THEN 1 ELSE 0 END) AS D
    FROM Binary
)
SELECT A, B, C, D,
       (A+B+C+D) AS N_Total,
       CAST((A+B+C+D) AS FLOAT) * POWER(CAST(A AS FLOAT)*D - CAST(B AS FLOAT)*C, 2)
         / NULLIF( (A+B)*1.0*(C+D)*(A+C)*(B+D), 0)  AS Chi_Square_Stat
FROM Cell;
GO

/* ============================================================================
   6. SEASONALITY: Q4 YEAR-END PUSH vs. REST OF YEAR
   ============================================================================ */
SELECT
    Is_Q4_Issue,
    Issue_Quarter,
    COUNT(*)                                                              AS Policies_Issued,
    SUM(CAST(Lapsed_Flag AS INT))                                          AS Lapsed_Count,
    ROUND(100.0 * SUM(CAST(Lapsed_Flag AS INT)) / COUNT(*), 2)             AS Overall_Lapse_Rate_Pct,
    SUM(CAST(Early_Lapse_3M_Flag AS INT))                                   AS Early_Lapse_Count,
    ROUND(100.0 * SUM(CAST(Early_Lapse_3M_Flag AS INT)) / COUNT(*), 2)      AS Early_Lapse_Rate_Pct,
    ROUND(100.0 * SUM(CASE WHEN Persistency_13M = 'Persisted' THEN 1 ELSE 0 END)
          / NULLIF(SUM(CASE WHEN Persistency_13M IN ('Persisted','Lapsed') THEN 1 ELSE 0 END),0), 2) AS Persistency_13M_Pct
FROM dbo.Policy_Data_Clean
GROUP BY Is_Q4_Issue, Issue_Quarter
ORDER BY Issue_Quarter;
GO

-- Year-over-year Q4 vs non-Q4 trend, to check if the effect is consistent or worsening.
SELECT
    Issue_Year,
    Is_Q4_Issue,
    COUNT(*)                                                          AS Policies_Issued,
    ROUND(100.0 * SUM(CAST(Early_Lapse_3M_Flag AS INT)) / COUNT(*), 2) AS Early_Lapse_Rate_Pct
FROM dbo.Policy_Data_Clean
WHERE Issue_Year IS NOT NULL
GROUP BY Issue_Year, Is_Q4_Issue
ORDER BY Issue_Year, Is_Q4_Issue;
GO

/* ============================================================================
   7. PREDICTIVE MODELING — linear probability model, fit in-database
   ----------------------------------------------------------------------------
   Target (Y)  : Early_Lapse_3M_Flag (0/1) — swap to Lapsed_Flag to predict
                 overall lapse instead of early/mis-sell risk.
   Predictors  : Intercept, Agent_Tenure_Years (mean-imputed), Is_Q4_Issue,
                 Premium_Monthly flag, Is_Bancassurance flag, Income_Low flag.
   Method      : Ordinary least squares via the normal equations
                 (X'X)*Beta = X'Y, solved with Gauss-Jordan elimination.
                 This is a linear probability model, not logistic regression —
                 fine for ranking/risk-banding, but predictions are only
                 clipped to [0,1] afterward rather than naturally bounded.
   Requires    : dbo.Policy_Data_Clean already built (Sections 0-1 above).
   ============================================================================ */

/* ---- 7a. Feature matrix ---------------------------------------------------- */
IF OBJECT_ID('dbo.Model_Features','U') IS NOT NULL DROP TABLE dbo.Model_Features;
GO

SELECT
    Policy_ID,
    1.0 AS X0_Intercept,
    COALESCE(Agent_Tenure_Years, AVG(Agent_Tenure_Years) OVER()) AS X1_Tenure,
    CAST(Is_Q4_Issue AS FLOAT)                                              AS X2_Q4,
    CAST(CASE WHEN Premium_Payment_Mode = 'Monthly' THEN 1 ELSE 0 END AS FLOAT) AS X3_Monthly,
    CAST(CASE WHEN Channel = 'Bancassurance' THEN 1 ELSE 0 END AS FLOAT)   AS X4_Banca,
    CAST(CASE WHEN Income_Segment = 'Low' THEN 1 ELSE 0 END AS FLOAT)      AS X5_LowIncome,
    CAST(Early_Lapse_3M_Flag AS FLOAT)                                      AS Y
INTO dbo.Model_Features
FROM dbo.Policy_Data_Clean
WHERE Early_Lapse_3M_Flag IS NOT NULL;
GO

/* ---- 7b. Build the 6x6 augmented matrix [ X'X | X'Y ] --------------------- */
IF OBJECT_ID('tempdb..#Matrix') IS NOT NULL DROP TABLE #Matrix;
CREATE TABLE #Matrix (RowID INT PRIMARY KEY, C1 FLOAT, C2 FLOAT, C3 FLOAT, C4 FLOAT, C5 FLOAT, C6 FLOAT, C7 FLOAT);

INSERT INTO #Matrix
SELECT 1,
    SUM(X0_Intercept*X0_Intercept), SUM(X0_Intercept*X1_Tenure), SUM(X0_Intercept*X2_Q4),
    SUM(X0_Intercept*X3_Monthly),   SUM(X0_Intercept*X4_Banca),  SUM(X0_Intercept*X5_LowIncome),
    SUM(X0_Intercept*Y)
FROM dbo.Model_Features
UNION ALL
SELECT 2,
    SUM(X1_Tenure*X0_Intercept), SUM(X1_Tenure*X1_Tenure), SUM(X1_Tenure*X2_Q4),
    SUM(X1_Tenure*X3_Monthly),   SUM(X1_Tenure*X4_Banca),  SUM(X1_Tenure*X5_LowIncome),
    SUM(X1_Tenure*Y)
FROM dbo.Model_Features
UNION ALL
SELECT 3,
    SUM(X2_Q4*X0_Intercept), SUM(X2_Q4*X1_Tenure), SUM(X2_Q4*X2_Q4),
    SUM(X2_Q4*X3_Monthly),   SUM(X2_Q4*X4_Banca),  SUM(X2_Q4*X5_LowIncome),
    SUM(X2_Q4*Y)
FROM dbo.Model_Features
UNION ALL
SELECT 4,
    SUM(X3_Monthly*X0_Intercept), SUM(X3_Monthly*X1_Tenure), SUM(X3_Monthly*X2_Q4),
    SUM(X3_Monthly*X3_Monthly),   SUM(X3_Monthly*X4_Banca),  SUM(X3_Monthly*X5_LowIncome),
    SUM(X3_Monthly*Y)
FROM dbo.Model_Features
UNION ALL
SELECT 5,
    SUM(X4_Banca*X0_Intercept), SUM(X4_Banca*X1_Tenure), SUM(X4_Banca*X2_Q4),
    SUM(X4_Banca*X3_Monthly),   SUM(X4_Banca*X4_Banca),  SUM(X4_Banca*X5_LowIncome),
    SUM(X4_Banca*Y)
FROM dbo.Model_Features
UNION ALL
SELECT 6,
    SUM(X5_LowIncome*X0_Intercept), SUM(X5_LowIncome*X1_Tenure), SUM(X5_LowIncome*X2_Q4),
    SUM(X5_LowIncome*X3_Monthly),   SUM(X5_LowIncome*X4_Banca),  SUM(X5_LowIncome*X5_LowIncome),
    SUM(X5_LowIncome*Y)
FROM dbo.Model_Features;
GO

/* ---- Gauss-Jordan elimination — solves the 6x6 system in-place inside
        #Matrix. After this runs, column C7 of each row holds that row's
        Beta coefficient. NOTE: if a predictor is a near-perfect linear
        combination of the others (severe multicollinearity), a pivot can be
        ~0 and this will error with a divide-by-zero — drop/replace that
        predictor if so. ------------------------------------------------- */
DECLARE @k INT = 1, @sql NVARCHAR(MAX);

WHILE @k <= 6
BEGIN
    -- Normalize pivot row: divide every column of row k by its pivot value
    SET @sql = N'
        DECLARE @piv FLOAT;
        SELECT @piv = CASE 
            WHEN @k = 1 THEN C1 
            WHEN @k = 2 THEN C2 
            WHEN @k = 3 THEN C3 
            WHEN @k = 4 THEN C4 
            WHEN @k = 5 THEN C5 
            WHEN @k = 6 THEN C6 
        END FROM #Matrix WHERE RowID = @k;
        IF @piv IS NULL OR @piv = 0
            THROW 50000, ''Singular matrix at pivot row - remove a collinear predictor.'', 1;
            
        UPDATE #Matrix SET 
            C1=C1/@piv, C2=C2/@piv, C3=C3/@piv, C4=C4/@piv, C5=C5/@piv, C6=C6/@piv, C7=C7/@piv
        WHERE RowID = @k;';
    EXEC sp_executesql @sql, N'@k INT', @k = @k;

    -- Eliminate column k from every other row
    SET @sql = N'
        DECLARE @p1 FLOAT,@p2 FLOAT,@p3 FLOAT,@p4 FLOAT,@p5 FLOAT,@p6 FLOAT,@p7 FLOAT;
        SELECT @p1=C1,@p2=C2,@p3=C3,@p4=C4,@p5=C5,@p6=C6,@p7=C7 FROM #Matrix WHERE RowID=' + CAST(@k AS NVARCHAR) + N';
        UPDATE #Matrix SET
            C1 = C1 - C' + CAST(@k AS NVARCHAR) + N' * @p1,
            C2 = C2 - C' + CAST(@k AS NVARCHAR) + N' * @p2,
            C3 = C3 - C' + CAST(@k AS NVARCHAR) + N' * @p3,
            C4 = C4 - C' + CAST(@k AS NVARCHAR) + N' * @p4,
            C5 = C5 - C' + CAST(@k AS NVARCHAR) + N' * @p5,
            C6 = C6 - C' + CAST(@k AS NVARCHAR) + N' * @p6,
            C7 = C7 - C' + CAST(@k AS NVARCHAR) + N' * @p7
        WHERE RowID <> ' + CAST(@k AS NVARCHAR) + N';';
    EXEC sp_executesql @sql;

    SET @k += 1;
END
GO

/* ---- 7c. Extract fitted coefficients --------------------------------------- */
IF OBJECT_ID('dbo.Model_Coefficients','U') IS NOT NULL DROP TABLE dbo.Model_Coefficients;
GO
SELECT
    RowID,
    CASE RowID
        WHEN 1 THEN 'Intercept'
        WHEN 2 THEN 'Agent_Tenure_Years'
        WHEN 3 THEN 'Is_Q4_Issue'
        WHEN 4 THEN 'Premium_Monthly'
        WHEN 5 THEN 'Is_Bancassurance'
        WHEN 6 THEN 'Income_Low'
    END AS Predictor,
    C7 AS Beta
INTO dbo.Model_Coefficients
FROM #Matrix;

SELECT * FROM dbo.Model_Coefficients ORDER BY RowID;
GO

/* ---- 7d. Score every policy (predicted early-lapse probability, clipped) -- */
IF OBJECT_ID('dbo.Lapse_LPM_Scores','U') IS NOT NULL DROP TABLE dbo.Lapse_LPM_Scores;
GO

DECLARE @B0 FLOAT, @B1 FLOAT, @B2 FLOAT, @B3 FLOAT, @B4 FLOAT, @B5 FLOAT;
SELECT @B0 = Beta FROM dbo.Model_Coefficients WHERE RowID = 1;
SELECT @B1 = Beta FROM dbo.Model_Coefficients WHERE RowID = 2;
SELECT @B2 = Beta FROM dbo.Model_Coefficients WHERE RowID = 3;
SELECT @B3 = Beta FROM dbo.Model_Coefficients WHERE RowID = 4;
SELECT @B4 = Beta FROM dbo.Model_Coefficients WHERE RowID = 5;
SELECT @B5 = Beta FROM dbo.Model_Coefficients WHERE RowID = 6;

SELECT
    Policy_ID,
    (@B0 + @B1*X1_Tenure + @B2*X2_Q4 + @B3*X3_Monthly + @B4*X4_Banca + @B5*X5_LowIncome) AS Raw_Score,
    CASE
        WHEN (@B0 + @B1*X1_Tenure + @B2*X2_Q4 + @B3*X3_Monthly + @B4*X4_Banca + @B5*X5_LowIncome) < 0 THEN 0
        WHEN (@B0 + @B1*X1_Tenure + @B2*X2_Q4 + @B3*X3_Monthly + @B4*X4_Banca + @B5*X5_LowIncome) > 1 THEN 1
        ELSE (@B0 + @B1*X1_Tenure + @B2*X2_Q4 + @B3*X3_Monthly + @B4*X4_Banca + @B5*X5_LowIncome)
    END AS Predicted_Lapse_Prob,
    CASE
        WHEN (@B0 + @B1*X1_Tenure + @B2*X2_Q4 + @B3*X3_Monthly + @B4*X4_Banca + @B5*X5_LowIncome) >= 0.45 THEN 'High'
        WHEN (@B0 + @B1*X1_Tenure + @B2*X2_Q4 + @B3*X3_Monthly + @B4*X4_Banca + @B5*X5_LowIncome) >= 0.20 THEN 'Medium'
        ELSE 'Low'
    END AS Risk_Band
INTO dbo.Lapse_LPM_Scores
FROM dbo.Model_Features;

SELECT * FROM dbo.Lapse_LPM_Scores ORDER BY Predicted_Lapse_Prob DESC;
GO

/* ---- 7e. Validation — does the model actually separate real lapse rates? -- */
SELECT
    s.Risk_Band,
    COUNT(*)                                                              AS Policies,
    ROUND(100.0 * SUM(CAST(f.Y AS INT)) / COUNT(*), 2)                    AS Actual_Early_Lapse_Rate_Pct,
    ROUND(AVG(s.Predicted_Lapse_Prob) * 100, 2)                           AS Avg_Predicted_Prob_Pct
FROM dbo.Lapse_LPM_Scores s
JOIN dbo.Model_Features f ON f.Policy_ID = s.Policy_ID
GROUP BY s.Risk_Band
ORDER BY CASE s.Risk_Band WHEN 'High' THEN 1 WHEN 'Medium' THEN 2 ELSE 3 END;
GO