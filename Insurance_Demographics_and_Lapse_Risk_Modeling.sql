/* ============================================================================
   GEOGRAPHIC / DEMOGRAPHIC SEGMENTATION & PREDICTIVE MODEL
   Database: Insurance | Requires: dbo.Policy_Data_Clean (from master script)
   Story: check data quality -> Rural/Urban persistency gap -> is it really
          geography or the Bancassurance channel mix? -> income/occupation/
          age/gender cuts -> multivariate LPM isolating each factor's true
          independent effect on lapse, controlling for the others
   ============================================================================ */

USE Insurance;
GO

/* ============================================================================
   1. DATA QUALITY CHECK — Policyholder_Age has known bad values (e.g. negative,
   >100); exclude these from age-based analysis rather than let them skew it.
   ============================================================================ */
SELECT
    COUNT(*) AS Total_Policies,
    SUM(CASE WHEN Policyholder_Age NOT BETWEEN 18 AND 100 THEN 1 ELSE 0 END) AS Invalid_Age_Count,
    MIN(Policyholder_Age) AS Min_Age, MAX(Policyholder_Age) AS Max_Age
FROM dbo.Policy_Data_Clean;
GO

/* ============================================================================
   2. REGION_TYPE PERSISTENCY GAP (Rural vs Urban vs Semi-Urban)
   ============================================================================ */
SELECT
    Region_Type,
    COUNT(*) AS Policies,
    ROUND(100.0 * SUM(CAST(Lapsed_Flag AS INT)) / COUNT(*), 2) AS Lapse_Rate_Pct,
    ROUND(100.0 * SUM(CAST(Early_Lapse_3M_Flag AS INT)) / COUNT(*), 2) AS Early_Lapse_Rate_Pct,
    ROUND(100.0 * SUM(CASE WHEN Persistency_13M='Persisted' THEN 1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN Persistency_13M IN ('Persisted','Lapsed') THEN 1 ELSE 0 END),0),2) AS Persistency_13M_Pct,
    ROUND(100.0 * SUM(CASE WHEN Persistency_25M='Persisted' THEN 1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN Persistency_25M IN ('Persisted','Lapsed') THEN 1 ELSE 0 END),0),2) AS Persistency_25M_Pct,
    ROUND(100.0 * SUM(CASE WHEN Persistency_37M='Persisted' THEN 1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN Persistency_37M IN ('Persisted','Lapsed') THEN 1 ELSE 0 END),0),2) AS Persistency_37M_Pct,
    ROUND(100.0 * SUM(CASE WHEN Persistency_61M='Persisted' THEN 1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN Persistency_61M IN ('Persisted','Lapsed') THEN 1 ELSE 0 END),0),2) AS Persistency_61M_Pct
FROM dbo.Policy_Data_Clean
GROUP BY Region_Type;
GO

-- Is the rural gap really geography, or just its Bancassurance-heavy channel mix?
SELECT
    Region_Type, Channel,
    COUNT(*) AS Policies,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY Region_Type), 1) AS Pct_Of_Region,
    ROUND(100.0 * SUM(CAST(Lapsed_Flag AS INT)) / COUNT(*), 2) AS Lapse_Rate_Pct
FROM dbo.Policy_Data_Clean
GROUP BY Region_Type, Channel
ORDER BY Region_Type, Channel;
GO

/* ============================================================================
   3. INCOME SEGMENT CUTS
   ============================================================================ */
SELECT
    Income_Segment,
    COUNT(*) AS Policies,
    ROUND(100.0 * SUM(CAST(Lapsed_Flag AS INT)) / COUNT(*), 2) AS Lapse_Rate_Pct,
    ROUND(100.0 * SUM(CAST(Early_Lapse_3M_Flag AS INT)) / COUNT(*), 2) AS Early_Lapse_Rate_Pct,
    ROUND(AVG(Annual_Premium), 0) AS Avg_Annual_Premium
FROM dbo.Policy_Data_Clean
GROUP BY Income_Segment;
GO

/* ============================================================================
   4. OCCUPATION CUTS
   ============================================================================ */
