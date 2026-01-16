-- 1. Base client snapshot
-- This is the full list of clients we want to keep in the final output
with client_snapshot as (
    select 
        c.client_id,
        c.days_since_activation,
        c.inactive_days,
        c.creationdate as creation_date,
        c.mambu_state,
        c.first_transaction_date,
        c.last_transaction_date,

        c.total_loan_amount,
        c.total_inflow_amt,
        c.total_outflow_amt,
        c.total_billpayment_amt,
        c.total_savings_amt
    from bianalytics.client_snapshot_daily c
),

-- 2. Global variables for credit LTV and cost of acquisition
variables as (
    select 
        1680::numeric as cost_of_atr,  -- cost of acquisition per loan
        0.9::numeric  as lgd           -- loss given default
),


-- 3. Calendar of months with discount rate
-- Used to expand loans by month and attach cost of funding
calendar as (
    select 
        "date"::date as month,
        round(discount_rate / 100, 2)::numeric(5,4) as discount_rate  
    from ds_dbt_dev.discount_rate
),

-- 4. Cost of funding (portfolio-level average discount rate)
-- We use the average cost of new money as the single discount rate
cost_of_funding as (
    select 
        min(new_money_cost) as min_discount_rate,
        avg(new_money_cost)::numeric(10,6) as avg_discount_rate, -- annual cost of funding (Renmoney)
        max(new_money_cost) as max_discount_rate
    from datamarts.banking_monthly
),

-- 5. Loans: monthly loan amount per loan_id and client_id
--  We aggregate loans at (client, loan_id, loan_month) level
loans as (
    select 
        l.client_id,
        l.loan_id,
        date_trunc('month', l.loan_date)::date as loan_month,
        sum(l.loan_amount)::numeric(18,2)     as loan_amount
    from bianalytics.loans l
    group by 
        l.client_id,
        l.loan_id,
        date_trunc('month', l.loan_date)
),

-- 6. Revenue: monthly cash flow from loan_transaction
--    We sum actual payments by loan and month
revenue as (
    select 
        lt.loan_id,
        date_trunc('month', lt.pmt_date)::date as pmt_month,
        sum(lt.pmt_amount)::numeric(18,2)      as revenue_amount,
        sum(lt.pmt_principal)::numeric(18,2)   as principal_payment
    from bianalytics.loan_transaction lt
    where lt.pmt_type in ('PAYMENT', 'REPAYMENT') -- only real payments
    group by 
        lt.loan_id,
        date_trunc('month', lt.pmt_date)
),

-- 7. Base monthly loan panel:
--  One row per (client, loan, month) with revenues, loan amounts,
-- acquisition cost in the origination month, and portfolio discount rate
base as (
    select
        l.client_id,
        l.loan_id,
        c.month,
        c.discount_rate,  -- calendar discount rate (not used in DF, but kept for diagnostics)
        cof.avg_discount_rate, -- portfolio-level average cost of funding
        l.loan_month,
        l.loan_amount,
        coalesce(r.revenue_amount, 0)::numeric(18,2)       as revenue_amount,
        coalesce(r.principal_payment, 0)::numeric(18,2)    as principal_payment,

        case 
            when c.month = l.loan_month then v.cost_of_atr 
            else 0 
        end::numeric(18,2) as cost_of_atr_t,   -- acquisition cost only in origination month
        v.lgd
    from loans l
    join calendar c
        on c.month >= l.loan_month            -- expand loan into all months from origination onward
    left join revenue r
        on r.loan_id  = l.loan_id
       and r.pmt_month = c.month              -- attach monthly revenues
    cross join variables v
    cross join cost_of_funding cof
),

-- 8. PD per client: weighted by loan_amount across models
pd as (
    select
        s.client_id,
        round(
            sum(s.score * s.loan_amount) / nullif(sum(s.loan_amount), 0)
        )::numeric(18, 6) as pd,
        round(
            avg(
                sum(s.score * s.loan_amount) / nullif(sum(s.loan_amount), 0)
            ) over (),
            6
        )::numeric(18, 6) as avg_pd
    from bianalytics.scorestability s
    where s.model_name not in (
        'ot_internal_pngme_income_2504',
        'af_internal_addresssim_sel_pl_2411',
        'sc_internal_credolab_2501',
        'sc_internal_seon_2411',
        'af_internal_emailsim_insta_2408'
    )
    group by s.client_id
),


-- 9. Portfolio-level average PD (used as fallback when client PD is missing)
pd_avg as (
    select 
        round(
            sum(s.score * s.loan_amount) / nullif(sum(s.loan_amount), 0),
            6
        )::numeric(18,6) as avg_pd
    from bianalytics.scorestability s
    where s.model_name not in (
        'ot_internal_pngme_income_2504',
        'af_internal_addresssim_sel_pl_2411',
        'sc_internal_credolab_2501',
        'sc_internal_seon_2411',
        'af_internal_emailsim_insta_2408'
    )
),

