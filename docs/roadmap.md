# Cloud Cost Auditing Tools -- Roadmap

**Goal:** Build a suite of CLI-based auditing tools that enumerate all billable resources across AWS, GCP, and Azure, surface current costs and trends, and detect orphaned or forgotten resources still incurring charges.

**Design Principles:**
- Each cloud provider gets its own directory of scripts (`aws/`, `gcp/`, `azure/`).
- Scripts are bash, wrapping the respective provider CLI (`aws`, `gcloud`, `az`). Terraform is used only where data sources provide cleaner enumeration than CLI (e.g., account/project listing via Terraform providers).
- All output is human-readable, formatted in aligned tables printed to stdout. Scripts also emit a machine-readable JSON sidecar (`.json`) for downstream aggregation.
- No assumptions about pre-installed tools. Every script validates its own prerequisites before executing.
- Authentication is the user's responsibility. Scripts verify that valid credentials exist and fail fast with clear instructions if they do not.

**Notation:**
- `[script]` -- a standalone bash script to be written.
- `[tf]` -- a Terraform configuration to be written.
- `[lib]` -- a shared library/helper sourced by other scripts.

---

## Milestone 0: Project Scaffolding and Shared Utilities ✅ COMPLETED

Set up the repository structure and shared helpers that all provider-specific scripts depend on.

- [x] Create directory structure:
  ```
  cloud-audit/
    lib/
      prereqs.sh        # shared prerequisite-checking functions
      table.sh          # shared table-formatting functions (column, printf)
      json.sh           # shared JSON output helpers
      colors.sh         # terminal color definitions
    aws/
    gcp/
    azure/
    summary/
    output/             # default output directory for JSON sidecars
    README.md
  ```
- [x] `[lib]` `lib/prereqs.sh` -- Functions to check whether a binary exists and is a minimum version. Functions: `require_bin <name> [min_version]`, `require_auth_aws`, `require_auth_gcp`, `require_auth_azure`. Each prints a clear remediation message on failure and returns non-zero.
- [x] `[lib]` `lib/table.sh` -- Portable table formatter. Takes a header row and data rows (pipe-delimited), prints an aligned ASCII table with column separators. Must handle wide Unicode and long strings gracefully (truncate with ellipsis at configurable max width). Also supports a `--markdown` flag to emit a Markdown table instead.
- [x] `[lib]` `lib/json.sh` -- Helpers to build a JSON array of objects incrementally from bash without requiring `jq` at call sites. Functions: `json_start_array`, `json_add_object <key=val ...>`, `json_end_array`, `json_write <file>`.
- [x] `[lib]` `lib/colors.sh` -- Define terminal color variables (`RED`, `GREEN`, `YELLOW`, `BOLD`, `RESET`). Automatically disable colors when stdout is not a TTY (piped or redirected).
- [x] Write a top-level `README.md` explaining the project, prerequisites, and how to run each provider's audit independently or all together.
- [x] Write a top-level `audit-all.sh` orchestrator that runs all three providers (skipping any whose CLI/auth is not configured) and then runs the cross-cloud summary.

---

## Milestone 1: AWS -- Prerequisites and Account Enumeration ✅ COMPLETED

- [x] `[script]` `aws/00-check-prereqs.sh` -- Verify:
  - `aws` CLI is installed (v2 preferred, v1 accepted with warning).
  - `jq` is installed (required for JSON parsing).
  - `column` is available (fallback to printf if not).
  - AWS credentials are configured and valid (`aws sts get-caller-identity` succeeds).
  - Print the authenticated identity (account ID, ARN, user/role) in a summary box.
  - If running in an AWS Organization, detect and report whether the caller has `organizations:ListAccounts` permission.
- [x] `[script]` `aws/01-enumerate-accounts.sh` -- If the caller has Organizations access:
  - List all accounts in the organization with: Account ID, Account Name, Email, Status (ACTIVE/SUSPENDED), Joined Date.
  - Output: table to stdout, JSON to `output/aws-accounts.json`.
  - If not in an Organization, report the single account from `sts get-caller-identity`.
- [x] `[script]` `aws/01a-enumerate-regions.sh` -- List all enabled regions for the account. Many audit scripts will iterate over regions; this script produces the canonical region list.
  - Output: one region per line to stdout, JSON array to `output/aws-regions.json`.
  - Accept `--all` flag to include opt-in regions, or default to only enabled regions.

---

## Milestone 2: AWS -- Cost and Billing Audit ✅ COMPLETED

- [x] `[script]` `aws/10-cost-current-month.sh` -- Query AWS Cost Explorer for the current calendar month:
  - Total unblended cost, broken down by service (top 20 services).
  - Columns: Service, Cost (USD), % of Total.
  - Requires `ce:GetCostAndUsage` permission. Detect and report if Cost Explorer is not enabled.
  - Output: table + `output/aws-cost-current-month.json`.
- [x] `[script]` `aws/11-cost-by-account.sh` -- Query Cost Explorer grouped by linked account:
  - Columns: Account ID, Account Name, Cost (USD), % of Total.
  - Only meaningful in an Organization with consolidated billing; warn and skip otherwise.
  - Output: table + `output/aws-cost-by-account.json`.
- [x] `[script]` `aws/12-cost-trend.sh` -- Query Cost Explorer for the last 6 months:
  - Columns: Month, Total Cost (USD), Delta vs Previous Month (USD), Delta (%).
  - Highlight months with >20% increase in red.
  - Output: table + `output/aws-cost-trend.json`.
- [x] `[script]` `aws/13-cost-by-tag.sh` -- Query Cost Explorer grouped by a user-specified tag key (default: `Environment`):
  - Columns: Tag Value, Cost (USD), % of Total.
  - Accept `--tag-key <key>` argument.
  - Output: table + `output/aws-cost-by-tag.json`.

---

## Milestone 3: AWS -- Compute Resource Inventory ✅ COMPLETED

- [x] `[script]` `aws/20-ec2-instances.sh` -- Enumerate all EC2 instances across all enabled regions:
  - Columns: Region, Instance ID, Name (from tag), Type, State, Launch Time, Private IP, Public IP, Monthly Est. Cost.
  - Estimate monthly cost using on-demand pricing for the instance type (embed a lookup table for common types or query the Pricing API).
  - Flag instances in `running` state with no Name tag as potential orphans.
  - Output: table + `output/aws-ec2-instances.json`.
