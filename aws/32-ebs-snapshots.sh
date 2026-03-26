#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# 32-ebs-snapshots.sh -- AWS EBS Snapshot Inventory across all regions
#
# Enumerates all EBS snapshots owned by the current account.  Flags snapshots
# older than 180 days and snapshots whose source volume no longer exists.
#
# Columns: Region | Snapshot ID | Volume ID | Size (GB) | Start Time |
#          Description | Age (days) | Monthly Est. Cost
# Output : table + output/aws-ebs-snapshots.json
#
# Required IAM permissions: ec2:DescribeSnapshots, ec2:DescribeVolumes,
#   ec2:DescribeRegions
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/colors.sh"
source "${SCRIPT_DIR}/../lib/prereqs.sh"
source "${SCRIPT_DIR}/../lib/table.sh"
source "${SCRIPT_DIR}/../lib/json.sh"

OUTPUT_DIR="${SCRIPT_DIR}/../output"
OUTPUT_FILE="${OUTPUT_DIR}/aws-ebs-snapshots.json"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
section "Prerequisites"
require_bin aws  || exit 1
require_bin jq   || exit 1
require_bin bc   || exit 1
require_auth_aws || exit 1

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SNAPSHOT_COST_PER_GB=0.05   # $/GB-month
OLD_THRESHOLD_DAYS=180
NOW_EPOCH="$(date -u +%s)"

# ---------------------------------------------------------------------------
# Discover enabled regions
# ---------------------------------------------------------------------------
section "AWS EBS Snapshot Inventory"
info "Discovering enabled regions..."

regions_raw=""
if ! regions_raw="$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text 2>&1)"; then
    err "Failed to list AWS regions: ${regions_raw}"
    exit 1
fi
read -ra REGIONS <<< "$regions_raw"
info "Found ${#REGIONS[@]} enabled regions."

# ---------------------------------------------------------------------------
# Iterate regions and collect snapshots
# ---------------------------------------------------------------------------
json_start_array

table_rows=()
table_rows+=("Region|Snapshot ID|Volume ID|Size (GB)|Start Time|Description|Age (days)|Monthly Est. Cost")

total_snapshots=0
old_count=0
orphan_vol_count=0
total_cost=0

