/* ============================================================================
   INSURANCE — PERSISTENCY & LAPSE ANALYTICS
   ============================================================================
   A single, ordered pipeline:
     1. Clean the raw policy table
     2. Measure persistency (overall, by channel, product, cohort)
     3. Diagnose the Agency vs Bancassurance gap
     4. Test payment-mode impact on lapse
     5. Flag agent/branch outliers (mis-selling / audit candidates)
     6. Check new-business quality (Q4 push, agent tenure)
     7. Break down lapse reasons and claims-driven attrition
     8. Compare rural vs urban servicing
     9. Build a predictive lapse-risk scorecard
    10. Produce the retention team's priority call list

   Run top to bottom in one execution (or select an entire numbered
   section at a time) — later steps depend on objects created earlier.
   ============================================================================ */
USE Insurance;
GO

/* ============================================================================
   1. DATA CLEANING
      Dedupe, type-cast, standardize text, drop invalid records.
      Cleans dbo.Policy_Data in place and logs the result for governance.
   ============================================================================ */

-- 1.1 Helper: SQL Server has no built-in INITCAP, needed to fix City casing
IF OBJECT_ID('dbo.fn_TitleCase', 'FN') IS NOT NULL DROP FUNCTION dbo.fn_TitleCase;
GO
CREATE FUNCTION dbo.fn_TitleCase (@Input VARCHAR(200))
RETURNS VARCHAR(200)
AS
BEGIN
    DECLARE @Result VARCHAR(200) = '';
    DECLARE @i INT = 1;
    DECLARE @PrevIsSpace BIT = 1;
    DECLARE @Char CHAR(1);

    IF @Input IS NULL RETURN NULL;

    WHILE @i <= LEN(@Input)
    BEGIN
        SET @Char = SUBSTRING(@Input, @i, 1);
        SET @Result = @Result + CASE WHEN @PrevIsSpace = 1 THEN UPPER(@Char) ELSE LOWER(@Char) END;
        SET @PrevIsSpace = CASE WHEN @Char = ' ' THEN 1 ELSE 0 END;
        SET @i += 1;
    END
    RETURN @Result;
END
GO

-- 1.2 Dedupe: exact duplicate rows, then duplicate Policy_IDs (keep first)
DECLARE @RawRowCount INT = (SELECT COUNT(*) FROM dbo.Policy_Data);

IF OBJECT_ID('tempdb..#Deduped') IS NOT NULL DROP TABLE #Deduped;
WITH Ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY Policy_ID ORDER BY (SELECT NULL)) AS rn
    FROM (SELECT DISTINCT * FROM dbo.Policy_Data) AS DistinctRows
)
SELECT * INTO #Deduped FROM Ranked WHERE rn = 1;

-- 1.3 Type-cast, standardize text, and filter out bad records
TRUNCATE TABLE dbo.Policy_Data;

