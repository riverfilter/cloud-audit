#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# 21-ecs-services.sh -- AWS ECS Cluster, Service & Task Inventory
#
# Enumerates all ECS clusters, their services, and running tasks across
# every enabled region.  For Fargate tasks, estimates monthly cost from
# vCPU/memory configuration.
#
# Columns: Region | Cluster | Service | Launch Type | Running Tasks |
#          CPU | Memory | Status
# Output : table + output/aws-ecs-services.json
#
# Required IAM permissions: ecs:ListClusters, ecs:ListServices,
#   ecs:DescribeServices, ecs:DescribeTaskDefinition, ec2:DescribeRegions
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/colors.sh"
source "${SCRIPT_DIR}/../lib/prereqs.sh"
source "${SCRIPT_DIR}/../lib/table.sh"
source "${SCRIPT_DIR}/../lib/json.sh"

OUTPUT_DIR="${SCRIPT_DIR}/../output"
OUTPUT_FILE="${OUTPUT_DIR}/aws-ecs-services.json"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
section "Prerequisites"
require_bin aws  || exit 1
require_bin jq   || exit 1
require_auth_aws || exit 1

# ---------------------------------------------------------------------------
# Fargate pricing (us-east-1, per hour)
# ---------------------------------------------------------------------------
FARGATE_VCPU_PER_HOUR=0.04048
FARGATE_GB_MEM_PER_HOUR=0.004445
HOURS_PER_MONTH=730

estimate_fargate_monthly() {
    local cpu_units="$1"   # e.g. 256, 512, 1024, etc.
    local mem_mb="$2"      # e.g. 512, 1024, 2048, etc.
    local task_count="$3"

    if [[ "$task_count" -eq 0 ]]; then
        echo "0.00"
        return
    fi

    local vcpu mem_gb
    vcpu="$(echo "scale=4; ${cpu_units} / 1024" | bc -l)"
    mem_gb="$(echo "scale=4; ${mem_mb} / 1024" | bc -l)"

    local monthly
    monthly="$(echo "scale=2; (${vcpu} * ${FARGATE_VCPU_PER_HOUR} + ${mem_gb} * ${FARGATE_GB_MEM_PER_HOUR}) * ${HOURS_PER_MONTH} * ${task_count}" | bc -l)"
    printf '%.2f' "$monthly"
}

# ---------------------------------------------------------------------------
# Discover enabled regions
# ---------------------------------------------------------------------------
section "AWS ECS Service Inventory"
info "Discovering enabled regions..."

regions_raw=""
if ! regions_raw="$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text 2>&1)"; then
    err "Failed to list AWS regions: ${regions_raw}"
    exit 1
fi
read -ra REGIONS <<< "$regions_raw"
info "Found ${#REGIONS[@]} enabled regions."

# ---------------------------------------------------------------------------
# Iterate regions, clusters, and services
# ---------------------------------------------------------------------------
json_start_array

table_rows=()
table_rows+=("Region|Cluster|Service|Launch Type|Running Tasks|CPU|Memory|Status|Monthly Est. Cost")

total_services=0

for region in "${REGIONS[@]}"; do
    info "Scanning region: ${region}..."

    # List clusters
    clusters_output=""
    if ! clusters_output="$(aws ecs list-clusters --region "$region" --output json 2>&1)"; then
        if echo "$clusters_output" | grep -qi "AccessDenied\|AuthFailure\|UnauthorizedAccess"; then
            warn "Permission denied in region ${region} -- skipping."
            continue
        fi
        warn "Error listing ECS clusters in ${region}: ${clusters_output} -- skipping."
        continue
    fi

    cluster_arns="$(echo "$clusters_output" | jq -r '.clusterArns[]' 2>/dev/null)" || true
    [[ -z "$cluster_arns" ]] && continue

    while IFS= read -r cluster_arn; do
        [[ -z "$cluster_arn" ]] && continue
        cluster_name="${cluster_arn##*/}"

        # List services in cluster (paginate with max 100)
        services_output=""
        if ! services_output="$(aws ecs list-services \
            --region "$region" \
            --cluster "$cluster_arn" \
            --output json 2>&1)"; then
            warn "Error listing services for cluster ${cluster_name} in ${region} -- skipping."
            continue
        fi

        service_arns="$(echo "$services_output" | jq -r '.serviceArns[]' 2>/dev/null)" || true
        [[ -z "$service_arns" ]] && continue

        # Describe services in batches of 10 (API limit)
        service_arns_array=()
        while IFS= read -r sa; do
            [[ -n "$sa" ]] && service_arns_array+=("$sa")
        done <<< "$service_arns"

        # Process in batches of 10
        for (( i=0; i<${#service_arns_array[@]}; i+=10 )); do
            batch=("${service_arns_array[@]:$i:10}")

            describe_output=""
            if ! describe_output="$(aws ecs describe-services \
                --region "$region" \
                --cluster "$cluster_arn" \
                --services "${batch[@]}" \
                --output json 2>&1)"; then
                warn "Error describing services in cluster ${cluster_name} -- skipping batch."
                continue
            fi

            while IFS=$'\t' read -r svc_name launch_type running_count status task_def; do
                [[ -z "$svc_name" ]] && continue
                total_services=$(( total_services + 1 ))

                cpu="-"
                memory="-"
                monthly_cost="-"

                # Fetch task definition for CPU/memory
                if [[ -n "$task_def" && "$task_def" != "null" ]]; then
                    td_output=""
                    if td_output="$(aws ecs describe-task-definition \
                        --region "$region" \
                        --task-definition "$task_def" \
                        --query 'taskDefinition.{cpu:cpu,memory:memory}' \
                        --output json 2>/dev/null)"; then
                        td_cpu="$(echo "$td_output" | jq -r '.cpu // empty')"
                        td_mem="$(echo "$td_output" | jq -r '.memory // empty')"
                        [[ -n "$td_cpu" ]] && cpu="${td_cpu}"
                        [[ -n "$td_mem" ]] && memory="${td_mem}"
                    fi
                fi

                # Estimate Fargate cost
                if [[ "$launch_type" == "FARGATE" && "$cpu" != "-" && "$memory" != "-" ]]; then
                    monthly_cost="\$$(estimate_fargate_monthly "$cpu" "$memory" "$running_count")"
                fi

                table_rows+=("${region}|${cluster_name}|${svc_name}|${launch_type}|${running_count}|${cpu}|${memory}|${status}|${monthly_cost}")

                json_add_object \
                    "region=s:${region}" \
                    "cluster=s:${cluster_name}" \
                    "service=s:${svc_name}" \
                    "launch_type=s:${launch_type}" \
                    "running_tasks=${running_count}" \
                    "cpu=s:${cpu}" \
                    "memory=s:${memory}" \
                    "status=s:${status}" \
                    "monthly_est_cost=s:${monthly_cost//\$/}"

            done < <(echo "$describe_output" | jq -r '
                .services[] |
                [
                    .serviceName,
                    .launchType // (.capacityProviderStrategy[0].capacityProvider // "UNKNOWN"),
                    .runningCount,
                    .status,
                    .taskDefinition
                ] | @tsv
            ')
        done
    done <<< "$cluster_arns"
done

json_end_array

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
section "ECS Services Summary"

if [[ "$total_services" -eq 0 ]]; then
    info "No ECS services found across any region."
else
    printf '%s\n' "${table_rows[@]}" | table_print
    echo ""
    info "Total ECS services: ${total_services}"
fi

mkdir -p "$OUTPUT_DIR"
json_write "$OUTPUT_FILE"
ok "JSON written to ${OUTPUT_FILE}"
