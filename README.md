# Cloud Cost Audit

A multi-cloud cost auditing toolkit that inventories compute, storage, and networking resources across AWS (with GCP and Azure planned) and identifies idle, orphaned, oversized, and misconfigured resources. All audits are implemented as portable bash scripts with structured JSON output for downstream automation.

## Design Philosophy

- **Zero dependencies beyond the cloud CLIs and standard Unix tools.** No Python, Node, or compiled binaries required.
- **Structured output by default.** Every script produces both a human-readable ASCII table (stdout) and a machine-readable JSON file (output directory) for pipeline integration.
- **Safe, read-only operations.** No script modifies any cloud resource. All API calls are read-only describe/list/get operations.
- **Graceful degradation.** Missing permissions, unavailable regions, or disabled services are warned about and skipped rather than causing a hard failure.
- **Portable.** Scripts target bash 4.0+ and work on Linux and macOS (with GNU coreutils recommended).

## Directory Structure

```
cloud-audit/
  audit-all.sh                    # Orchestrator -- detects providers, runs all audits
  lib/
    colors.sh                     # Terminal color definitions with automatic TTY detection
    prereqs.sh                    # Binary and cloud auth prerequisite checks
    table.sh                      # Portable ASCII / Markdown table formatter
    json.sh                       # Incremental JSON array builder (no jq dependency)
  aws/
    00-check-prereqs.sh           # Verify AWS CLI, jq, credentials, Organizations access
    01-enumerate-accounts.sh      # List all accounts in the Organization
    01a-enumerate-regions.sh      # List all enabled (or all) AWS regions
    10-cost-current-month.sh      # Cost Explorer: current month by service (top 20)
    11-cost-by-account.sh         # Cost Explorer: current month by linked account
    12-cost-trend.sh              # Cost Explorer: 6-month cost trend with delta
    13-cost-by-tag.sh             # Cost Explorer: current month by tag key
    20-ec2-instances.sh           # EC2 instance inventory across all regions
    21-ecs-services.sh            # ECS cluster, service & task inventory
    22-lambda-functions.sh        # Lambda function inventory with orphan detection
    23-eks-clusters.sh            # EKS cluster and node group inventory
    24-lightsail-instances.sh     # Lightsail instance and database inventory
    30-s3-buckets.sh              # S3 bucket inventory with security audit
    31-ebs-volumes.sh             # EBS volume inventory with orphan detection
    32-ebs-snapshots.sh           # EBS snapshot inventory with age analysis
    33-efs-filesystems.sh         # EFS file system inventory
    34-fsx-filesystems.sh         # FSx file system inventory (Lustre, Windows, ONTAP, OpenZFS)
  output/                         # Default output directory for JSON reports (auto-created)
  bugs.md                         # Known bugs and issues
  features.md                     # Feature requests and improvement ideas
  README.md                       # This file
```

## Prerequisites

### Required Tools

