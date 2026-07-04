/* ============================================================================
   CLAIMS-DRIVEN ATTRITION & REVENUE AT RISK
   Database: Insurance | Requires: dbo.Policy_Data_Clean 
   Story: compare lapse by claims experience -> test significance -> isolate
          the claim-rejection effect controlling for other drivers (LPM) ->
          quantify revenue at risk (realized + forward-looking)
   ============================================================================ */

USE Insurance;
GO

/* ============================================================================
   1. LAPSE RATE BY CLAIMS EXPERIENCE SEGMENT
   ============================================================================ */
SELECT
    CASE
        WHEN Claim_Filed_Yr1 = 0 OR Claim_Filed_Yr1 IS NULL THEN 'No Claim Yr1'
        WHEN Claim_Filed_Yr1 = 1 AND Claim_Rejected = 1 THEN 'Claim Rejected'
        WHEN Claim_Filed_Yr1 = 1 AND Claim_Rejected = 0 THEN 'Claim Approved'
    END AS Claims_Segment,
    COUNT(*) AS Policies,
    ROUND(100.0 * SUM(CAST(Lapsed_Flag AS INT)) / COUNT(*), 2) AS Lapse_Rate_Pct,
    ROUND(100.0 * SUM(CAST(Early_Lapse_3M_Flag AS INT)) / COUNT(*), 2) AS Early_Lapse_Rate_Pct,
    ROUND(AVG(Annual_Premium), 0) AS Avg_Annual_Premium
FROM dbo.Policy_Data_Clean
GROUP BY CASE
        WHEN Claim_Filed_Yr1 = 0 OR Claim_Filed_Yr1 IS NULL THEN 'No Claim Yr1'
        WHEN Claim_Filed_Yr1 = 1 AND Claim_Rejected = 1 THEN 'Claim Rejected'
        WHEN Claim_Filed_Yr1 = 1 AND Claim_Rejected = 0 THEN 'Claim Approved'
    END;
GO

/* ============================================================================
   2. SIGNIFICANCE TEST: claim rejection vs. lapse (2x2, chi-square + odds ratio)
   ============================================================================ */
WITH Cell AS (
    SELECT
        SUM(CASE WHEN Claim_Rejected = 1 AND Lapsed_Flag = 1 THEN 1 ELSE 0 END) AS A,
        SUM(CASE WHEN Claim_Rejected = 1 AND Lapsed_Flag = 0 THEN 1 ELSE 0 END) AS B,
        SUM(CASE WHEN COALESCE(Claim_Rejected,0) = 0 AND Lapsed_Flag = 1 THEN 1 ELSE 0 END) AS C,
        SUM(CASE WHEN COALESCE(Claim_Rejected,0) = 0 AND Lapsed_Flag = 0 THEN 1 ELSE 0 END) AS D
    FROM dbo.Policy_Data_Clean
)
SELECT A, B, C, D, (A+B+C+D) AS N_Total,
    CAST((A+B+C+D) AS FLOAT) * POWER(CAST(A AS FLOAT)*D - CAST(B AS FLOAT)*C, 2)
      / NULLIF((A+B)*1.0*(C+D)*(A+C)*(B+D), 0) AS Chi_Square_Stat,  -- df=1; 3.841=p<.05
    ROUND(CAST(A AS FLOAT)*D / NULLIF(CAST(B AS FLOAT)*C,0), 2) AS Odds_Ratio
FROM Cell;
GO

/* ============================================================================
   3. MULTIVARIATE LPM — isolates the claim-rejection effect on lapse,
   controlling for tenure, seasonality, payment mode, channel, income.
   Target: Lapsed_Flag | Predictors: Intercept, Tenure, Q4, Monthly, Banca,
   LowIncome, ClaimFiled, ClaimRejected  (N=8)
   ============================================================================ */

-- 3a. Design matrix
IF OBJECT_ID('dbo.Claims_Model_Features','U') IS NOT NULL DROP TABLE dbo.Claims_Model_Features;
GO
DECLARE @AvgTenure DECIMAL(5,2);
SELECT @AvgTenure = AVG(Agent_Tenure_Years) FROM dbo.Policy_Data_Clean WHERE Agent_Tenure_Years IS NOT NULL;

