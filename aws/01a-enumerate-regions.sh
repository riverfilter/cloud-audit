#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# 01a-enumerate-regions.sh -- List all enabled AWS regions for the account
#
# Flags:
#   --all    Include opt-in regions (not yet enabled). Default: only enabled.
#
# Output:
#   - One region per line to stdout
#   - JSON array to output/aws-regions.json
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}/.."
OUTPUT_DIR="${PROJECT_ROOT}/output"

source "${SCRIPT_DIR}/../lib/colors.sh"
source "${SCRIPT_DIR}/../lib/prereqs.sh"
source "${SCRIPT_DIR}/../lib/table.sh"
source "${SCRIPT_DIR}/../lib/json.sh"

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
include_all=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)
            include_all=true
            shift
            ;;
        -h|--help)
            echo "Usage: $(basename "$0") [--all]"
            echo ""
            echo "  --all    Include opt-in regions (not-opted-in). Default: enabled only."
            exit 0
            ;;
        *)
            err "Unknown flag: $1"
            err "Usage: $(basename "$0") [--all]"
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
section "AWS Region Enumeration"

if ! require_bin aws; then
    err "AWS CLI is required. Aborting."
    exit 1
fi

if ! require_bin jq; then
    err "jq is required. Aborting."
    exit 1
fi

# Verify authentication.
if ! aws sts get-caller-identity --output json &>/dev/null; then
    err "AWS credentials are not configured or have expired."
    exit 1
fi

# ---------------------------------------------------------------------------
# Enumerate regions
# ---------------------------------------------------------------------------
if [[ "$include_all" == true ]]; then
    info "Listing all regions (including opt-in regions not yet enabled)..."
    filter="--all-regions"
else
    info "Listing enabled regions only (use --all to include opt-in regions)..."
    filter=""
fi

regions_json=""
if ! regions_json="$(aws ec2 describe-regions ${filter} --output json 2>&1)"; then
    err "Failed to list regions."
    err "  Output: ${regions_json}"
    err "  Ensure the caller has ec2:DescribeRegions permission."
    exit 1
fi

# ---------------------------------------------------------------------------
# Build output
# ---------------------------------------------------------------------------
json_start_array

# Table header
table_rows=("Region|Opt-In Status")
region_count=0

while IFS=$'\t' read -r region_name opt_in_status; do
    table_rows+=("${region_name}|${opt_in_status}")

    json_add_object \
        "region=${region_name}" \
        "opt_in_status=${opt_in_status}"

    (( region_count++ )) || true
done < <(echo "$regions_json" | jq -r '.Regions | sort_by(.RegionName) | .[] | [.RegionName, .OptInStatus] | @tsv')

json_end_array

# ---------------------------------------------------------------------------
# Display table
# ---------------------------------------------------------------------------
echo ""
info "Found ${region_count} region(s)"
echo ""
table_print "${table_rows[@]}"

# Also print a compact one-per-line list for easy piping.
echo ""
section "Region List (one per line)"
echo "$regions_json" | jq -r '.Regions | sort_by(.RegionName) | .[].RegionName'

# ---------------------------------------------------------------------------
# Write JSON output
# ---------------------------------------------------------------------------
mkdir -p "${OUTPUT_DIR}"
json_write "${OUTPUT_DIR}/aws-regions.json"

echo ""
ok "JSON written to ${OUTPUT_DIR}/aws-regions.json"