SELECT
    Occupation,
    COUNT(*) AS Policies,
    ROUND(100.0 * SUM(CAST(Lapsed_Flag AS INT)) / COUNT(*), 2) AS Lapse_Rate_Pct,
    ROUND(100.0 * SUM(CAST(Early_Lapse_3M_Flag AS INT)) / COUNT(*), 2) AS Early_Lapse_Rate_Pct
FROM dbo.Policy_Data_Clean
GROUP BY Occupation
ORDER BY Lapse_Rate_Pct DESC;
GO

/* ============================================================================
   5. AGE BAND CUTS (valid ages only)
   ============================================================================ */
SELECT
    CASE
        WHEN Policyholder_Age < 25 THEN '<25'
        WHEN Policyholder_Age < 35 THEN '25-34'
        WHEN Policyholder_Age < 45 THEN '35-44'
        WHEN Policyholder_Age < 55 THEN '45-54'
        WHEN Policyholder_Age < 65 THEN '55-64'
        ELSE '65+'
    END AS Age_Band,
    COUNT(*) AS Policies,
    ROUND(100.0 * SUM(CAST(Lapsed_Flag AS INT)) / COUNT(*), 2) AS Lapse_Rate_Pct
FROM dbo.Policy_Data_Clean
WHERE Policyholder_Age BETWEEN 18 AND 100
GROUP BY CASE
        WHEN Policyholder_Age < 25 THEN '<25'
        WHEN Policyholder_Age < 35 THEN '25-34'
        WHEN Policyholder_Age < 45 THEN '35-44'
        WHEN Policyholder_Age < 55 THEN '45-54'
        WHEN Policyholder_Age < 65 THEN '55-64'
        ELSE '65+'
    END
ORDER BY MIN(Policyholder_Age);
GO

/* ============================================================================
   6. GENDER CUTS
   ============================================================================ */
SELECT
    Gender,
    COUNT(*) AS Policies,
    ROUND(100.0 * SUM(CAST(Lapsed_Flag AS INT)) / COUNT(*), 2) AS Lapse_Rate_Pct
FROM dbo.Policy_Data_Clean
GROUP BY Gender;
GO

/* ============================================================================
   7. MULTIVARIATE LPM — isolates each geographic/demographic effect on lapse
   controlling for the others (and for tenure/channel/seasonality/pay mode).
   Target: Lapsed_Flag
   Predictors: Intercept, Tenure, Q4, Monthly, Banca, Region_Rural,
   Region_SemiUrban, Income_Low, Income_Mid, Age, Gender_Male,
   Occupation_NonWorking (Retired+Homemaker), Occupation_SelfEmployed
   (Business Owner+Self-Employed)   [N=13]
   ============================================================================ */

-- 7a. Design matrix
IF OBJECT_ID('dbo.Geo_Model_Features','U') IS NOT NULL DROP TABLE dbo.Geo_Model_Features;
GO
DECLARE @AvgTenure DECIMAL(5,2), @AvgAge DECIMAL(5,2);
SELECT @AvgTenure = AVG(Agent_Tenure_Years) FROM dbo.Policy_Data_Clean WHERE Agent_Tenure_Years IS NOT NULL;
SELECT @AvgAge = AVG(CAST(Policyholder_Age AS DECIMAL(5,2))) FROM dbo.Policy_Data_Clean WHERE Policyholder_Age BETWEEN 18 AND 100;

SELECT
    Policy_ID,
    CAST(1.0 AS FLOAT) AS X0_Intercept,
    CAST(COALESCE(Agent_Tenure_Years, @AvgTenure) AS FLOAT) AS X1_Tenure,
    CAST(Is_Q4_Issue AS FLOAT) AS X2_Q4,
    CAST(CASE WHEN Premium_Payment_Mode = 'Monthly' THEN 1 ELSE 0 END AS FLOAT) AS X3_Monthly,
    CAST(CASE WHEN Channel = 'Bancassurance' THEN 1 ELSE 0 END AS FLOAT) AS X4_Banca,
    CAST(CASE WHEN Region_Type = 'Rural' THEN 1 ELSE 0 END AS FLOAT) AS X5_Rural,
    CAST(CASE WHEN Region_Type = 'Semi-Urban' THEN 1 ELSE 0 END AS FLOAT) AS X6_SemiUrban,
    CAST(CASE WHEN Income_Segment = 'Low' THEN 1 ELSE 0 END AS FLOAT) AS X7_IncomeLow,
    CAST(CASE WHEN Income_Segment = 'Mid' THEN 1 ELSE 0 END AS FLOAT) AS X8_IncomeMid,
    CAST(CASE WHEN Policyholder_Age BETWEEN 18 AND 100 THEN Policyholder_Age ELSE @AvgAge END AS FLOAT) AS X9_Age,
    CAST(CASE WHEN Gender = 'Male' THEN 1 ELSE 0 END AS FLOAT) AS X10_Male,
    CAST(CASE WHEN Occupation IN ('Retired','Homemaker') THEN 1 ELSE 0 END AS FLOAT) AS X11_NonWorking,
    CAST(CASE WHEN Occupation IN ('Business Owner','Self-Employed') THEN 1 ELSE 0 END AS FLOAT) AS X12_SelfEmployed,
    CAST(Lapsed_Flag AS FLOAT) AS Y