- [x] `[script]` `aws/21-ecs-services.sh` -- Enumerate ECS clusters, services, and running tasks:
  - Columns: Region, Cluster, Service, Launch Type (EC2/FARGATE), Running Tasks, CPU, Memory, Status.
  - For Fargate tasks, estimate monthly cost from vCPU/memory configuration.
  - Output: table + `output/aws-ecs-services.json`.
- [x] `[script]` `aws/22-lambda-functions.sh` -- Enumerate all Lambda functions:
  - Columns: Region, Function Name, Runtime, Memory (MB), Timeout (s), Last Invoked, Code Size.
  - Flag functions not invoked in >90 days as potentially orphaned (requires CloudWatch `GetMetricStatistics`).
  - Output: table + `output/aws-lambda-functions.json`.
- [x] `[script]` `aws/23-eks-clusters.sh` -- Enumerate all EKS clusters:
  - Columns: Region, Cluster Name, Version, Status, Node Groups (count), Total Nodes, Platform Version.
  - For each managed node group: Instance Type, Desired/Min/Max, Current Count.
  - Output: table + `output/aws-eks-clusters.json`.
- [x] `[script]` `aws/24-lightsail-instances.sh` -- Enumerate Lightsail instances and databases:
  - Columns: Region, Name, Blueprint, Bundle (size), State, Monthly Price.
  - Output: table + `output/aws-lightsail.json`.

---

## Milestone 4: AWS -- Storage Resource Inventory ✅ COMPLETED

- [x] `[script]` `aws/30-s3-buckets.sh` -- Enumerate all S3 buckets:
  - Columns: Bucket Name, Region, Creation Date, Size (from CloudWatch `BucketSizeBytes`), Object Count, Storage Class breakdown, Versioning, Encryption, Public Access.
  - Flag buckets with public access enabled or block public access disabled.
  - Flag buckets with no objects or zero size as potential cleanup candidates.
  - Output: table + `output/aws-s3-buckets.json`.
- [x] `[script]` `aws/31-ebs-volumes.sh` -- Enumerate all EBS volumes across regions:
  - Columns: Region, Volume ID, Name, Size (GB), Type (gp3/io2/etc.), State, Attached To, IOPS, Throughput, Encrypted, Monthly Est. Cost.
  - Flag volumes in `available` state (not attached to any instance) as orphaned.
  - Output: table + `output/aws-ebs-volumes.json`.
- [x] `[script]` `aws/32-ebs-snapshots.sh` -- Enumerate all EBS snapshots owned by the account:
  - Columns: Region, Snapshot ID, Volume ID, Size (GB), Start Time, Description, Age (days), Monthly Est. Cost.
  - Flag snapshots older than 180 days.
  - Flag snapshots whose source volume no longer exists.
  - Output: table + `output/aws-ebs-snapshots.json`.
- [x] `[script]` `aws/33-efs-filesystems.sh` -- Enumerate EFS file systems:
  - Columns: Region, File System ID, Name, Size (from `describe-file-systems`), Throughput Mode, Performance Mode, Lifecycle Policy, Monthly Est. Cost.
  - Flag EFS file systems with 0 mount targets.
  - Output: table + `output/aws-efs.json`.
- [x] `[script]` `aws/34-fsx-filesystems.sh` -- Enumerate FSx file systems (Lustre, Windows, NetApp ONTAP, OpenZFS):
  - Columns: Region, File System ID, Type, Storage Capacity (GB), Throughput, Status, Monthly Est. Cost.
  - Output: table + `output/aws-fsx.json`.

---

## Milestone 5: AWS -- Database Resource Inventory

- [ ] `[script]` `aws/40-rds-instances.sh` -- Enumerate all RDS instances and clusters:
  - Columns: Region, DB Identifier, Engine, Engine Version, Instance Class, Multi-AZ, Storage (GB), Storage Type, Status, Monthly Est. Cost.
  - Flag stopped instances (still incur storage costs).
  - Flag instances with no recent connections (CloudWatch `DatabaseConnections` metric = 0 for 14+ days).
  - Output: table + `output/aws-rds.json`.
- [ ] `[script]` `aws/41-dynamodb-tables.sh` -- Enumerate all DynamoDB tables:
  - Columns: Region, Table Name, Billing Mode (on-demand/provisioned), RCU, WCU, Size (bytes), Item Count, GSI Count, Status, Monthly Est. Cost.
  - Flag tables with provisioned capacity that have had zero consumed capacity for 30+ days.
  - Output: table + `output/aws-dynamodb.json`.
- [ ] `[script]` `aws/42-elasticache-clusters.sh` -- Enumerate ElastiCache clusters (Redis, Memcached):
  - Columns: Region, Cluster ID, Engine, Node Type, Num Nodes, Status, Multi-AZ, Monthly Est. Cost.
  - Output: table + `output/aws-elasticache.json`.
- [ ] `[script]` `aws/43-redshift-clusters.sh` -- Enumerate Redshift clusters:
  - Columns: Region, Cluster ID, Node Type, Num Nodes, Status, Encrypted, Monthly Est. Cost.
  - Flag paused clusters (still incur storage costs).
  - Output: table + `output/aws-redshift.json`.
- [ ] `[script]` `aws/44-opensearch-domains.sh` -- Enumerate OpenSearch (Elasticsearch) domains:
  - Columns: Region, Domain Name, Engine Version, Instance Type, Instance Count, Storage (GB), Status, Monthly Est. Cost.
  - Output: table + `output/aws-opensearch.json`.

---

## Milestone 6: AWS -- Networking Resource Inventory

- [ ] `[script]` `aws/50-elastic-ips.sh` -- Enumerate all Elastic IPs:
  - Columns: Region, Allocation ID, Public IP, Associated Instance/ENI, Domain (vpc/classic).
  - Flag unassociated EIPs (these incur hourly charges when not attached).
  - Output: table + `output/aws-eips.json`.
- [ ] `[script]` `aws/51-load-balancers.sh` -- Enumerate ALBs, NLBs, CLBs, and GLBs:
  - Columns: Region, Name, Type (ALB/NLB/CLB/GLB), Scheme (internet-facing/internal), State, Target Groups, Healthy Targets, DNS Name, Monthly Est. Cost.
  - Flag load balancers with zero healthy targets across all target groups.
  - Flag Classic Load Balancers (migration candidates).
  - Output: table + `output/aws-load-balancers.json`.
