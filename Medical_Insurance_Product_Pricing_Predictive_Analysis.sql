/* ============================================================================
   MEDICAL INSURANCE PRODUCT, PRICING & PREDICTIVE LAPSE INTELLIGENCE
   Payment-Mode Persistency | Product/Plan Performance | Rider & PED Risk |
   Predictive Lapse Scoring & Renewal Forecasting

   Platform : Microsoft SQL Server (T-SQL)
   Source   : Policy_Data.csv (13,255 policies)
   Story    : PART A prices the book and finds where pricing/margin sits.
              PART B answers the core question: does payment frequency drive
              lapse, and what's the ROI of pushing Annual pay? PART C ranks
              products/plans on commercial performance. PART D tests whether
              riders and pre-existing conditions change persistency. PART E
              turns all of that into a predictive risk score and a forecast.
   ============================================================================ */
/* ============================================================================
   PART A — PRODUCT & PRICING ANALYTICS
   ============================================================================ */

-- A1. Pricing structure by product: rate per 1,000 sum insured is the true price signal
SELECT 
    Product_Type,
    COUNT(*) AS Policies,
    ROUND(AVG(Annual_Premium), 0) AS Avg_Annual_Premium,
    ROUND(AVG(Sum_Insured), 0) AS Avg_Sum_Insured,
    ROUND(AVG(Annual_Premium / (Sum_Insured / 1000.0)), 2) AS Avg_Premium_Per_1000_SI
FROM [dbo].[Policy_Data]
GROUP BY Product_Type
ORDER BY Avg_Premium_Per_1000_SI DESC;

-- A2. Pricing tier check: does a higher price point itself predict lapse? (NTILE quartiles)
SELECT 
    NTILE(4) OVER(ORDER BY Annual_Premium DESC) AS Price_Quartile,
    COUNT(*) AS Total_Policies,
    SUM(CASE WHEN Policy_Status = 'Lapsed' THEN 1 ELSE 0 END) AS Lapsed_Policies,
    ROUND(CAST(SUM(CASE WHEN Policy_Status = 'Lapsed' THEN 1 ELSE 0 END) AS DECIMAL(10,2)) / COUNT(*) * 100, 2) AS Lapse_Rate_Percent
FROM [dbo].[Policy_Data]
GROUP BY Annual_Premium, Policy_Status 
ORDER BY Price_Quartile;

-- A3. Channel pricing comparison: do Agency and Bancassurance sell different price points?
SELECT
    Channel, 
    COUNT(*) AS Policies,
    ROUND(AVG(Annual_Premium), 0) AS Avg_Premium,
    ROUND(AVG(Annual_Premium / (Sum_Insured / 1000.0)), 2) AS Avg_Premium_Per_1000_SI,
    ROUND(AVG(CASE WHEN Policy_Status = 'Lapsed' THEN 1.0 ELSE 0.0 END), 4) AS Lapse_Rate
FROM [dbo].[Policy_Data]
GROUP BY Channel;

-- A4. Underwriting/claims cost proxy by product: claim incidence and rejection rate
SELECT
    Product_Type,
    ROUND(AVG(CAST(Claim_Filed_Yr1 AS FLOAT)), 4)   AS Yr1_Claim_Rate,
    ROUND(AVG(CAST(Claim_Rejected AS FLOAT)), 4)      AS Claim_Rejection_Rate
FROM [dbo].[Policy_Data]
GROUP BY Product_Type
ORDER BY Yr1_Claim_Rate DESC;

/* ============================================================================
   PART B — PREMIUM PAYMENT MODE IMPACT ON LAPSE (core business case)
   ============================================================================ */

-- B1. Headline: lapse rate and premium revenue at risk, by payment frequency
SELECT
    Premium_Payment_Mode,
    COUNT(*) AS Policies,
    ROUND(SUM(CASE WHEN Policy_Status = 'Lapsed' THEN 1.0 ELSE 0.0 END) / COUNT(*), 4) AS Lapse_Rate,
    ROUND(AVG(Annual_Premium), 0) AS Avg_Premium,
    SUM(CASE WHEN Policy_Status = 'Lapsed' THEN Annual_Premium ELSE 0 END) AS Revenue_At_Risk
FROM [dbo].[Policy_Data]
GROUP BY Premium_Payment_Mode
ORDER BY Lapse_Rate DESC;

-- B2. Persistency erosion curve: Persisted-rate at each checkpoint, by payment mode
-- (only counts policies actually old enough to have reached that checkpoint)

SELECT '13M' AS [Checkpoint], Premium_Payment_Mode,
    ROUND(AVG(CASE WHEN Persistency_13M = 'Persisted' THEN 1.0 ELSE 0 END), 3) AS Persisted_Rate