for region in "${REGIONS[@]}"; do
    info "Scanning region: ${region}..."

    # --- Collect all existing volume IDs in this region for orphan check ---
    existing_volumes=""
    if vol_ids_output="$(aws ec2 describe-volumes \
        --region "$region" \
        --query 'Volumes[].VolumeId' \
        --output json 2>/dev/null)"; then
        existing_volumes="$(echo "$vol_ids_output" | jq -r '.[]' 2>/dev/null)" || existing_volumes=""
    fi
    # Store in an associative array for O(1) lookup
    declare -A vol_exists_map=()
    if [[ -n "$existing_volumes" ]]; then
        while IFS= read -r vid; do
            [[ -n "$vid" ]] && vol_exists_map["$vid"]=1
        done <<< "$existing_volumes"
    fi

    # --- Enumerate snapshots owned by this account ---
    snap_output=""
    if ! snap_output="$(aws ec2 describe-snapshots \
        --region "$region" \
        --owner-ids self \
        --output json 2>&1)"; then
        if echo "$snap_output" | grep -qi "UnauthorizedAccess\|AccessDenied\|AuthFailure"; then
            warn "Permission denied in region ${region} -- skipping."
            unset vol_exists_map
            continue
        fi
        warn "Error querying snapshots in ${region}: ${snap_output} -- skipping."
        unset vol_exists_map
        continue
    fi

    snap_count="$(echo "$snap_output" | jq '.Snapshots | length')"
    if [[ "$snap_count" -eq 0 || "$snap_output" == "null" ]]; then
        unset vol_exists_map
        continue
    fi

    while IFS=$'\t' read -r snapshot_id volume_id size_gb start_time description; do
        [[ -z "$snapshot_id" ]] && continue
        total_snapshots=$(( total_snapshots + 1 ))

        # Clean up values
        [[ "$volume_id" == "null" || -z "$volume_id" ]] && volume_id="-"
        [[ "$description" == "null" || -z "$description" ]] && description="-"
        [[ "$start_time" == "null" || -z "$start_time" ]] && start_time="-"

        # Calculate age in days
        age_days="-"
        is_old="false"
        if [[ "$start_time" != "-" ]]; then
            snap_epoch="$(date -u -d "$start_time" +%s 2>/dev/null)" || snap_epoch=""
            if [[ -n "$snap_epoch" ]]; then
                age_days=$(( (NOW_EPOCH - snap_epoch) / 86400 ))
                if [[ "$age_days" -ge "$OLD_THRESHOLD_DAYS" ]]; then
                    is_old="true"
                    old_count=$(( old_count + 1 ))
                fi
            fi
        fi

        # Truncate start_time to date
        start_date="${start_time%%T*}"

        # Check if source volume still exists
        vol_orphaned="false"
        if [[ "$volume_id" != "-" && "$volume_id" != "vol-ffffffff" ]]; then
            if [[ -z "${vol_exists_map[$volume_id]:-}" ]]; then
                vol_orphaned="true"
                orphan_vol_count=$(( orphan_vol_count + 1 ))
            fi
        fi

        # Cost estimate
        monthly_cost="$(printf '%.2f' "$(echo "${SNAPSHOT_COST_PER_GB} * ${size_gb}" | bc -l)")"
        total_cost="$(echo "${total_cost} + ${monthly_cost}" | bc -l)"

        # Truncate long descriptions for display
        desc_display="$description"
        if [[ "${#desc_display}" -gt 50 ]]; then
            desc_display="${desc_display:0:47}..."
        fi

        # Build flags for display
        flags=""
        if [[ "$is_old" == "true" ]]; then
            flags="OLD"
        fi
        if [[ "$vol_orphaned" == "true" ]]; then
            [[ -n "$flags" ]] && flags="${flags},"
            flags="${flags}VOL_GONE"
        fi

        # Age display
        age_display="${age_days}"
        if [[ "$is_old" == "true" ]]; then
            age_display="${age_days} (>180d)"
        fi

        # Volume ID display
        vol_display="$volume_id"
        if [[ "$vol_orphaned" == "true" ]]; then
            vol_display="${volume_id} (DELETED)"
        fi

        table_rows+=("${region}|${snapshot_id}|${vol_display}|${size_gb}|${start_date}|${desc_display}|${age_display}|\$${monthly_cost}")

        json_add_object \
            "region=s:${region}" \
            "snapshot_id=s:${snapshot_id}" \
            "volume_id=s:${volume_id}" \
            "size_gb=${size_gb}" \
            "start_time=s:${start_time}" \
            "description=s:${description}" \
            "age_days=s:${age_days}" \
            "monthly_est_cost=s:${monthly_cost}" \
            "is_old=${is_old}" \
            "source_volume_exists=$( [[ "$vol_orphaned" == "true" ]] && echo false || echo true )" \
            "flags=s:${flags}"

    done < <(echo "$snap_output" | jq -r '
        .Snapshots[] |
        [
            .SnapshotId,
            .VolumeId,
            .VolumeSize,
            .StartTime,
            (.Description // "null")
        ] | @tsv
    ')

    unset vol_exists_map
done

json_end_array

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
section "EBS Snapshots Summary"

if [[ "$total_snapshots" -eq 0 ]]; then
    info "No EBS snapshots found across any region."
else
    printf '%s\n' "${table_rows[@]}" | table_print
    echo ""
    info "Total snapshots: ${total_snapshots}"
    total_cost_fmt="$(printf '%.2f' "$total_cost")"
    info "Total estimated monthly cost: \$${total_cost_fmt}"
    if [[ "$old_count" -gt 0 ]]; then
        warn "Snapshots older than ${OLD_THRESHOLD_DAYS} days: ${old_count}"
    fi
    if [[ "$orphan_vol_count" -gt 0 ]]; then
        warn "Snapshots with deleted source volume: ${orphan_vol_count}"
    fi
fi

mkdir -p "$OUTPUT_DIR"
json_write "$OUTPUT_FILE"
ok "JSON written to ${OUTPUT_FILE}"