- [ ] `[script]` `aws/52-nat-gateways.sh` -- Enumerate NAT Gateways:
  - Columns: Region, NAT Gateway ID, Name, State, Subnet, VPC, Public IP, Monthly Est. Cost.
  - NAT Gateways are ~$32/month + data processing; flag any in non-production VPCs.
  - Output: table + `output/aws-nat-gateways.json`.
- [ ] `[script]` `aws/53-vpn-connections.sh` -- Enumerate Site-to-Site VPN connections and Client VPN endpoints:
  - Columns: Region, VPN ID, Type, State, Customer Gateway, Monthly Est. Cost.
  - Output: table + `output/aws-vpn.json`.
- [ ] `[script]` `aws/54-transit-gateways.sh` -- Enumerate Transit Gateways and attachments:
  - Columns: Region, TGW ID, Name, State, Attachment Count, Monthly Est. Cost.
  - Output: table + `output/aws-transit-gateways.json`.
- [ ] `[script]` `aws/55-cloudfront-distributions.sh` -- Enumerate CloudFront distributions:
  - Columns: Distribution ID, Domain, Aliases, Status, Price Class, Origin Count, Last Modified.
  - Flag distributions with `Disabled` status that still exist (configuration cost is zero, but worth noting for cleanup).
  - Output: table + `output/aws-cloudfront.json`.

---

## Milestone 7: AWS -- Other Billable Resources

- [ ] `[script]` `aws/60-route53-zones.sh` -- Enumerate Route 53 hosted zones:
  - Columns: Zone ID, Domain, Type (Public/Private), Record Count, Monthly Cost ($0.50/zone).
  - Output: table + `output/aws-route53.json`.
- [ ] `[script]` `aws/61-secrets-manager.sh` -- Enumerate Secrets Manager secrets:
  - Columns: Region, Secret Name, Last Accessed, Last Rotated, Monthly Cost ($0.40/secret).
  - Flag secrets not accessed in >180 days.
  - Output: table + `output/aws-secrets.json`.
- [ ] `[script]` `aws/62-kms-keys.sh` -- Enumerate KMS customer-managed keys:
  - Columns: Region, Key ID, Alias, State, Creation Date, Monthly Cost ($1/key).
  - Flag disabled keys that still exist (consider scheduling deletion).
  - Output: table + `output/aws-kms.json`.
- [ ] `[script]` `aws/63-cloudwatch-log-groups.sh` -- Enumerate CloudWatch Log Groups:
  - Columns: Region, Log Group, Stored Bytes, Retention (days), Last Ingestion Time.
  - Flag log groups with no retention policy set (infinite retention = unbounded cost growth).
  - Flag log groups with no ingestion in 90+ days.
  - Output: table + `output/aws-cloudwatch-logs.json`.
- [ ] `[script]` `aws/64-sagemaker-endpoints.sh` -- Enumerate SageMaker endpoints and notebook instances:
  - Columns: Region, Name, Type (Endpoint/Notebook), Instance Type, Status, Creation Time, Monthly Est. Cost.
  - Flag `InService` notebook instances (commonly forgotten and expensive).
  - Output: table + `output/aws-sagemaker.json`.
- [ ] `[script]` `aws/65-sqs-sns.sh` -- Enumerate SQS queues and SNS topics:
  - Columns: Region, Name, Type (SQS/SNS), Messages Available (SQS), Subscriptions (SNS), Age.
  - Flag SQS queues with zero messages sent/received in 30+ days.
  - Output: table + `output/aws-sqs-sns.json`.
- [ ] `[script]` `aws/66-ecr-repositories.sh` -- Enumerate ECR repositories:
  - Columns: Region, Repository, Image Count, Total Size, Lifecycle Policy (yes/no), Last Push.
  - Flag repositories with no lifecycle policy (image accumulation = cost growth).
  - Flag repositories with no pushes in 180+ days.
  - Output: table + `output/aws-ecr.json`.

---

## Milestone 8: AWS -- Orphaned and Unused Resource Detection

This milestone produces a consolidated orphan/waste report by aggregating findings from previous scripts and running additional targeted checks.

- [ ] `[script]` `aws/70-orphan-report.sh` -- Aggregation script that:
  - Reads JSON output from all previous AWS scripts.
  - Collects all flagged orphaned/unused resources into a single report.
  - Adds additional checks not covered above:
    - AMIs owned by the account that are not referenced by any launch template or instance.
    - Elastic Network Interfaces in `available` state not attached to anything.
    - Old snapshots with no associated AMI or volume.
    - Unused Elastic Beanstalk environments.
    - Empty Auto Scaling Groups (desired=0, no scheduled actions).
  - Output: prioritized table sorted by estimated monthly waste, highest first.
  - Columns: Resource Type, Resource ID, Region, Name/Description, Reason Flagged, Est. Monthly Waste (USD).
  - Output: table + `output/aws-orphan-report.json`.
- [ ] `[script]` `aws/71-cost-anomalies.sh` -- Highlight resources whose cost is disproportionate:
  - Compare per-resource estimated cost against the service-level Cost Explorer data.
  - Flag any single resource estimated at >10% of its service's total cost.
  - Output: table + `output/aws-cost-anomalies.json`.

---

## Milestone 9: GCP -- Prerequisites and Project Enumeration

- [ ] `[script]` `gcp/00-check-prereqs.sh` -- Verify:
  - `gcloud` CLI is installed and in PATH (minimum version 400.0.0).
  - `jq` is installed.
  - `gcloud auth list` shows an active account.
  - `gcloud config get-value project` returns a valid default project.
  - Print the authenticated identity, default project, and organization (if any).
- [ ] `[script]` `gcp/01-enumerate-projects.sh` -- List all accessible projects:
  - Columns: Project ID, Project Name, Project Number, State, Create Time, Labels.
  - If the caller has Organization-level access, group projects by folder hierarchy.
  - Output: table + `output/gcp-projects.json`.
- [ ] `[script]` `gcp/01a-enumerate-billing-accounts.sh` -- List billing accounts and their linked projects:
  - Columns: Billing Account ID, Display Name, Open (yes/no), Linked Projects (count).
  - Output: table + `output/gcp-billing-accounts.json`.

---

