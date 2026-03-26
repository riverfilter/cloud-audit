#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# 30-s3-buckets.sh -- AWS S3 Bucket Inventory
#
# Enumerates all S3 buckets with size, object count, versioning, encryption,
# and public access status.  Flags buckets with public access enabled or
# block-public-access disabled.  Flags empty buckets as cleanup candidates.
#
# Columns: Bucket Name | Region | Creation Date | Size | Object Count |
#          Versioning | Encryption | Public Access
# Output : table + output/aws-s3-buckets.json
#
# Required IAM permissions:
#   s3:ListAllMyBuckets, s3:GetBucketLocation, s3:GetBucketVersioning,
#   s3:GetBucketEncryption, s3:GetBucketPublicAccessBlock,
#   s3:GetBucketPolicyStatus, cloudwatch:GetMetricStatistics
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/colors.sh"
source "${SCRIPT_DIR}/../lib/prereqs.sh"
source "${SCRIPT_DIR}/../lib/table.sh"
source "${SCRIPT_DIR}/../lib/json.sh"

OUTPUT_DIR="${SCRIPT_DIR}/../output"
OUTPUT_FILE="${OUTPUT_DIR}/aws-s3-buckets.json"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
section "Prerequisites"
require_bin aws  || exit 1
require_bin jq   || exit 1
require_bin bc   || exit 1
require_auth_aws || exit 1

