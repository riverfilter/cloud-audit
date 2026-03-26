#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# 13-cost-by-tag.sh -- AWS Cost Explorer: current month by tag key
#
# Queries AWS Cost Explorer for the current calendar month, grouped by a
# user-specified tag key (default: Environment).
#
# Usage: ./13-cost-by-tag.sh [--tag-key <key>]
#
# Columns: Tag Value | Cost (USD) | % of Total
# Output : table + output/aws-cost-by-tag.json
#
# Required IAM permission: ce:GetCostAndUsage
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/colors.sh"
source "${SCRIPT_DIR}/../lib/prereqs.sh"
source "${SCRIPT_DIR}/../lib/table.sh"
source "${SCRIPT_DIR}/../lib/json.sh"

OUTPUT_DIR="${SCRIPT_DIR}/../output"
OUTPUT_FILE="${OUTPUT_DIR}/aws-cost-by-tag.json"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
TAG_KEY="Environment"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag-key)
            TAG_KEY="${2:?--tag-key requires a value}"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $(basename "$0") [--tag-key <key>]"
            echo ""
            echo "  --tag-key <key>   Cost allocation tag key to group by (default: Environment)"
            exit 0
            ;;
        *)
            err "Unknown argument: $1"
            err "Usage: $(basename "$0") [--tag-key <key>]"
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
section "Prerequisites"
require_bin aws  || exit 1
require_bin jq   || exit 1
require_auth_aws || exit 1

# ---------------------------------------------------------------------------
# Compute date range: current calendar month
# ---------------------------------------------------------------------------
month_start="$(date +%Y-%m-01)"
if [[ "$(date +%m)" == "12" ]]; then
    month_end="$(date -d "$(date +%Y)-12-01 +1 month" +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)"
else
    next_month=$(( 10#$(date +%m) + 1 ))
    month_end="$(printf '%s-%02d-01' "$(date +%Y)" "$next_month")"
fi

section "AWS Cost Explorer -- Cost by Tag"
info "Tag key: ${TAG_KEY}"
info "Period:  ${month_start} to ${month_end} (exclusive)"

# ---------------------------------------------------------------------------
# Query Cost Explorer grouped by TAG
# ---------------------------------------------------------------------------
ce_output=""
if ! ce_output="$(aws ce get-cost-and-usage \
    --time-period "Start=${month_start},End=${month_end}" \
    --granularity MONTHLY \
    --metrics UnblendedCost \
    --group-by "Type=TAG,Key=${TAG_KEY}" \
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
# Parse results: extract tag values and costs, sort descending
# The tag key in the response is formatted as "Environment$value" -- we
# need to strip the "TagKey$" prefix.
# ---------------------------------------------------------------------------
parsed="$(echo "$ce_output" | jq -r --arg tag_key "$TAG_KEY" '
    [.ResultsByTime[0].Groups[]
     | {
         tag_value: (
           .Keys[0]
           | if startswith($tag_key + "$") then
               split("$")[1]
             else
               .
             end
           | if . == "" then "(not tagged)" else . end
         ),
         cost: (.Metrics.UnblendedCost.Amount | tonumber)
       }
    ]
    | sort_by(-.cost)
    | .[]
    | "\(.tag_value)\t\(.cost)"
')"

total_cost="$(echo "$ce_output" | jq -r '
    [.ResultsByTime[0].Groups[].Metrics.UnblendedCost.Amount | tonumber] | add // 0
')"

if [[ -z "$total_cost" || "$total_cost" == "null" ]]; then
    total_cost=0
fi

info "Total unblended cost: \$$(printf '%.2f' "$total_cost")"

# ---------------------------------------------------------------------------
# Build table rows and JSON
# ---------------------------------------------------------------------------
json_start_array

table_rows=()
table_rows+=("Tag Value (${TAG_KEY})|Cost (USD)|% of Total")

while IFS=$'\t' read -r tag_value cost; do
    [[ -z "$tag_value" ]] && continue

    cost_fmt="$(printf '%.2f' "$cost")"

    if (( $(echo "$total_cost > 0" | bc -l) )); then
        pct="$(echo "scale=4; ($cost / $total_cost) * 100" | bc -l)"
        pct_fmt="$(printf '%.1f%%' "$pct")"
    else
        pct_fmt="0.0%"
        pct="0"
    fi

    table_rows+=("${tag_value}|${cost_fmt}|${pct_fmt}")

    json_add_object \
        "tag_key=s:${TAG_KEY}" \
        "tag_value=s:${tag_value}" \
        "cost_usd=${cost_fmt}" \
        "percent_of_total=$(printf '%.1f' "$pct")"
done <<< "$parsed"

json_end_array

# ---------------------------------------------------------------------------
# Handle no data
# ---------------------------------------------------------------------------
if [[ "${#table_rows[@]}" -le 1 ]]; then
    warn "No cost data found for tag key '${TAG_KEY}'."
    warn "  Ensure the tag is activated as a cost allocation tag in the Billing console."
    warn "  Billing > Cost Allocation Tags > Activate"
fi

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
section "Cost by Tag: ${TAG_KEY}"
printf '%s\n' "${table_rows[@]}" | table_print

mkdir -p "$OUTPUT_DIR"
json_write "$OUTPUT_FILE"
ok "JSON written to ${OUTPUT_FILE}"