## Milestone 10: GCP -- Cost and Billing Audit

- [ ] `[script]` `gcp/10-cost-current-month.sh` -- Query Cloud Billing Budget API or BigQuery billing export (if configured) for the current month:
  - Columns: Service, Cost (USD), % of Total.
  - If BigQuery billing export is available, use it (more granular). Otherwise, fall back to `gcloud billing budgets list` for high-level data and inform the user that BigQuery export provides richer data.
  - Accept `--billing-account <id>` or detect from the default project.
  - Output: table + `output/gcp-cost-current-month.json`.
- [ ] `[script]` `gcp/11-cost-by-project.sh` -- Break down costs by project (requires BigQuery billing export):
  - Columns: Project ID, Project Name, Cost (USD), % of Total.
  - If BigQuery export is not configured, print instructions for enabling it and exit gracefully.
  - Output: table + `output/gcp-cost-by-project.json`.
- [ ] `[script]` `gcp/12-cost-trend.sh` -- Query last 6 months of billing data:
  - Columns: Month, Total Cost (USD), Delta vs Previous Month (USD), Delta (%).
  - Output: table + `output/gcp-cost-trend.json`.
- [ ] `[script]` `gcp/13-cost-by-label.sh` -- Break down costs by a user-specified label key (default: `env`):
  - Accept `--label-key <key>` argument.
  - Requires BigQuery billing export.
  - Output: table + `output/gcp-cost-by-label.json`.

---

## Milestone 11: GCP -- Compute Resource Inventory

- [ ] `[script]` `gcp/20-compute-instances.sh` -- Enumerate all Compute Engine instances across all projects the caller can access:
  - Columns: Project, Zone, Name, Machine Type, Status, Internal IP, External IP, Disks (count), Preemptible, Monthly Est. Cost.
  - Iterate over all projects from `gcp/01-enumerate-projects.sh` output (or accept `--project <id>`).
  - Flag instances in TERMINATED state that have persistent disks still attached.
  - Output: table + `output/gcp-compute-instances.json`.
- [ ] `[script]` `gcp/21-gke-clusters.sh` -- Enumerate GKE clusters:
  - Columns: Project, Location, Cluster Name, Version, Status, Node Pools, Total Nodes, Autopilot (yes/no), Monthly Est. Cost.
  - For each node pool: Machine Type, Node Count (current/min/max), Preemptible/Spot.
  - Output: table + `output/gcp-gke-clusters.json`.
- [ ] `[script]` `gcp/22-cloud-run-services.sh` -- Enumerate Cloud Run services and jobs:
  - Columns: Project, Region, Service/Job Name, Last Deployed, Container Image, CPU, Memory, Min/Max Instances, Request Count (30d).
  - Flag services with zero requests in the last 30 days.
  - Output: table + `output/gcp-cloud-run.json`.
- [ ] `[script]` `gcp/23-cloud-functions.sh` -- Enumerate Cloud Functions (v1 and v2):
  - Columns: Project, Region, Function Name, Runtime, Memory, Timeout, Status, Last Invocation, Generation (v1/v2).
  - Flag functions not invoked in 90+ days.
  - Output: table + `output/gcp-cloud-functions.json`.
- [ ] `[script]` `gcp/24-app-engine.sh` -- Enumerate App Engine applications and services:
  - Columns: Project, Service, Version, Traffic %, Instance Class, Status, Serving Status.
  - Flag non-default versions still serving traffic or still deployed.
  - Output: table + `output/gcp-app-engine.json`.

---

## Milestone 12: GCP -- Storage Resource Inventory

- [ ] `[script]` `gcp/30-gcs-buckets.sh` -- Enumerate Cloud Storage buckets:
  - Columns: Project, Bucket Name, Location, Storage Class, Size, Object Count, Versioning, Lifecycle Rules (count), Public Access, Created.
  - Flag buckets with `allUsers` or `allAuthenticatedUsers` IAM bindings.
  - Flag buckets with no lifecycle rules (unbounded cost growth).
  - Output: table + `output/gcp-gcs-buckets.json`.
- [ ] `[script]` `gcp/31-persistent-disks.sh` -- Enumerate Persistent Disks and their attachment status:
  - Columns: Project, Zone, Disk Name, Size (GB), Type (pd-standard/pd-ssd/pd-balanced), Status, Attached To, Encrypted, Monthly Est. Cost.
  - Flag disks not attached to any instance.
  - Output: table + `output/gcp-persistent-disks.json`.
- [ ] `[script]` `gcp/32-snapshots.sh` -- Enumerate disk snapshots:
  - Columns: Project, Snapshot Name, Source Disk, Size (GB), Status, Creation Time, Age (days), Monthly Est. Cost.
  - Flag snapshots older than 180 days.
  - Flag snapshots whose source disk no longer exists.
  - Output: table + `output/gcp-snapshots.json`.
- [ ] `[script]` `gcp/33-filestore.sh` -- Enumerate Filestore instances:
  - Columns: Project, Location, Instance Name, Tier, Capacity (TB), Status, Network, Monthly Est. Cost.
  - Output: table + `output/gcp-filestore.json`.

---

## Milestone 13: GCP -- Database Resource Inventory

- [ ] `[script]` `gcp/40-cloud-sql.sh` -- Enumerate Cloud SQL instances:
  - Columns: Project, Region, Instance Name, DB Engine, Tier, Storage (GB), Storage Type, HA (yes/no), State, Monthly Est. Cost.
  - Flag stopped instances.
  - Flag instances with zero connections in 14+ days (Cloud Monitoring).
  - Output: table + `output/gcp-cloud-sql.json`.
- [ ] `[script]` `gcp/41-bigquery-datasets.sh` -- Enumerate BigQuery datasets and estimate storage costs:
  - Columns: Project, Dataset ID, Location, Table Count, Total Size (logical), Total Size (physical/compressed), Default Partition Expiration, Monthly Est. Cost.
  - Flag datasets with no query activity in 90+ days (via INFORMATION_SCHEMA.JOBS if accessible).
  - Output: table + `output/gcp-bigquery.json`.
- [ ] `[script]` `gcp/42-spanner-instances.sh` -- Enumerate Cloud Spanner instances:
  - Columns: Project, Instance ID, Config, Node Count / Processing Units, State, Monthly Est. Cost.
  - Spanner is expensive; flag instances in any non-production project.
  - Output: table + `output/gcp-spanner.json`.