FROM [dbo].[Policy_Data_Clean] WHERE Persistency_13M <> 'Not Yet Due' GROUP BY Premium_Payment_Mode
UNION ALL
SELECT '25M', Premium_Payment_Mode,
    ROUND(AVG(CASE WHEN Persistency_25M = 'Persisted' THEN 1.0 ELSE 0 END), 3) AS Persisted_Rate
FROM [dbo].[Policy_Data_Clean] WHERE Persistency_25M <> 'Not Yet Due' GROUP BY Premium_Payment_Mode
UNION ALL
SELECT '37M', Premium_Payment_Mode,
    ROUND(AVG(CASE WHEN Persistency_37M = 'Persisted' THEN 1.0 ELSE 0 END), 3) AS Persisted_Rate
FROM [dbo].[Policy_Data_Clean] WHERE Persistency_37M <> 'Not Yet Due' GROUP BY Premium_Payment_Mode
UNION ALL
SELECT '49M', Premium_Payment_Mode,
    ROUND(AVG(CASE WHEN Persistency_49M = 'Persisted' THEN 1.0 ELSE 0 END), 3) AS Persisted_Rate
FROM [dbo].[Policy_Data_Clean] WHERE Persistency_49M <> 'Not Yet Due' GROUP BY Premium_Payment_Mode
UNION ALL
SELECT '61M', Premium_Payment_Mode,
    ROUND(AVG(CASE WHEN Persistency_61M = 'Persisted' THEN 1.0 ELSE 0 END), 3) AS Persisted_Rate
FROM [dbo].[Policy_Data_Clean] WHERE Persistency_61M <> 'Not Yet Due' GROUP BY Premium_Payment_Mode
ORDER BY [Checkpoint], Persisted_Rate DESC;

-- B3. Does a rider offset the Monthly-pay lapse penalty? (interaction check)
SELECT 
    p.Product_Type,
    p.Has_Rider, 
    COUNT(*) AS Policies,
    SUM(p.Annual_Premium) AS Total_Premium,
    ROUND(AVG(CASE WHEN p.Policy_Status = 'Lapsed' THEN 1.0 ELSE 0.0 END), 4) AS Lapse_Rate,
    SUM(CASE WHEN p.Policy_Status = 'Active' AND r.Risk_Tier IN ('High', 'Critical') THEN 1 ELSE 0 END) AS Active_High_Risk_Policies
FROM [dbo].[Policy_Data] p
LEFT JOIN [dbo].[vw_Lapse_Risk_Score] r 
    ON r.Policy_ID = p.Policy_ID
GROUP BY p.Product_Type, p.Has_Rider 
ORDER BY Lapse_Rate DESC;

-- B4. Business case: premium that would be retained if Monthly/Quarterly payers
-- lapsed at the (lower) Annual-payer rate instead of their actual rate
WITH ModeRates AS (
    SELECT Premium_Payment_Mode,
        AVG(CASE WHEN Policy_Status = 'Lapsed' THEN 1.0 ELSE 0.0 END) AS ActualLapseRate,
        SUM(Annual_Premium) AS TotalPremiumBase
    FROM [dbo].[Policy_Data]
    GROUP BY Premium_Payment_Mode
),
AnnualBenchmark AS (
    SELECT ActualLapseRate AS AnnualLapseRate FROM ModeRates WHERE Premium_Payment_Mode = 'Annual'
)
SELECT m.Premium_Payment_Mode, m.ActualLapseRate,
    a.AnnualLapseRate,
    ROUND(m.TotalPremiumBase * (m.ActualLapseRate - a.AnnualLapseRate), 0) AS Potential_Premium_Recoverable
FROM ModeRates m CROSS JOIN AnnualBenchmark a
WHERE m.Premium_Payment_Mode <> 'Annual'
ORDER BY Potential_Premium_Recoverable DESC;

/* ============================================================================
   PART C — PRODUCT_TYPE & PLAN_NAME PERFORMANCE COMPARISON
   ============================================================================ */

-- C1. Product_Type scorecard: volume, revenue, lapse, claims in one view
SELECT
    Product_Type, 
    COUNT(*) AS Policies,
    SUM(Annual_Premium) AS Total_Premium,
    ROUND(AVG(CASE WHEN Policy_Status = 'Lapsed' THEN 1.0 ELSE 0.0 END), 4) AS Lapse_Rate,
    ROUND(AVG(CASE WHEN Claim_Filed_Yr1 = 1 THEN 1.0 ELSE 0.0 END), 4) AS Claim_Rate
FROM [dbo].[Policy_Data]
GROUP BY Product_Type
ORDER BY Total_Premium DESC;


