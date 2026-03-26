#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# 01-enumerate-accounts.sh -- Enumerate AWS accounts in the Organization
#
# If the caller has Organizations access, lists all accounts with:
#   Account ID, Account Name, Email, Status, Joined Date
#
# If not in an Organization (or access denied), reports the single account
# from sts get-caller-identity.
#
# Output:
#   - Table to stdout
#   - JSON to output/aws-accounts.json
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}/.."
OUTPUT_DIR="${PROJECT_ROOT}/output"

source "${SCRIPT_DIR}/../lib/colors.sh"
source "${SCRIPT_DIR}/../lib/prereqs.sh"
source "${SCRIPT_DIR}/../lib/table.sh"
source "${SCRIPT_DIR}/../lib/json.sh"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
section "AWS Account Enumeration"

if ! require_bin aws; then
    err "AWS CLI is required. Aborting."
    exit 1
fi

if ! require_bin jq; then
    err "jq is required. Aborting."
    exit 1
fi

# Verify authentication.
sts_json=""
if ! sts_json="$(aws sts get-caller-identity --output json 2>&1)"; then
    err "AWS credentials are not configured or have expired."
    err "  Output: ${sts_json}"
    exit 1
fi

account_id="$(echo "$sts_json" | jq -r '.Account')"
caller_arn="$(echo "$sts_json" | jq -r '.Arn')"
ok "Authenticated as ${caller_arn}"

# ---------------------------------------------------------------------------
# Attempt Organizations enumeration
# ---------------------------------------------------------------------------
use_org=false
org_accounts_json=""

if org_accounts_json="$(aws organizations list-accounts --output json 2>&1)"; then
    # Validate it's actual JSON with accounts
    if echo "$org_accounts_json" | jq -e '.Accounts' &>/dev/null; then
        use_org=true
    fi
fi

# ---------------------------------------------------------------------------
# Build output
# ---------------------------------------------------------------------------
json_start_array

if [[ "$use_org" == true ]]; then
    account_count="$(echo "$org_accounts_json" | jq '.Accounts | length')"
    info "Organization detected -- found ${account_count} account(s)"

    # Build table rows. Header first.
    table_rows=("Account ID|Account Name|Email|Status|Joined Date")

    while IFS=$'\t' read -r acct_id acct_name email status joined_ts; do
        # Format the joined timestamp to a human-readable date.
        # AWS returns ISO 8601 timestamps; extract the date portion.
        joined_date="${joined_ts%%T*}"

        table_rows+=("${acct_id}|${acct_name}|${email}|${status}|${joined_date}")

        json_add_object \
            "account_id=s:${acct_id}" \
            "account_name=${acct_name}" \
            "email=${email}" \
            "status=${status}" \
            "joined_date=${joined_date}"
    done < <(echo "$org_accounts_json" | jq -r '.Accounts[] | [.Id, .Name, .Email, .Status, .JoinedTimestamp] | @tsv')

    echo ""
    table_print "${table_rows[@]}"
else
    if echo "${org_accounts_json}" | grep -qi "AWSOrganizationsNotInUseException"; then
        info "Account is not part of an AWS Organization."
    else
        warn "Could not enumerate Organization accounts (access denied or other error)."
        warn "  Falling back to current account only."
    fi

    info "Reporting single account from caller identity."

    # Attempt to get the account alias for a friendlier name.
    account_name=""
    if aliases_json="$(aws iam list-account-aliases --output json 2>&1)"; then
        account_name="$(echo "$aliases_json" | jq -r '.AccountAliases[0] // empty' 2>/dev/null || true)"
    fi
    [[ -z "$account_name" ]] && account_name="(current account)"

    echo ""
    table_print \
        "Account ID|Account Name|Email|Status|Joined Date" \
        "${account_id}|${account_name}|N/A|ACTIVE|N/A"

    json_add_object \
        "account_id=s:${account_id}" \
        "account_name=${account_name}" \
        "email=N/A" \
        "status=ACTIVE" \
        "joined_date=N/A"
fi

json_end_array

# ---------------------------------------------------------------------------
# Write JSON output
# ---------------------------------------------------------------------------
mkdir -p "${OUTPUT_DIR}"
json_write "${OUTPUT_DIR}/aws-accounts.json"

echo ""
ok "JSON written to ${OUTPUT_DIR}/aws-accounts.json"