| Tool      | Minimum Version | Purpose                          | Install Guide |
|-----------|-----------------|----------------------------------|---------------|
| `bash`    | 4.0+            | Script runtime (associative arrays, `readarray`) | Pre-installed on most Linux; macOS ships 3.x -- install via Homebrew: `brew install bash` |
| `aws`     | 2.0+            | AWS API access                   | [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |
| `jq`      | 1.6+            | JSON parsing of AWS CLI output   | [jq](https://jqlang.github.io/jq/download/) or `apt install jq` / `brew install jq` |
| `bc`      | --              | Floating-point arithmetic        | `apt install bc` / `brew install bc` (pre-installed on most systems) |
| `column`  | --              | Optional: improved table alignment | Part of `util-linux` (Linux) or `bsdmainutils` (Debian/Ubuntu) |

### Verify Installation

```bash
# Check bash version (need 4.0+)
bash --version | head -1

# Check AWS CLI version (need 2.x)
aws --version

# Check jq
jq --version

# Check bc
echo "1 + 1" | bc

# Run the built-in prerequisite checker
./aws/00-check-prereqs.sh
```

## Authentication Setup

### AWS

The scripts use whatever AWS credentials are configured in your environment. Any of the standard AWS credential methods work:

```bash
# Option 1: AWS SSO (recommended for interactive use)
aws sso login --profile your-profile
export AWS_PROFILE=your-profile

# Option 2: Long-lived access keys
aws configure
# Enter: AWS Access Key ID, Secret Access Key, default region, output format

# Option 3: Environment variables (CI/CD)
export AWS_ACCESS_KEY_ID="AKIA..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_DEFAULT_REGION="us-east-1"

# Option 4: EC2 Instance Profile / ECS Task Role (auto-detected)
# No configuration needed -- credentials are retrieved from the metadata service.

# Option 5: Assume a role
aws sts assume-role --role-arn arn:aws:iam::ACCOUNT:role/ROLE --role-session-name audit
# Export the returned credentials

# Verify authentication
aws sts get-caller-identity
```

### GCP (planned)

```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
gcloud auth application-default login   # for application-default credentials
```

### Azure (planned)

```bash
az login
az account set --subscription YOUR_SUBSCRIPTION_ID
az account show   # verify
```

## Quick Start

```bash
# Run the full audit across all configured providers
./audit-all.sh

# Or run just the AWS prerequisite check first
./aws/00-check-prereqs.sh

# Results are printed to stdout and JSON is saved to output/
ls output/
```

## Script Reference

### Orchestrator

#### `audit-all.sh`

Top-level orchestrator that detects installed and authenticated cloud provider CLIs, runs each provider's audit, and produces a final status report.

- **Permissions needed:** None directly (delegates to provider scripts)
- **Output:** Status table showing which providers ran/skipped/failed
- **Exit codes:** `0` = success, `1` = one or more audits failed, `2` = no providers available

---

### AWS: Prerequisites & Enumeration (00-01)

#### `aws/00-check-prereqs.sh`

Verifies all prerequisites for AWS auditing: CLI version, jq, column, AWS credentials, authenticated identity, and AWS Organizations access.

- **IAM permissions:** `sts:GetCallerIdentity`, `organizations:DescribeOrganization`, `organizations:ListAccounts`
- **Output:** Table of authenticated identity details; Organizations status
- **JSON output:** None (diagnostic script)

```bash
./aws/00-check-prereqs.sh
```

#### `aws/01-enumerate-accounts.sh`

Lists all AWS accounts in the Organization, or falls back to the single current account if Organizations is not available.

- **IAM permissions:** `sts:GetCallerIdentity`, `organizations:ListAccounts`, `iam:ListAccountAliases`
- **Output:** Table with Account ID, Name, Email, Status, Joined Date
- **JSON output:** `output/aws-accounts.json`

```bash
./aws/01-enumerate-accounts.sh
```

#### `aws/01a-enumerate-regions.sh`

Lists all enabled AWS regions for the account. Optionally includes opt-in regions not yet enabled.

- **IAM permissions:** `sts:GetCallerIdentity`, `ec2:DescribeRegions`
- **Output:** Table with Region Name and Opt-In Status; one-per-line list for piping
- **JSON output:** `output/aws-regions.json`

```bash
# Enabled regions only
./aws/01a-enumerate-regions.sh

# Include opt-in regions
./aws/01a-enumerate-regions.sh --all
```

---

### AWS: Cost Reports (10-13)

#### `aws/10-cost-current-month.sh`

Queries AWS Cost Explorer for the current calendar month, showing total unblended cost broken down by service (top 20).

- **IAM permissions:** `ce:GetCostAndUsage`
- **Output:** Table with Service, Cost (USD), % of Total
- **JSON output:** `output/aws-cost-current-month.json`

```bash
./aws/10-cost-current-month.sh
```

#### `aws/11-cost-by-account.sh`

Queries Cost Explorer for the current month grouped by linked account. Only meaningful in an AWS Organization with consolidated billing.

- **IAM permissions:** `ce:GetCostAndUsage`, `organizations:DescribeOrganization`, `organizations:ListAccounts`
- **Output:** Table with Account ID, Account Name, Cost (USD), % of Total
- **JSON output:** `output/aws-cost-by-account.json`

```bash
./aws/11-cost-by-account.sh
```

#### `aws/12-cost-trend.sh`

Queries Cost Explorer for the last 6 complete months and shows monthly totals with month-over-month delta. Months with greater than 20% cost increase are highlighted in red.

- **IAM permissions:** `ce:GetCostAndUsage`
- **Output:** Table with Month, Total Cost, Delta vs Previous (USD), Delta (%)
- **JSON output:** `output/aws-cost-trend.json`

```bash
./aws/12-cost-trend.sh
```

#### `aws/13-cost-by-tag.sh`

Queries Cost Explorer for the current month grouped by a user-specified cost allocation tag key.

- **IAM permissions:** `ce:GetCostAndUsage`
- **Output:** Table with Tag Value, Cost (USD), % of Total
- **JSON output:** `output/aws-cost-by-tag.json`

```bash
# Default: group by "Environment" tag
./aws/13-cost-by-tag.sh

# Custom tag key
./aws/13-cost-by-tag.sh --tag-key Team
./aws/13-cost-by-tag.sh --tag-key CostCenter
```

**Note:** The tag must be activated as a cost allocation tag in the Billing console (Billing > Cost Allocation Tags > Activate) for data to appear.

---

### AWS: Compute Inventory (20-24)

#### `aws/20-ec2-instances.sh`

Enumerates all EC2 instances across every enabled region. Includes on-demand monthly cost estimates and flags running instances with no Name tag as potential orphans.

- **IAM permissions:** `ec2:DescribeInstances`, `ec2:DescribeRegions`
- **Output:** Table with Region, Instance ID, Name, Type, State, Launch Time, IPs, Monthly Est. Cost
- **JSON output:** `output/aws-ec2-instances.json`

```bash
./aws/20-ec2-instances.sh
```

#### `aws/21-ecs-services.sh`

Enumerates all ECS clusters, services, and running tasks across every enabled region. Estimates monthly cost for Fargate services based on vCPU/memory configuration.

- **IAM permissions:** `ecs:ListClusters`, `ecs:ListServices`, `ecs:DescribeServices`, `ecs:DescribeTaskDefinition`, `ec2:DescribeRegions`
- **Output:** Table with Region, Cluster, Service, Launch Type, Running Tasks, CPU, Memory, Status, Monthly Est. Cost
- **JSON output:** `output/aws-ecs-services.json`

```bash
./aws/21-ecs-services.sh
```

#### `aws/22-lambda-functions.sh`

Enumerates all Lambda functions across every enabled region. Uses CloudWatch metrics to detect functions not invoked in 90+ days (flagged as potentially orphaned).

- **IAM permissions:** `lambda:ListFunctions`, `cloudwatch:GetMetricStatistics`, `ec2:DescribeRegions`
- **Output:** Table with Region, Function Name, Runtime, Memory, Timeout, Last Invoked, Code Size, Orphan flag
- **JSON output:** `output/aws-lambda-functions.json`

```bash
./aws/22-lambda-functions.sh
```

#### `aws/23-eks-clusters.sh`

Enumerates all EKS clusters and managed node groups across every enabled region. Reports cluster version, status, platform version, node group scaling configuration, and instance types.

- **IAM permissions:** `eks:ListClusters`, `eks:DescribeCluster`, `eks:ListNodegroups`, `eks:DescribeNodegroup`, `ec2:DescribeRegions`
- **Output:** Two tables: Clusters summary + Node Group detail
- **JSON output:** `output/aws-eks-clusters.json`

```bash
./aws/23-eks-clusters.sh
```

#### `aws/24-lightsail-instances.sh`

Enumerates all Lightsail instances and managed databases across every Lightsail region. Reports the fixed monthly price from the bundle configuration.

- **IAM permissions:** `lightsail:GetInstances`, `lightsail:GetRelationalDatabases`, `lightsail:GetRegions`, `lightsail:GetBundles`, `lightsail:GetRelationalDatabaseBundles`
- **Output:** Table with Region, Name, Type, Blueprint, Bundle, State, Monthly Price
- **JSON output:** `output/aws-lightsail.json`

```bash
./aws/24-lightsail-instances.sh
```

---

### AWS: Storage Inventory (30-34)

#### `aws/30-s3-buckets.sh`

Enumerates all S3 buckets with size (from CloudWatch), object count, versioning status, encryption configuration, and public access audit. Flags buckets with public access enabled and empty buckets.

- **IAM permissions:** `s3:ListAllMyBuckets`, `s3:GetBucketLocation`, `s3:GetBucketVersioning`, `s3:GetBucketEncryption`, `s3:GetBucketPublicAccessBlock`, `s3:GetBucketPolicyStatus`, `cloudwatch:GetMetricStatistics`
- **Output:** Table with Bucket Name, Region, Creation Date, Size, Object Count, Versioning, Encryption, Public Access
- **JSON output:** `output/aws-s3-buckets.json`

```bash
./aws/30-s3-buckets.sh
```

#### `aws/31-ebs-volumes.sh`

Enumerates all EBS volumes across every enabled region. Includes cost estimates based on volume type, size, and provisioned IOPS. Flags unattached ("available") volumes as orphaned.

- **IAM permissions:** `ec2:DescribeVolumes`, `ec2:DescribeRegions`
- **Output:** Table with Region, Volume ID, Name, Size, Type, State, Attached To, IOPS, Throughput, Encrypted, Monthly Est. Cost
- **JSON output:** `output/aws-ebs-volumes.json`

```bash
./aws/31-ebs-volumes.sh
```

#### `aws/32-ebs-snapshots.sh`

Enumerates all EBS snapshots owned by the current account. Flags snapshots older than 180 days and snapshots whose source volume has been deleted.

- **IAM permissions:** `ec2:DescribeSnapshots`, `ec2:DescribeVolumes`, `ec2:DescribeRegions`
- **Output:** Table with Region, Snapshot ID, Volume ID, Size, Start Time, Description, Age, Monthly Est. Cost
- **JSON output:** `output/aws-ebs-snapshots.json`

```bash
./aws/32-ebs-snapshots.sh
```

#### `aws/33-efs-filesystems.sh`

Enumerates all EFS file systems across every enabled region. Reports size, throughput/performance modes, lifecycle policies, mount target count, and monthly cost estimates. Flags EFS file systems with 0 mount targets as potentially unused.

- **IAM permissions:** `elasticfilesystem:DescribeFileSystems`, `elasticfilesystem:DescribeMountTargets`, `elasticfilesystem:DescribeLifecycleConfiguration`, `ec2:DescribeRegions`
- **Output:** Table with Region, File System ID, Name, Size, Throughput Mode, Performance Mode, Lifecycle Policy, Monthly Est. Cost
- **JSON output:** `output/aws-efs.json`

```bash
./aws/33-efs-filesystems.sh
```

#### `aws/34-fsx-filesystems.sh`

Enumerates all FSx file systems (Lustre, Windows File Server, NetApp ONTAP, OpenZFS) across every enabled region. Includes storage capacity, throughput, lifecycle status, and monthly cost estimates.

- **IAM permissions:** `fsx:DescribeFileSystems`, `ec2:DescribeRegions`
- **Output:** Table with Region, File System ID, Type, Storage Capacity, Throughput, Status, Monthly Est. Cost
- **JSON output:** `output/aws-fsx.json`

```bash
./aws/34-fsx-filesystems.sh
```

---

## Shared Libraries

### `lib/colors.sh`

Defines terminal color variables (`RED`, `GREEN`, `YELLOW`, `BLUE`, `BOLD`, `RESET`, etc.) with automatic TTY detection. When stdout is not a terminal (piped or redirected), all color variables are set to empty strings so ANSI escape codes never appear in log files or downstream tooling.

Also provides convenience functions:
- `info "message"` -- cyan `[INFO]` prefix
- `ok "message"` -- green `[ OK ]` prefix
- `warn "message"` -- yellow `[WARN]` prefix, prints to stderr
- `err "message"` -- red `[ ERR]` prefix, prints to stderr
- `section "title"` -- bold section header

### `lib/prereqs.sh`

Provides functions for checking prerequisites:
- `require_bin <name> [min_version]` -- Verify a binary is on PATH, optionally check minimum version
- `require_auth_aws` -- Verify AWS CLI is installed and credentials are valid
- `require_auth_gcp` -- Verify gcloud CLI is installed and an active account is configured
- `require_auth_azure` -- Verify Azure CLI is installed and a session is active

Each function prints actionable remediation messages on failure and returns a non-zero exit code.

### `lib/table.sh`

Portable ASCII and Markdown table formatter. Accepts pipe-delimited rows (first row = header) and produces aligned tables with box-drawing characters.

Features:
- ASCII box-drawing mode (default) and Markdown mode (`--markdown`)
- Configurable maximum column width with ellipsis truncation (`--max-width N`, default 50)
- Input from arguments (one row per argument) or from stdin
- ANSI-aware width calculation (color codes do not affect column alignment)

### `lib/json.sh`

Incremental JSON array builder that works entirely in bash without requiring jq at call sites. Handles proper escaping of special characters.

Functions:
- `json_start_array` -- Begin a new JSON array (resets state)
- `json_add_object "key=value" [...]` -- Append an object; auto-detects numbers, booleans, null
- `json_end_array` -- Finalize the array
- `json_dump` -- Print the JSON array to stdout
- `json_write <file>` -- Write the JSON array to a file (creates parent directories)

Value type rules:
- Numbers are emitted unquoted
- `true`, `false`, `null` are emitted as literals
- Everything else is emitted as a quoted string
- Prefix a value with `s:` to force string type (e.g., `"zip=s:07030"`)

## Output Format

### JSON Schema

Every audit script writes a JSON array of objects to the `output/` directory. Each object represents one resource. Example from `aws-ec2-instances.json`:

```json
[
  {
    "region": "us-east-1",
    "instance_id": "i-0abc123def456789",
    "name": "web-server-prod",
    "type": "t3.medium",
    "state": "running",
    "launch_time": "2025-06-15",
    "private_ip": "10.0.1.42",
    "public_ip": "54.123.45.67",
    "monthly_est_cost": "30.37",
    "is_potential_orphan": false
  }
]
```

Example from `aws-cost-current-month.json`:

```json
[
  {
    "service": "Amazon Elastic Compute Cloud - Compute",
    "cost_usd": 1234.56,
    "percent_of_total": 45.2
  }
]
```

### Table Format

ASCII tables use `+`/`-`/`|` box-drawing characters:

```
+---------------------+------------+---------+
| Service             | Cost (USD) | % Total |
+---------------------+------------+---------+
| Amazon EC2          | 1234.56    | 45.2%   |
| Amazon S3           | 567.89     | 20.8%   |
+---------------------+------------+---------+
```

### Output File Naming

| Script | Output File |
|--------|-------------|
| `01-enumerate-accounts.sh` | `output/aws-accounts.json` |
| `01a-enumerate-regions.sh` | `output/aws-regions.json` |
| `10-cost-current-month.sh` | `output/aws-cost-current-month.json` |
| `11-cost-by-account.sh` | `output/aws-cost-by-account.json` |
| `12-cost-trend.sh` | `output/aws-cost-trend.json` |
| `13-cost-by-tag.sh` | `output/aws-cost-by-tag.json` |
| `20-ec2-instances.sh` | `output/aws-ec2-instances.json` |
| `21-ecs-services.sh` | `output/aws-ecs-services.json` |
| `22-lambda-functions.sh` | `output/aws-lambda-functions.json` |
| `23-eks-clusters.sh` | `output/aws-eks-clusters.json` |
| `24-lightsail-instances.sh` | `output/aws-lightsail.json` |
| `30-s3-buckets.sh` | `output/aws-s3-buckets.json` |
| `31-ebs-volumes.sh` | `output/aws-ebs-volumes.json` |
| `32-ebs-snapshots.sh` | `output/aws-ebs-snapshots.json` |
| `33-efs-filesystems.sh` | `output/aws-efs.json` |
| `34-fsx-filesystems.sh` | `output/aws-fsx.json` |

## Usage Examples

### Run the Full Audit

```bash
# Run everything (all providers, all scripts)
./audit-all.sh

# Pipe all output to a file for later review
./audit-all.sh 2>&1 | tee audit-$(date +%Y%m%d).log
```

### Run Individual Scripts

```bash
# Check prerequisites before running anything
./aws/00-check-prereqs.sh

# Cost reports only
./aws/10-cost-current-month.sh
./aws/11-cost-by-account.sh
./aws/12-cost-trend.sh
./aws/13-cost-by-tag.sh --tag-key Team

# Compute inventory only
./aws/20-ec2-instances.sh
./aws/21-ecs-services.sh
./aws/22-lambda-functions.sh
./aws/23-eks-clusters.sh
./aws/24-lightsail-instances.sh

# Storage inventory only
./aws/30-s3-buckets.sh
./aws/31-ebs-volumes.sh
./aws/32-ebs-snapshots.sh
./aws/33-efs-filesystems.sh
./aws/34-fsx-filesystems.sh
```

### Parse JSON Output with jq

```bash
# Find all orphaned EC2 instances
jq '.[] | select(.is_potential_orphan == true)' output/aws-ec2-instances.json

# Find all public S3 buckets
jq '.[] | select(.is_public == true)' output/aws-s3-buckets.json

# Find orphaned EBS volumes and sum their monthly cost
jq '[.[] | select(.is_orphan == true) | .monthly_est_cost | tonumber] | add' output/aws-ebs-volumes.json

# List old snapshots with deleted source volumes
jq '.[] | select(.is_old == true and .source_volume_exists == false)' output/aws-ebs-snapshots.json

# Get total monthly EC2 cost estimate (running instances with known prices)
jq '[.[] | select(.monthly_est_cost != "N/A" and .monthly_est_cost != "0.00") | .monthly_est_cost | tonumber] | add' output/aws-ec2-instances.json

# Find EFS file systems with no mount targets
jq '.[] | select(.has_no_mounts == true)' output/aws-efs.json

# List Lambda functions not invoked in 90+ days
jq '.[] | select(.is_potential_orphan == true) | {region, function_name, runtime, memory_mb}' output/aws-lambda-functions.json

# Get cost breakdown sorted by service
jq 'sort_by(-.cost_usd) | .[] | "\(.service): $\(.cost_usd)"' output/aws-cost-current-month.json

# Find unencrypted EBS volumes
jq '.[] | select(.encrypted == false)' output/aws-ebs-volumes.json

# Count resources by region across all inventory files
for f in output/aws-ec2-instances.json output/aws-ebs-volumes.json output/aws-efs.json; do
    echo "=== $(basename $f) ==="
    jq 'group_by(.region) | .[] | {region: .[0].region, count: length}' "$f"
done
```

### Generate Markdown Tables

```bash
# Any script's table output can be converted to Markdown by piping through table_print
# First source the library, then pipe data:
source lib/table.sh
echo "Name|Size|Cost" | table_print --markdown

# Or capture JSON and reformat:
jq -r '.[] | "\(.service)|\(.cost_usd)|\(.percent_of_total)%"' output/aws-cost-current-month.json \
  | { echo "Service|Cost (USD)|% of Total"; cat; } \
  | source lib/table.sh && table_print --markdown
```

### Redirect Output

```bash
# Strip colors when piping (automatic -- TTY detection disables colors)
./aws/20-ec2-instances.sh > ec2-report.txt

# View long output with a pager
./aws/31-ebs-volumes.sh 2>&1 | less -R

# Save both stdout and stderr
./aws/30-s3-buckets.sh > s3-report.txt 2> s3-errors.txt
```

### Find Specific Resource Types

```bash
# Find orphaned resources (potential cost savings)
./aws/31-ebs-volumes.sh   # Look for "ORPHANED" in State column
./aws/32-ebs-snapshots.sh # Look for "OLD" and "VOL_GONE" flags
./aws/22-lambda-functions.sh  # Look for "[ORPHAN?]" markers
./aws/20-ec2-instances.sh     # Look for "[ORPHAN?] (no Name tag)"

# Get a cost breakdown for a specific tag
./aws/13-cost-by-tag.sh --tag-key Project
./aws/13-cost-by-tag.sh --tag-key Environment
./aws/13-cost-by-tag.sh --tag-key CostCenter
```

## Extending the Tool

To add a new audit script following the existing patterns:

### 1. Create the Script

```bash
#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# XX-my-new-check.sh -- Description of what this checks
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/colors.sh"
source "${SCRIPT_DIR}/../lib/prereqs.sh"
source "${SCRIPT_DIR}/../lib/table.sh"
source "${SCRIPT_DIR}/../lib/json.sh"

OUTPUT_DIR="${SCRIPT_DIR}/../output"
OUTPUT_FILE="${OUTPUT_DIR}/aws-my-new-check.json"

# Prerequisites
section "Prerequisites"
require_bin aws  || exit 1
require_bin jq   || exit 1
require_auth_aws || exit 1

# Discover regions (if multi-region)
regions_raw=""
if ! regions_raw="$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text 2>&1)"; then
    err "Failed to list AWS regions: ${regions_raw}"
    exit 1
fi
read -ra REGIONS <<< "$regions_raw"

# Initialize JSON and table
json_start_array
table_rows=()
table_rows+=("Col1|Col2|Col3")

# Iterate and collect data
for region in "${REGIONS[@]}"; do
    info "Scanning region: ${region}..."

    # Your AWS API calls here...
    # Handle errors gracefully:
    #   - Permission denied: warn and skip
    #   - Service not available: silently skip
    #   - Other errors: warn and skip

    # Add to table
    table_rows+=("val1|val2|val3")

    # Add to JSON
    json_add_object \
        "field1=s:${val1}" \
        "field2=${val2}" \
        "field3=${val3}"
done

json_end_array

# Output
section "Summary"
printf '%s\n' "${table_rows[@]}" | table_print

mkdir -p "$OUTPUT_DIR"
json_write "$OUTPUT_FILE"
ok "JSON written to ${OUTPUT_FILE}"
```

### 2. Naming Convention

- `00-09`: Prerequisites and enumeration
- `10-19`: Cost reports
- `20-29`: Compute inventory
- `30-39`: Storage inventory
- `40-49`: Network inventory (planned)
- `50-59`: Database inventory (planned)

### 3. Key Patterns to Follow

- Always check prerequisites at the top (`require_bin`, `require_auth_aws`)
- Always handle API errors gracefully (check for `AccessDenied`, service unavailability)
- Always produce both table output and JSON output
- Use `s:` prefix for string values that might look like numbers (e.g., account IDs)
- Use `section`, `info`, `ok`, `warn`, `err` for consistent messaging
- Clean up null/empty values from AWS API responses before display
- Flag orphaned/unused resources for easy identification

## Troubleshooting

### "AWS credentials are not configured or have expired"

```bash
# Check if credentials are set
aws sts get-caller-identity

# If using SSO, re-authenticate
aws sso login --profile your-profile

# If using environment variables, verify they are set
echo $AWS_ACCESS_KEY_ID
echo $AWS_DEFAULT_REGION
```

### "AWS Cost Explorer is not enabled for this account"

Cost Explorer must be enabled in the AWS Console before the cost scripts (10-13) can run. Go to **Billing > Cost Explorer > Enable Cost Explorer**. Data takes up to 24 hours to become available after enabling.

### "Permission denied: ce:GetCostAndUsage is required"

The cost scripts require the `ce:GetCostAndUsage` permission. This is not included in common policies like `ReadOnlyAccess`. You need to explicitly grant it:

```json
{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Action": "ce:GetCostAndUsage",
        "Resource": "*"
    }]
}
```

### "No cost data found for tag key 'X'"

The tag must be activated as a **cost allocation tag** in the Billing console: **Billing > Cost Allocation Tags > Activate**. AWS-generated tags and user-defined tags must be separately activated. It can take up to 24 hours for tag data to appear after activation.

### "Failed to list AWS regions"

The `ec2:DescribeRegions` permission is required. This is included in `ReadOnlyAccess` and most EC2 policies.

### Scripts run very slowly

The region-scanning scripts make API calls sequentially across all enabled regions (15+). This is by design to avoid rate limiting, but can take 10-30+ minutes for a full audit. To speed things up:

- Run only the scripts you need instead of `audit-all.sh`
- The S3 bucket script is typically the slowest (CloudWatch calls per bucket)
- Lambda orphan detection is also slow (CloudWatch call per function)

### "bc: command not found"

Install `bc`:
```bash
# Debian/Ubuntu
sudo apt install bc

# macOS
brew install bc

# Amazon Linux / RHEL
sudo yum install bc
```

### "jq: command not found"

Install `jq`:
```bash
# Debian/Ubuntu
sudo apt install jq

# macOS
brew install jq

# Amazon Linux / RHEL
sudo yum install jq
```

### Date computation errors on macOS

Several scripts use GNU `date` syntax (`date -d`). macOS ships BSD `date` which uses different flags. Install GNU coreutils:

```bash
brew install coreutils
# Then use gdate instead of date, or add to PATH:
export PATH="/opt/homebrew/opt/coreutils/libexec/gnubin:$PATH"
```

## Required IAM Permissions

### Minimum for Cost Reports (10-13)

```
ce:GetCostAndUsage
sts:GetCallerIdentity
organizations:DescribeOrganization    (optional, for cost-by-account)
organizations:ListAccounts            (optional, for account names)
```

### Minimum for Compute Inventory (20-24)

```
ec2:DescribeInstances
ec2:DescribeRegions
ecs:ListClusters
ecs:ListServices
ecs:DescribeServices
ecs:DescribeTaskDefinition
lambda:ListFunctions
cloudwatch:GetMetricStatistics
eks:ListClusters
eks:DescribeCluster
eks:ListNodegroups
eks:DescribeNodegroup
lightsail:GetInstances
lightsail:GetRelationalDatabases
lightsail:GetRegions
lightsail:GetBundles
lightsail:GetRelationalDatabaseBundles
```

### Minimum for Storage Inventory (30-34)

```
s3:ListAllMyBuckets
s3:GetBucketLocation
s3:GetBucketVersioning
s3:GetBucketEncryption
s3:GetBucketPublicAccessBlock
s3:GetBucketPolicyStatus
cloudwatch:GetMetricStatistics
ec2:DescribeVolumes
ec2:DescribeSnapshots
ec2:DescribeRegions
elasticfilesystem:DescribeFileSystems
elasticfilesystem:DescribeMountTargets
elasticfilesystem:DescribeLifecycleConfiguration
fsx:DescribeFileSystems
```

### Full Audit (All Scripts)

For convenience, the `ReadOnlyAccess` AWS managed policy covers most permissions except Cost Explorer. A complete custom policy:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "CloudCostAudit",
            "Effect": "Allow",
            "Action": [
                "ce:GetCostAndUsage",
                "ec2:DescribeInstances",
                "ec2:DescribeRegions",
                "ec2:DescribeVolumes",
                "ec2:DescribeSnapshots",
                "ecs:ListClusters",
                "ecs:ListServices",
                "ecs:DescribeServices",
                "ecs:DescribeTaskDefinition",
                "eks:ListClusters",
                "eks:DescribeCluster",
                "eks:ListNodegroups",
                "eks:DescribeNodegroup",
                "elasticfilesystem:DescribeFileSystems",
                "elasticfilesystem:DescribeMountTargets",
                "elasticfilesystem:DescribeLifecycleConfiguration",
                "fsx:DescribeFileSystems",
                "iam:ListAccountAliases",
                "lambda:ListFunctions",
                "lightsail:GetBundles",
                "lightsail:GetInstances",
                "lightsail:GetRegions",
                "lightsail:GetRelationalDatabaseBundles",
                "lightsail:GetRelationalDatabases",
                "organizations:DescribeOrganization",
                "organizations:ListAccounts",
                "cloudwatch:GetMetricStatistics",
                "s3:GetBucketEncryption",
                "s3:GetBucketLocation",
                "s3:GetBucketPolicyStatus",
                "s3:GetBucketPublicAccessBlock",
                "s3:GetBucketVersioning",
                "s3:ListAllMyBuckets",
                "sts:GetCallerIdentity"
            ],
            "Resource": "*"
        }
    ]
}
```

## License

Internal use only. See your organization's policies for details.
