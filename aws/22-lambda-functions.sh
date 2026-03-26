#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# 22-lambda-functions.sh -- AWS Lambda Function Inventory
#
# Enumerates all Lambda functions across every enabled region.  Uses
# CloudWatch GetMetricStatistics to detect functions not invoked in the
# last 90 days (flagged as potentially orphaned).
#
# Columns: Region | Function Name | Runtime | Memory (MB) | Timeout (s) |
#          Last Invoked | Code Size
# Output : table + output/aws-lambda-functions.json
#
# Required IAM permissions: lambda:ListFunctions, cloudwatch:GetMetricStatistics,
#   ec2:DescribeRegions
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/colors.sh"
source "${SCRIPT_DIR}/../lib/prereqs.sh"
source "${SCRIPT_DIR}/../lib/table.sh"
source "${SCRIPT_DIR}/../lib/json.sh"

OUTPUT_DIR="${SCRIPT_DIR}/../output"
OUTPUT_FILE="${OUTPUT_DIR}/aws-lambda-functions.json"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
section "Prerequisites"
require_bin aws  || exit 1
require_bin jq   || exit 1
require_auth_aws || exit 1

# ---------------------------------------------------------------------------
# Helper: format bytes to human-readable
# ---------------------------------------------------------------------------
format_bytes() {
    local bytes="$1"
    if [[ "$bytes" -ge 1048576 ]]; then
        printf '%.1f MB' "$(echo "scale=1; ${bytes} / 1048576" | bc -l)"
    elif [[ "$bytes" -ge 1024 ]]; then
        printf '%.1f KB' "$(echo "scale=1; ${bytes} / 1024" | bc -l)"
    else
        echo "${bytes} B"
    fi
}

# ---------------------------------------------------------------------------
# Discover enabled regions
# ---------------------------------------------------------------------------
section "AWS Lambda Function Inventory"
info "Discovering enabled regions..."

regions_raw=""
if ! regions_raw="$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text 2>&1)"; then
    err "Failed to list AWS regions: ${regions_raw}"
    exit 1
fi
read -ra REGIONS <<< "$regions_raw"
info "Found ${#REGIONS[@]} enabled regions."

# Dates for orphan detection (90 days)
now_epoch="$(date +%s)"
ninety_days_ago_epoch=$(( now_epoch - 90 * 86400 ))
ninety_days_ago_iso="$(date -u -d "@${ninety_days_ago_epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "${ninety_days_ago_epoch}" +%Y-%m-%dT%H:%M:%SZ)"
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---------------------------------------------------------------------------
# Iterate regions
# ---------------------------------------------------------------------------
json_start_array

table_rows=()
table_rows+=("Region|Function Name|Runtime|Memory (MB)|Timeout (s)|Last Invoked|Code Size|Orphan?")

total_functions=0
orphan_count=0

for region in "${REGIONS[@]}"; do
    info "Scanning region: ${region}..."

    # List all functions (handle pagination)
    all_functions="[]"
    next_marker=""
    while true; do
        list_args=(--region "$region" --output json --max-items 50)
        if [[ -n "$next_marker" ]]; then
            list_args+=(--starting-token "$next_marker")
        fi

        lambda_output=""
        if ! lambda_output="$(aws lambda list-functions "${list_args[@]}" 2>&1)"; then
            if echo "$lambda_output" | grep -qi "AccessDenied\|AuthFailure\|UnauthorizedAccess"; then
                warn "Permission denied in region ${region} -- skipping."
            else
                warn "Error listing Lambda functions in ${region}: ${lambda_output} -- skipping."
            fi
            break
        fi

        page_functions="$(echo "$lambda_output" | jq '.Functions // []')"
        all_functions="$(echo "${all_functions} ${page_functions}" | jq -s '.[0] + .[1]')"

        next_marker="$(echo "$lambda_output" | jq -r '.NextToken // empty')"
        [[ -z "$next_marker" ]] && break
    done

    func_count="$(echo "$all_functions" | jq 'length')"
    [[ "$func_count" -eq 0 ]] && continue

    while IFS=$'\t' read -r func_name runtime memory_size timeout code_size; do
        [[ -z "$func_name" ]] && continue
        total_functions=$(( total_functions + 1 ))

        [[ "$runtime" == "null" || -z "$runtime" ]] && runtime="-"
        [[ "$code_size" == "null" || -z "$code_size" ]] && code_size="0"

        code_size_fmt="$(format_bytes "$code_size")"

        # Check CloudWatch for last invocation
        last_invoked="-"
        is_orphan="false"
        cw_output=""
        if cw_output="$(aws cloudwatch get-metric-statistics \
            --region "$region" \
            --namespace AWS/Lambda \
            --metric-name Invocations \
            --dimensions "Name=FunctionName,Value=${func_name}" \
            --start-time "$ninety_days_ago_iso" \
            --end-time "$now_iso" \
            --period 86400 \
            --statistics Sum \
            --output json 2>/dev/null)"; then

            datapoints_count="$(echo "$cw_output" | jq '.Datapoints | length')"
            if [[ "$datapoints_count" -gt 0 ]]; then
                # Find the most recent datapoint with Sum > 0
                last_ts="$(echo "$cw_output" | jq -r '
                    [.Datapoints[] | select(.Sum > 0)] | sort_by(.Timestamp) | last | .Timestamp // empty
                ')"
                if [[ -n "$last_ts" ]]; then
                    last_invoked="${last_ts%%T*}"
                else
                    last_invoked=">90 days ago"
                    is_orphan="true"
                    orphan_count=$(( orphan_count + 1 ))
                fi
            else
                last_invoked=">90 days ago"
                is_orphan="true"
                orphan_count=$(( orphan_count + 1 ))
            fi
        fi

        orphan_marker=""
        if [[ "$is_orphan" == "true" ]]; then
            orphan_marker="[ORPHAN?]"
        fi

        table_rows+=("${region}|${func_name}|${runtime}|${memory_size}|${timeout}|${last_invoked}|${code_size_fmt}|${orphan_marker}")

        json_add_object \
            "region=s:${region}" \
            "function_name=s:${func_name}" \
            "runtime=s:${runtime}" \
            "memory_mb=${memory_size}" \
            "timeout_seconds=${timeout}" \
            "last_invoked=s:${last_invoked}" \
            "code_size_bytes=${code_size}" \
            "is_potential_orphan=${is_orphan}"

    done < <(echo "$all_functions" | jq -r '
        .[] |
        [
            .FunctionName,
            .Runtime,
            .MemorySize,
            .Timeout,
            .CodeSize
        ] | @tsv
    ')
done

json_end_array

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
section "Lambda Functions Summary"

if [[ "$total_functions" -eq 0 ]]; then
    info "No Lambda functions found across any region."
else
    printf '%s\n' "${table_rows[@]}" | table_print
    echo ""
    info "Total Lambda functions: ${total_functions}"
    if [[ "$orphan_count" -gt 0 ]]; then
        warn "Potentially orphaned functions (no invocations in 90+ days): ${orphan_count}"
    fi
fi

mkdir -p "$OUTPUT_DIR"
json_write "$OUTPUT_FILE"
ok "JSON written to ${OUTPUT_FILE}"