INTO dbo.Geo_Model_Features
FROM dbo.Policy_Data_Clean
WHERE Lapsed_Flag IS NOT NULL;
GO

-- 7b. Normal equations: augmented matrix [X'X | X'Y], 13 rows x 14 cols
IF OBJECT_ID('tempdb..#GMatrix') IS NOT NULL DROP TABLE #GMatrix;
CREATE TABLE #GMatrix (RowID INT PRIMARY KEY, C1 FLOAT, C2 FLOAT, C3 FLOAT, C4 FLOAT, C5 FLOAT, C6 FLOAT, C7 FLOAT, C8 FLOAT, C9 FLOAT, C10 FLOAT, C11 FLOAT, C12 FLOAT, C13 FLOAT, C14 FLOAT);

INSERT INTO #GMatrix
SELECT 1, SUM(X0_Intercept*X0_Intercept), SUM(X0_Intercept*X1_Tenure), SUM(X0_Intercept*X2_Q4), SUM(X0_Intercept*X3_Monthly), SUM(X0_Intercept*X4_Banca), SUM(X0_Intercept*X5_Rural), SUM(X0_Intercept*X6_SemiUrban), SUM(X0_Intercept*X7_IncomeLow), SUM(X0_Intercept*X8_IncomeMid), SUM(X0_Intercept*X9_Age), SUM(X0_Intercept*X10_Male), SUM(X0_Intercept*X11_NonWorking), SUM(X0_Intercept*X12_SelfEmployed), SUM(X0_Intercept*Y)
FROM dbo.Geo_Model_Features
UNION ALL
SELECT 2, SUM(X1_Tenure*X0_Intercept), SUM(X1_Tenure*X1_Tenure), SUM(X1_Tenure*X2_Q4), SUM(X1_Tenure*X3_Monthly), SUM(X1_Tenure*X4_Banca), SUM(X1_Tenure*X5_Rural), SUM(X1_Tenure*X6_SemiUrban), SUM(X1_Tenure*X7_IncomeLow), SUM(X1_Tenure*X8_IncomeMid), SUM(X1_Tenure*X9_Age), SUM(X1_Tenure*X10_Male), SUM(X1_Tenure*X11_NonWorking), SUM(X1_Tenure*X12_SelfEmployed), SUM(X1_Tenure*Y)
FROM dbo.Geo_Model_Features
UNION ALL
SELECT 3, SUM(X2_Q4*X0_Intercept), SUM(X2_Q4*X1_Tenure), SUM(X2_Q4*X2_Q4), SUM(X2_Q4*X3_Monthly), SUM(X2_Q4*X4_Banca), SUM(X2_Q4*X5_Rural), SUM(X2_Q4*X6_SemiUrban), SUM(X2_Q4*X7_IncomeLow), SUM(X2_Q4*X8_IncomeMid), SUM(X2_Q4*X9_Age), SUM(X2_Q4*X10_Male), SUM(X2_Q4*X11_NonWorking), SUM(X2_Q4*X12_SelfEmployed), SUM(X2_Q4*Y)
FROM dbo.Geo_Model_Features
UNION ALL
SELECT 4, SUM(X3_Monthly*X0_Intercept), SUM(X3_Monthly*X1_Tenure), SUM(X3_Monthly*X2_Q4), SUM(X3_Monthly*X3_Monthly), SUM(X3_Monthly*X4_Banca), SUM(X3_Monthly*X5_Rural), SUM(X3_Monthly*X6_SemiUrban), SUM(X3_Monthly*X7_IncomeLow), SUM(X3_Monthly*X8_IncomeMid), SUM(X3_Monthly*X9_Age), SUM(X3_Monthly*X10_Male), SUM(X3_Monthly*X11_NonWorking), SUM(X3_Monthly*X12_SelfEmployed), SUM(X3_Monthly*Y)
FROM dbo.Geo_Model_Features
UNION ALL
SELECT 5, SUM(X4_Banca*X0_Intercept), SUM(X4_Banca*X1_Tenure), SUM(X4_Banca*X2_Q4), SUM(X4_Banca*X3_Monthly), SUM(X4_Banca*X4_Banca), SUM(X4_Banca*X5_Rural), SUM(X4_Banca*X6_SemiUrban), SUM(X4_Banca*X7_IncomeLow), SUM(X4_Banca*X8_IncomeMid), SUM(X4_Banca*X9_Age), SUM(X4_Banca*X10_Male), SUM(X4_Banca*X11_NonWorking), SUM(X4_Banca*X12_SelfEmployed), SUM(X4_Banca*Y)
FROM dbo.Geo_Model_Features
UNION ALL
SELECT 6, SUM(X5_Rural*X0_Intercept), SUM(X5_Rural*X1_Tenure), SUM(X5_Rural*X2_Q4), SUM(X5_Rural*X3_Monthly), SUM(X5_Rural*X4_Banca), SUM(X5_Rural*X5_Rural), SUM(X5_Rural*X6_SemiUrban), SUM(X5_Rural*X7_IncomeLow), SUM(X5_Rural*X8_IncomeMid), SUM(X5_Rural*X9_Age), SUM(X5_Rural*X10_Male), SUM(X5_Rural*X11_NonWorking), SUM(X5_Rural*X12_SelfEmployed), SUM(X5_Rural*Y)
FROM dbo.Geo_Model_Features
UNION ALL
SELECT 7, SUM(X6_SemiUrban*X0_Intercept), SUM(X6_SemiUrban*X1_Tenure), SUM(X6_SemiUrban*X2_Q4), SUM(X6_SemiUrban*X3_Monthly), SUM(X6_SemiUrban*X4_Banca), SUM(X6_SemiUrban*X5_Rural), SUM(X6_SemiUrban*X6_SemiUrban), SUM(X6_SemiUrban*X7_IncomeLow), SUM(X6_SemiUrban*X8_IncomeMid), SUM(X6_SemiUrban*X9_Age), SUM(X6_SemiUrban*X10_Male), SUM(X6_SemiUrban*X11_NonWorking), SUM(X6_SemiUrban*X12_SelfEmployed), SUM(X6_SemiUrban*Y)
FROM dbo.Geo_Model_Features
UNION ALL
SELECT 8, SUM(X7_IncomeLow*X0_Intercept), SUM(X7_IncomeLow*X1_Tenure), SUM(X7_IncomeLow*X2_Q4), SUM(X7_IncomeLow*X3_Monthly), SUM(X7_IncomeLow*X4_Banca), SUM(X7_IncomeLow*X5_Rural), SUM(X7_IncomeLow*X6_SemiUrban), SUM(X7_IncomeLow*X7_IncomeLow), SUM(X7_IncomeLow*X8_IncomeMid), SUM(X7_IncomeLow*X9_Age), SUM(X7_IncomeLow*X10_Male), SUM(X7_IncomeLow*X11_NonWorking), SUM(X7_IncomeLow*X12_SelfEmployed), SUM(X7_IncomeLow*Y)
FROM dbo.Geo_Model_Features
UNION ALL
SELECT 9, SUM(X8_IncomeMid*X0_Intercept), SUM(X8_IncomeMid*X1_Tenure), SUM(X8_IncomeMid*X2_Q4), SUM(X8_IncomeMid*X3_Monthly), SUM(X8_IncomeMid*X4_Banca), SUM(X8_IncomeMid*X5_Rural), SUM(X8_IncomeMid*X6_SemiUrban), SUM(X8_IncomeMid*X7_IncomeLow), SUM(X8_IncomeMid*X8_IncomeMid), SUM(X8_IncomeMid*X9_Age), SUM(X8_IncomeMid*X10_Male), SUM(X8_IncomeMid*X11_NonWorking), SUM(X8_IncomeMid*X12_SelfEmployed), SUM(X8_IncomeMid*Y)
FROM dbo.Geo_Model_Features
UNION ALL
SELECT 10, SUM(X9_Age*X0_Intercept), SUM(X9_Age*X1_Tenure), SUM(X9_Age*X2_Q4), SUM(X9_Age*X3_Monthly), SUM(X9_Age*X4_Banca), SUM(X9_Age*X5_Rural), SUM(X9_Age*X6_SemiUrban), SUM(X9_Age*X7_IncomeLow), SUM(X9_Age*X8_IncomeMid), SUM(X9_Age*X9_Age), SUM(X9_Age*X10_Male), SUM(X9_Age*X11_NonWorking), SUM(X9_Age*X12_SelfEmployed), SUM(X9_Age*Y)
FROM dbo.Geo_Model_Features
UNION ALL
SELECT 11, SUM(X10_Male*X0_Intercept), SUM(X10_Male*X1_Tenure), SUM(X10_Male*X2_Q4), SUM(X10_Male*X3_Monthly), SUM(X10_Male*X4_Banca), SUM(X10_Male*X5_Rural), SUM(X10_Male*X6_SemiUrban), SUM(X10_Male*X7_IncomeLow), SUM(X10_Male*X8_IncomeMid), SUM(X10_Male*X9_Age), SUM(X10_Male*X10_Male), SUM(X10_Male*X11_NonWorking), SUM(X10_Male*X12_SelfEmployed), SUM(X10_Male*Y)
FROM dbo.Geo_Model_Features
UNION ALL
SELECT 12, SUM(X11_NonWorking*X0_Intercept), SUM(X11_NonWorking*X1_Tenure), SUM(X11_NonWorking*X2_Q4), SUM(X11_NonWorking*X3_Monthly), SUM(X11_NonWorking*X4_Banca), SUM(X11_NonWorking*X5_Rural), SUM(X11_NonWorking*X6_SemiUrban), SUM(X11_NonWorking*X7_IncomeLow), SUM(X11_NonWorking*X8_IncomeMid), SUM(X11_NonWorking*X9_Age), SUM(X11_NonWorking*X10_Male), SUM(X11_NonWorking*X11_NonWorking), SUM(X11_NonWorking*X12_SelfEmployed), SUM(X11_NonWorking*Y)
FROM dbo.Geo_Model_Features
UNION ALL
SELECT 13, SUM(X12_SelfEmployed*X0_Intercept), SUM(X12_SelfEmployed*X1_Tenure), SUM(X12_SelfEmployed*X2_Q4), SUM(X12_SelfEmployed*X3_Monthly), SUM(X12_SelfEmployed*X4_Banca), SUM(X12_SelfEmployed*X5_Rural), SUM(X12_SelfEmployed*X6_SemiUrban), SUM(X12_SelfEmployed*X7_IncomeLow), SUM(X12_SelfEmployed*X8_IncomeMid), SUM(X12_SelfEmployed*X9_Age), SUM(X12_SelfEmployed*X10_Male), SUM(X12_SelfEmployed*X11_NonWorking), SUM(X12_SelfEmployed*X12_SelfEmployed), SUM(X12_SelfEmployed*Y)
FROM dbo.Geo_Model_Features;
GO

