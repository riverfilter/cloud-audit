#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# 12-cost-trend.sh -- AWS Cost Explorer: 6-month cost trend
#
# Queries AWS Cost Explorer for the last 6 complete months and displays
# monthly totals with month-over-month delta.  Months with >20% increase
# are highlighted in red.
#
# Columns: Month | Total Cost (USD) | Delta vs Previous Month (USD) | Delta (%)
# Output : table + output/aws-cost-trend.json
#
# Required IAM permission: ce:GetCostAndUsage
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/colors.sh"
source "${SCRIPT_DIR}/../lib/prereqs.sh"
source "${SCRIPT_DIR}/../lib/table.sh"
source "${SCRIPT_DIR}/../lib/json.sh"

OUTPUT_DIR="${SCRIPT_DIR}/../output"
OUTPUT_FILE="${OUTPUT_DIR}/aws-cost-trend.json"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
section "Prerequisites"
require_bin aws  || exit 1
require_bin jq   || exit 1
require_auth_aws || exit 1

# ---------------------------------------------------------------------------
# Compute date range: 6 months ago to end of current month
# ---------------------------------------------------------------------------
# Start: first day of the month 6 months ago
trend_start="$(date -d "$(date +%Y-%m-01) -6 months" +%Y-%m-%d)"
# End: first day of next month (exclusive)
if [[ "$(date +%m)" == "12" ]]; then
    trend_end="$(date -d "$(date +%Y)-12-01 +1 month" +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)"
else
    next_month=$(( 10#$(date +%m) + 1 ))
    trend_end="$(printf '%s-%02d-01' "$(date +%Y)" "$next_month")"
fi

section "AWS Cost Explorer -- 6-Month Cost Trend"
info "Period: ${trend_start} to ${trend_end} (exclusive)"

# ---------------------------------------------------------------------------
# Query Cost Explorer -- monthly granularity, no grouping
# ---------------------------------------------------------------------------
ce_output=""
if ! ce_output="$(aws ce get-cost-and-usage \
    --time-period "Start=${trend_start},End=${trend_end}" \
    --granularity MONTHLY \
    --metrics UnblendedCost \
    --output json 2>&1)"; then

    if echo "$ce_output" | grep -qi "OptInRequired\|not subscribed\|not enabled\|SubscriptionRequiredException"; then
        err "AWS Cost Explorer is not enabled for this account."
        err "  Enable it in the AWS Console: Billing > Cost Explorer > Enable Cost Explorer"
        exit 1
    fi

    if echo "$ce_output" | grep -qi "AccessDeniedException\|not authorized\|UnauthorizedAccess"; then
        err "Permission denied: ce:GetCostAndUsage is required."
        exit 1
    fi

    err "Cost Explorer query failed."
    err "  Output: ${ce_output}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Parse results: extract month start dates and costs in chronological order
# ---------------------------------------------------------------------------
months=()
costs=()

while IFS=$'\t' read -r month_start cost; do
    [[ -z "$month_start" ]] && continue
    # Display as YYYY-MM
    month_label="${month_start:0:7}"
    months+=("$month_label")
    costs+=("$cost")
done < <(echo "$ce_output" | jq -r '
    .ResultsByTime[]
    | "\(.TimePeriod.Start)\t\(.Total.UnblendedCost.Amount | tonumber)"
')

num_months="${#months[@]}"

if [[ "$num_months" -eq 0 ]]; then
    warn "No cost data returned for the requested period."
    json_start_array
    json_end_array
    mkdir -p "$OUTPUT_DIR"
    json_write "$OUTPUT_FILE"
    ok "Empty JSON written to ${OUTPUT_FILE}"
    exit 0
fi

# ---------------------------------------------------------------------------
# Build table rows and JSON with delta calculations
# ---------------------------------------------------------------------------
json_start_array

table_rows=()
table_rows+=("Month|Total Cost (USD)|Delta vs Previous (USD)|Delta (%)")

prev_cost=""
for (( i=0; i<num_months; i++ )); do
    month="${months[$i]}"
    cost="${costs[$i]}"
    cost_fmt="$(printf '%.2f' "$cost")"

    if [[ -z "$prev_cost" ]]; then
        # First month -- no delta
        delta_fmt="--"
        delta_pct_fmt="--"
        delta_pct_raw=""

        table_rows+=("${month}|${cost_fmt}|${delta_fmt}|${delta_pct_fmt}")

        json_add_object \
            "month=s:${month}" \
            "cost_usd=${cost_fmt}" \
            "delta_usd=null" \
            "delta_percent=null"
    else
        delta="$(echo "scale=4; $cost - $prev_cost" | bc -l)"
        delta_fmt="$(printf '%.2f' "$delta")"

        if (( $(echo "$prev_cost != 0" | bc -l) )); then
            delta_pct="$(echo "scale=4; ($delta / $prev_cost) * 100" | bc -l)"
            delta_pct_fmt="$(printf '%.1f%%' "$delta_pct")"
            delta_pct_raw="$(printf '%.1f' "$delta_pct")"
        else
            if (( $(echo "$cost > 0" | bc -l) )); then
                delta_pct_fmt="N/A"
                delta_pct_raw=""
            else
                delta_pct_fmt="0.0%"
                delta_pct_raw="0.0"
            fi
        fi

        # Highlight months with >20% increase in bold red
        highlight=0
        if [[ -n "$delta_pct_raw" ]] && (( $(echo "$delta_pct_raw > 20" | bc -l) )); then
            highlight=1
        fi

        if [[ "$highlight" -eq 1 ]]; then
            table_rows+=("${BOLD_RED}${month}${RESET}|${BOLD_RED}${cost_fmt}${RESET}|${BOLD_RED}${delta_fmt}${RESET}|${BOLD_RED}${delta_pct_fmt}${RESET}")
        else
            table_rows+=("${month}|${cost_fmt}|${delta_fmt}|${delta_pct_fmt}")
        fi

        if [[ -n "$delta_pct_raw" ]]; then
            json_add_object \
                "month=s:${month}" \
                "cost_usd=${cost_fmt}" \
                "delta_usd=${delta_fmt}" \
                "delta_percent=${delta_pct_raw}"
        else
            json_add_object \
                "month=s:${month}" \
                "cost_usd=${cost_fmt}" \
                "delta_usd=${delta_fmt}" \
                "delta_percent=null"
        fi
    fi

    prev_cost="$cost"
done

json_end_array

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
section "6-Month Cost Trend"
printf '%s\n' "${table_rows[@]}" | table_print

mkdir -p "$OUTPUT_DIR"
json_write "$OUTPUT_FILE"
ok "JSON written to ${OUTPUT_FILE}"
