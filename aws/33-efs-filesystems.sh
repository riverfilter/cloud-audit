#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# 33-efs-filesystems.sh -- AWS EFS File System Inventory across all regions
#
# Enumerates all EFS file systems with size, throughput/performance modes,
# lifecycle policies, and monthly cost estimates.  Flags EFS file systems
# with 0 mount targets as potentially unused.
#
# Columns: Region | File System ID | Name | Size | Throughput Mode |
#          Performance Mode | Lifecycle Policy | Monthly Est. Cost
# Output : table + output/aws-efs.json
#
# Required IAM permissions: elasticfilesystem:DescribeFileSystems,
#   elasticfilesystem:DescribeMountTargets, elasticfilesystem:DescribeLifecycleConfiguration,
#   ec2:DescribeRegions
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/colors.sh"
source "${SCRIPT_DIR}/../lib/prereqs.sh"
source "${SCRIPT_DIR}/../lib/table.sh"
source "${SCRIPT_DIR}/../lib/json.sh"

OUTPUT_DIR="${SCRIPT_DIR}/../output"
OUTPUT_FILE="${OUTPUT_DIR}/aws-efs.json"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
section "Prerequisites"
require_bin aws  || exit 1
require_bin jq   || exit 1
require_bin bc   || exit 1
require_auth_aws || exit 1

# ---------------------------------------------------------------------------
# EFS pricing (approximate, us-east-1)
# ---------------------------------------------------------------------------
EFS_STANDARD_PER_GB=0.30    # $/GB-month Standard storage
EFS_IA_PER_GB=0.025         # $/GB-month Infrequent Access storage

# ---------------------------------------------------------------------------
# Helper: human-readable byte sizes
# ---------------------------------------------------------------------------
human_size() {
    local bytes="$1"
    if [[ -z "$bytes" || "$bytes" == "0" ]]; then
        echo "0 B"
        return
    fi
    echo "$bytes" | awk '{
        split("B KB MB GB TB PB", u, " ");
        v = $1;
        i = 1;
        while (v >= 1024 && i < 6) { v /= 1024; i++ }
        if (i == 1) printf "%d %s", v, u[i];
        else printf "%.2f %s", v, u[i];
    }'
}

# ---------------------------------------------------------------------------
# Discover enabled regions
# ---------------------------------------------------------------------------
section "AWS EFS File System Inventory"
info "Discovering enabled regions..."

regions_raw=""
if ! regions_raw="$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text 2>&1)"; then
    err "Failed to list AWS regions: ${regions_raw}"
    exit 1
fi
read -ra REGIONS <<< "$regions_raw"
info "Found ${#REGIONS[@]} enabled regions."

# ---------------------------------------------------------------------------
# Iterate regions and collect EFS file systems
# ---------------------------------------------------------------------------
json_start_array

table_rows=()
table_rows+=("Region|File System ID|Name|Size|Throughput Mode|Performance Mode|Lifecycle Policy|Monthly Est. Cost")

total_filesystems=0
no_mount_count=0
total_cost=0