-- C2. Plan_Name scorecard, ranked by lapse (worst-performing plans first)
SELECT
    Plan_Name, COUNT(*) AS Policies,
    SUM(Annual_Premium) AS Total_Premium,
    ROUND(AVG(CASE WHEN Policy_Status = 'Lapsed' THEN 1.0 ELSE 0.0 END), 4) AS Lapse_Rate
FROM [dbo].[Policy_Data]
GROUP BY Plan_Name
ORDER BY Lapse_Rate DESC;

-- C3. Issuance trend: is each product growing or shrinking year over year?
SELECT YEAR(Issue_Date) AS Issue_Year, Product_Type, COUNT(*) AS New_Policies
FROM [dbo].[Policy_Data]
GROUP BY YEAR(Issue_Date), Product_Type
ORDER BY Issue_Year, Product_Type;

/* ============================================================================
   PART D — RIDER ATTACHMENT & PRE-EXISTING DISEASE VS. PERSISTENCY
   ============================================================================ */

-- D1. Rider attachment vs lapse: does an attached rider correlate with better persistency?
SELECT Has_Rider, COUNT(*) AS Policies,
    ROUND(AVG(CASE WHEN Policy_Status = 'Lapsed' THEN 1.0 ELSE 0.0 END), 4) AS Lapse_Rate 
FROM [dbo].[Policy_Data] 
GROUP BY Has_Rider;

-- D2. Pre-existing disease flag vs lapse
SELECT Pre_Existing_Disease_Flag, COUNT(*) AS Policies,
    ROUND(AVG(CASE WHEN Policy_Status = 'Lapsed' THEN 1.0 ELSE 0.0 END), 4) AS Lapse_Rate
FROM [dbo].[Policy_Data]
GROUP BY Pre_Existing_Disease_Flag;

-- D3. Combined 2x2: Rider x Pre-Existing-Disease interaction on lapse
SELECT Has_Rider, Pre_Existing_Disease_Flag, COUNT(*) AS Policies,
    ROUND(AVG(CASE WHEN Policy_Status = 'Lapsed' THEN 1.0 ELSE 0.0 END), 4) AS Lapse_Rate
FROM [dbo].[Policy_Data]
GROUP BY Has_Rider, Pre_Existing_Disease_Flag
ORDER BY Lapse_Rate DESC;

-- D4. Underwriting signal: claim rejection rate among policyholders who declared a
-- pre-existing condition vs those who didn't (waiting-period / disclosure risk check)
SELECT Pre_Existing_Disease_Flag,
    ROUND(AVG(CAST(Claim_Rejected AS FLOAT)), 4) AS Claim_Rejection_Rate
FROM [dbo].[Policy_Data]
WHERE Claim_Filed_Yr1 = 1
GROUP BY Pre_Existing_Disease_Flag;

/* ============================================================================
   PART E — PREDICTIVE ANALYSIS
   Method: transparent weighted risk score (auditable, no black box) validated
   by checking that actual lapse rate rises monotonically with the score tier,
   plus an OLS trend forecast of new-business volume by product.
   ============================================================================ */

-- E1. Lapse Risk Score (0-100 style): weights sized to the effect strength
-- measured in Parts A-D (payment mode is the single largest lever)
CREATE OR ALTER VIEW vw_Lapse_Risk_Score AS
SELECT *,
    (CASE Premium_Payment_Mode WHEN 'Monthly' THEN 25 WHEN 'Quarterly' THEN 15
                                WHEN 'Half-Yearly' THEN 8 ELSE 0 END)
  + (CASE WHEN Channel = 'Bancassurance' THEN 8 ELSE 0 END)
  + (CASE WHEN Has_Rider = 0 THEN 10 ELSE 0 END)
  + (CASE Income_Segment WHEN 'Low' THEN 15 WHEN 'Mid' THEN 5 ELSE 0 END)
  + (CASE WHEN Region_Type = 'Rural' THEN 6 ELSE 0 END)                    AS Risk_Score,
    CASE
        WHEN (CASE Premium_Payment_Mode WHEN 'Monthly' THEN 25 WHEN 'Quarterly' THEN 15
                                          WHEN 'Half-Yearly' THEN 8 ELSE 0 END)
           + (CASE WHEN Channel = 'Bancassurance' THEN 8 ELSE 0 END)
           + (CASE WHEN Has_Rider = 0 THEN 10 ELSE 0 END)
           + (CASE Income_Segment WHEN 'Low' THEN 15 WHEN 'Mid' THEN 5 ELSE 0 END)
           + (CASE WHEN Region_Type = 'Rural' THEN 6 ELSE 0 END) >= 40 THEN 'Critical'
        WHEN (CASE Premium_Payment_Mode WHEN 'Monthly' THEN 25 WHEN 'Quarterly' THEN 15
                                          WHEN 'Half-Yearly' THEN 8 ELSE 0 END)
           + (CASE WHEN Channel = 'Bancassurance' THEN 8 ELSE 0 END)
           + (CASE WHEN Has_Rider = 0 THEN 10 ELSE 0 END)
           + (CASE Income_Segment WHEN 'Low' THEN 15 WHEN 'Mid' THEN 5 ELSE 0 END)
           + (CASE WHEN Region_Type = 'Rural' THEN 6 ELSE 0 END) >= 25 THEN 'High'
        WHEN (CASE Premium_Payment_Mode WHEN 'Monthly' THEN 25 WHEN 'Quarterly' THEN 15
                                          WHEN 'Half-Yearly' THEN 8 ELSE 0 END)
           + (CASE WHEN Channel = 'Bancassurance' THEN 8 ELSE 0 END)
           + (CASE WHEN Has_Rider = 0 THEN 10 ELSE 0 END)
           + (CASE Income_Segment WHEN 'Low' THEN 15 WHEN 'Mid' THEN 5 ELSE 0 END)
           + (CASE WHEN Region_Type = 'Rural' THEN 6 ELSE 0 END) >= 10 THEN 'Medium'
        ELSE 'Low'
    END AS Risk_Tier
