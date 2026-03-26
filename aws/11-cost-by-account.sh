#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# 11-cost-by-account.sh -- AWS Cost Explorer: current month by linked account
#
# Queries AWS Cost Explorer grouped by linked account. Only meaningful in
# an AWS Organization with consolidated billing.
#
# Columns: Account ID | Account Name | Cost (USD) | % of Total
# Output : table + output/aws-cost-by-account.json
#
# Required IAM permissions: ce:GetCostAndUsage, organizations:ListAccounts
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/colors.sh"
source "${SCRIPT_DIR}/../lib/prereqs.sh"
source "${SCRIPT_DIR}/../lib/table.sh"
source "${SCRIPT_DIR}/../lib/json.sh"

OUTPUT_DIR="${SCRIPT_DIR}/../output"
OUTPUT_FILE="${OUTPUT_DIR}/aws-cost-by-account.json"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
section "Prerequisites"
require_bin aws  || exit 1
require_bin jq   || exit 1
require_auth_aws || exit 1

# ---------------------------------------------------------------------------
# Check Organizations access -- needed for account name mapping and to
# confirm consolidated billing is in use.
# ---------------------------------------------------------------------------
section "AWS Organizations Check"

declare -A account_names=()
has_org=0

org_output=""
if org_output="$(aws organizations describe-organization --output json 2>&1)"; then
    has_org=1
    ok "Running within an AWS Organization."

    # Attempt to build account ID -> name mapping
    accounts_output=""
    if accounts_output="$(aws organizations list-accounts --output json 2>&1)"; then
        while IFS=$'\t' read -r acct_id acct_name; do
            account_names["$acct_id"]="$acct_name"
        done < <(echo "$accounts_output" | jq -r '.Accounts[] | "\(.Id)\t\(.Name)"')
        ok "Loaded ${#account_names[@]} account name(s) from Organizations."
    else
        warn "Could not list organization accounts (organizations:ListAccounts denied)."
        warn "  Account IDs will be shown without names."
    fi
else
    if echo "$org_output" | grep -qi "AWSOrganizationsNotInUseException"; then
        warn "This account is not part of an AWS Organization."
        warn "  Cost-by-account grouping is only meaningful with consolidated billing."
        warn "  Skipping this audit."
        # Write empty JSON for consistency
        json_start_array
        json_end_array
        mkdir -p "$OUTPUT_DIR"
        json_write "$OUTPUT_FILE"
        ok "Empty JSON written to ${OUTPUT_FILE}"
        exit 0
    elif echo "$org_output" | grep -qi "AccessDeniedException\|not authorized"; then
        warn "Cannot access AWS Organizations (access denied)."
        warn "  Proceeding with cost query -- account names may not be available."
    else
        warn "Could not determine Organizations status: ${org_output}"
        warn "  Proceeding with cost query -- account names may not be available."
    fi
fi

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

section "AWS Cost Explorer -- Cost by Account"
info "Period: ${month_start} to ${month_end} (exclusive)"

# ---------------------------------------------------------------------------
# Query Cost Explorer grouped by LINKED_ACCOUNT
# ---------------------------------------------------------------------------
ce_output=""
if ! ce_output="$(aws ce get-cost-and-usage \
    --time-period "Start=${month_start},End=${month_end}" \
    --granularity MONTHLY \
    --metrics UnblendedCost \
    --group-by Type=DIMENSION,Key=LINKED_ACCOUNT \
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
# Parse results
# ---------------------------------------------------------------------------
parsed="$(echo "$ce_output" | jq -r '
    [.ResultsByTime[0].Groups[]
     | {account_id: .Keys[0], cost: (.Metrics.UnblendedCost.Amount | tonumber)}]
    | sort_by(-.cost)
    | .[]
    | "\(.account_id)\t\(.cost)"
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
table_rows+=("Account ID|Account Name|Cost (USD)|% of Total")

while IFS=$'\t' read -r account_id cost; do
    [[ -z "$account_id" ]] && continue

    cost_fmt="$(printf '%.2f' "$cost")"

    # Resolve account name from Organizations data if available
    acct_name="${account_names[$account_id]:-N/A}"

    if (( $(echo "$total_cost > 0" | bc -l) )); then
        pct="$(echo "scale=4; ($cost / $total_cost) * 100" | bc -l)"
        pct_fmt="$(printf '%.1f%%' "$pct")"
    else
        pct_fmt="0.0%"
        pct="0"
    fi

    table_rows+=("${account_id}|${acct_name}|${cost_fmt}|${pct_fmt}")

    json_add_object \
        "account_id=s:${account_id}" \
        "account_name=s:${acct_name}" \
        "cost_usd=${cost_fmt}" \
        "percent_of_total=$(printf '%.1f' "$pct")"
done <<< "$parsed"

json_end_array

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
section "Cost by Linked Account"
printf '%s\n' "${table_rows[@]}" | table_print

mkdir -p "$OUTPUT_DIR"
json_write "$OUTPUT_FILE"
ok "JSON written to ${OUTPUT_FILE}"