-- 10. Monthly loan-level LTV (credit side)
--     Here we compute:
--     - EAD (exposure at default) as remaining principal
--     - Discount factor from avg_discount_rate
--     - No-risk margin and risk-adjusted EV per month
credit_monthly as ( 
    select
        b.client_id,
        b.loan_id,
        b.month,
        b.revenue_amount,
        b.principal_payment,
        case 
            when b.month = b.loan_month then b.loan_amount + b.cost_of_atr_t
            else 0
        end::numeric(18,2) as cost_amount,

        b.avg_discount_rate,
        
        round(
            (coalesce(p.pd, pa.avg_pd) / 1000.0),
            4
        )::numeric(18,8) as pd_prob,

        b.lgd,

        -- EAD approximation: original loan amount minus cumulative principal payments up to previous month
        greatest(
            b.loan_amount 
            - coalesce(
                  sum(b.principal_payment) over (
                      partition by b.loan_id
                      order by b.month
                      rows between unbounded preceding and 1 preceding
                  ),
                  0
              ),
            0
        )::numeric(18,2) as ead,

        -- Index of month within the loan life (0, 1, 2, ...)
        row_number() over (partition by b.loan_id order by b.month) - 1 as t_months,

        -- Discount factor using a constant avg_discount_rate for all months
        exp(
            - sum(
                ln(
                    1.0 + (b.avg_discount_rate::double precision / 12.0)
                )
            ) over (
                partition by b.loan_id
                order by b.month
                rows between unbounded preceding and current row
            )
        )::numeric(18,8) as discount_factor,

        -- Margin without risk in a given month
        (b.revenue_amount - cost_amount)::numeric(18,2) as margin_no_risk,

        -- No-risk NPV for this month
        round((b.revenue_amount - cost_amount) * discount_factor, 2) as ev_t_no_risk,

        -- Expected credit loss in this month
        round(pd_prob * b.lgd * ead, 2) as ecl,

        -- Risk-adjusted revenue in this month
        round(
            (b.revenue_amount * (1 - pd_prob) - (pd_prob * b.lgd * ead)),
            2
        ) as adj_revenue,

        -- Risk-adjusted NPV for this month
        round((adj_revenue - cost_amount) * discount_factor, 2) as ev_t

    from base b
    left join pd p    on p.client_id = b.client_id
    cross join pd_avg pa
    where not (
        coalesce(b.revenue_amount,0) = 0
        and (
              case when b.month = b.loan_month then b.loan_amount else 0 end
            ) = 0
    )
),


-- 11. Aggregate credit LTV per client
--     LTV_credit = sum of risk-adjusted NPV across all loans and months

ltv_credit as (
    select 
        cm.client_id,
        sum(cm.ev_t_no_risk)::numeric(18, 2) as ltv_credit_no_risk,
        sum(cm.ev_t)::numeric(18, 2)         as ltv_credit,          -- main LTV_credit metric
        sum(cm.margin_no_risk)::numeric(18, 2) as credit_margin_no_risk,
        -- we keep cost_amount just for diagnostics (3 * cost_of_atr is portfolio-level adjustment)
        sum(cm.cost_amount) - 3 * 1680        as credit_cost_amount
    from credit_monthly cm
    group by cm.client_id
),


-- 12. Non-credit margin assumptions (simple constants)
--     These coefficients approximate net margin from non-credit activities:
--       - transfers/inflows: 0.2% of monthly inflow
--       - bill payments:     1.0% of monthly bill payment volume
--       - savings:           3% annual spread on savings (converted to monthly)

noncredit_margin_coeffs as (
    select
        0.002::numeric(10,6) as k_inflow,        -- 0.2% margin on inflows
        0.010::numeric(10,6) as k_billpay,       -- 1.0% margin on bill payments
        0.030::numeric(10,6) as k_savings_year   -- 3% annual spread on savings
),


-- 13. Non-credit base: derive average monthly non-credit margin per client
--     Based only on snapshot fields and a constant avg_discount_rate

noncredit_base as (
    select
        cs.client_id,
        cs.first_transaction_date,
        cs.last_transaction_date,
        cs.total_inflow_amt,
        cs.total_outflow_amt,
        cs.total_billpayment_amt,
        cs.total_savings_amt,
        cof.avg_discount_rate,
        m.k_inflow,
        m.k_billpay,
        m.k_savings_year,

        -- Active window in days (fallback to 30 if dates are missing)
        case 
            when cs.first_transaction_date is not null 
             and cs.last_transaction_date  is not null
            then datediff(day, cs.first_transaction_date, cs.last_transaction_date) + 1
            else 30
        end::numeric(18,2) as active_days,

        -- Approximate number of active months (at least 1)
        greatest(
            (
                case 
                    when cs.first_transaction_date is not null 
                     and cs.last_transaction_date  is not null
                    then datediff(day, cs.first_transaction_date, cs.last_transaction_date) + 1
                    else 30
                end
            ) / 30.0,
            1.0
        )::numeric(18,4) as active_months
    from client_snapshot cs
    cross join cost_of_funding cof
    cross join noncredit_margin_coeffs m
),


