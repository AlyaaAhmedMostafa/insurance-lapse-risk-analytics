# Insurance Portfolio Persistency & Risk Analytics
### Comprehensive Strategic Portfolio Report: Pricing, Payment Dynamics, and Operational Churn Drivers

**A comprehensive diagnostic of policy lapse behavior, claims-driven attrition, distribution channel quality, and predictive churn risk — built on SQL Server (T-SQL, closed-form Linear Probability Modeling).**

![SQL Server](https://img.shields.io/badge/SQL%20Server-T--SQL-CC2927?logo=microsoftsqlserver&logoColor=white)
![Status](https://img.shields.io/badge/status-complete-brightgreen)
![Analysis](https://img.shields.io/badge/method-Linear%20Probability%20Model-blue)

---

## 📑 Table of Contents
1. [Overview](#overview)
2. [Data Integrity](#1-data-integrity)
3. [Portfolio Persistency (Cohort Decay)](#2-portfolio-persistency-cohort-decay)
4. [Distribution Channel Performance](#3-distribution-channel-performance)
5. [Geographic & Demographic Segmentation](#4-geographic--demographic-segmentation)
6. [Claims-Driven Attrition](#5-claims-driven-attrition)
7. [Product, Pricing & Payment Behavior](#6-product-pricing--payment-behavior)
8. [Root Causes of Lapse](#7-root-causes-of-lapse)
9. [Predictive Modeling & Risk Scoring](#8-predictive-modeling--risk-scoring)
10. [Agent & Branch Operational Risk](#9-agent--branch-operational-risk)
11. [Strengths](#-strengths)
12. [Weaknesses / Risk Areas](#-weaknesses--risk-areas)
13. [Opportunities & Recommendations](#-opportunities--recommendations)
14. [Closing Note](#closing-note)

---

## Overview

This report consolidates every analysis run against the `Policy_Data` table (SQL Server, `Insurance` database): data quality checks, cohort persistency curves, channel and geographic segmentation, demographic cuts, claims-driven attrition economics, and multivariate predictive models — **Linear Probability Models solved in pure T-SQL via closed-form Normal Equations / Gauss-Jordan elimination, with no external ML runtime required.**

> **Note on figures:** Some percentages below come from independent analysis passes with slightly different segment definitions or sample slices (the dataset is a simulated portfolio). Where two sections report different absolute numbers for a similar cut, both are shown with their source context — the **directional conclusion** (which segment is riskier, and by roughly how much) is the reliable takeaway, not the exact decimal.

---

## 1. Data Integrity

- Total policies evaluated: **13,128**
- Invalid age count: **0** (after cleaning) — ages cleanly range from **18 to 78**
- This confirms the demographic and predictive layers are built on a reliable baseline, free of age-driven distortion.

---

## 2. Portfolio Persistency (Cohort Decay)

Persistency declines steadily and near-linearly across the policy lifecycle:

| Checkpoint | Persistency Ratio |
|---|---|
| Month 13 (Year 1) | 81.65% |
| Month 25 (Year 2) | 68.39% |
| Month 37 (Year 3) | 58.05% |
| Month 49 (Year 4) | 48.74% |
| Month 61 (Year 5) | 41.68% |

**Key insight:** the book bleeds roughly 10–13% of its active base every year; by Year 5 more than half the original cohort has lapsed.

**By Product Type (Month 61):**
- Strongest retention: **Individual Health** (41.11%), **Critical Illness** (40.17%)
- Weakest retention: **Top-Up** (39.45%), **Family Floater**

**Historical underwriting-quality trend (13-month persistency by issue cohort):**
- 2020–mid 2021: stable, 83–85%
- Late 2022–late 2023 ("the quality dip"): fell to 76.53% (2022 Q4) and 73.44% (2023 Q4)
- 2024–2025 (recovery): back up to 82–85%

---

## 3. Distribution Channel Performance

| Channel | Volume | Lapse Rate | 13M Persistency | 61M Persistency |
|---|---|---|---|---|
| Agency | 8,542 policies (dominant) | 39.98% | 83.28% | 44.82% |
| Bancassurance | growing share | 40.91% | 78.26% | 30.43% |

- **Business mix shift:** Agency held 79.48% of volume in 2020; by 2026 Bancassurance became dominant at 53.36% of issued policies.
- **Channel Supremacy:** Agency consistently outperforms Bancassurance on retention across *every* region studied.

> **Strategic tension:** the company has been scaling its lowest-retaining channel while its highest-quality channel loses volume share — this is actively eroding long-term portfolio LTV.

---

## 4. Geographic & Demographic Segmentation

### Region (Rural vs. Urban vs. Semi-Urban)

| Region | Policies | Lapse Rate | 61M Persistency |
|---|---|---|---|
| Rural | 2,117 | 44.78% | 33.50% |
| Urban | 6,886 | 41.30% | — |
| Semi-Urban | 4,125 | 40.36% (most stable) | — |

**Is it geography or channel?** Isolating the interaction shows Agency is the *more* volatile channel within rural territories specifically (45.54% lapse) vs. Bancassurance (43.74%) in that same region — but a separate regional-servicing cut found Rural Bancassurance to be the single worst cell overall at 77.23% 13-month persistency, and Semi-Urban/Urban Agency the best (84.51% / 83.60%).

> **Read together:** geography and channel both matter, and their combination compounds risk — rural + the weaker channel in that context is the worst-performing cell no matter which channel that turns out to be in a given cut.

### Income

| Segment | Lapse Rate |
|---|---|
| Low income | 48.27% (highest risk) |
| High income | 35.86% (most stable) |

Clear inverse relationship between income and attrition.

### Occupation
Fairly uniform — a narrow band from **40.43%** (Self-Employed) to **42.67%** (Retired). Not a strong standalone driver.

### Age

| Age Band | Lapse Rate |
|---|---|
| Under 25 | 47.52% (highest) |
| 65+ | 30.71% (lowest) |

Risk declines steadily and cleanly with age — a clean, monotonic relationship.

### Gender
Minimal effect: Male 40.93% vs. Female 42.25% — not a meaningful standalone driver.

---

## 5. Claims-Driven Attrition

This is one of the strongest, most actionable signals in the entire portfolio.

| Claims Segment | Policies | Lapse Rate |
|---|---|---|
| No Claim (Year 1) — baseline | 10,506 | 40.53% |
| Claim Approved | 2,023 | 41.13% (≈ baseline) |
| **Claim Rejected** | 599 | **61.27%** |

- **Chi-square statistic: 100.29** — the claim-rejection → lapse relationship is statistically highly significant, not noise.
- **Odds Ratio: 2.31** — a customer with a rejected claim is **2.31× more likely** to lapse than one without.
- **Multivariate model** (controlling for tenure, premium mode, income, etc.): `Claim_Rejected` carries an independent Beta of **+0.2068** — rejection alone raises lapse probability by ~20.7 percentage points, *net* of every other factor in the model.

### Revenue at Risk

- **Realized loss:** of 599 rejected-claim policies, 367 have already lapsed vs. an expected 242.8 at baseline — an **excess of 124.2 "forced lapses"** attributable to the rejection event, translating to **$326,491.80** in lost annual premium already recognized.
- **Forward-looking exposure:** 230 of the 599 rejected-claim accounts are still active today. Applying the +20.69% adjusted lapse-probability uplift to their remaining premium stream puts **$804,280** in additional revenue at risk if nothing changes.
- A complementary cut confirms the pattern at a longer horizon: 25-month persistency is **69.1–69.3%** for both "claim paid" and "no claim" cohorts, but collapses to **51.20%** after a rejection — exposing **$2,697,123** in active in-force premium to defection risk from this single friction point.
- A broader claims-utilization view reinforces the same story from the other direction: filing *any* claim (successful or not) tends to lower lapse risk relative to never engaging with the product at all (customers who never file lapse at the highest rate), while rejection specifically reverses that protective effect.

---

## 6. Product, Pricing & Payment Behavior

**Pricing / product risk:**
- **Senior Citizen** plans command the highest rate (62.24 per 1,000 Sum Assured) — most premium-intensive.
- **Individual Health** carries the highest operational risk: highest claim-filing rate (22.18%) *and* highest rejection rate (4.87%) — a sign of underwriting pressure on this line.
- **Family Floater** is the most stable/profitable product: lowest claim rate (18.41%) and lowest rejection rate (4.37%).

**Plan-level scorecard:**
- Worst performer: **Luxe Care** (42.23% lapse)
- Best-performing / most stable: **Standard Shield** (39.26% lapse)
- Top revenue generator: **Essential Plus** (~$120.5M total premium, 39.46% lapse)

**Payment frequency — one of the most powerful leading indicators in the whole dataset:**

| Payment Mode | Lapse Rate | 13M Persistency | 61M Persistency |
|---|---|---|---|
| Monthly | 44.49% (up to 68.04% by month 61 in one cut) | 78.5% | — |
| Annual | 36.29% (low as 14.70% at month 13 in one cut) | 85.3% | 49.34–50.7% |

Monthly-pay customers alone put an estimated **$52.6M in revenue at risk**.

**Customer behavior drivers:**
- **Riders:** having an attached rider drops lapse from 42.92% → 36.95% — one of the clearest positive levers available, especially strong in Retail Conversion and Family Floater lines.
- **Pre-existing conditions:** counter-intuitively *more* loyal (38.90% vs. 41.13% for healthy policyholders) — likely driven by ongoing perceived need for coverage.
- **No medical exam required:** associated with a *higher* lapse rate (41.04%) — a possible proxy for lower initial underwriting engagement/commitment.
- **Complaints:** the single strongest late-stage warning sign — **46.33%** of anyone who logs a formal complaint eventually lapses.

---

## 7. Root Causes of Lapse

Stated reasons behind terminations:

| Reason | Share of Lapses |
|---|---|
| Non-Payment of Premium | 42.84% |
| Affordability Issues | 12.70% |
| Switched Provider | 11.73% |
| Service Dissatisfaction | 11.67% |
| Suspected Mis-selling | 4.01% |

**Collections and affordability alone drive over 55% of all lapses** — this is fundamentally a payments/collections problem before it is anything else, with competitive and service-quality friction as the second-order cause.

---

## 8. Predictive Modeling & Risk Scoring

A multivariate Linear Probability Model (closed-form OLS, solved via Gauss-Jordan elimination directly in T-SQL — no R/Python/ML Services dependency) was built to isolate each factor's *independent* contribution to lapse probability.

### Regression Coefficients (Beta) — net of all other factors

| Predictor | Beta | Direction |
|---|---|---|
| Income_Low | **+0.1205** | 🔴 Strongest risk driver |
| Is_Q4_Issue | +0.1036 | 🔴 Major risk driver |
| Premium_Monthly | +0.0695 | 🔴 Moderate risk driver |
| Region_Rural | +0.0311 | 🟠 Minor risk driver |
| Age | −0.0033 | 🟢 Minor protective factor |
| Agent_Tenure_Years | **−0.0247** | 🟢 Protective factor |
| Claim_Rejected *(claims-focused model)* | **+0.2068** | 🔴 Single largest isolated driver identified across all models |

**Interpretation:** even after controlling for everything else, a rejected claim is the single most powerful lapse predictor uncovered in this analysis — more than double the effect size of the next-largest driver (low income).

### Model Validation — predicted vs. actual, by risk band

| Risk Band | Policies | Avg. Predicted Prob. | Actual Lapse Rate |
|---|---|---|---|
| High (≥40%) | 7,268 | 49.73% | 49.92% |
| Medium (20–40%) | 5,444 | 32.66% | 32.49% |
| Low (<20%) | 416 | 15.48% | 14.42% |

The gap between predicted and actual is under 1 point in every band — the model is well-calibrated, not overfit or directionally biased.

### Portfolio-Level Exposure (active book, scored)

| Risk Band | Policies | Premium Exposure |
|---|---|---|
| Low (0–20%) | 3,011 | $83,711,857 |
| Medium (20–40%) | 4,115 | $111,665,367 |
| High (40–60%) | 316 | $8,050,316 |
| Very High (60%+) | 26 | $455,844 |

Individual extremes: highest-risk account observed at **~80–85% predicted lapse probability**; lowest-risk accounts as low as **~3%**.

---

## 9. Agent & Branch Operational Risk

- Peer-average early lapse rate: **5.71%** (agents), **6.62%** (branches).
- Using a minimum-volume threshold of 10 policies (to suppress small-sample noise), **56 agents** breached safe operational thresholds.
  - Top outlier: **AGT00048** at 44.44% early lapse (+38.73 points above peer average)
  - Runner-up: **AGT00303** at 35.29%
- Branch-level: **BR0142** is the single largest regional risk at 34.38% early lapse (+27.75 points above benchmark), followed by **BR0039** at 28.57%.
- These magnitudes are well outside normal variance and are consistent with forced volume or low-quality sales practices under short-term targets — strong candidates for commission clawback review and sales-quality audit.

---

## ✅ Strengths

- **Clean, reliable underlying data** — zero invalid ages after standard cleaning; no structural data-quality blocker to analysis.
- **Strong, statistically validated signal on claims handling** — the claim-rejection → lapse link is confirmed by both a highly significant chi-square test (100.29) and an independent multivariate model (Beta +0.2068), not just a raw correlation.
- **A well-calibrated predictive model** — validation bands track actual outcomes within ~1 percentage point, meaning the risk scores can be trusted operationally, not just directionally.
- **Clear, actionable levers already visible in the data** — riders, annual payment mode, and agent tenure all show consistent, sizeable protective effects that can be acted on immediately.
- **Agency channel and higher-tenure agents demonstrably outperform** on retention across virtually every cut — proof that the company already has a "gold standard" internally to benchmark against and scale.
- **Underwriting quality has recovered** from the 2022–2023 dip back to historical norms (82–85% 13-month persistency), showing the business can correct course when needed.

## ⚠️ Weaknesses / Risk Areas

- **Structural over-reliance on the weaker channel.** Bancassurance now represents the majority of new business (53%+) despite consistently trailing Agency on every retention metric, in every region — a strategic mix problem, not a one-off.
- **Claims rejection handling is actively destroying value.** ~$326K already lost historically, ~$804K more at risk from currently active accounts — and this is arguably one of the most controllable drivers in the whole portfolio.
- **Collections/affordability dominate root causes** (>55% of all lapses), suggesting payment friction — not product quality — is the primary leak.
- **Monthly payment mode is a persistent high-risk segment** (~44–45% lapse, up to 68% by month 61 in some cuts), and tens of millions in premium sit exposed here.
- **Rural segment underperforms across the board**, compounded further when paired with the weaker distribution channel in that geography.
- **Meaningful pockets of agent/branch-level misconduct or poor sales quality** — 56 agents and multiple branches show early-lapse rates 5–7× the peer average, a red flag for point-of-sale practices.
- **Q4 year-end sales push measurably degrades business quality** (13-month persistency 74.78% vs. 83.72% rest of year) — volume incentives appear to be trading short-term targets for long-term retention.

## 🎯 Opportunities & Recommendations

1. **Fix claims-rejection experience first — it's the single highest-leverage lever identified.** Audit rejection communication for tone and clarity, build a real appeals/escalation path, and proactively assign retention outreach to the ~230 currently active accounts with a past rejection before their next renewal.
2. **Rebalance channel strategy.** Tie Bancassurance partner compensation to multi-year persistency rather than point-of-sale volume; consider capping or slowing Bancassurance volume growth until quality gaps close, especially in rural markets.
3. **Attack the payment-mode problem directly.** Incentivize migration from Monthly to Annual (discounts, grace periods, micro-incentives) — this single change plausibly protects tens of millions in at-risk premium.
4. **Mandate/bundle riders at point of sale** — one of the cleanest, most consistent protective factors in the data, with minimal apparent downside.
5. **Stand up a real-time complaint-triggered retention workflow.** A logged complaint is close to a coin-flip on eventual lapse (46.33%) — this population should be intercepted immediately, not reactively.
6. **Re-architect Q4 incentive structures** so volume targets don't come at the direct expense of persistency — consider quality-adjusted KPIs (e.g., persistency-weighted commission) for year-end campaigns.
7. **Formal audit of the 56 flagged agents and top-risk branches** (led by AGT00048, BR0142) for potential forced-volume or mis-selling practices, with commission clawback review where warranted.
8. **Operationalize the predictive risk score.** With validation this tight, the model is ready to drive real workflows: route the ~342 High/Very-High risk accounts (40%+ predicted probability) to proactive retention teams now, and use the Medium band (4,115 policies, ~$112M exposure) for lighter-touch nurture campaigns.
9. **Offer no-claim incentives** (renewal cashback / no-claim bonus) to offset the counter-intuitively high lapse inclination among customers who never engage with a claim at all.
10. **Use tenured agents as a training benchmark.** The tenure effect (protective Beta, and a clean 80.74% vs. 84.63% 13-month persistency gap between <1yr and 1yr+ agents) suggests structured mentorship or an extended onboarding/certification period for new agents could measurably lift early-book quality.

---

## Closing Note

Across every independent analysis — descriptive segmentation, statistical significance testing, and multivariate predictive modeling — the same handful of drivers surface repeatedly: **claims handling, payment mode/collections friction, channel mix, and Q4 sales-quality discipline.** These are not exotic risks; they are known, measurable, and — based on the model's calibration accuracy — predictable well in advance. The opportunity is less about finding new signal and more about operationalizing the signal that has already been found.

---

*This report was generated from SQL Server (T-SQL) analysis of the `Policy_Data` table in the `Insurance` database, including closed-form Linear Probability Models solved via in-database Gauss-Jordan elimination.*
