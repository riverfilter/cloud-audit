#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# 20-ec2-instances.sh -- AWS EC2 Instance Inventory across all regions
#
# Enumerates all EC2 instances across every enabled region, with on-demand
# monthly cost estimates.  Running instances with no Name tag are flagged
# as potential orphans.
#
# Columns: Region | Instance ID | Name | Type | State | Launch Time |
#          Private IP | Public IP | Monthly Est. Cost
# Output : table + output/aws-ec2-instances.json
#
# Required IAM permissions: ec2:DescribeInstances, ec2:DescribeRegions
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/colors.sh"
source "${SCRIPT_DIR}/../lib/prereqs.sh"
source "${SCRIPT_DIR}/../lib/table.sh"
source "${SCRIPT_DIR}/../lib/json.sh"

OUTPUT_DIR="${SCRIPT_DIR}/../output"
OUTPUT_FILE="${OUTPUT_DIR}/aws-ec2-instances.json"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
section "Prerequisites"
require_bin aws  || exit 1
require_bin jq   || exit 1
require_auth_aws || exit 1

# ---------------------------------------------------------------------------
# On-demand monthly pricing lookup (us-east-1, USD, Linux)
# Prices are approximate hourly rates * 730 hours/month.
# ---------------------------------------------------------------------------
declare -A HOURLY_PRICE=(
    # t2 family
    [t2.micro]=0.0116    [t2.small]=0.0232    [t2.medium]=0.0464
    [t2.large]=0.0928    [t2.xlarge]=0.1856   [t2.2xlarge]=0.3712
    # t3 family
    [t3.micro]=0.0104    [t3.small]=0.0208    [t3.medium]=0.0416
    [t3.large]=0.0832    [t3.xlarge]=0.1664   [t3.2xlarge]=0.3328
    # t3a family
    [t3a.micro]=0.0094   [t3a.small]=0.0188   [t3a.medium]=0.0376
    [t3a.large]=0.0752   [t3a.xlarge]=0.1504  [t3a.2xlarge]=0.3008
    # m5 family
    [m5.large]=0.096     [m5.xlarge]=0.192    [m5.2xlarge]=0.384
    [m5.4xlarge]=0.768   [m5.8xlarge]=1.536   [m5.12xlarge]=2.304
    [m5.16xlarge]=3.072  [m5.24xlarge]=4.608
    # m6i family
    [m6i.large]=0.096    [m6i.xlarge]=0.192   [m6i.2xlarge]=0.384
    [m6i.4xlarge]=0.768  [m6i.8xlarge]=1.536  [m6i.12xlarge]=2.304
    [m6i.16xlarge]=3.072 [m6i.24xlarge]=4.608
    # c5 family
    [c5.large]=0.085     [c5.xlarge]=0.170    [c5.2xlarge]=0.340
    [c5.4xlarge]=0.680   [c5.9xlarge]=1.530   [c5.12xlarge]=2.040
    [c5.18xlarge]=3.060  [c5.24xlarge]=4.080
    # r5 family
    [r5.large]=0.126     [r5.xlarge]=0.252    [r5.2xlarge]=0.504
    [r5.4xlarge]=1.008   [r5.8xlarge]=2.016   [r5.12xlarge]=3.024
    [r5.16xlarge]=4.032  [r5.24xlarge]=6.048
)

HOURS_PER_MONTH=730

estimate_monthly_cost() {
    local itype="$1"
    local state="$2"
    if [[ "$state" != "running" ]]; then
        echo "0.00"
        return
    fi
    local hourly="${HOURLY_PRICE[$itype]:-}"
    if [[ -z "$hourly" ]]; then
        echo "N/A"
        return
    fi
    printf '%.2f' "$(echo "${hourly} * ${HOURS_PER_MONTH}" | bc -l)"
}

# ---------------------------------------------------------------------------
# Discover enabled regions
# ---------------------------------------------------------------------------
section "AWS EC2 Instance Inventory"
info "Discovering enabled regions..."

regions_raw=""
if ! regions_raw="$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text 2>&1)"; then
    err "Failed to list AWS regions: ${regions_raw}"
    exit 1
