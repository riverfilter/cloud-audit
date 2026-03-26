#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# 00-check-prereqs.sh -- Verify prerequisites for AWS cost auditing
#
# Checks:
#   1. aws CLI is installed (v2 preferred, v1 accepted with warning)
#   2. jq is installed
#   3. column is available (fallback noted if missing)
#   4. AWS credentials are configured and valid
#   5. Prints authenticated identity summary
#   6. Detects Organizations access (organizations:ListAccounts)
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/colors.sh"
source "${SCRIPT_DIR}/../lib/prereqs.sh"
source "${SCRIPT_DIR}/../lib/table.sh"

# ---------------------------------------------------------------------------
# Track overall result -- we want to report all issues, not bail on the first.
# ---------------------------------------------------------------------------
failures=0

section "Prerequisite Checks"

# --- 1. AWS CLI -----------------------------------------------------------
if require_bin aws; then
    # Determine version and warn if v1.
    aws_version_raw="$(aws --version 2>&1 || true)"
    if [[ "$aws_version_raw" =~ aws-cli/([0-9]+)\. ]]; then
        aws_major="${BASH_REMATCH[1]}"
        if [[ "$aws_major" -ge 2 ]]; then
            ok "AWS CLI v2 detected (${aws_version_raw%% *})"
        else
            warn "AWS CLI v1 detected (${aws_version_raw%% *}). v2 is recommended."
            warn "  Upgrade: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
        fi
    else
        ok "AWS CLI detected (could not parse major version from: ${aws_version_raw})"
    fi
else
    (( failures++ )) || true
fi

# --- 2. jq ----------------------------------------------------------------
if require_bin jq; then
    ok "jq is installed ($(jq --version 2>&1 || echo 'unknown version'))"
else
    (( failures++ )) || true
fi

# --- 3. column -------------------------------------------------------------
if command -v column &>/dev/null; then
    ok "column is available"
else
    warn "'column' is not installed. Table output will fall back to printf alignment."
fi

# --- 4. AWS Credentials ----------------------------------------------------
section "AWS Authentication"

sts_json=""
if sts_json="$(aws sts get-caller-identity --output json 2>&1)"; then
    ok "AWS credentials are valid"
else
    err "AWS credentials check failed."
    err "  Output: ${sts_json}"
    err "  Remediation:"
    err "    - Run 'aws configure' to set up access keys, or"
    err "    - Run 'aws sso login' if using AWS SSO, or"
    err "    - Export AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY."
    (( failures++ )) || true
fi

# --- 5. Identity Summary ---------------------------------------------------
if [[ -n "$sts_json" ]] && echo "$sts_json" | jq -e '.Account' &>/dev/null; then
    account_id="$(echo "$sts_json" | jq -r '.Account')"
    caller_arn="$(echo "$sts_json" | jq -r '.Arn')"
    user_id="$(echo "$sts_json" | jq -r '.UserId')"

    section "Authenticated Identity"
    table_print \
        "Field|Value" \
        "Account ID|${account_id}" \
        "ARN|${caller_arn}" \
        "User/Role ID|${user_id}"
fi

# --- 6. Organizations Access -----------------------------------------------
section "AWS Organizations"

if [[ -z "$sts_json" ]] || ! echo "$sts_json" | jq -e '.Account' &>/dev/null; then
    warn "Skipping Organizations check -- AWS credentials are not valid."
else
    org_output=""
    if org_output="$(aws organizations describe-organization --output json 2>&1)"; then
        org_id="$(echo "$org_output" | jq -r '.Organization.Id')"
        master_account="$(echo "$org_output" | jq -r '.Organization.MasterAccountId')"
        ok "Running within AWS Organization: ${org_id}"
        info "Management account: ${master_account}"

        # Check ListAccounts permission specifically.
        if aws organizations list-accounts --max-items 1 --output json &>/dev/null 2>&1; then
            ok "organizations:ListAccounts permission confirmed"
        else
            warn "organizations:ListAccounts permission denied."
            warn "  Account enumeration will be limited to the current account only."
            warn "  Grant 'organizations:ListAccounts' to enumerate all accounts."
        fi
    else
        if echo "$org_output" | grep -qi "AccessDeniedException\|not authorized"; then
            warn "Cannot access AWS Organizations (access denied)."
            warn "  This account may not be part of an Organization, or"
            warn "  the caller lacks 'organizations:Describe*' permissions."
        elif echo "$org_output" | grep -qi "AWSOrganizationsNotInUseException"; then
            info "This account is not part of an AWS Organization."
            info "  Account enumeration will report the current account only."
        else
            warn "Could not determine Organizations status."
            warn "  Output: ${org_output}"
        fi
    fi
fi

# --- Final Summary ---------------------------------------------------------
section "Summary"

if [[ "$failures" -gt 0 ]]; then
    err "${failures} prerequisite check(s) failed. Resolve the issues above before continuing."
    exit 1
else
    ok "All prerequisite checks passed."
fi