-- 7c. Gauss-Jordan elimination (N=13): reduces #GMatrix to identity; C14 becomes each Beta
DECLARE @k INT = 1, @sql NVARCHAR(MAX);
WHILE @k <= 13
BEGIN
    SET @sql = N'
        DECLARE @piv FLOAT;
        SELECT @piv = C' + CAST(@k AS NVARCHAR) + N' FROM #GMatrix WHERE RowID = ' + CAST(@k AS NVARCHAR) + N';
        IF @piv IS NULL OR @piv = 0 THROW 50000, ''Singular matrix - remove a collinear predictor.'', 1;
        UPDATE #GMatrix SET C1=C1/@piv,C2=C2/@piv,C3=C3/@piv,C4=C4/@piv,C5=C5/@piv,C6=C6/@piv,C7=C7/@piv,C8=C8/@piv,C9=C9/@piv,C10=C10/@piv,C11=C11/@piv,C12=C12/@piv,C13=C13/@piv,C14=C14/@piv
        WHERE RowID = ' + CAST(@k AS NVARCHAR) + N';';
    EXEC sp_executesql @sql;

    SET @sql = N'
        DECLARE @p1 FLOAT,@p2 FLOAT,@p3 FLOAT,@p4 FLOAT,@p5 FLOAT,@p6 FLOAT,@p7 FLOAT,@p8 FLOAT,@p9 FLOAT,@p10 FLOAT,@p11 FLOAT,@p12 FLOAT,@p13 FLOAT,@p14 FLOAT;
        SELECT @p1=C1,@p2=C2,@p3=C3,@p4=C4,@p5=C5,@p6=C6,@p7=C7,@p8=C8,@p9=C9,@p10=C10,@p11=C11,@p12=C12,@p13=C13,@p14=C14 FROM #GMatrix WHERE RowID=' + CAST(@k AS NVARCHAR) + N';
        UPDATE #GMatrix SET
            C1=C1-C' + CAST(@k AS NVARCHAR) + N'*@p1,
            C2=C2-C' + CAST(@k AS NVARCHAR) + N'*@p2,
            C3=C3-C' + CAST(@k AS NVARCHAR) + N'*@p3,
            C4=C4-C' + CAST(@k AS NVARCHAR) + N'*@p4,
            C5=C5-C' + CAST(@k AS NVARCHAR) + N'*@p5,
            C6=C6-C' + CAST(@k AS NVARCHAR) + N'*@p6,
            C7=C7-C' + CAST(@k AS NVARCHAR) + N'*@p7,
            C8=C8-C' + CAST(@k AS NVARCHAR) + N'*@p8,
            C9=C9-C' + CAST(@k AS NVARCHAR) + N'*@p9,
            C10=C10-C' + CAST(@k AS NVARCHAR) + N'*@p10,
            C11=C11-C' + CAST(@k AS NVARCHAR) + N'*@p11,
            C12=C12-C' + CAST(@k AS NVARCHAR) + N'*@p12,
            C13=C13-C' + CAST(@k AS NVARCHAR) + N'*@p13,
            C14=C14-C' + CAST(@k AS NVARCHAR) + N'*@p14
        WHERE RowID <> ' + CAST(@k AS NVARCHAR) + N';';
    EXEC sp_executesql @sql;

    SET @k += 1;
