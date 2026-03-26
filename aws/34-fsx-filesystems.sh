#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# 34-fsx-filesystems.sh -- AWS FSx File System Inventory across all regions
#
# Enumerates all FSx file systems (Lustre, Windows File Server, NetApp ONTAP,
# OpenZFS) with storage capacity, throughput, status, and monthly cost
# estimates.
#
# Columns: Region | File System ID | Type | Storage Capacity (GB) |
#          Throughput | Status | Monthly Est. Cost
# Output : table + output/aws-fsx.json
#
# Required IAM permissions: fsx:DescribeFileSystems, ec2:DescribeRegions
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/colors.sh"
source "${SCRIPT_DIR}/../lib/prereqs.sh"
source "${SCRIPT_DIR}/../lib/table.sh"
source "${SCRIPT_DIR}/../lib/json.sh"

OUTPUT_DIR="${SCRIPT_DIR}/../output"
OUTPUT_FILE="${OUTPUT_DIR}/aws-fsx.json"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
section "Prerequisites"
require_bin aws  || exit 1
require_bin jq   || exit 1
require_bin bc   || exit 1
require_auth_aws || exit 1

# ---------------------------------------------------------------------------
# FSx pricing lookup (approximate $/GB-month, us-east-1)
# ---------------------------------------------------------------------------
declare -A FSX_PRICE_PER_GB=(
    [LUSTRE]=0.14
    [WINDOWS]=0.13
    [ONTAP]=0.12
    [OPENZFS]=0.09
)

estimate_fsx_cost() {
    local fs_type="$1"
    local capacity_gb="$2"

    local price="${FSX_PRICE_PER_GB[$fs_type]:-}"
    if [[ -z "$price" ]]; then
        echo "N/A"
        return
    fi
    printf '%.2f' "$(echo "${price} * ${capacity_gb}" | bc -l)"
}

# ---------------------------------------------------------------------------
# Discover enabled regions
# ---------------------------------------------------------------------------
section "AWS FSx File System Inventory"
info "Discovering enabled regions..."

regions_raw=""
if ! regions_raw="$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text 2>&1)"; then
    err "Failed to list AWS regions: ${regions_raw}"
    exit 1
fi
read -ra REGIONS <<< "$regions_raw"
info "Found ${#REGIONS[@]} enabled regions."

# ---------------------------------------------------------------------------
# Iterate regions and collect FSx file systems
# ---------------------------------------------------------------------------
json_start_array

table_rows=()
table_rows+=("Region|File System ID|Type|Storage Capacity (GB)|Throughput|Status|Monthly Est. Cost")

total_filesystems=0
total_cost=0

for region in "${REGIONS[@]}"; do
    info "Scanning region: ${region}..."

    fsx_output=""
    if ! fsx_output="$(aws fsx describe-file-systems \
        --region "$region" \
        --output json 2>&1)"; then
        if echo "$fsx_output" | grep -qi "UnauthorizedAccess\|AccessDenied\|AuthFailure"; then
            warn "Permission denied in region ${region} -- skipping."
            continue
        fi
        # FSx may not be available in all regions
        if echo "$fsx_output" | grep -qi "not available\|Could not connect\|InvalidRegion\|UnknownEndpoint"; then
            continue
        fi
        warn "Error querying FSx in ${region}: ${fsx_output} -- skipping."
        continue
    fi

    fs_count="$(echo "$fsx_output" | jq '.FileSystems | length')"
    if [[ "$fs_count" -eq 0 || "$fsx_output" == "null" ]]; then
        continue
    fi

    while IFS=$'\t' read -r fs_id fs_type storage_capacity throughput lifecycle; do
        [[ -z "$fs_id" ]] && continue
        total_filesystems=$(( total_filesystems + 1 ))

        # Clean up values
        [[ "$fs_type" == "null" || -z "$fs_type" ]] && fs_type="-"
        [[ "$storage_capacity" == "null" || -z "$storage_capacity" ]] && storage_capacity="0"
        [[ "$throughput" == "null" || -z "$throughput" ]] && throughput="-"
        [[ "$lifecycle" == "null" || -z "$lifecycle" ]] && lifecycle="-"

        # Map FileSystemType to pricing key
        # API returns: WINDOWS, LUSTRE, ONTAP, OPENZFS
        price_key="$fs_type"

        # Friendly type name for display
        case "$fs_type" in
            LUSTRE)  type_display="Lustre" ;;
            WINDOWS) type_display="Windows" ;;
            ONTAP)   type_display="NetApp ONTAP" ;;
            OPENZFS) type_display="OpenZFS" ;;
            *)       type_display="$fs_type" ;;
        esac

        # Cost estimate
        monthly_cost="$(estimate_fsx_cost "$price_key" "$storage_capacity")"
        if [[ "$monthly_cost" != "N/A" ]]; then
            total_cost="$(echo "${total_cost} + ${monthly_cost}" | bc -l)"
            cost_display="\$${monthly_cost}"
        else
            cost_display="N/A"
        fi

        # Throughput display
        throughput_display="$throughput"
        if [[ "$throughput" != "-" ]]; then
            throughput_display="${throughput} MB/s"
        fi

        table_rows+=("${region}|${fs_id}|${type_display}|${storage_capacity}|${throughput_display}|${lifecycle}|${cost_display}")

        json_add_object \
            "region=s:${region}" \
            "file_system_id=s:${fs_id}" \
            "type=s:${fs_type}" \
            "type_display=s:${type_display}" \
            "storage_capacity_gb=${storage_capacity}" \
            "throughput_mbps=s:${throughput}" \
            "status=s:${lifecycle}" \
            "monthly_est_cost=s:${monthly_cost}"

    done < <(echo "$fsx_output" | jq -r '
        .FileSystems[] |
        [
            .FileSystemId,
            .FileSystemType,
            .StorageCapacity,
            (
                # Throughput is in different locations depending on type
                if .FileSystemType == "LUSTRE" then
                    (.LustreConfiguration.PerUnitStorageThroughput // "null" | tostring)
                elif .FileSystemType == "WINDOWS" then
                    (.WindowsConfiguration.ThroughputCapacity // "null" | tostring)
                elif .FileSystemType == "ONTAP" then
                    (.OntapConfiguration.ThroughputCapacity // "null" | tostring)
                elif .FileSystemType == "OPENZFS" then
                    (.OpenZFSConfiguration.ThroughputCapacity // "null" | tostring)
                else
                    "null"
                end
            ),
            .Lifecycle
        ] | @tsv
    ')
done

json_end_array

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
section "FSx File Systems Summary"

if [[ "$total_filesystems" -eq 0 ]]; then
    info "No FSx file systems found across any region."
else
    printf '%s\n' "${table_rows[@]}" | table_print
    echo ""
    info "Total FSx file systems: ${total_filesystems}"
    total_cost_fmt="$(printf '%.2f' "$total_cost")"
    info "Total estimated monthly cost: \$${total_cost_fmt}"
fi

mkdir -p "$OUTPUT_DIR"
json_write "$OUTPUT_FILE"
ok "JSON written to ${OUTPUT_FILE}"