SELECT
    Policy_ID,
    CAST(1.0 AS FLOAT) AS X0_Intercept,
    CAST(COALESCE(Agent_Tenure_Years, @AvgTenure) AS FLOAT) AS X1_Tenure,
    CAST(Is_Q4_Issue AS FLOAT) AS X2_Q4,
    CAST(CASE WHEN Premium_Payment_Mode = 'Monthly' THEN 1 ELSE 0 END AS FLOAT) AS X3_Monthly,
    CAST(CASE WHEN Channel = 'Bancassurance' THEN 1 ELSE 0 END AS FLOAT) AS X4_Banca,
    CAST(CASE WHEN Income_Segment = 'Low' THEN 1 ELSE 0 END AS FLOAT) AS X5_LowIncome,
    CAST(COALESCE(Claim_Filed_Yr1,0) AS FLOAT) AS X6_ClaimFiled,
    CAST(COALESCE(Claim_Rejected,0) AS FLOAT) AS X7_ClaimRejected,
    CAST(Lapsed_Flag AS FLOAT) AS Y
INTO dbo.Claims_Model_Features
FROM dbo.Policy_Data_Clean
WHERE Lapsed_Flag IS NOT NULL;
GO

-- 3b. Normal equations: augmented matrix [X'X | X'Y], 8 rows x 9 cols
IF OBJECT_ID('tempdb..#CMatrix') IS NOT NULL DROP TABLE #CMatrix;
CREATE TABLE #CMatrix (RowID INT PRIMARY KEY,
    C1 FLOAT, C2 FLOAT, C3 FLOAT, C4 FLOAT, C5 FLOAT, C6 FLOAT, C7 FLOAT, C8 FLOAT, C9 FLOAT);

INSERT INTO #CMatrix
SELECT 1, SUM(X0_Intercept*X0_Intercept), SUM(X0_Intercept*X1_Tenure), SUM(X0_Intercept*X2_Q4),
          SUM(X0_Intercept*X3_Monthly), SUM(X0_Intercept*X4_Banca), SUM(X0_Intercept*X5_LowIncome),
          SUM(X0_Intercept*X6_ClaimFiled), SUM(X0_Intercept*X7_ClaimRejected), SUM(X0_Intercept*Y)
FROM dbo.Claims_Model_Features
UNION ALL
SELECT 2, SUM(X1_Tenure*X0_Intercept), SUM(X1_Tenure*X1_Tenure), SUM(X1_Tenure*X2_Q4),
          SUM(X1_Tenure*X3_Monthly), SUM(X1_Tenure*X4_Banca), SUM(X1_Tenure*X5_LowIncome),
          SUM(X1_Tenure*X6_ClaimFiled), SUM(X1_Tenure*X7_ClaimRejected), SUM(X1_Tenure*Y)
FROM dbo.Claims_Model_Features
UNION ALL
SELECT 3, SUM(X2_Q4*X0_Intercept), SUM(X2_Q4*X1_Tenure), SUM(X2_Q4*X2_Q4),
          SUM(X2_Q4*X3_Monthly), SUM(X2_Q4*X4_Banca), SUM(X2_Q4*X5_LowIncome),
          SUM(X2_Q4*X6_ClaimFiled), SUM(X2_Q4*X7_ClaimRejected), SUM(X2_Q4*Y)
FROM dbo.Claims_Model_Features
UNION ALL
SELECT 4, SUM(X3_Monthly*X0_Intercept), SUM(X3_Monthly*X1_Tenure), SUM(X3_Monthly*X2_Q4),
          SUM(X3_Monthly*X3_Monthly), SUM(X3_Monthly*X4_Banca), SUM(X3_Monthly*X5_LowIncome),
          SUM(X3_Monthly*X6_ClaimFiled), SUM(X3_Monthly*X7_ClaimRejected), SUM(X3_Monthly*Y)
FROM dbo.Claims_Model_Features
UNION ALL
SELECT 5, SUM(X4_Banca*X0_Intercept), SUM(X4_Banca*X1_Tenure), SUM(X4_Banca*X2_Q4),
          SUM(X4_Banca*X3_Monthly), SUM(X4_Banca*X4_Banca), SUM(X4_Banca*X5_LowIncome),
          SUM(X4_Banca*X6_ClaimFiled), SUM(X4_Banca*X7_ClaimRejected), SUM(X4_Banca*Y)