- [ ] `[script]` `gcp/43-memorystore.sh` -- Enumerate Memorystore instances (Redis, Memcached):
  - Columns: Project, Region, Instance ID, Engine, Tier, Memory (GB), State, Monthly Est. Cost.
  - Output: table + `output/gcp-memorystore.json`.
- [ ] `[script]` `gcp/44-firestore-bigtable.sh` -- Enumerate Firestore databases and Bigtable instances:
  - Columns: Project, Database/Instance Name, Type, Location, State, Monthly Est. Cost.
  - Output: table + `output/gcp-firestore-bigtable.json`.

---

## Milestone 14: GCP -- Networking Resource Inventory

- [ ] `[script]` `gcp/50-external-ips.sh` -- Enumerate static external IP addresses:
  - Columns: Project, Region, Name, Address, Status, In Use By.
  - Flag RESERVED (not in use) static IPs (charged at $0.01/hr when idle).
  - Output: table + `output/gcp-external-ips.json`.
- [ ] `[script]` `gcp/51-load-balancers.sh` -- Enumerate load balancers (forwarding rules, backend services, URL maps):
  - Columns: Project, Name, Type (HTTP(S)/TCP/UDP/Internal), Scheme, IP, Backends (count), Healthy Backends, Monthly Est. Cost.
  - Flag load balancers with zero healthy backends.
  - Output: table + `output/gcp-load-balancers.json`.
- [ ] `[script]` `gcp/52-cloud-nat.sh` -- Enumerate Cloud NAT gateways:
  - Columns: Project, Region, Router, NAT Name, IP Allocation, Status, Monthly Est. Cost.
  - Output: table + `output/gcp-cloud-nat.json`.
- [ ] `[script]` `gcp/53-vpn-interconnects.sh` -- Enumerate Cloud VPN tunnels and Interconnect attachments:
  - Columns: Project, Region, Name, Type (VPN/Interconnect), Status, Bandwidth, Monthly Est. Cost.
  - Output: table + `output/gcp-vpn-interconnects.json`.
- [ ] `[script]` `gcp/54-cloud-cdn.sh` -- Enumerate Cloud CDN-enabled backend services:
  - Columns: Project, Backend Service, CDN Enabled, Cache Mode, Origin.
  - Output: table + `output/gcp-cloud-cdn.json`.

---

## Milestone 15: GCP -- Other Billable Resources

- [ ] `[script]` `gcp/60-dns-zones.sh` -- Enumerate Cloud DNS managed zones:
  - Columns: Project, Zone Name, DNS Name, Visibility, Record Set Count, Monthly Cost.
  - Output: table + `output/gcp-dns.json`.
- [ ] `[script]` `gcp/61-secret-manager.sh` -- Enumerate Secret Manager secrets:
  - Columns: Project, Secret Name, Version Count, Last Accessed, Monthly Cost.
  - Flag secrets not accessed in 180+ days.
  - Output: table + `output/gcp-secrets.json`.
- [ ] `[script]` `gcp/62-kms-keys.sh` -- Enumerate Cloud KMS keys:
  - Columns: Project, Key Ring, Key Name, Purpose, State, Protection Level, Monthly Cost.
  - Flag disabled keys.
  - Output: table + `output/gcp-kms.json`.
- [ ] `[script]` `gcp/63-logging.sh` -- Enumerate Log Router sinks and log storage:
  - Columns: Project, Sink Name, Destination, Filter, Volume Estimate.
  - Flag sinks routing to BigQuery or Cloud Storage with no exclusion filters (potential cost amplification).
  - Output: table + `output/gcp-logging.json`.
- [ ] `[script]` `gcp/64-ai-platform.sh` -- Enumerate Vertex AI endpoints, models, and notebook instances:
  - Columns: Project, Region, Name, Type (Endpoint/Notebook/Training Job), Machine Type, Status, Monthly Est. Cost.
  - Flag running notebook instances and deployed endpoints.
  - Output: table + `output/gcp-ai-platform.json`.
- [ ] `[script]` `gcp/65-pubsub.sh` -- Enumerate Pub/Sub topics and subscriptions:
  - Columns: Project, Topic/Subscription Name, Type, Message Retention, Subscription Count (topics), Unacked Messages (subscriptions).
  - Flag subscriptions with large backlogs (>1M unacked messages).
  - Output: table + `output/gcp-pubsub.json`.

---

## Milestone 16: GCP -- Orphaned and Unused Resource Detection

- [ ] `[script]` `gcp/70-orphan-report.sh` -- Aggregation script, same pattern as the AWS equivalent:
  - Reads all JSON output from previous GCP scripts.
  - Additional checks:
    - Unused service account keys older than 90 days.
    - Custom images not referenced by any instance template.
    - Unattached persistent disks.
    - Instance templates not referenced by any instance group.
  - Output: prioritized table sorted by estimated monthly waste.
  - Columns: Resource Type, Resource ID, Project, Zone/Region, Name, Reason Flagged, Est. Monthly Waste (USD).
  - Output: table + `output/gcp-orphan-report.json`.

---

## Milestone 17: Azure -- Prerequisites and Subscription Enumeration

- [ ] `[script]` `azure/00-check-prereqs.sh` -- Verify:
  - `az` CLI is installed (minimum version 2.50.0).
  - `jq` is installed.
  - `az account show` succeeds (user is logged in).
  - Print the authenticated identity, default subscription, and tenant.
- [ ] `[script]` `azure/01-enumerate-subscriptions.sh` -- List all accessible subscriptions:
  - Columns: Subscription ID, Subscription Name, State, Tenant ID, Spending Limit.
  - Output: table + `output/azure-subscriptions.json`.
- [ ] `[script]` `azure/01a-enumerate-resource-groups.sh` -- List all resource groups across all subscriptions:
  - Columns: Subscription, Resource Group, Location, Provisioning State, Tags, Resource Count.
  - Flag empty resource groups (zero resources).
  - Output: table + `output/azure-resource-groups.json`.

---

## Milestone 18: Azure -- Cost and Billing Audit

- [ ] `[script]` `azure/10-cost-current-month.sh` -- Query Azure Cost Management for the current month:
  - Use `az costmanagement query` (or the REST API via `az rest`).
  - Columns: Service (Meter Category), Cost (USD), % of Total.
  - Accept `--subscription <id>` or iterate all subscriptions.
  - Output: table + `output/azure-cost-current-month.json`.
