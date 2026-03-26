#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# 10-cost-current-month.sh -- AWS Cost Explorer: current month by service
#
# Queries AWS Cost Explorer for the current calendar month and displays
# total unblended cost broken down by service (top 20).
#
# Columns: Service | Cost (USD) | % of Total
# Output : table + output/aws-cost-current-month.json
#
# Required IAM permission: ce:GetCostAndUsage
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/colors.sh"
source "${SCRIPT_DIR}/../lib/prereqs.sh"
source "${SCRIPT_DIR}/../lib/table.sh"
source "${SCRIPT_DIR}/../lib/json.sh"

OUTPUT_DIR="${SCRIPT_DIR}/../output"
OUTPUT_FILE="${OUTPUT_DIR}/aws-cost-current-month.json"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
section "Prerequisites"
require_bin aws  || exit 1
require_bin jq   || exit 1
require_auth_aws || exit 1

# ---------------------------------------------------------------------------
# Compute date range: first day of current month to today + 1 day
# Cost Explorer end date is exclusive, so we use tomorrow to include today.
# ---------------------------------------------------------------------------
month_start="$(date +%Y-%m-01)"
# End date: first day of next month (exclusive upper bound)
# Using the first of next month ensures we capture the full current month.
if [[ "$(date +%m)" == "12" ]]; then
    month_end="$(date -d "$(date +%Y)-12-01 +1 month" +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)"
else
    next_month=$(( 10#$(date +%m) + 1 ))
    month_end="$(printf '%s-%02d-01' "$(date +%Y)" "$next_month")"
fi

section "AWS Cost Explorer -- Current Month"
info "Period: ${month_start} to ${month_end} (exclusive)"

# ---------------------------------------------------------------------------
# Query Cost Explorer
# ---------------------------------------------------------------------------
ce_output=""
if ! ce_output="$(aws ce get-cost-and-usage \
    --time-period "Start=${month_start},End=${month_end}" \
    --granularity MONTHLY \
    --metrics UnblendedCost \
    --group-by Type=DIMENSION,Key=SERVICE \
    --output json 2>&1)"; then

    # Detect Cost Explorer not enabled
    if echo "$ce_output" | grep -qi "OptInRequired\|not subscribed\|not enabled\|SubscriptionRequiredException"; then
        err "AWS Cost Explorer is not enabled for this account."
        err "  Enable it in the AWS Console: Billing > Cost Explorer > Enable Cost Explorer"
        err "  Note: It can take up to 24 hours for data to become available after enabling."
        exit 1
    fi

    # Detect permission errors
    if echo "$ce_output" | grep -qi "AccessDeniedException\|not authorized\|UnauthorizedAccess"; then
        err "Permission denied: ce:GetCostAndUsage is required."
        err "  Grant the 'ce:GetCostAndUsage' permission to your IAM identity."
        exit 1
    fi

    err "Cost Explorer query failed."
    err "  Output: ${ce_output}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Parse results: extract service-level costs, compute total, sort descending
# ---------------------------------------------------------------------------
# Build a sorted list: service \t cost
parsed="$(echo "$ce_output" | jq -r '
    [.ResultsByTime[0].Groups[]
     | {service: .Keys[0], cost: (.Metrics.UnblendedCost.Amount | tonumber)}]
    | sort_by(-.cost)
    | .[]
    | "\(.service)\t\(.cost)"
')"

# Compute total cost
total_cost="$(echo "$ce_output" | jq -r '
    [.ResultsByTime[0].Groups[].Metrics.UnblendedCost.Amount | tonumber] | add // 0
')"

if [[ -z "$total_cost" || "$total_cost" == "null" ]]; then
    total_cost=0
fi

info "Total unblended cost: \$$(printf '%.2f' "$total_cost")"

# ---------------------------------------------------------------------------
# Build table rows and JSON output (top 20 services)
# ---------------------------------------------------------------------------
json_start_array

table_rows=()
table_rows+=("Service|Cost (USD)|% of Total")

count=0
while IFS=$'\t' read -r service cost; do
    [[ -z "$service" ]] && continue
    (( count++ )) || true
    [[ "$count" -gt 20 ]] && break

    cost_fmt="$(printf '%.2f' "$cost")"

    if (( $(echo "$total_cost > 0" | bc -l) )); then
        pct="$(echo "scale=4; ($cost / $total_cost) * 100" | bc -l)"
        pct_fmt="$(printf '%.1f%%' "$pct")"
    else
        pct_fmt="0.0%"
        pct="0"
    fi

    table_rows+=("${service}|${cost_fmt}|${pct_fmt}")

    json_add_object \
        "service=s:${service}" \
        "cost_usd=${cost_fmt}" \
        "percent_of_total=$(printf '%.1f' "$pct")"
done <<< "$parsed"

json_end_array

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
section "Cost by Service (Top 20)"
printf '%s\n' "${table_rows[@]}" | table_print

info "Total: \$$(printf '%.2f' "$total_cost") across $(echo "$ce_output" | jq '.ResultsByTime[0].Groups | length') services"

mkdir -p "$OUTPUT_DIR"
json_write "$OUTPUT_FILE"
ok "JSON written to ${OUTPUT_FILE}"