INSERT INTO dbo.Policy_Data (
    Policy_ID, Issue_Date, Channel, Agent_ID, Agent_Tenure_Years_At_Issue,
    Bank_Partner, Branch_ID, Region_Type, City, Product_Type, Plan_Name,
    Policy_Term_Years, Sum_Insured, Annual_Premium, Premium_Payment_Mode,
    Policyholder_Age, Gender, Income_Segment, Occupation, Has_Rider,
    Pre_Existing_Disease_Flag, Medical_Exam_Required, Claim_Filed_Yr1,
    Claim_Rejected, Policy_Status, Lapse_Surrender_Date, Lapse_Reason,
    Policy_Duration_Months, Renewal_Count, Persistency_13M, Persistency_25M,
    Persistency_37M, Persistency_49M, Persistency_61M
)
SELECT
    Policy_ID,
    TRY_CONVERT(DATE, Issue_Date),
    Channel,
    NULLIF(Agent_ID, ''),
    TRY_CONVERT(DECIMAL(5,2), Agent_Tenure_Years_At_Issue),
    NULLIF(Bank_Partner, ''),
    NULLIF(Branch_ID, ''),
    Region_Type,
    dbo.fn_TitleCase(LTRIM(RTRIM(City))),                  -- "  cairo " / "CAIRO" -> "Cairo"
    Product_Type,
    Plan_Name,
    TRY_CONVERT(SMALLINT, Policy_Term_Years),
    TRY_CONVERT(DECIMAL(14,2), Sum_Insured),
    TRY_CONVERT(DECIMAL(12,2), Annual_Premium),
    Premium_Payment_Mode,
    TRY_CONVERT(SMALLINT, Policyholder_Age),
    CASE WHEN LOWER(LTRIM(RTRIM(Gender))) IN ('m','male')   THEN 'Male'
         WHEN LOWER(LTRIM(RTRIM(Gender))) IN ('f','female') THEN 'Female'
         ELSE NULL END,
    NULLIF(Income_Segment, ''),
    NULLIF(Occupation, ''),
    CASE WHEN LOWER(Has_Rider) IN ('true','1','yes') THEN 1 WHEN LOWER(Has_Rider) IN ('false','0','no') THEN 0 ELSE NULL END,
    CASE WHEN LOWER(Pre_Existing_Disease_Flag) IN ('true','1','yes') THEN 1 WHEN LOWER(Pre_Existing_Disease_Flag) IN ('false','0','no') THEN 0 ELSE NULL END,
    CASE WHEN LOWER(Medical_Exam_Required) IN ('true','1','yes') THEN 1 WHEN LOWER(Medical_Exam_Required) IN ('false','0','no') THEN 0 ELSE NULL END,
    CASE WHEN LOWER(Claim_Filed_Yr1) IN ('true','1','yes') THEN 1 WHEN LOWER(Claim_Filed_Yr1) IN ('false','0','no') THEN 0 ELSE NULL END,
    CASE WHEN LOWER(Claim_Rejected) IN ('true','1','yes') THEN 1 WHEN LOWER(Claim_Rejected) IN ('false','0','no') THEN 0 ELSE NULL END,
    Policy_Status,
    TRY_CONVERT(DATE, Lapse_Surrender_Date),
    NULLIF(Lapse_Reason, ''),
    TRY_CONVERT(INT, Policy_Duration_Months),
    TRY_CONVERT(INT, Renewal_Count),
    Persistency_13M, Persistency_25M, Persistency_37M, Persistency_49M, Persistency_61M
FROM #Deduped
WHERE TRY_CONVERT(SMALLINT, Policyholder_Age) BETWEEN 1 AND 100      -- drop invalid ages
  AND TRY_CONVERT(DECIMAL(12,2), Annual_Premium) > 0                 -- drop zero/invalid premiums
  AND TRY_CONVERT(DATE, Issue_Date) IS NOT NULL
  AND (NULLIF(Lapse_Surrender_Date, '') IS NULL
       OR TRY_CONVERT(DATE, Lapse_Surrender_Date) >= TRY_CONVERT(DATE, Issue_Date));  -- drop bad date logic