-- 14. Non-credit LTV per client
--     We:
--       - estimate average monthly non-credit margins
--       - assume constant avg_discount_rate
--       - project margins over a fixed horizon (e.g. 12 months)
--       - compute NPV of that "annuity" using standard formula

ltv_nocredit as (
    select
        nb.client_id,

        -- Average monthly inflow, bill payment and savings level
        case 
            when nb.active_months > 0 
            then nb.total_inflow_amt      / nb.active_months 
            else 0
        end::numeric(18,2) as avg_monthly_inflow,

        case 
            when nb.active_months > 0 
            then nb.total_billpayment_amt / nb.active_months 
            else 0
        end::numeric(18,2) as avg_monthly_billpay,

        case 
            when nb.active_months > 0 
            then nb.total_savings_amt     / nb.active_months 
            else 0
        end::numeric(18,2) as avg_monthly_savings,

        nb.avg_discount_rate,

        -- Monthly non-credit margin:
        --  - k_inflow * inflow
        --  - k_billpay * bill payments
        --  - k_savings_year / 12 * savings
        (
            nb.k_inflow       * coalesce(nb.total_inflow_amt,      0)
          / nullif(nb.active_months, 0)
          + nb.k_billpay     * coalesce(nb.total_billpayment_amt, 0)
          / nullif(nb.active_months, 0)
          + (nb.k_savings_year / 12.0)
            * coalesce(nb.total_savings_amt, 0)
          / nullif(nb.active_months, 0)
        )::numeric(18,4) as margin_noncredit_month,

        -- We use a fixed horizon of 12 months for projecting future non-credit margin.
        12::integer as horizon_months,

        -- Monthly discount rate derived from avg_discount_rate
        (nb.avg_discount_rate / 12.0)::numeric(18,8) as r_month,

        -- NPV of a fixed monthly margin over horizon_months:
        --  if r_month > 0:
        --      LTV_nocredit = M * (1 - (1 + r_m)^(-T)) / r_m
        --  else:
        --      LTV_nocredit = M * T
        case 
            when nb.avg_discount_rate is null 
              or nb.avg_discount_rate = 0 
            then
                (
                    (
                        nb.k_inflow       * coalesce(nb.total_inflow_amt,      0)
                      / nullif(nb.active_months, 0)
                      + nb.k_billpay     * coalesce(nb.total_billpayment_amt, 0)
                      / nullif(nb.active_months, 0)
                      + (nb.k_savings_year / 12.0)
                        * coalesce(nb.total_savings_amt, 0)
                      / nullif(nb.active_months, 0)
                    ) * 12
                )::numeric(18,2)
            else
                (
                    (
                        nb.k_inflow       * coalesce(nb.total_inflow_amt,      0)
                      / nullif(nb.active_months, 0)
                      + nb.k_billpay     * coalesce(nb.total_billpayment_amt, 0)
                      / nullif(nb.active_months, 0)
                      + (nb.k_savings_year / 12.0)
                        * coalesce(nb.total_savings_amt, 0)
                      / nullif(nb.active_months, 0)
                    )
                    * (
                        1 - power(1 + (nb.avg_discount_rate / 12.0), -12)
                      ) / (nb.avg_discount_rate / 12.0)
                )::numeric(18,2)
        end as ltv_nocredit
    from noncredit_base nb
),


-- 15. Final output: one row per client, with LTV_credit and LTV_nocredit
--     All clients from client_snapshot are preserved (LEFT JOINs).

final as (
    select
        cs.client_id,
        cs.days_since_activation,
        cs.inactive_days,
        cs.creation_date,
        cs.mambu_state,
        cs.first_transaction_date,
        cs.last_transaction_date,
        cs.total_loan_amount,
        cs.total_inflow_amt,
        cs.total_outflow_amt,
        cs.total_billpayment_amt,
        cs.total_savings_amt,

        -- Credit LTV (risk-adjusted, based on loan cash flows)
        coalesce(lc.ltv_credit, 0)::numeric(18,2)          as ltv_credit,
        coalesce(lc.ltv_credit_no_risk, 0)::numeric(18,2)  as ltv_credit_no_risk,

        -- Non-credit LTV (based on snapshot aggregates and avg_discount_rate)
        coalesce(lnc.ltv_nocredit, 0)::numeric(18,2)       as ltv_nocredit
    from client_snapshot cs
    left join ltv_credit   lc  on lc.client_id = cs.client_id
    left join ltv_nocredit lnc on lnc.client_id = cs.client_id
)

select
    count(*) over () as rn,
    *,
    ltv_credit + ltv_nocredit as ltv 
from final
order by ltv_credit + ltv_nocredit asc;