FROM dbo.Claims_Model_Features
UNION ALL
SELECT 6, SUM(X5_LowIncome*X0_Intercept), SUM(X5_LowIncome*X1_Tenure), SUM(X5_LowIncome*X2_Q4),
          SUM(X5_LowIncome*X3_Monthly), SUM(X5_LowIncome*X4_Banca), SUM(X5_LowIncome*X5_LowIncome),
          SUM(X5_LowIncome*X6_ClaimFiled), SUM(X5_LowIncome*X7_ClaimRejected), SUM(X5_LowIncome*Y)
FROM dbo.Claims_Model_Features
UNION ALL
SELECT 7, SUM(X6_ClaimFiled*X0_Intercept), SUM(X6_ClaimFiled*X1_Tenure), SUM(X6_ClaimFiled*X2_Q4),
          SUM(X6_ClaimFiled*X3_Monthly), SUM(X6_ClaimFiled*X4_Banca), SUM(X6_ClaimFiled*X5_LowIncome),
          SUM(X6_ClaimFiled*X6_ClaimFiled), SUM(X6_ClaimFiled*X7_ClaimRejected), SUM(X6_ClaimFiled*Y)
FROM dbo.Claims_Model_Features
UNION ALL
SELECT 8, SUM(X7_ClaimRejected*X0_Intercept), SUM(X7_ClaimRejected*X1_Tenure), SUM(X7_ClaimRejected*X2_Q4),
          SUM(X7_ClaimRejected*X3_Monthly), SUM(X7_ClaimRejected*X4_Banca), SUM(X7_ClaimRejected*X5_LowIncome),
          SUM(X7_ClaimRejected*X6_ClaimFiled), SUM(X7_ClaimRejected*X7_ClaimRejected), SUM(X7_ClaimRejected*Y)
FROM dbo.Claims_Model_Features;
GO

-- 3c. Gauss-Jordan elimination (N=8): reduces #CMatrix to identity; C9 becomes each Beta
DECLARE @k INT = 1, @sql NVARCHAR(MAX), @cols NVARCHAR(50) = 'C1,C2,C3,C4,C5,C6,C7,C8,C9';
WHILE @k <= 8
BEGIN
    SET @sql = N'
        DECLARE @piv FLOAT;
        SELECT @piv = C' + CAST(@k AS NVARCHAR) + N' FROM #CMatrix WHERE RowID = ' + CAST(@k AS NVARCHAR) + N';
        IF @piv IS NULL OR @piv = 0 THROW 50000, ''Singular matrix - remove a collinear predictor.'', 1;
        UPDATE #CMatrix SET C1=C1/@piv,C2=C2/@piv,C3=C3/@piv,C4=C4/@piv,C5=C5/@piv,
                             C6=C6/@piv,C7=C7/@piv,C8=C8/@piv,C9=C9/@piv
        WHERE RowID = ' + CAST(@k AS NVARCHAR) + N';';
    EXEC sp_executesql @sql;

    SET @sql = N'
        DECLARE @p1 FLOAT,@p2 FLOAT,@p3 FLOAT,@p4 FLOAT,@p5 FLOAT,@p6 FLOAT,@p7 FLOAT,@p8 FLOAT,@p9 FLOAT;
        SELECT @p1=C1,@p2=C2,@p3=C3,@p4=C4,@p5=C5,@p6=C6,@p7=C7,@p8=C8,@p9=C9
        FROM #CMatrix WHERE RowID=' + CAST(@k AS NVARCHAR) + N';
        UPDATE #CMatrix SET
            C1=C1-C' + CAST(@k AS NVARCHAR) + N'*@p1, C2=C2-C' + CAST(@k AS NVARCHAR) + N'*@p2,
            C3=C3-C' + CAST(@k AS NVARCHAR) + N'*@p3, C4=C4-C' + CAST(@k AS NVARCHAR) + N'*@p4,
            C5=C5-C' + CAST(@k AS NVARCHAR) + N'*@p5, C6=C6-C' + CAST(@k AS NVARCHAR) + N'*@p6,
            C7=C7-C' + CAST(@k AS NVARCHAR) + N'*@p7, C8=C8-C' + CAST(@k AS NVARCHAR) + N'*@p8,
            C9=C9-C' + CAST(@k AS NVARCHAR) + N'*@p9
        WHERE RowID <> ' + CAST(@k AS NVARCHAR) + N';';
    EXEC sp_executesql @sql;

    SET @k += 1;