END
GO

-- 7d. Extract coefficients — each Beta is that factor's independent effect on
-- lapse probability, holding all the other factors constant
IF OBJECT_ID('dbo.Geo_Model_Coefficients','U') IS NOT NULL DROP TABLE dbo.Geo_Model_Coefficients;
GO
SELECT RowID,
    CASE RowID
        WHEN 1 THEN 'Intercept' WHEN 2 THEN 'Agent_Tenure_Years' WHEN 3 THEN 'Is_Q4_Issue'
        WHEN 4 THEN 'Premium_Monthly' WHEN 5 THEN 'Is_Bancassurance' WHEN 6 THEN 'Region_Rural'
        WHEN 7 THEN 'Region_SemiUrban' WHEN 8 THEN 'Income_Low' WHEN 9 THEN 'Income_Mid'
        WHEN 10 THEN 'Age' WHEN 11 THEN 'Gender_Male' WHEN 12 THEN 'Occupation_NonWorking'
        WHEN 13 THEN 'Occupation_SelfEmployed'
    END AS Predictor,
    C14 AS Beta
INTO dbo.Geo_Model_Coefficients
FROM #GMatrix;

SELECT * FROM dbo.Geo_Model_Coefficients ORDER BY RowID;
GO

-- 7e. Score every policy (probability clipped to [0,1])
IF OBJECT_ID('dbo.Geo_LPM_Scores','U') IS NOT NULL DROP TABLE dbo.Geo_LPM_Scores;
GO
DECLARE @B0 FLOAT,@B1 FLOAT,@B2 FLOAT,@B3 FLOAT,@B4 FLOAT,@B5 FLOAT,@B6 FLOAT,@B7 FLOAT,@B8 FLOAT,@B9 FLOAT,@B10 FLOAT,@B11 FLOAT,@B12 FLOAT;
SELECT @B0=Beta FROM dbo.Geo_Model_Coefficients WHERE RowID=1;
SELECT @B1=Beta FROM dbo.Geo_Model_Coefficients WHERE RowID=2;
SELECT @B2=Beta FROM dbo.Geo_Model_Coefficients WHERE RowID=3;
SELECT @B3=Beta FROM dbo.Geo_Model_Coefficients WHERE RowID=4;
SELECT @B4=Beta FROM dbo.Geo_Model_Coefficients WHERE RowID=5;
SELECT @B5=Beta FROM dbo.Geo_Model_Coefficients WHERE RowID=6;
SELECT @B6=Beta FROM dbo.Geo_Model_Coefficients WHERE RowID=7;
SELECT @B7=Beta FROM dbo.Geo_Model_Coefficients WHERE RowID=8;
SELECT @B8=Beta FROM dbo.Geo_Model_Coefficients WHERE RowID=9;
SELECT @B9=Beta FROM dbo.Geo_Model_Coefficients WHERE RowID=10;
SELECT @B10=Beta FROM dbo.Geo_Model_Coefficients WHERE RowID=11;
SELECT @B11=Beta FROM dbo.Geo_Model_Coefficients WHERE RowID=12;
SELECT @B12=Beta FROM dbo.Geo_Model_Coefficients WHERE RowID=13;

