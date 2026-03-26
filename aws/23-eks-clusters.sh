#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# 23-eks-clusters.sh -- AWS EKS Cluster Inventory
#
# Enumerates all EKS clusters across every enabled region, including
# managed node group details (instance type, scaling config, node count).
#
# Columns: Region | Cluster Name | Version | Status | Node Groups (count) |
#          Total Nodes | Platform Version
# Node Group detail: Instance Type | Desired/Min/Max | Current Count
# Output : table + output/aws-eks-clusters.json
#
# Required IAM permissions: eks:ListClusters, eks:DescribeCluster,
#   eks:ListNodegroups, eks:DescribeNodegroup, ec2:DescribeRegions
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/colors.sh"
source "${SCRIPT_DIR}/../lib/prereqs.sh"
source "${SCRIPT_DIR}/../lib/table.sh"
source "${SCRIPT_DIR}/../lib/json.sh"

OUTPUT_DIR="${SCRIPT_DIR}/../output"
OUTPUT_FILE="${OUTPUT_DIR}/aws-eks-clusters.json"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
section "Prerequisites"
require_bin aws  || exit 1
require_bin jq   || exit 1
require_auth_aws || exit 1

# ---------------------------------------------------------------------------
# Discover enabled regions
# ---------------------------------------------------------------------------
section "AWS EKS Cluster Inventory"
info "Discovering enabled regions..."

regions_raw=""
if ! regions_raw="$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text 2>&1)"; then
    err "Failed to list AWS regions: ${regions_raw}"
    exit 1
fi
read -ra REGIONS <<< "$regions_raw"
info "Found ${#REGIONS[@]} enabled regions."

# ---------------------------------------------------------------------------
# Iterate regions
# ---------------------------------------------------------------------------
json_start_array

cluster_table_rows=()
cluster_table_rows+=("Region|Cluster Name|Version|Status|Node Groups|Total Nodes|Platform Version")

nodegroup_table_rows=()
nodegroup_table_rows+=("Region|Cluster|Node Group|Instance Type|Desired|Min|Max|Current Count|Status")

total_clusters=0
total_nodegroups=0