FROM [dbo].[Policy_Data];
GO

-- E2. Model calibration check: actual lapse rate should climb monotonically by tier
SELECT Risk_Tier, COUNT(*) AS Policies,
    ROUND(AVG(CASE WHEN Policy_Status = 'Lapsed' THEN 1.0 ELSE 0.0 END), 4) AS Actual_Lapse_Rate
FROM vw_Lapse_Risk_Score
GROUP BY Risk_Tier
ORDER BY Actual_Lapse_Rate;

-- E3. New-business forecast: OLS trend regression of yearly issuance, by Product_Type
-- Formula: slope = (nΣxy - ΣxΣy) / (nΣx² - (Σx)²); projects next calendar year
WITH Yearly AS (
    SELECT Product_Type, YEAR(Issue_Date) AS Yr, COUNT(*) AS Policies
    FROM [dbo].[Policy_Data]
    WHERE YEAR(Issue_Date) BETWEEN 2020 AND 2025   
    GROUP BY Product_Type, YEAR(Issue_Date)
),
Trend AS (
    SELECT Product_Type, Yr, Policies, ROW_NUMBER() OVER (PARTITION BY Product_Type ORDER BY Yr) AS t
    FROM Yearly
),
Agg AS (
    SELECT Product_Type, COUNT(*) n, SUM(t) sx, SUM(Policies) sy,
           SUM(t*Policies) sxy, SUM(t*t) sx2, MAX(t) last_t
    FROM Trend GROUP BY Product_Type
)
SELECT Product_Type,
    ROUND(((sy - (((n*sxy - sx*sy)*1.0/NULLIF(n*sx2 - sx*sx,0))*sx))/n)
        + ((n*sxy - sx*sy)*1.0/NULLIF(n*sx2 - sx*sx,0)) * (last_t + 1), 0) AS Forecast_Next_Year_Policies
FROM Agg
ORDER BY Forecast_Next_Year_Policies DESC;

-- E4. Retention target list: currently Active policies with High/Critical risk score -
-- the actionable priority-call list for the renewal/retention team
SELECT Policy_ID, Channel, Product_Type, Premium_Payment_Mode, Risk_Score, Risk_Tier, Annual_Premium
FROM vw_Lapse_Risk_Score
WHERE Policy_Status = 'Active' AND Risk_Tier IN ('High','Critical')
ORDER BY Risk_Score DESC;

/* ============================================================================
   PART F — EXECUTIVE SUMMARY
   ============================================================================ */
SELECT 
    p.Product_Type,
    COUNT(*) AS Policies,
    SUM(p.Annual_Premium) AS Total_Premium,
    ROUND(AVG(CASE WHEN p.Policy_Status = 'Lapsed' THEN 1.0 ELSE 0.0 END), 4) AS Lapse_Rate,
    SUM(CASE WHEN p.Policy_Status = 'Active' AND r.Risk_Tier IN ('High', 'Critical') THEN 1 ELSE 0 END) AS Active_High_Risk_Policies
FROM [dbo].[Policy_Data] p
LEFT JOIN [dbo].[vw_Lapse_Risk_Score] r 
    ON r.Policy_ID = p.Policy_ID 
GROUP BY p.Product_Type
ORDER BY Lapse_Rate DESC;
