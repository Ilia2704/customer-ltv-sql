# customer-ltv-sql
Risk-adjusted Customer Lifetime Value (Economic Value) modeling using pure SQL 

(CLTV × credit &amp; retention risk: PD, LGD, EAD)

# customer-ltv-sql

This repository presents a **risk-oriented Customer Lifetime Value framework**, implemented entirely in **SQL**.

The project goes beyond classical CLTV calculations by incorporating **customer-specific risk**, resulting in a metric called **Economic Value (EV)**.

Economic Value reflects the *true expected contribution* of a customer after accounting for:
- credit risk,
- retention uncertainty,
- cost-to-serve,
- and discounting of future cash flows.

The approach is inspired by real-world **fintech and credit risk practices**, where profitability must always be evaluated together with risk.

## Purpose and Definitions

### Purpose
The goal of this project is to demonstrate a **production-style methodology** for calculating  
**risk-adjusted Customer Lifetime Value (Economic Value, EV)** using SQL only.

The metric **EV** represents the economic value of a customer after adjusting traditional CLTV
for **individual credit risk and retention risk**.

This type of metric is commonly used in:
- fintech and consumer lending,
- credit decisioning,
- portfolio profitability analysis,
- risk-based customer segmentation.


### Key Definitions

- **CLTV (Customer Lifetime Value)**  
  Discounted future revenues minus future costs, *without* explicit risk adjustment.

- **EV (Economic Value)**  
  Risk-adjusted CLTV that incorporates individual customer risk:

  EV = CLTV × Customer Risk Adjustment

- **Risk Adjustment**  
  Combination of:
  - PD (Probability of Default),
  - LGD (Loss Given Default),
  - EAD (Exposure at Default),
  - Retention probability.

- **Unit of analysis**  
  Single customer.


## Calculation Order

Two levels are provided: a high-level overview and detailed analytical steps.

### High-Level Steps
1. Forecast future customer revenues.
2. Estimate cost-to-serve per period.
3. Calculate baseline CLTV (without risk).
4. Apply risk adjustment using PD, LGD, EAD, and retention.
5. Compute Economic Value (EV).


### Step 1 – Revenue Forecast
- Extract historical income (interest, fees, penalties).
- Determine ticket-size dynamics for repeat borrowers.
- Build revenue projections for future periods.

Adjusted expected revenue per period:

AdjRevenue_t = Revenue_t × (1 − PD_t) − ECL_t

Where:
- ECL_t = PD_t × LGD_t × EAD_t


### Step 2 – Cost-to-Serve
Includes:
- Customer Acquisition Cost (CAC),
- Scoring and KYC costs,
- Operational servicing costs,
- Collection and recovery costs.

Total costs are projected per customer and period.


### Step 3 – Baseline CLTV
Baseline CLTV is calculated as the discounted sum of future net cash flows:

- Discount rate: **22%**
- Time horizon: defined loan / customer lifecycle

### Step 4 – Risk Adjustment
Risk adjustment reduces expected value by:
- probability of default,
- expected credit loss (LGD × EAD),
- probability of customer retention in future cycles.

### Step 5 – Economic Value (EV)
Economic Value reflects the **true economic contribution** of a customer after accounting for risk:

- EV > 0 → customer creates value.
- EV < 0 → customer destroys value.
- EV ≪ CLTV → profitability eroded by risk.
- EV ≈ CLTV → stable, low-risk customer.