- [ ] `[script]` `azure/11-cost-by-subscription.sh` -- Break down costs by subscription:
  - Columns: Subscription ID, Subscription Name, Cost (USD), % of Total.
  - Output: table + `output/azure-cost-by-subscription.json`.
- [ ] `[script]` `azure/12-cost-trend.sh` -- Query last 6 months:
  - Columns: Month, Total Cost (USD), Delta vs Previous Month (USD), Delta (%).
  - Output: table + `output/azure-cost-trend.json`.
- [ ] `[script]` `azure/13-cost-by-resource-group.sh` -- Break down costs by resource group:
  - Columns: Subscription, Resource Group, Cost (USD), % of Total.
  - Accept `--subscription <id>` or iterate all.
  - Output: table + `output/azure-cost-by-resource-group.json`.

---

## Milestone 19: Azure -- Compute Resource Inventory

- [ ] `[script]` `azure/20-virtual-machines.sh` -- Enumerate all VMs across all subscriptions:
  - Columns: Subscription, Resource Group, VM Name, Size, OS, Status (Running/Deallocated/Stopped), Location, Public IP, Monthly Est. Cost.
  - Flag VMs in `Stopped` state (still incur compute charges, unlike `Deallocated`).
  - Output: table + `output/azure-vms.json`.
- [ ] `[script]` `azure/21-vmss.sh` -- Enumerate Virtual Machine Scale Sets:
  - Columns: Subscription, Resource Group, VMSS Name, SKU, Capacity (current/min/max), Location, Monthly Est. Cost.
  - Output: table + `output/azure-vmss.json`.
- [ ] `[script]` `azure/22-app-services.sh` -- Enumerate App Service plans and apps:
  - Columns: Subscription, Resource Group, Plan Name, SKU/Tier, OS, App Count, Location, Status, Monthly Est. Cost.
  - Flag App Service plans with zero apps deployed.
  - Flag plans on Premium or Isolated tier in non-production resource groups.
  - Output: table + `output/azure-app-services.json`.
- [ ] `[script]` `azure/23-aks-clusters.sh` -- Enumerate AKS clusters:
  - Columns: Subscription, Resource Group, Cluster Name, Version, Node Pools, Total Nodes, Location, Power State, Monthly Est. Cost.
  - Output: table + `output/azure-aks.json`.
- [ ] `[script]` `azure/24-container-instances.sh` -- Enumerate Container Instances (ACI) and Container Apps:
  - Columns: Subscription, Resource Group, Name, Type (ACI/ContainerApp), CPU, Memory, Status, Location, Monthly Est. Cost.
  - Output: table + `output/azure-containers.json`.
- [ ] `[script]` `azure/25-functions.sh` -- Enumerate Azure Functions:
  - Columns: Subscription, Resource Group, Function App Name, Runtime, SKU, Location, Status, Last Execution.
  - Flag function apps on Premium/Dedicated plans with no recent executions.
  - Output: table + `output/azure-functions.json`.

---

## Milestone 20: Azure -- Storage Resource Inventory

- [ ] `[script]` `azure/30-storage-accounts.sh` -- Enumerate all Storage Accounts:
  - Columns: Subscription, Resource Group, Account Name, SKU, Kind, Location, Access Tier, Replication, Total Used Capacity, Public Access, Monthly Est. Cost.
  - Flag storage accounts with public blob access enabled.
  - Output: table + `output/azure-storage-accounts.json`.
- [ ] `[script]` `azure/31-managed-disks.sh` -- Enumerate all Managed Disks:
  - Columns: Subscription, Resource Group, Disk Name, Size (GB), SKU (Premium/Standard/Ultra), OS Type, State (Attached/Unattached), Attached To, Location, Monthly Est. Cost.
  - Flag unattached disks.
  - Output: table + `output/azure-managed-disks.json`.
- [ ] `[script]` `azure/32-snapshots.sh` -- Enumerate disk snapshots:
  - Columns: Subscription, Resource Group, Snapshot Name, Size (GB), Source Disk, Creation Time, Age (days), Monthly Est. Cost.
  - Flag snapshots older than 180 days.
  - Output: table + `output/azure-snapshots.json`.
- [ ] `[script]` `azure/33-file-shares.sh` -- Enumerate Azure Files shares:
  - Columns: Subscription, Resource Group, Storage Account, Share Name, Quota (GB), Used (GB), Tier, Monthly Est. Cost.
  - Output: table + `output/azure-file-shares.json`.

---

## Milestone 21: Azure -- Database Resource Inventory

- [ ] `[script]` `azure/40-sql-databases.sh` -- Enumerate Azure SQL Databases and Managed Instances:
  - Columns: Subscription, Resource Group, Server, Database Name, SKU/Tier, DTU/vCores, Size, Status, Monthly Est. Cost.
  - Flag databases on Premium/Business Critical tier in non-production resource groups.
  - Output: table + `output/azure-sql.json`.
- [ ] `[script]` `azure/41-cosmos-db.sh` -- Enumerate Cosmos DB accounts:
  - Columns: Subscription, Resource Group, Account Name, API Kind, Consistency, Locations, Offer Type, Monthly Est. Cost.
  - List each database/container with its provisioned RU/s or autoscale max RU/s.
  - Output: table + `output/azure-cosmos.json`.
- [ ] `[script]` `azure/42-redis-cache.sh` -- Enumerate Azure Cache for Redis:
  - Columns: Subscription, Resource Group, Name, SKU, Size, Shard Count, Location, State, Monthly Est. Cost.
  - Output: table + `output/azure-redis.json`.
- [ ] `[script]` `azure/43-synapse-workspaces.sh` -- Enumerate Azure Synapse workspaces and dedicated SQL pools:
  - Columns: Subscription, Resource Group, Workspace, SQL Pools (count), Spark Pools (count), Status, Monthly Est. Cost.
  - Flag paused SQL pools (still incur storage costs).
  - Output: table + `output/azure-synapse.json`.
- [ ] `[script]` `azure/44-mysql-postgresql.sh` -- Enumerate Azure Database for MySQL and PostgreSQL (Flexible Server):
  - Columns: Subscription, Resource Group, Server Name, Engine, SKU, Storage (GB), Version, State, HA, Monthly Est. Cost.
  - Flag stopped servers.
  - Output: table + `output/azure-mysql-postgresql.json`.

