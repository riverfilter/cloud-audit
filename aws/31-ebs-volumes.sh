#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# 31-ebs-volumes.sh -- AWS EBS Volume Inventory across all regions
#
# Enumerates all EBS volumes with type, state, attachment info, and monthly
# cost estimates.  Flags volumes in "available" state (not attached to any
# instance) as orphaned.
#
# Columns: Region | Volume ID | Name | Size (GB) | Type | State |
#          Attached To | IOPS | Throughput | Encrypted | Monthly Est. Cost
# Output : table + output/aws-ebs-volumes.json
#
# Required IAM permissions: ec2:DescribeVolumes, ec2:DescribeRegions
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/colors.sh"
source "${SCRIPT_DIR}/../lib/prereqs.sh"
source "${SCRIPT_DIR}/../lib/table.sh"
source "${SCRIPT_DIR}/../lib/json.sh"

OUTPUT_DIR="${SCRIPT_DIR}/../output"
OUTPUT_FILE="${OUTPUT_DIR}/aws-ebs-volumes.json"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
section "Prerequisites"
require_bin aws  || exit 1
require_bin jq   || exit 1
require_bin bc   || exit 1
require_auth_aws || exit 1

# ---------------------------------------------------------------------------
# EBS pricing lookup ($/GB-month, us-east-1 approximate)
# For io1/io2 there is an additional per-provisioned-IOPS charge.
# ---------------------------------------------------------------------------
declare -A PRICE_PER_GB=(
    [gp2]=0.10
    [gp3]=0.08
    [io1]=0.125
    [io2]=0.125
    [st1]=0.045
    [sc1]=0.015
    [standard]=0.05
)

# io1/io2 also charge per provisioned IOPS
PRICE_PER_IOPS_IO=0.065

estimate_ebs_cost() {
    local vol_type="$1"
    local size_gb="$2"
    local iops="$3"

    local gb_price="${PRICE_PER_GB[$vol_type]:-}"
    if [[ -z "$gb_price" ]]; then
        echo "N/A"
        return
    fi

    local cost
    cost="$(echo "${gb_price} * ${size_gb}" | bc -l)"

    # Add IOPS cost for io1/io2
    if [[ "$vol_type" == "io1" || "$vol_type" == "io2" ]]; then
        if [[ -n "$iops" && "$iops" != "null" && "$iops" != "0" ]]; then
            local iops_cost
            iops_cost="$(echo "${PRICE_PER_IOPS_IO} * ${iops}" | bc -l)"
            cost="$(echo "${cost} + ${iops_cost}" | bc -l)"
        fi
    fi

    printf '%.2f' "$cost"
}

# ---------------------------------------------------------------------------
# Discover enabled regions
# ---------------------------------------------------------------------------
section "AWS EBS Volume Inventory"
info "Discovering enabled regions..."

regions_raw=""
if ! regions_raw="$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text 2>&1)"; then
    err "Failed to list AWS regions: ${regions_raw}"
    exit 1
fi
read -ra REGIONS <<< "$regions_raw"
info "Found ${#REGIONS[@]} enabled regions."

# ---------------------------------------------------------------------------
# Iterate regions and collect volumes
# ---------------------------------------------------------------------------
json_start_array

table_rows=()
table_rows+=("Region|Volume ID|Name|Size (GB)|Type|State|Attached To|IOPS|Throughput|Encrypted|Monthly Est. Cost")

total_volumes=0
orphan_count=0
total_cost=0

for region in "${REGIONS[@]}"; do
    info "Scanning region: ${region}..."

    vol_output=""
    if ! vol_output="$(aws ec2 describe-volumes \
        --region "$region" \
        --output json 2>&1)"; then
        if echo "$vol_output" | grep -qi "UnauthorizedAccess\|AccessDenied\|AuthFailure"; then
            warn "Permission denied in region ${region} -- skipping."
            continue
        fi
        warn "Error querying EBS volumes in ${region}: ${vol_output} -- skipping."
        continue
    fi

    vol_count="$(echo "$vol_output" | jq '.Volumes | length')"
    if [[ "$vol_count" -eq 0 || "$vol_output" == "null" ]]; then
        continue
    fi

    while IFS=$'\t' read -r volume_id name size_gb vol_type state attached_instance iops throughput encrypted; do
        [[ -z "$volume_id" ]] && continue
        total_volumes=$(( total_volumes + 1 ))

        # Clean up null/empty values
        [[ "$name" == "null" || -z "$name" ]] && name="-"
        [[ "$attached_instance" == "null" || -z "$attached_instance" ]] && attached_instance="-"
        [[ "$iops" == "null" || -z "$iops" ]] && iops="0"
        [[ "$throughput" == "null" || -z "$throughput" ]] && throughput="-"
        [[ "$encrypted" == "null" || -z "$encrypted" ]] && encrypted="false"

        # Encrypted display
        encrypted_display="No"
        [[ "$encrypted" == "true" ]] && encrypted_display="Yes"

        # Orphan detection: volume in 'available' state (not attached)
        is_orphan="false"
        state_display="$state"
        if [[ "$state" == "available" ]]; then
            is_orphan="true"
            orphan_count=$(( orphan_count + 1 ))
            state_display="available (ORPHANED)"
        fi

        # Cost estimate
        monthly_cost="$(estimate_ebs_cost "$vol_type" "$size_gb" "$iops")"
        if [[ "$monthly_cost" != "N/A" ]]; then
            total_cost="$(echo "${total_cost} + ${monthly_cost}" | bc -l)"
            cost_display="\$${monthly_cost}"
        else
            cost_display="N/A"
        fi

        # Throughput display: append MB/s if numeric
        throughput_display="$throughput"
        if [[ "$throughput" != "-" && "$throughput" != "null" ]]; then
            throughput_display="${throughput} MB/s"
        fi

        table_rows+=("${region}|${volume_id}|${name}|${size_gb}|${vol_type}|${state_display}|${attached_instance}|${iops}|${throughput_display}|${encrypted_display}|${cost_display}")

        json_add_object \
            "region=s:${region}" \
            "volume_id=s:${volume_id}" \
            "name=s:${name}" \
            "size_gb=${size_gb}" \
            "type=s:${vol_type}" \
            "state=s:${state}" \
            "attached_to=s:${attached_instance}" \
            "iops=${iops}" \
            "throughput=s:${throughput}" \
            "encrypted=${encrypted}" \
            "monthly_est_cost=s:${monthly_cost}" \
            "is_orphan=${is_orphan}"

    done < <(echo "$vol_output" | jq -r '
        .Volumes[] |
        [
            .VolumeId,
            ((.Tags // []) | map(select(.Key == "Name")) | .[0].Value // "null"),
            .Size,
            .VolumeType,
            .State,
            (.Attachments[0].InstanceId // "null"),
            (.Iops // 0),
            (.Throughput // "null"),
            .Encrypted
        ] | @tsv
    ')
done

json_end_array

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
section "EBS Volumes Summary"

if [[ "$total_volumes" -eq 0 ]]; then
    info "No EBS volumes found across any region."
else
    printf '%s\n' "${table_rows[@]}" | table_print
    echo ""
    info "Total volumes: ${total_volumes}"
    total_cost_fmt="$(printf '%.2f' "$total_cost")"
    info "Total estimated monthly cost: \$${total_cost_fmt}"
    if [[ "$orphan_count" -gt 0 ]]; then
        warn "Orphaned volumes (available, not attached): ${orphan_count}"
    fi
fi

mkdir -p "$OUTPUT_DIR"
json_write "$OUTPUT_FILE"
ok "JSON written to ${OUTPUT_FILE}"