fi
read -ra REGIONS <<< "$regions_raw"
info "Found ${#REGIONS[@]} enabled regions."

# ---------------------------------------------------------------------------
# Iterate regions and collect instances
# ---------------------------------------------------------------------------
json_start_array

table_rows=()
table_rows+=("Region|Instance ID|Name|Type|State|Launch Time|Private IP|Public IP|Monthly Est. Cost")

total_instances=0
total_running=0
orphan_count=0

for region in "${REGIONS[@]}"; do
    info "Scanning region: ${region}..."

    ec2_output=""
    if ! ec2_output="$(aws ec2 describe-instances \
        --region "$region" \
        --query 'Reservations[].Instances[]' \
        --output json 2>&1)"; then
        if echo "$ec2_output" | grep -qi "UnauthorizedAccess\|AccessDenied\|AuthFailure"; then
            warn "Permission denied in region ${region} -- skipping."
            continue
        fi
        warn "Error querying EC2 in ${region}: ${ec2_output} -- skipping."
        continue
    fi

    instance_count="$(echo "$ec2_output" | jq -r 'length')"
    if [[ "$instance_count" -eq 0 || "$ec2_output" == "null" || "$ec2_output" == "[]" ]]; then
        continue
    fi

    while IFS=$'\t' read -r instance_id name itype state launch_time private_ip public_ip; do
        [[ -z "$instance_id" ]] && continue
        total_instances=$(( total_instances + 1 ))

        # Replace null/empty values
        [[ "$name" == "null" || -z "$name" ]] && name=""
        [[ "$private_ip" == "null" || -z "$private_ip" ]] && private_ip="-"
        [[ "$public_ip" == "null" || -z "$public_ip" ]] && public_ip="-"
        [[ "$launch_time" == "null" || -z "$launch_time" ]] && launch_time="-"

        # Truncate launch time to date portion
        launch_time="${launch_time%%T*}"

        if [[ "$state" == "running" ]]; then
            total_running=$(( total_running + 1 ))
        fi

        # Orphan detection: running with no Name tag
        display_name="$name"
        is_orphan="false"
        if [[ "$state" == "running" && -z "$name" ]]; then
            display_name="[ORPHAN?] (no Name tag)"
            orphan_count=$(( orphan_count + 1 ))
            is_orphan="true"
        elif [[ -z "$name" ]]; then
            display_name="(no Name tag)"
        fi

        monthly_cost="$(estimate_monthly_cost "$itype" "$state")"

        table_rows+=("${region}|${instance_id}|${display_name}|${itype}|${state}|${launch_time}|${private_ip}|${public_ip}|\$${monthly_cost}")

        json_add_object \
            "region=s:${region}" \
            "instance_id=s:${instance_id}" \
            "name=s:${name}" \
            "type=s:${itype}" \
            "state=s:${state}" \
            "launch_time=s:${launch_time}" \
            "private_ip=s:${private_ip}" \
            "public_ip=s:${public_ip}" \
            "monthly_est_cost=s:${monthly_cost}" \
            "is_potential_orphan=${is_orphan}"

    done < <(echo "$ec2_output" | jq -r '
        .[] |
        [
            .InstanceId,
            ((.Tags // []) | map(select(.Key == "Name")) | .[0].Value // "null"),
            .InstanceType,
            .State.Name,
            .LaunchTime,
            .PrivateIpAddress,
            .PublicIpAddress
        ] | @tsv
    ')
done

json_end_array

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
section "EC2 Instances Summary"

if [[ "$total_instances" -eq 0 ]]; then
    info "No EC2 instances found across any region."
else
    printf '%s\n' "${table_rows[@]}" | table_print
    echo ""
    info "Total instances: ${total_instances} (${total_running} running)"
    if [[ "$orphan_count" -gt 0 ]]; then
        warn "Potential orphans (running, no Name tag): ${orphan_count}"
    fi
fi

mkdir -p "$OUTPUT_DIR"
json_write "$OUTPUT_FILE"
ok "JSON written to ${OUTPUT_FILE}"