---

## Milestone 22: Azure -- Networking Resource Inventory

- [ ] `[script]` `azure/50-public-ips.sh` -- Enumerate all Public IP addresses:
  - Columns: Subscription, Resource Group, Name, IP Address, SKU, Allocation (Static/Dynamic), Associated To, Location.
  - Flag unassociated static public IPs (charged when idle).
  - Output: table + `output/azure-public-ips.json`.
- [ ] `[script]` `azure/51-load-balancers.sh` -- Enumerate Azure Load Balancers and Application Gateways:
  - Columns: Subscription, Resource Group, Name, Type (LB/AppGW), SKU, Frontend IPs, Backend Pools, Health Status, Monthly Est. Cost.
  - Flag load balancers with empty backend pools.
  - Flag Application Gateways (minimum ~$170/month even if idle).
  - Output: table + `output/azure-load-balancers.json`.
- [ ] `[script]` `azure/52-nat-gateways.sh` -- Enumerate NAT Gateways:
  - Columns: Subscription, Resource Group, Name, Location, Public IPs, Associated Subnets, Monthly Est. Cost.
  - Output: table + `output/azure-nat-gateways.json`.
- [ ] `[script]` `azure/53-vpn-expressroute.sh` -- Enumerate VPN Gateways and ExpressRoute circuits:
  - Columns: Subscription, Resource Group, Name, Type (VPN/ExpressRoute), SKU, Status, Monthly Est. Cost.
  - Output: table + `output/azure-vpn-expressroute.json`.
- [ ] `[script]` `azure/54-front-door-cdn.sh` -- Enumerate Azure Front Door and CDN profiles:
  - Columns: Subscription, Resource Group, Name, Type (FrontDoor/CDN), SKU, Endpoints, Status, Monthly Est. Cost.
  - Output: table + `output/azure-front-door-cdn.json`.
- [ ] `[script]` `azure/55-private-endpoints.sh` -- Enumerate Private Endpoints:
  - Columns: Subscription, Resource Group, Name, Target Resource, Location, Connection State.
  - Private endpoints cost $0.01/hr; list them for awareness.
  - Output: table + `output/azure-private-endpoints.json`.

---

## Milestone 23: Azure -- Other Billable Resources

- [ ] `[script]` `azure/60-dns-zones.sh` -- Enumerate Azure DNS zones:
  - Columns: Subscription, Resource Group, Zone Name, Type (Public/Private), Record Set Count, Monthly Cost.
  - Output: table + `output/azure-dns.json`.
- [ ] `[script]` `azure/61-key-vaults.sh` -- Enumerate Key Vaults and their contents:
  - Columns: Subscription, Resource Group, Vault Name, SKU, Keys (count), Secrets (count), Certificates (count), Soft Delete, Location.
  - Flag vaults with soft-deleted items (still incur retention costs).
  - Output: table + `output/azure-key-vaults.json`.
- [ ] `[script]` `azure/62-log-analytics.sh` -- Enumerate Log Analytics workspaces:
  - Columns: Subscription, Resource Group, Workspace Name, SKU, Retention (days), Daily Cap (GB), Ingestion Rate, Monthly Est. Cost.
  - Flag workspaces with retention >90 days (default) or no daily cap set.
  - Output: table + `output/azure-log-analytics.json`.
- [ ] `[script]` `azure/63-ml-workspaces.sh` -- Enumerate Azure Machine Learning workspaces and compute:
  - Columns: Subscription, Resource Group, Workspace Name, Compute Name, Type (Cluster/Instance), VM Size, State, Monthly Est. Cost.
  - Flag running compute instances.
  - Output: table + `output/azure-ml.json`.
- [ ] `[script]` `azure/64-service-bus-event-hubs.sh` -- Enumerate Service Bus namespaces and Event Hubs:
  - Columns: Subscription, Resource Group, Name, Type (ServiceBus/EventHub), SKU/Tier, TU/PU, Entities (count), Monthly Est. Cost.
  - Output: table + `output/azure-messaging.json`.
- [ ] `[script]` `azure/65-container-registries.sh` -- Enumerate Container Registries:
  - Columns: Subscription, Resource Group, Registry Name, SKU, Storage Used, Admin Enabled, Location, Monthly Est. Cost.
  - Flag registries on Premium SKU with small storage usage (potential over-provisioning).
  - Output: table + `output/azure-acr.json`.

---

## Milestone 24: Azure -- Orphaned and Unused Resource Detection

- [ ] `[script]` `azure/70-orphan-report.sh` -- Aggregation script:
  - Reads all JSON output from previous Azure scripts.
  - Additional checks:
    - Network Security Groups not associated with any subnet or NIC.
    - Network Interfaces not attached to any VM.
    - Availability Sets with no VMs.
    - Unused Route Tables.
  - Output: prioritized table sorted by estimated monthly waste.
  - Columns: Resource Type, Resource ID, Subscription, Resource Group, Name, Reason Flagged, Est. Monthly Waste (USD).
  - Output: table + `output/azure-orphan-report.json`.

---

## Milestone 25: Cross-Cloud Summary Dashboard

Aggregate all provider outputs into a single unified view.

- [ ] `[script]` `summary/80-cross-cloud-summary.sh` -- Read all `output/*.json` files and produce:
  - **Cost Summary Table:**
    - Columns: Cloud, Account/Subscription/Project, Current Month Cost (USD), Previous Month, 3-Month Avg, Trend.
    - Grand total row at the bottom.
  - **Resource Count Summary Table:**
    - Columns: Resource Category, AWS Count, GCP Count, Azure Count, Total.
    - Categories: Compute, Storage, Databases, Networking, Other.
  - **Top Orphaned Resources Table (all clouds):**
    - Columns: Cloud, Resource Type, Resource ID, Account/Project/Sub, Est. Monthly Waste (USD).
    - Top 25 by estimated waste.
  - **Total Waste Estimate:** Single line with total estimated monthly waste across all clouds.
  - Output: combined table to stdout + `output/cross-cloud-summary.json`.