# ---------------------------------------------------------------------------
# Helper: human-readable byte sizes
# ---------------------------------------------------------------------------
human_size() {
    local bytes="$1"
    if [[ -z "$bytes" || "$bytes" == "0" ]]; then
        echo "0 B"
        return
    fi
    # Use awk for floating-point division
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
# List all S3 buckets
# ---------------------------------------------------------------------------
section "AWS S3 Bucket Inventory"
info "Listing all S3 buckets..."

buckets_raw=""
if ! buckets_raw="$(aws s3api list-buckets --output json 2>&1)"; then
    err "Failed to list S3 buckets: ${buckets_raw}"
    exit 1
fi

bucket_count="$(echo "$buckets_raw" | jq '.Buckets | length')"
if [[ "$bucket_count" -eq 0 ]]; then
    info "No S3 buckets found."
    json_start_array
    json_end_array
    mkdir -p "$OUTPUT_DIR"
    json_write "$OUTPUT_FILE"
    ok "JSON written to ${OUTPUT_FILE}"
    exit 0
fi

info "Found ${bucket_count} buckets. Inspecting each..."

# ---------------------------------------------------------------------------
# Iterate buckets
# ---------------------------------------------------------------------------
json_start_array

table_rows=()
table_rows+=("Bucket Name|Region|Creation Date|Size|Object Count|Versioning|Encryption|Public Access")

total_buckets=0
public_count=0
empty_count=0

# CloudWatch metric window: last 3 days (daily storage metrics may lag)
cw_end="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cw_start="$(date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-3d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"

while IFS=$'\t' read -r bucket_name creation_date; do
    [[ -z "$bucket_name" ]] && continue
    total_buckets=$(( total_buckets + 1 ))

    # Truncate creation date to date portion
    creation_date="${creation_date%%T*}"

    info "  Inspecting bucket: ${bucket_name}..."

    # --- Region ---
    bucket_region=""
    if location="$(aws s3api get-bucket-location --bucket "$bucket_name" --output json 2>/dev/null)"; then
        bucket_region="$(echo "$location" | jq -r '.LocationConstraint // "us-east-1"')"
        # null means us-east-1
        [[ "$bucket_region" == "null" || -z "$bucket_region" ]] && bucket_region="us-east-1"
    else
        bucket_region="unknown"
    fi

    # --- Size from CloudWatch ---
    size_bytes="0"
    object_count="0"
    if [[ -n "$cw_start" && "$bucket_region" != "unknown" ]]; then
        # BucketSizeBytes
        cw_size=""
        if cw_size="$(aws cloudwatch get-metric-statistics \
            --region "$bucket_region" \
            --namespace AWS/S3 \
            --metric-name BucketSizeBytes \
            --dimensions "Name=BucketName,Value=${bucket_name}" "Name=StorageType,Value=StandardStorage" \
            --start-time "$cw_start" \
            --end-time "$cw_end" \
            --period 86400 \
            --statistics Average \
            --output json 2>/dev/null)"; then
            size_bytes="$(echo "$cw_size" | jq -r '
                .Datapoints | sort_by(.Timestamp) | last | .Average // 0
            ' 2>/dev/null)" || size_bytes="0"
            [[ "$size_bytes" == "null" || -z "$size_bytes" ]] && size_bytes="0"
            # Truncate to integer
            size_bytes="$(printf '%.0f' "$size_bytes" 2>/dev/null)" || size_bytes="0"
        fi

        # NumberOfObjects
        cw_count=""
        if cw_count="$(aws cloudwatch get-metric-statistics \
            --region "$bucket_region" \
            --namespace AWS/S3 \
            --metric-name NumberOfObjects \
            --dimensions "Name=BucketName,Value=${bucket_name}" "Name=StorageType,Value=AllStorageTypes" \
            --start-time "$cw_start" \
            --end-time "$cw_end" \
            --period 86400 \
            --statistics Average \
            --output json 2>/dev/null)"; then
            object_count="$(echo "$cw_count" | jq -r '
                .Datapoints | sort_by(.Timestamp) | last | .Average // 0
            ' 2>/dev/null)" || object_count="0"
            [[ "$object_count" == "null" || -z "$object_count" ]] && object_count="0"
            object_count="$(printf '%.0f' "$object_count" 2>/dev/null)" || object_count="0"
        fi
    fi

    size_display="$(human_size "$size_bytes")"

    # --- Versioning ---
    versioning="Disabled"
    if ver_output="$(aws s3api get-bucket-versioning --bucket "$bucket_name" --output json 2>/dev/null)"; then
        ver_status="$(echo "$ver_output" | jq -r '.Status // "Disabled"')"
        [[ "$ver_status" == "null" ]] && ver_status="Disabled"
        versioning="$ver_status"
    fi

    # --- Encryption ---
    encryption="None"
    if enc_output="$(aws s3api get-bucket-encryption --bucket "$bucket_name" --output json 2>/dev/null)"; then
        encryption="$(echo "$enc_output" | jq -r '
            .ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm // "None"
        ')" || encryption="None"
        [[ "$encryption" == "null" ]] && encryption="None"
    fi

    # --- Public Access ---
    public_access="Blocked"
    is_public="false"

    # Check block public access settings
    if pab_output="$(aws s3api get-public-access-block --bucket "$bucket_name" --output json 2>/dev/null)"; then
        block_all="$(echo "$pab_output" | jq -r '
            .PublicAccessBlockConfiguration |
            (.BlockPublicAcls == true) and (.IgnorePublicAcls == true) and
            (.BlockPublicPolicy == true) and (.RestrictPublicBuckets == true)
        ')" || block_all="true"
        if [[ "$block_all" != "true" ]]; then
            public_access="PARTIAL BLOCK"
            is_public="true"
        fi
    else
        # No block public access configured at all -- check policy status
        public_access="NO BLOCK"
        is_public="true"
    fi

    # Also check bucket policy status if block is not full
    if [[ "$is_public" == "true" ]]; then
        if policy_status="$(aws s3api get-bucket-policy-status --bucket "$bucket_name" --output json 2>/dev/null)"; then
            policy_is_public="$(echo "$policy_status" | jq -r '.PolicyStatus.IsPublic // false')"
            if [[ "$policy_is_public" == "true" ]]; then
                public_access="PUBLIC"
            fi
        fi
    fi

    # --- Flags ---
    flags=""
    if [[ "$is_public" == "true" ]]; then
        public_count=$(( public_count + 1 ))
        flags="PUBLIC"
    fi

    is_empty="false"
    if [[ "$object_count" == "0" && "$size_bytes" == "0" ]]; then
        empty_count=$(( empty_count + 1 ))
        is_empty="true"
        if [[ -n "$flags" ]]; then
            flags="${flags}, EMPTY"
        else
            flags="EMPTY"
        fi
    fi

    # Display public access with warning coloring
    public_display="$public_access"
    if [[ "$is_public" == "true" ]]; then
        public_display="⚠ ${public_access}"
    fi

    table_rows+=("${bucket_name}|${bucket_region}|${creation_date}|${size_display}|${object_count}|${versioning}|${encryption}|${public_display}")

    json_add_object \
        "bucket_name=s:${bucket_name}" \
        "region=s:${bucket_region}" \
        "creation_date=s:${creation_date}" \
        "size_bytes=${size_bytes}" \
        "size_display=s:${size_display}" \
        "object_count=${object_count}" \
        "versioning=s:${versioning}" \
        "encryption=s:${encryption}" \
        "public_access=s:${public_access}" \
        "is_public=${is_public}" \
        "is_empty=${is_empty}" \
        "flags=s:${flags}"

done < <(echo "$buckets_raw" | jq -r '.Buckets[] | [.Name, .CreationDate] | @tsv')

json_end_array

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
section "S3 Buckets Summary"

if [[ "$total_buckets" -eq 0 ]]; then
    info "No S3 buckets found."
else
    printf '%s\n' "${table_rows[@]}" | table_print
    echo ""
    info "Total buckets: ${total_buckets}"
    if [[ "$public_count" -gt 0 ]]; then
        warn "Buckets with public access enabled or block disabled: ${public_count}"
    fi
    if [[ "$empty_count" -gt 0 ]]; then
        warn "Empty buckets (potential cleanup candidates): ${empty_count}"
    fi
fi

mkdir -p "$OUTPUT_DIR"
json_write "$OUTPUT_FILE"
ok "JSON written to ${OUTPUT_FILE}"
