#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# 24-lightsail-instances.sh -- AWS Lightsail Instance & Database Inventory
#
# Enumerates all Lightsail instances and managed databases across every
# enabled region.  Lightsail has a fixed monthly price per bundle, so
# cost is reported directly from the API response.
#
# Columns: Region | Name | Type | Blueprint | Bundle (size) | State |
#          Monthly Price
# Output : table + output/aws-lightsail.json
#
# Required IAM permissions: lightsail:GetInstances, lightsail:GetRelationalDatabases,
#   lightsail:GetRegions
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/colors.sh"
source "${SCRIPT_DIR}/../lib/prereqs.sh"
source "${SCRIPT_DIR}/../lib/table.sh"
source "${SCRIPT_DIR}/../lib/json.sh"

OUTPUT_DIR="${SCRIPT_DIR}/../output"
OUTPUT_FILE="${OUTPUT_DIR}/aws-lightsail.json"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
section "Prerequisites"
require_bin aws  || exit 1
require_bin jq   || exit 1
require_auth_aws || exit 1

# ---------------------------------------------------------------------------
# Discover Lightsail regions
# Lightsail has its own region list (subset of EC2 regions).
# ---------------------------------------------------------------------------
section "AWS Lightsail Inventory"
info "Discovering Lightsail regions..."

regions_output=""
if ! regions_output="$(aws lightsail get-regions --output json 2>&1)"; then
    # Fall back to EC2 region list if get-regions fails
    warn "Could not query Lightsail regions, falling back to EC2 region list."
    if ! regions_output="$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text 2>&1)"; then
        err "Failed to list regions: ${regions_output}"
        exit 1
    fi
    read -ra REGIONS <<< "$regions_output"
else
    readarray -t REGIONS < <(echo "$regions_output" | jq -r '.regions[].name')
fi

info "Found ${#REGIONS[@]} regions to scan."

# ---------------------------------------------------------------------------
# Iterate regions -- Instances
# ---------------------------------------------------------------------------
json_start_array

table_rows=()
table_rows+=("Region|Name|Type|Blueprint|Bundle (size)|State|Monthly Price")

total_instances=0
total_databases=0
total_monthly=0

for region in "${REGIONS[@]}"; do
    info "Scanning region: ${region}..."

    # --- Lightsail Instances ---
    instances_output=""
    if ! instances_output="$(aws lightsail get-instances --region "$region" --output json 2>&1)"; then
        if echo "$instances_output" | grep -qi "AccessDenied\|AuthFailure\|UnauthorizedAccess"; then
            warn "Permission denied in region ${region} -- skipping."
            continue
        fi
        if echo "$instances_output" | grep -qi "InvalidRegion\|not available\|Could not connect"; then
            continue
        fi
        warn "Error querying Lightsail instances in ${region} -- skipping."
        continue
    fi

    instance_count="$(echo "$instances_output" | jq '.instances | length')"
    if [[ "$instance_count" -gt 0 ]]; then
        # Fetch bundle pricing for this region to map bundle IDs to prices
        declare -A bundle_prices=()
        bundles_output=""
        if bundles_output="$(aws lightsail get-bundles --region "$region" --output json 2>/dev/null)"; then
            while IFS=$'\t' read -r bid bprice; do
                [[ -n "$bid" ]] && bundle_prices["$bid"]="$bprice"
            done < <(echo "$bundles_output" | jq -r '.bundles[] | [.bundleId, .price] | @tsv')
        fi

        while IFS=$'\t' read -r name blueprint_id bundle_id state; do
            [[ -z "$name" ]] && continue
            total_instances=$(( total_instances + 1 ))

            [[ "$state" == "null" || -z "$state" ]] && state="-"

            # Look up monthly price from bundle
            monthly_price="${bundle_prices[$bundle_id]:-}"
            if [[ -n "$monthly_price" && "$monthly_price" != "null" ]]; then
                price_fmt="$(printf '%.2f' "$monthly_price")"
                total_monthly="$(echo "${total_monthly} + ${monthly_price}" | bc -l)"
                price_display="\$${price_fmt}"
            else
                price_fmt="-"
                price_display="-"
            fi

            table_rows+=("${region}|${name}|Instance|${blueprint_id}|${bundle_id}|${state}|${price_display}")

            json_add_object \
                "region=s:${region}" \
                "name=s:${name}" \
                "type=s:Instance" \
                "blueprint=s:${blueprint_id}" \
                "bundle=s:${bundle_id}" \
                "state=s:${state}" \
                "monthly_price=s:${price_fmt}"

        done < <(echo "$instances_output" | jq -r '
            .instances[] |
            [
                .name,
                .blueprintId,
                .bundleId,
                .state.name
            ] | @tsv
        ')

        unset bundle_prices
    fi

    # --- Lightsail Relational Databases ---
    db_output=""
    if ! db_output="$(aws lightsail get-relational-databases --region "$region" --output json 2>&1)"; then
        if echo "$db_output" | grep -qi "AccessDenied\|not available\|InvalidRegion"; then
            continue
        fi
        warn "Error querying Lightsail databases in ${region} -- skipping."
        continue
    fi

    db_count="$(echo "$db_output" | jq '.relationalDatabases | length' 2>/dev/null)" || db_count=0
    if [[ "$db_count" -gt 0 ]]; then
        # Fetch relational database bundle pricing
        declare -A db_bundle_prices=()
        db_bundles_output=""
        if db_bundles_output="$(aws lightsail get-relational-database-bundles --region "$region" --output json 2>/dev/null)"; then
            while IFS=$'\t' read -r bid bprice; do
                [[ -n "$bid" ]] && db_bundle_prices["$bid"]="$bprice"
            done < <(echo "$db_bundles_output" | jq -r '.bundles[] | [.bundleId, .price] | @tsv')
        fi

        while IFS=$'\t' read -r name engine bundle_id state; do
            [[ -z "$name" ]] && continue
            total_databases=$(( total_databases + 1 ))

            [[ "$state" == "null" || -z "$state" ]] && state="-"

            # Look up monthly price from relational database bundle
            monthly_price="${db_bundle_prices[$bundle_id]:-}"
            if [[ -n "$monthly_price" && "$monthly_price" != "null" ]]; then
                price_fmt="$(printf '%.2f' "$monthly_price")"
                total_monthly="$(echo "${total_monthly} + ${monthly_price}" | bc -l)"
                price_display="\$${price_fmt}"
            else
                price_fmt="-"
                price_display="-"
            fi

            table_rows+=("${region}|${name}|Database|${engine}|${bundle_id}|${state}|${price_display}")

            json_add_object \
                "region=s:${region}" \
                "name=s:${name}" \
                "type=s:Database" \
                "blueprint=s:${engine}" \
                "bundle=s:${bundle_id}" \
                "state=s:${state}" \
                "monthly_price=s:${price_fmt}"

        done < <(echo "$db_output" | jq -r '
            .relationalDatabases[] |
            [
                .name,
                .engine,
                .relationalDatabaseBundleId,
                .state
            ] | @tsv
        ')

        unset db_bundle_prices
    fi
done

json_end_array

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
section "Lightsail Summary"

if [[ "$total_instances" -eq 0 && "$total_databases" -eq 0 ]]; then
    info "No Lightsail instances or databases found across any region."
else
    printf '%s\n' "${table_rows[@]}" | table_print
    echo ""
    info "Total Lightsail instances: ${total_instances}"
    info "Total Lightsail databases: ${total_databases}"
fi

mkdir -p "$OUTPUT_DIR"
json_write "$OUTPUT_FILE"
ok "JSON written to ${OUTPUT_FILE}"