- [ ] `[script]` `summary/81-markdown-report.sh` -- Generate a self-contained Markdown report:
  - Combine all tables from the summary into a single `.md` file with a timestamp header.
  - Include a table of contents.
  - Include per-provider sections with all detail tables.
  - Suitable for pasting into Confluence, Notion, or a GitHub wiki.
  - Output: `output/cloud-audit-report-YYYY-MM-DD.md`.
- [ ] `[script]` `summary/82-csv-export.sh` -- Export all JSON sidecar files as CSV:
  - One CSV per JSON file, placed in `output/csv/`.
  - Useful for loading into Google Sheets or Excel for further analysis.

---

## Milestone 26: Testing and Validation

- [ ] Write a test harness (`tests/run-tests.sh`) that validates:
  - All scripts are executable and have a shebang line.
  - All scripts source the shared libraries correctly.
  - All scripts accept `--help` and print usage information.
  - All scripts handle missing prerequisites gracefully (exit with clear error, not a stack trace).
  - All scripts handle missing permissions gracefully (report what permission is needed, not a raw API error).
- [ ] `[script]` `tests/test-table-formatting.sh` -- Unit tests for `lib/table.sh`:
  - Verify correct alignment with various column widths.
  - Verify truncation behavior.
  - Verify Markdown output mode.
  - Verify behavior with empty input.
- [ ] `[script]` `tests/test-json-output.sh` -- Unit tests for `lib/json.sh`:
  - Verify valid JSON is produced.
  - Verify correct handling of special characters in values.
- [ ] `[script]` `tests/dry-run-aws.sh` -- Dry-run test for AWS scripts using AWS CLI mock responses:
  - Use `aws --cli-input-json` or override AWS endpoints to use a mock server (e.g., `localstack` or `moto`).
  - Verify each script produces expected table output given known input.
- [ ] `[script]` `tests/dry-run-gcp.sh` -- Dry-run test for GCP scripts:
  - Mock `gcloud` output using wrapper functions.
  - Verify table output.
- [ ] `[script]` `tests/dry-run-azure.sh` -- Dry-run test for Azure scripts:
  - Mock `az` output using wrapper functions.
  - Verify table output.
- [ ] Write a CI pipeline configuration (`.github/workflows/lint-and-test.yml`):
  - `shellcheck` on all `.sh` files.
  - Run the unit tests (table formatting, JSON output).
  - Run dry-run tests with mocked CLI output.

---

## Milestone 27: Documentation and Packaging

- [ ] Write per-provider README files (`aws/README.md`, `gcp/README.md`, `azure/README.md`):
  - Required IAM permissions / roles for each script.
  - Example output screenshots or sample table output.
  - Known limitations and caveats.
- [ ] Write a quickstart guide in the top-level `README.md`:
  - One-command install/setup.
  - How to run a full audit.
  - How to run a single provider or single script.
  - How to read the output.
- [ ] Document the JSON schema for each output file so that downstream consumers (dashboards, Slack bots, etc.) can parse them reliably.
- [ ] Add a `Makefile` with targets:
  - `make audit-all` -- run full audit across all configured clouds.
  - `make audit-aws` / `make audit-gcp` / `make audit-azure` -- per-provider.
  - `make report` -- generate the Markdown report.
  - `make clean` -- remove all output files.
  - `make test` -- run all tests.
  - `make lint` -- run `shellcheck` on all scripts.

---

## Appendix A: Required Permissions by Provider

### AWS (IAM Policy)
The auditing scripts require **read-only** access. The following AWS managed policies cover all required permissions:
- `arn:aws:iam::aws:policy/ReadOnlyAccess` (covers most resource enumeration)
- `arn:aws:iam::aws:policy/AWSBillingReadOnlyAccess` (for Cost Explorer queries)
- `arn:aws:iam::aws:policy/AWSOrganizationsReadOnlyAccess` (for multi-account enumeration)

### GCP (IAM Roles)
- `roles/viewer` on each project (resource enumeration)
- `roles/billing.viewer` on the billing account (cost data)
- `roles/resourcemanager.organizationViewer` (project enumeration across the org)
- `roles/bigquery.dataViewer` on the billing export dataset (if using BigQuery cost queries)

### Azure (RBAC Roles)
- `Reader` role on each subscription (resource enumeration)
- `Cost Management Reader` role on each subscription (cost data)
- `Billing Reader` at the billing account level (for cross-subscription cost views)

---

## Appendix B: Estimated Effort

| Milestone | Description | Est. Effort |
|-----------|-------------|-------------|
| 0 | Scaffolding and shared libs | 2-3 days |
| 1-8 | AWS (prereqs through orphan detection) | 8-10 days |
| 9-16 | GCP (prereqs through orphan detection) | 8-10 days |
| 17-24 | Azure (prereqs through orphan detection) | 8-10 days |
| 25 | Cross-cloud summary | 2-3 days |
| 26 | Testing and validation | 3-4 days |
| 27 | Documentation and packaging | 2-3 days |
| **Total** | | **33-43 days** |

These estimates assume a single engineer working sequentially. Providers can be parallelized across team members to reduce calendar time to roughly 15-20 days.

---

## Appendix C: Design Decisions and Trade-offs

1. **Bash over Python/Go:** Chosen for zero-dependency execution on any machine with a shell and the cloud CLIs installed. The trade-off is more verbose string manipulation and weaker error handling. If scripts grow beyond ~300 lines, consider refactoring into Python with the `boto3`/`google-cloud`/`azure-sdk` libraries.

2. **CLI wrapping over SDK usage:** Cloud CLIs provide consistent, well-documented JSON output and handle authentication, pagination, and retries internally. SDKs would offer better performance for large-scale enumeration but add dependency management complexity.

3. **Cost estimation vs. exact billing:** The scripts estimate costs using public pricing where possible. These estimates will not match the invoice exactly due to reserved instances, committed use discounts, enterprise agreements, free tier, and credits. The estimates are directional and useful for identifying waste, not for accounting.

4. **Multi-account/project iteration:** Scripts iterate over all accounts/projects/subscriptions the caller has access to. For large organizations (hundreds of accounts), this can be slow. Consider adding `--account`, `--project`, or `--subscription` flags to scope to a single entity, and a `--parallel <n>` flag for concurrent execution.

5. **JSON sidecar output:** Every script writes both human-readable table output to stdout and machine-readable JSON to a file. This dual-output pattern allows scripts to be used interactively and in automation pipelines. The JSON files also serve as input for the cross-cloud summary aggregation.