for region in "${REGIONS[@]}"; do
    info "Scanning region: ${region}..."

    efs_output=""
    if ! efs_output="$(aws efs describe-file-systems \
        --region "$region" \
        --output json 2>&1)"; then
        if echo "$efs_output" | grep -qi "UnauthorizedAccess\|AccessDenied\|AuthFailure"; then
            warn "Permission denied in region ${region} -- skipping."
            continue
        fi
        # EFS may not be available in all regions
        if echo "$efs_output" | grep -qi "not available\|Could not connect\|InvalidRegion"; then
            continue
        fi
        warn "Error querying EFS in ${region}: ${efs_output} -- skipping."
        continue
    fi

    fs_count="$(echo "$efs_output" | jq '.FileSystems | length')"
    if [[ "$fs_count" -eq 0 || "$efs_output" == "null" ]]; then
        continue
    fi

    while IFS=$'\t' read -r fs_id name size_bytes throughput_mode perf_mode; do
        [[ -z "$fs_id" ]] && continue
        total_filesystems=$(( total_filesystems + 1 ))

        # Clean up values
        [[ "$name" == "null" || -z "$name" ]] && name="-"
        [[ "$size_bytes" == "null" || -z "$size_bytes" ]] && size_bytes="0"
        [[ "$throughput_mode" == "null" || -z "$throughput_mode" ]] && throughput_mode="-"
        [[ "$perf_mode" == "null" || -z "$perf_mode" ]] && perf_mode="-"

        size_display="$(human_size "$size_bytes")"

        # --- Mount targets ---
        mount_count=0
        has_no_mounts="false"
        if mt_output="$(aws efs describe-mount-targets \
            --region "$region" \
            --file-system-id "$fs_id" \
            --output json 2>/dev/null)"; then
            mount_count="$(echo "$mt_output" | jq '.MountTargets | length')"
        fi
        if [[ "$mount_count" -eq 0 ]]; then
            has_no_mounts="true"
            no_mount_count=$(( no_mount_count + 1 ))
        fi

        # --- Lifecycle policy ---
        lifecycle_policy="-"
        if lc_output="$(aws efs describe-lifecycle-configuration \
            --region "$region" \
            --file-system-id "$fs_id" \
            --output json 2>/dev/null)"; then
            lc_rules="$(echo "$lc_output" | jq -r '
                .LifecyclePolicies[]? |
                if .TransitionToIA then "ToIA:" + .TransitionToIA
                elif .TransitionToPrimaryStorageClass then "ToStd:" + .TransitionToPrimaryStorageClass
                elif .TransitionToArchive then "ToArchive:" + .TransitionToArchive
                else empty end
            ' 2>/dev/null | paste -sd "," -)" || lc_rules=""
            if [[ -n "$lc_rules" ]]; then
                lifecycle_policy="$lc_rules"
            fi
        fi

        # --- Cost estimate (use Standard rate as default) ---
        size_gb="$(echo "scale=6; ${size_bytes} / 1073741824" | bc -l)"
        monthly_cost="$(printf '%.2f' "$(echo "${EFS_STANDARD_PER_GB} * ${size_gb}" | bc -l)")"
        total_cost="$(echo "${total_cost} + ${monthly_cost}" | bc -l)"

        # Display with mount target warning
        name_display="$name"
        if [[ "$has_no_mounts" == "true" ]]; then
            name_display="${name} (NO MOUNTS)"
        fi

        table_rows+=("${region}|${fs_id}|${name_display}|${size_display}|${throughput_mode}|${perf_mode}|${lifecycle_policy}|\$${monthly_cost}")

        json_add_object \
            "region=s:${region}" \
            "file_system_id=s:${fs_id}" \
            "name=s:${name}" \
            "size_bytes=${size_bytes}" \
            "size_display=s:${size_display}" \
            "throughput_mode=s:${throughput_mode}" \
            "performance_mode=s:${perf_mode}" \
            "lifecycle_policy=s:${lifecycle_policy}" \
            "mount_target_count=${mount_count}" \
            "has_no_mounts=${has_no_mounts}" \
            "monthly_est_cost=s:${monthly_cost}"

    done < <(echo "$efs_output" | jq -r '
        .FileSystems[] |
        [
            .FileSystemId,
            (.Name // "null"),
            (.SizeInBytes.Value // 0),
            (.ThroughputMode // "null"),
            (.PerformanceMode // "null")
        ] | @tsv
    ')
done

json_end_array

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
section "EFS File Systems Summary"

if [[ "$total_filesystems" -eq 0 ]]; then
    info "No EFS file systems found across any region."
else
    printf '%s\n' "${table_rows[@]}" | table_print
    echo ""
    info "Total EFS file systems: ${total_filesystems}"
    total_cost_fmt="$(printf '%.2f' "$total_cost")"
    info "Total estimated monthly cost: \$${total_cost_fmt}"
    if [[ "$no_mount_count" -gt 0 ]]; then
        warn "EFS file systems with 0 mount targets: ${no_mount_count}"
    fi
fi

mkdir -p "$OUTPUT_DIR"
json_write "$OUTPUT_FILE"
ok "JSON written to ${OUTPUT_FILE}"