-- 1.4 Audit log — one row per cleaning run, for governance/repeatability
IF OBJECT_ID('dbo.Data_Cleaning_Audit', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Data_Cleaning_Audit (
        Run_Timestamp   DATETIME2 DEFAULT SYSDATETIME(),
        Raw_Rows        INT,
        Deduped_Rows    INT,
        Clean_Rows      INT,
        Rows_Dropped    AS (Deduped_Rows - Clean_Rows)
    );
END

INSERT INTO dbo.Data_Cleaning_Audit (Raw_Rows, Deduped_Rows, Clean_Rows)
SELECT @RawRowCount, (SELECT COUNT(*) FROM #Deduped), (SELECT COUNT(*) FROM dbo.Policy_Data);

SELECT * FROM dbo.Data_Cleaning_Audit ORDER BY Run_Timestamp DESC;
GO


/* ============================================================================
   2. PERSISTENCY RATIOS — overall, by channel, product, and issue cohort
      Persistency Ratio = Persisted / (Persisted + Lapsed); "Not Yet Due"
      is excluded from the base, per standard persistency methodology.
   ============================================================================ */

IF OBJECT_ID('dbo.vw_Persistency_Unpivoted', 'V') IS NOT NULL DROP VIEW dbo.vw_Persistency_Unpivoted;
GO
CREATE VIEW dbo.vw_Persistency_Unpivoted AS
SELECT
    Policy_ID, Channel, Product_Type, Region_Type, Premium_Payment_Mode,
    Agent_ID, Branch_ID, Income_Segment, Agent_Tenure_Years_At_Issue,
    YEAR(Issue_Date)                    AS Issue_Year,
    DATEPART(QUARTER, Issue_Date)       AS Issue_Quarter,
    CAST(Chkpt AS VARCHAR(10))          AS Checkpoint_Month,
    Outcome
FROM dbo.Policy_Data
CROSS APPLY (VALUES
    ('13', Persistency_13M), ('25', Persistency_25M), ('37', Persistency_37M),
    ('49', Persistency_49M), ('61', Persistency_61M)
) AS cp(Chkpt, Outcome);   -- alias avoids reserved keyword 'Checkpoint'
GO

-- 2.1 Overall persistency by checkpoint
SELECT
    Checkpoint_Month,
    COUNT(*)                                                      AS Base_Policies,
    SUM(CASE WHEN Outcome = 'Persisted' THEN 1 ELSE 0 END)        AS Persisted_Count,
    CAST(SUM(CASE WHEN Outcome = 'Persisted' THEN 1 ELSE 0 END) AS DECIMAL(10,4))
        / NULLIF(COUNT(*), 0)                                      AS Persistency_Ratio
FROM dbo.vw_Persistency_Unpivoted
WHERE Outcome IN ('Persisted', 'Lapsed')
GROUP BY Checkpoint_Month
ORDER BY CAST(Checkpoint_Month AS INT);
GO

-- 2.2 By Product_Type x Checkpoint
SELECT
    Product_Type, Checkpoint_Month,
    COUNT(*)                                                      AS Base_Policies,
    CAST(SUM(CASE WHEN Outcome = 'Persisted' THEN 1 ELSE 0 END) AS DECIMAL(10,4))
        / NULLIF(COUNT(*), 0)                                      AS Persistency_Ratio
FROM dbo.vw_Persistency_Unpivoted
WHERE Outcome IN ('Persisted', 'Lapsed')
GROUP BY Product_Type, Checkpoint_Month
ORDER BY Product_Type, CAST(Checkpoint_Month AS INT);
GO

-- 2.3 By issue-year/quarter cohort (13M checkpoint) — vintage curve
SELECT
    Issue_Year, Issue_Quarter,
    COUNT(*)                                                      AS Base_Policies,
    CAST(SUM(CASE WHEN Outcome = 'Persisted' THEN 1 ELSE 0 END) AS DECIMAL(10,4))
        / NULLIF(COUNT(*), 0)                                      AS Persistency_13M_Ratio
FROM dbo.vw_Persistency_Unpivoted
WHERE Checkpoint_Month = '13' AND Outcome IN ('Persisted', 'Lapsed')
GROUP BY Issue_Year, Issue_Quarter
ORDER BY Issue_Year, Issue_Quarter;
GO


/* ============================================================================
   3. CHANNEL DIAGNOSIS — Agency vs Bancassurance gap as policies age,
      and whether Bancassurance's growing new-business share is a risk
   ============================================================================ */

-- 3.1 Persistency gap (Agency minus Bancassurance) by checkpoint
SELECT
    Checkpoint_Month,
    MAX(CASE WHEN Channel = 'Agency' THEN Persistency_Ratio END)        AS Agency_Persistency,
    MAX(CASE WHEN Channel = 'Bancassurance' THEN Persistency_Ratio END) AS Bancassurance_Persistency,
    MAX(CASE WHEN Channel = 'Agency' THEN Persistency_Ratio END)
      - MAX(CASE WHEN Channel = 'Bancassurance' THEN Persistency_Ratio END) AS Agency_Minus_Banca_Gap
FROM (
    SELECT Channel, Checkpoint_Month,
           CAST(SUM(CASE WHEN Outcome = 'Persisted' THEN 1 ELSE 0 END) AS DECIMAL(10,4))
             / NULLIF(COUNT(*), 0) AS Persistency_Ratio
    FROM dbo.vw_Persistency_Unpivoted
    WHERE Outcome IN ('Persisted', 'Lapsed')
    GROUP BY Channel, Checkpoint_Month
) AS ChannelPersistency
GROUP BY Checkpoint_Month
ORDER BY CAST(Checkpoint_Month AS INT);
GO

-- 3.2 New-business mix shift: Bancassurance's share of issued policies by year
SELECT
    YEAR(Issue_Date)                                          AS Issue_Year,
    Channel,
    COUNT(*)                                                  AS Policies_Issued,
    CAST(COUNT(*) AS DECIMAL(10,4))
      / SUM(COUNT(*)) OVER (PARTITION BY YEAR(Issue_Date))     AS Channel_Share
FROM dbo.Policy_Data
GROUP BY YEAR(Issue_Date), Channel
ORDER BY Issue_Year, Channel;
GO


/* ============================================================================
   4. PAYMENT MODE IMPACT — lapse-rate difference by payment frequency
      (the business case for nudging customers to lower-frequency modes)
   ============================================================================ */
SELECT
    Premium_Payment_Mode, Checkpoint_Month,
    COUNT(*)                                                      AS Base_Policies,
    CAST(SUM(CASE WHEN Outcome = 'Lapsed' THEN 1 ELSE 0 END) AS DECIMAL(10,4))
        / NULLIF(COUNT(*), 0)                                      AS Lapse_Rate
FROM dbo.vw_Persistency_Unpivoted
WHERE Outcome IN ('Persisted', 'Lapsed')
GROUP BY Premium_Payment_Mode, Checkpoint_Month
ORDER BY Checkpoint_Month, Lapse_Rate DESC;
GO


/* ============================================================================
   5. DISTRIBUTION QUALITY — agents/branches with abnormally high EARLY
      lapse (within 3 months of issue) vs. their peer average: audit list
   ============================================================================ */

IF OBJECT_ID('dbo.vw_EarlyLapse_Flag', 'V') IS NOT NULL DROP VIEW dbo.vw_EarlyLapse_Flag;
GO
CREATE VIEW dbo.vw_EarlyLapse_Flag AS
SELECT
    Policy_ID, Channel, Agent_ID, Branch_ID,
    CASE WHEN Policy_Status IN ('Lapsed', 'Surrendered') AND Policy_Duration_Months <= 3
         THEN 1 ELSE 0 END AS Is_Early_Lapse
FROM dbo.Policy_Data;
GO

-- 5.1 Agent-level audit list (min. 10 policies to avoid small-sample noise)
WITH AgentStats AS (
    SELECT
        Agent_ID,
        COUNT(*)                                               AS Policy_Count,
        SUM(Is_Early_Lapse)                                     AS Early_Lapse_Count,
        CAST(SUM(Is_Early_Lapse) AS DECIMAL(10,4)) / COUNT(*)   AS Early_Lapse_Rate
    FROM dbo.vw_EarlyLapse_Flag
    WHERE Agent_ID IS NOT NULL
    GROUP BY Agent_ID
    HAVING COUNT(*) >= 10
),
Overall AS (SELECT AVG(Early_Lapse_Rate) AS Peer_Avg FROM AgentStats)
SELECT
    a.Agent_ID, a.Policy_Count, a.Early_Lapse_Count, a.Early_Lapse_Rate, o.Peer_Avg,
    a.Early_Lapse_Rate - o.Peer_Avg                             AS Excess_vs_Peer,
    CASE WHEN a.Early_Lapse_Rate > o.Peer_Avg * 2 THEN 'FLAG: AUDIT' ELSE 'Normal' END AS Audit_Flag
FROM AgentStats a CROSS JOIN Overall o
ORDER BY a.Early_Lapse_Rate DESC;
GO

-- 5.2 Branch-level audit list
WITH BranchStats AS (
    SELECT
        Branch_ID,
        COUNT(*)                                               AS Policy_Count,
        SUM(Is_Early_Lapse)                                     AS Early_Lapse_Count,
        CAST(SUM(Is_Early_Lapse) AS DECIMAL(10,4)) / COUNT(*)   AS Early_Lapse_Rate
    FROM dbo.vw_EarlyLapse_Flag
    WHERE Branch_ID IS NOT NULL
    GROUP BY Branch_ID
    HAVING COUNT(*) >= 10
),
Overall AS (SELECT AVG(Early_Lapse_Rate) AS Peer_Avg FROM BranchStats)
SELECT
    b.Branch_ID, b.Policy_Count, b.Early_Lapse_Count, b.Early_Lapse_Rate, o.Peer_Avg,
    b.Early_Lapse_Rate - o.Peer_Avg                             AS Excess_vs_Peer,
    CASE WHEN b.Early_Lapse_Rate > o.Peer_Avg * 2 THEN 'FLAG: AUDIT' ELSE 'Normal' END AS Audit_Flag
FROM BranchStats b CROSS JOIN Overall o
ORDER BY b.Early_Lapse_Rate DESC;
GO


/* ============================================================================
   6. NEW-BUSINESS QUALITY — Q4 year-end sales push, and agent tenure effect
   ============================================================================ */

-- 6.1 Q4 push vs. rest of year
SELECT
    CASE WHEN DATEPART(QUARTER, Issue_Date) = 4 THEN 'Q4 (Year-End Push)' ELSE 'Q1-Q3' END AS Issue_Window,
    COUNT(*)                                                      AS Base_Policies,
    CAST(SUM(CASE WHEN Persistency_13M = 'Persisted' THEN 1 ELSE 0 END) AS DECIMAL(10,4))
        / NULLIF(SUM(CASE WHEN Persistency_13M IN ('Persisted','Lapsed') THEN 1 ELSE 0 END), 0) AS Persistency_13M_Ratio
FROM dbo.Policy_Data
WHERE Persistency_13M IN ('Persisted', 'Lapsed')
GROUP BY CASE WHEN DATEPART(QUARTER, Issue_Date) = 4 THEN 'Q4 (Year-End Push)' ELSE 'Q1-Q3' END;
GO

-- 6.2 New agent (<1 year tenure) vs. experienced agent
SELECT
    CASE WHEN Agent_Tenure_Years_At_Issue < 1 THEN '<1 Year (New Agent)' ELSE '1+ Years' END AS Tenure_Bucket,
    COUNT(*)                                                      AS Base_Policies,
    CAST(SUM(CASE WHEN Persistency_13M = 'Persisted' THEN 1 ELSE 0 END) AS DECIMAL(10,4))
        / NULLIF(SUM(CASE WHEN Persistency_13M IN ('Persisted','Lapsed') THEN 1 ELSE 0 END), 0) AS Persistency_13M_Ratio
FROM dbo.Policy_Data
WHERE Channel = 'Agency' AND Agent_Tenure_Years_At_Issue IS NOT NULL
  AND Persistency_13M IN ('Persisted', 'Lapsed')
GROUP BY CASE WHEN Agent_Tenure_Years_At_Issue < 1 THEN '<1 Year (New Agent)' ELSE '1+ Years' END;
GO


/* ============================================================================
   7. ROOT-CAUSE ANALYSIS — lapse-reason mix, and claims-driven attrition
   ============================================================================ */

-- 7.1 Lapse reasons, split into preventable vs. structural
SELECT
    Lapse_Reason,
    COUNT(*)                                                      AS Lapse_Count,
    CAST(COUNT(*) AS DECIMAL(10,4)) / SUM(COUNT(*)) OVER ()        AS Pct_Of_All_Lapses,
    CASE
        WHEN Lapse_Reason IN ('Non-Payment', 'Affordability') THEN 'Preventable (Collections/Retention)'
        WHEN Lapse_Reason IN ('Claim Rejection Dissatisfaction', 'Suspected Mis-sell') THEN 'Service/Sales Quality (Root-Cause Fix)'
        WHEN Lapse_Reason = 'Switched Provider' THEN 'Competitive (Pricing/Product)'
        ELSE 'Other/Unknown'
    END AS Category
FROM dbo.Policy_Data
WHERE Policy_Status IN ('Lapsed', 'Surrendered') AND Lapse_Reason IS NOT NULL
GROUP BY Lapse_Reason
ORDER BY Lapse_Count DESC;
GO

-- 7.2 Impact of a rejected Yr-1 claim on subsequent lapse, and premium at risk
SELECT
    CASE
        WHEN Claim_Filed_Yr1 = 0 THEN 'No Claim Filed'
        WHEN Claim_Filed_Yr1 = 1 AND Claim_Rejected = 1 THEN 'Claim Filed & Rejected'
        WHEN Claim_Filed_Yr1 = 1 AND Claim_Rejected = 0 THEN 'Claim Filed & Paid'
    END AS Claim_Segment,
    COUNT(*)                                                      AS Base_Policies,
    CAST(SUM(CASE WHEN Persistency_25M = 'Persisted' THEN 1 ELSE 0 END) AS DECIMAL(10,4))
        / NULLIF(SUM(CASE WHEN Persistency_25M IN ('Persisted','Lapsed') THEN 1 ELSE 0 END), 0) AS Persistency_25M_Ratio,
    SUM(CASE WHEN Policy_Status = 'Active' THEN Annual_Premium ELSE 0 END) AS Inforce_Premium_At_Risk
FROM dbo.Policy_Data
WHERE Persistency_25M IN ('Persisted', 'Lapsed')
GROUP BY CASE
    WHEN Claim_Filed_Yr1 = 0 THEN 'No Claim Filed'
    WHEN Claim_Filed_Yr1 = 1 AND Claim_Rejected = 1 THEN 'Claim Filed & Rejected'
    WHEN Claim_Filed_Yr1 = 1 AND Claim_Rejected = 0 THEN 'Claim Filed & Paid'
END;
GO


/* ============================================================================
   8. RURAL vs URBAN SERVICING GAP, by channel
   ============================================================================ */
SELECT
    Region_Type, Channel,
    COUNT(*)                                                      AS Base_Policies,
    CAST(SUM(CASE WHEN Persistency_13M = 'Persisted' THEN 1 ELSE 0 END) AS DECIMAL(10,4))
        / NULLIF(SUM(CASE WHEN Persistency_13M IN ('Persisted','Lapsed') THEN 1 ELSE 0 END), 0) AS Persistency_13M_Ratio
FROM dbo.Policy_Data
WHERE Persistency_13M IN ('Persisted', 'Lapsed')
GROUP BY Region_Type, Channel
ORDER BY Region_Type, Channel;
GO


/* ============================================================================
   9. PREDICTIVE LAPSE-RISK SCORECARD (native T-SQL, no extensions required)
      Points-based scorecard, weighted by each factor's OBSERVED lapse rate
      at the 13-month checkpoint. Agent/branch history carries most of the
      signal — consistent with steps 5 and 6 above.
   ============================================================================ */

-- 9.1 Risk-factor lookups, built from the data
IF OBJECT_ID('dbo.Risk_Agent_LapseRate', 'U') IS NOT NULL DROP TABLE dbo.Risk_Agent_LapseRate;
SELECT
    Agent_ID,
    COUNT(*)                                                        AS Policy_Count,
    CAST(SUM(CASE WHEN Persistency_13M = 'Lapsed' THEN 1 ELSE 0 END) AS DECIMAL(10,4))
        / COUNT(*)                                                  AS Agent_Lapse_Rate
INTO dbo.Risk_Agent_LapseRate
FROM dbo.Policy_Data
WHERE Agent_ID IS NOT NULL AND Persistency_13M IN ('Persisted', 'Lapsed')
GROUP BY Agent_ID;
GO

IF OBJECT_ID('dbo.Risk_Branch_LapseRate', 'U') IS NOT NULL DROP TABLE dbo.Risk_Branch_LapseRate;
SELECT
    Branch_ID,
    COUNT(*)                                                        AS Policy_Count,
    CAST(SUM(CASE WHEN Persistency_13M = 'Lapsed' THEN 1 ELSE 0 END) AS DECIMAL(10,4))
        / COUNT(*)                                                  AS Branch_Lapse_Rate
INTO dbo.Risk_Branch_LapseRate
FROM dbo.Policy_Data
WHERE Branch_ID IS NOT NULL AND Persistency_13M IN ('Persisted', 'Lapsed')
GROUP BY Branch_ID;
GO

-- 9.2 Scoring view: agent/branch history (55%) + payment mode + income + age
IF OBJECT_ID('dbo.vw_Lapse_Risk_Score', 'V') IS NOT NULL DROP VIEW dbo.vw_Lapse_Risk_Score;
GO
CREATE VIEW dbo.vw_Lapse_Risk_Score AS
WITH Base AS (
    SELECT
        p.Policy_ID, p.Channel, p.Agent_ID, p.Branch_ID, p.Product_Type,
        p.Premium_Payment_Mode, p.Policyholder_Age, p.Annual_Premium,
        p.Income_Segment, p.Policy_Status,
        COALESCE(a.Agent_Lapse_Rate, 0.20)   AS Agent_Lapse_Rate,    -- 0.20 = portfolio-wide fallback
        COALESCE(b.Branch_Lapse_Rate, 0.20)  AS Branch_Lapse_Rate,
        CASE p.Premium_Payment_Mode
            WHEN 'Monthly' THEN 0.05 WHEN 'Quarterly' THEN 0.03
            WHEN 'Half-Yearly' THEN 0.01 WHEN 'Annual' THEN 0.00 ELSE 0.02 END AS PaymentMode_Adj,
        CASE WHEN p.Income_Segment = 'Low' THEN 0.04 ELSE 0.00 END  AS IncomeSeg_Adj,
        CASE WHEN p.Policyholder_Age < 25 THEN 0.03 ELSE 0.00 END   AS YoungAge_Adj
    FROM dbo.Policy_Data p
    LEFT JOIN dbo.Risk_Agent_LapseRate  a ON p.Agent_ID  = a.Agent_ID  AND a.Policy_Count >= 5
    LEFT JOIN dbo.Risk_Branch_LapseRate b ON p.Branch_ID = b.Branch_ID AND b.Policy_Count >= 5
)
SELECT
    Policy_ID, Channel, Agent_ID, Branch_ID, Product_Type, Premium_Payment_Mode,
    Policyholder_Age, Annual_Premium, Income_Segment, Policy_Status,
    Agent_Lapse_Rate, Branch_Lapse_Rate,
    CASE WHEN Channel = 'Agency' THEN 0.55 * Agent_Lapse_Rate ELSE 0.55 * Branch_Lapse_Rate END
        + PaymentMode_Adj + IncomeSeg_Adj + YoungAge_Adj             AS Raw_Risk_Score
FROM Base;
GO

-- 9.3 Normalize to a 0-1 score
IF OBJECT_ID('dbo.vw_Lapse_Risk_Score_Final', 'V') IS NOT NULL DROP VIEW dbo.vw_Lapse_Risk_Score_Final;
GO
CREATE VIEW dbo.vw_Lapse_Risk_Score_Final AS
SELECT *,
    CAST(
      (Raw_Risk_Score - MIN(Raw_Risk_Score) OVER())
      / NULLIF(MAX(Raw_Risk_Score) OVER() - MIN(Raw_Risk_Score) OVER(), 0)
    AS DECIMAL(10,4)) AS Lapse_Risk_Score_0to1
FROM dbo.vw_Lapse_Risk_Score;
GO


/* ============================================================================
   10. RETENTION PRIORITY LIST — the actionable output of this analysis
   ============================================================================ */

-- 10.1 Top 200 highest-risk ACTIVE policies — the retention team's call list
SELECT TOP 200
    Policy_ID, Channel, Agent_ID, Branch_ID, Product_Type,
    Premium_Payment_Mode, Policyholder_Age, Annual_Premium,
    Lapse_Risk_Score_0to1
FROM dbo.vw_Lapse_Risk_Score_Final
WHERE Policy_Status = 'Active'
ORDER BY Lapse_Risk_Score_0to1 DESC;
GO

-- 10.2 Risk-band distribution across the whole active book, with premium at risk
SELECT
    CASE
        WHEN Lapse_Risk_Score_0to1 < 0.20 THEN '1. Low (0-20%)'
        WHEN Lapse_Risk_Score_0to1 < 0.40 THEN '2. Medium (20-40%)'
        WHEN Lapse_Risk_Score_0to1 < 0.60 THEN '3. High (40-60%)'
        ELSE '4. Very High (60%+)'
    END AS Risk_Band,
    COUNT(*)                                                      AS Policy_Count,
    SUM(Annual_Premium)                                           AS Premium_At_Risk
FROM dbo.vw_Lapse_Risk_Score_Final
WHERE Policy_Status = 'Active'
GROUP BY CASE
        WHEN Lapse_Risk_Score_0to1 < 0.20 THEN '1. Low (0-20%)'
        WHEN Lapse_Risk_Score_0to1 < 0.40 THEN '2. Medium (20-40%)'
        WHEN Lapse_Risk_Score_0to1 < 0.60 THEN '3. High (40-60%)'
        ELSE '4. Very High (60%+)'
    END
ORDER BY Risk_Band;
GO