END
GO

-- 3d. Extract coefficients — Beta for X7_ClaimRejected is the answer to
-- "how much does a rejected claim raise lapse probability, controlling for other factors"
IF OBJECT_ID('dbo.Claims_Model_Coefficients','U') IS NOT NULL DROP TABLE dbo.Claims_Model_Coefficients;
GO
SELECT RowID,
    CASE RowID
        WHEN 1 THEN 'Intercept' WHEN 2 THEN 'Agent_Tenure_Years' WHEN 3 THEN 'Is_Q4_Issue'
        WHEN 4 THEN 'Premium_Monthly' WHEN 5 THEN 'Is_Bancassurance' WHEN 6 THEN 'Income_Low'
        WHEN 7 THEN 'Claim_Filed_Yr1' WHEN 8 THEN 'Claim_Rejected'
    END AS Predictor,
    C9 AS Beta
INTO dbo.Claims_Model_Coefficients
FROM #CMatrix;

SELECT * FROM dbo.Claims_Model_Coefficients ORDER BY RowID;
GO

/* ============================================================================
   4. REVENUE AT RISK — REALIZED (attributable excess lapses already occurred)
   Baseline = lapse rate of the "No Claim Yr1" segment.
   Excess lapses in the rejected-claim segment = actual - expected at baseline.
   ============================================================================ */
SELECT
    COUNT(*) AS Total_Rows,
    SUM(CAST(Lapsed_Flag AS INT)) AS Lapsed_Count,
    SUM(CAST(Claim_Filed_Yr1 AS INT)) AS Claim_Filed_Count,
    SUM(CAST(Claim_Rejected AS INT)) AS Claim_Rejected_Count
FROM dbo.Policy_Data_Clean;

SELECT TOP 5 Claim_Filed_Yr1, Claim_Rejected FROM dbo.Policy_Data;
SELECT DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'Policy_Data' AND COLUMN_NAME IN ('Claim_Filed_Yr1','Claim_Rejected');


/* ============================================================================
   5. REVENUE AT RISK — FORWARD-LOOKING (still-active policies with a rejected
   claim). Applies the adjusted Claim_Rejected effect (Section 3) to each
   policy's remaining premium stream.
   ============================================================================ */
DECLARE @BetaRejected FLOAT;
SELECT @BetaRejected = Beta FROM dbo.Claims_Model_Coefficients WHERE Predictor = 'Claim_Rejected';

SELECT
    COUNT(*) AS Active_Rejected_Claim_Policies,
    ROUND(@BetaRejected, 4) AS Adjusted_Lapse_Prob_Increase_Pct,
    ROUND(SUM(Annual_Premium * NULLIF(Policy_Term_Years - Policy_Duration_Months / 12.0, 0)), 0)
        AS Total_Remaining_Premium_Stream,
    ROUND(@BetaRejected * SUM(Annual_Premium * NULLIF(Policy_Term_Years - Policy_Duration_Months / 12.0, 0)), 0)
        AS Forward_Revenue_At_Risk
FROM dbo.Policy_Data_Clean
WHERE Claim_Rejected = 1 AND Policy_Status = 'Active';
GO

/* ============================================================================
   6. SUMMARY
   ============================================================================ */
SELECT
    (SELECT Beta FROM dbo.Claims_Model_Coefficients WHERE Predictor = 'Claim_Rejected') AS Adjusted_Lapse_Prob_Increase,
    (SELECT COUNT(*) FROM dbo.Policy_Data_Clean WHERE Claim_Rejected = 1) AS Total_Rejected_Claim_Policies,
    (SELECT COUNT(*) FROM dbo.Policy_Data_Clean WHERE Claim_Rejected = 1 AND Policy_Status = 'Active') AS Still_Active_Rejected_Claim_Policies;
GO