SELECT
    Policy_ID,
    CASE
        WHEN (@B0+@B1*X1_Tenure+@B2*X2_Q4+@B3*X3_Monthly+@B4*X4_Banca+@B5*X5_Rural+@B6*X6_SemiUrban+@B7*X7_IncomeLow+@B8*X8_IncomeMid+@B9*X9_Age+@B10*X10_Male+@B11*X11_NonWorking+@B12*X12_SelfEmployed) < 0 THEN 0
        WHEN (@B0+@B1*X1_Tenure+@B2*X2_Q4+@B3*X3_Monthly+@B4*X4_Banca+@B5*X5_Rural+@B6*X6_SemiUrban+@B7*X7_IncomeLow+@B8*X8_IncomeMid+@B9*X9_Age+@B10*X10_Male+@B11*X11_NonWorking+@B12*X12_SelfEmployed) > 1 THEN 1
        ELSE (@B0+@B1*X1_Tenure+@B2*X2_Q4+@B3*X3_Monthly+@B4*X4_Banca+@B5*X5_Rural+@B6*X6_SemiUrban+@B7*X7_IncomeLow+@B8*X8_IncomeMid+@B9*X9_Age+@B10*X10_Male+@B11*X11_NonWorking+@B12*X12_SelfEmployed)
    END AS Predicted_Lapse_Prob