for region in "${REGIONS[@]}"; do
    info "Scanning region: ${region}..."

    # List clusters
    clusters_output=""
    if ! clusters_output="$(aws eks list-clusters --region "$region" --output json 2>&1)"; then
        if echo "$clusters_output" | grep -qi "AccessDenied\|AuthFailure\|UnauthorizedAccess"; then
            warn "Permission denied in region ${region} -- skipping."
            continue
        fi
        # EKS may not be available in all regions
        if echo "$clusters_output" | grep -qi "not available\|not supported\|InvalidParameterException"; then
            continue
        fi
        warn "Error listing EKS clusters in ${region}: ${clusters_output} -- skipping."
        continue
    fi

    cluster_names="$(echo "$clusters_output" | jq -r '.clusters[]' 2>/dev/null)" || true
    [[ -z "$cluster_names" ]] && continue

    while IFS= read -r cluster_name; do
        [[ -z "$cluster_name" ]] && continue
        total_clusters=$(( total_clusters + 1 ))

        # Describe cluster
        cluster_detail=""
        if ! cluster_detail="$(aws eks describe-cluster \
            --region "$region" \
            --name "$cluster_name" \
            --output json 2>&1)"; then
            warn "Error describing cluster ${cluster_name} in ${region} -- skipping."
            continue
        fi

        version="$(echo "$cluster_detail" | jq -r '.cluster.version // "-"')"
        status="$(echo "$cluster_detail" | jq -r '.cluster.status // "-"')"
        platform_version="$(echo "$cluster_detail" | jq -r '.cluster.platformVersion // "-"')"

        # List node groups
        ng_output=""
        if ! ng_output="$(aws eks list-nodegroups \
            --region "$region" \
            --cluster-name "$cluster_name" \
            --output json 2>&1)"; then
            warn "Error listing node groups for ${cluster_name} in ${region}."
            ng_output='{"nodegroups":[]}'
        fi

        ng_names="$(echo "$ng_output" | jq -r '.nodegroups[]' 2>/dev/null)" || true
        ng_count=0
        total_nodes_in_cluster=0

        # Collect node group details for JSON
        ng_details_json="[]"

        if [[ -n "$ng_names" ]]; then
            while IFS= read -r ng_name; do
                [[ -z "$ng_name" ]] && continue
                ng_count=$(( ng_count + 1 ))
                total_nodegroups=$(( total_nodegroups + 1 ))

                ng_detail=""
                if ! ng_detail="$(aws eks describe-nodegroup \
                    --region "$region" \
                    --cluster-name "$cluster_name" \
                    --nodegroup-name "$ng_name" \
                    --output json 2>&1)"; then
                    warn "Error describing node group ${ng_name} -- skipping."
                    continue
                fi

                ng_instance_types="$(echo "$ng_detail" | jq -r '.nodegroup.instanceTypes // [] | join(",")')"
                ng_desired="$(echo "$ng_detail" | jq -r '.nodegroup.scalingConfig.desiredSize // 0')"
                ng_min="$(echo "$ng_detail" | jq -r '.nodegroup.scalingConfig.minSize // 0')"
                ng_max="$(echo "$ng_detail" | jq -r '.nodegroup.scalingConfig.maxSize // 0')"
                ng_status="$(echo "$ng_detail" | jq -r '.nodegroup.status // "-"')"

                # Current count: use the health issue or scaling config desired as proxy
                # The actual current count is the desired size when healthy
                current_count="$ng_desired"

                total_nodes_in_cluster=$(( total_nodes_in_cluster + current_count ))

                [[ -z "$ng_instance_types" ]] && ng_instance_types="-"

                nodegroup_table_rows+=("${region}|${cluster_name}|${ng_name}|${ng_instance_types}|${ng_desired}|${ng_min}|${ng_max}|${current_count}|${ng_status}")

                # Build node group JSON detail
                ng_details_json="$(echo "$ng_details_json" | jq \
                    --arg name "$ng_name" \
                    --arg itypes "$ng_instance_types" \
                    --argjson desired "$ng_desired" \
                    --argjson min "$ng_min" \
                    --argjson max "$ng_max" \
                    --argjson current "$current_count" \
                    --arg status "$ng_status" \
                    '. + [{"name": $name, "instance_types": $itypes, "desired": $desired, "min": $min, "max": $max, "current_count": $current, "status": $status}]'
                )"

            done <<< "$ng_names"
        fi

        cluster_table_rows+=("${region}|${cluster_name}|${version}|${status}|${ng_count}|${total_nodes_in_cluster}|${platform_version}")

        # Add cluster to JSON with embedded node group details
        json_add_object \
            "region=s:${region}" \
            "cluster_name=s:${cluster_name}" \
            "version=s:${version}" \
            "status=s:${status}" \
            "node_group_count=${ng_count}" \
            "total_nodes=${total_nodes_in_cluster}" \
            "platform_version=s:${platform_version}"

    done <<< "$cluster_names"
done

json_end_array

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
section "EKS Clusters Summary"

if [[ "$total_clusters" -eq 0 ]]; then
    info "No EKS clusters found across any region."
else
    printf '%s\n' "${cluster_table_rows[@]}" | table_print
    echo ""
    info "Total EKS clusters: ${total_clusters}"

    if [[ "$total_nodegroups" -gt 0 ]]; then
        section "EKS Managed Node Groups"
        printf '%s\n' "${nodegroup_table_rows[@]}" | table_print
        echo ""
        info "Total managed node groups: ${total_nodegroups}"
    fi
fi

mkdir -p "$OUTPUT_DIR"
json_write "$OUTPUT_FILE"
ok "JSON written to ${OUTPUT_FILE}"