INTO dbo.Geo_LPM_Scores
FROM dbo.Geo_Model_Features;

SELECT * FROM dbo.Geo_LPM_Scores ORDER BY Predicted_Lapse_Prob DESC;
GO

-- 7f. Validation: bucket into risk bands and compare to actual lapse rate
WITH Banded AS (
    SELECT s.Predicted_Lapse_Prob, f.Y,
        CASE WHEN s.Predicted_Lapse_Prob >= 0.40 THEN 'High'
             WHEN s.Predicted_Lapse_Prob >= 0.20 THEN 'Medium' ELSE 'Low' END AS Risk_Band
    FROM dbo.Geo_LPM_Scores s
    JOIN dbo.Geo_Model_Features f ON f.Policy_ID = s.Policy_ID
)
SELECT
    Risk_Band,
    COUNT(*) AS Policies,
    ROUND(100.0 * SUM(CAST(Y AS INT)) / COUNT(*), 2) AS Actual_Lapse_Rate_Pct,
    ROUND(AVG(Predicted_Lapse_Prob) * 100, 2) AS Avg_Predicted_Prob_Pct
FROM Banded
GROUP BY Risk_Band
ORDER BY CASE Risk_Band WHEN 'High' THEN 1 WHEN 'Medium' THEN 2 ELSE 3 END;
GO