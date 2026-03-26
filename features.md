# Feature & Improvement Recommendations -- Cloud Cost Audit

Generated: 2026-03-26

---

## 1. Parallel Region Scanning

- **Category:** Optimization
- **Priority:** High
- **Affected files:** `aws/20-ec2-instances.sh`, `aws/21-ecs-services.sh`, `aws/22-lambda-functions.sh`, `aws/23-eks-clusters.sh`, `aws/24-lightsail-instances.sh`, `aws/30-s3-buckets.sh`, `aws/31-ebs-volumes.sh`, `aws/32-ebs-snapshots.sh`, `aws/33-efs-filesystems.sh`, `aws/34-fsx-filesystems.sh`
- **Description:** Every region-scanning script iterates regions sequentially. With 15+ enabled regions and multiple API calls per region, a full audit can take 30-60+ minutes. Running region scans in parallel (e.g., 4-8 concurrent regions using `xargs -P` or `GNU parallel`) would dramatically reduce total audit time. The JSON builder would need to be refactored to support concurrent writes (e.g., write per-region temp files and merge at the end).

---

## 2. API Retry Logic with Exponential Backoff

- **Category:** Robustness
- **Priority:** High
- **Affected files:** All `aws/*.sh` scripts
- **Description:** None of the scripts implement retry logic for AWS API calls. AWS APIs are subject to rate limiting and transient failures. A shared `aws_retry` function in `lib/` that wraps `aws` CLI calls with configurable retries and exponential backoff would prevent intermittent failures from aborting or producing incomplete audits. The AWS CLI has built-in retry for some errors, but not all, and the max retry count is configurable but not set by these scripts.

---

## 3. CSV Export Option

- **Category:** Enhancement
- **Priority:** High
- **Affected files:** `lib/table.sh`, all audit scripts
- **Description:** Currently output is either ASCII table (stdout) or JSON (file). Many users need CSV for spreadsheet analysis or importing into BI tools. Adding a `--csv` flag to `table_print` or a global `--output-format csv` option would be valuable. The pipe-delimited internal format is already close to CSV; it mainly needs proper quoting and a different delimiter.

---

## 4. Configurable Region List

- **Category:** Enhancement
- **Priority:** High
- **Affected files:** All region-scanning `aws/*.sh` scripts
- **Description:** There is no way to limit the audit to specific regions. Users auditing only `us-east-1` and `us-west-2` must wait for all 15+ regions to be scanned. Adding a `--regions us-east-1,us-west-2` flag (or `AWS_AUDIT_REGIONS` environment variable) would allow targeted scanning. This is especially useful for development/testing and for organizations that only use a few regions.

---

## 5. Progress Indicator / Verbose Mode

- **Category:** UX
- **Priority:** Medium
- **Affected files:** All `aws/*.sh` scripts
- **Description:** For long-running scans (especially S3 bucket inspection, Lambda orphan detection), there is no progress indication beyond per-region info messages. Adding a progress bar or percentage counter (e.g., "Scanning region 5/17...") and a `--quiet` flag to suppress per-resource info messages would improve the user experience. A `--verbose` flag could show per-API-call timing.

---

## 6. Savings Recommendations Engine

- **Category:** Enhancement
- **Priority:** High
- **Affected files:** `aws/20-ec2-instances.sh`, `aws/31-ebs-volumes.sh`, `aws/32-ebs-snapshots.sh`
- **Description:** The scripts flag orphaned/unused resources but do not calculate potential savings. Adding a summary section that totals up the estimated monthly cost of all orphaned/unused resources would give immediate actionable value:
  - Orphaned EBS volumes: sum of monthly cost
  - Old snapshots with deleted source volumes: sum of monthly cost
  - Running EC2 instances with no Name tag: sum of monthly cost
  - Lambda functions not invoked in 90+ days: highlight as zero-cost but cleanup candidates
  This could be a new `aws/40-savings-summary.sh` script that reads the JSON output from previous scripts.

---

## 7. Cost Estimates for Additional Instance Types

- **Category:** Enhancement
- **Priority:** Medium
- **Affected files:** `aws/20-ec2-instances.sh`
- **Description:** The EC2 pricing lookup table only covers t2, t3, t3a, m5, m6i, c5, and r5 families. Many common instance types are missing: m6g, m7i, c6i, c6g, c7g, r6i, r6g, x1, x2, p3, p4, g4, g5, i3, d2, etc. Instances of these types will show "N/A" for cost estimates. Consider either:
  - Expanding the lookup table significantly
  - Using the AWS Pricing API (`aws pricing get-products`) to fetch current on-demand prices dynamically
  - Caching pricing data in a local file that can be refreshed

---

## 8. RDS/Aurora Database Inventory

- **Category:** Enhancement
- **Priority:** High
- **Affected files:** New script: `aws/25-rds-instances.sh`
- **Description:** RDS and Aurora databases are among the most expensive AWS resources and are completely absent from the audit. A new script should enumerate:
  - RDS instances: engine, instance class, storage size, Multi-AZ status, monthly cost estimate
  - Aurora clusters: engine, instance count, serverless v2 ACU range
  - Read replicas
  - Stopped instances (potential candidates for termination)
  - Instances without deletion protection

---

## 9. ElastiCache / MemoryDB Inventory

- **Category:** Enhancement
- **Priority:** Medium
- **Affected files:** New script: `aws/26-elasticache.sh`
- **Description:** ElastiCache (Redis/Memcached) clusters are common and can be expensive. A new script should enumerate clusters with node type, node count, engine version, and monthly cost estimate.

---

## 10. NAT Gateway and Elastic IP Inventory

- **Category:** Enhancement
- **Priority:** Medium
- **Affected files:** New script: `aws/35-network-resources.sh`
- **Description:** NAT Gateways ($0.045/hr + data processing) and unattached Elastic IPs ($0.005/hr) are common cost leaks. A script that enumerates NAT Gateways per region and flags unattached Elastic IPs would catch a common class of waste.

---

## 11. S3 Intelligent-Tiering and Storage Class Breakdown

- **Category:** Enhancement
- **Priority:** Medium
- **Affected files:** `aws/30-s3-buckets.sh`
- **Description:** The S3 script only queries CloudWatch for `StandardStorage` size. Buckets using Intelligent-Tiering, Glacier, or other storage classes will show incomplete size data. Querying additional `StorageType` dimensions (e.g., `IntelligentTieringFAStorage`, `GlacierStorage`, etc.) and reporting the breakdown would give a more accurate picture. Also, adding a recommendation for buckets without lifecycle policies could help identify cost savings.

---

## 12. Cost Anomaly Detection

- **Category:** Enhancement
- **Priority:** Medium
- **Affected files:** `aws/12-cost-trend.sh`
- **Description:** The trend script highlights months with >20% increase, but this threshold is hardcoded. Making it configurable via `--threshold` flag would be useful. Additionally, computing a rolling average and flagging deviations from the average (rather than just month-over-month) would catch more subtle cost anomalies.

---

## 13. HTML Report Generation

- **Category:** Enhancement
- **Priority:** Medium
- **Affected files:** New script or post-processor
- **Description:** A script that reads all JSON output files and generates a single HTML report with tables, charts (using inline SVG or ASCII art), and a table of contents would be valuable for sharing audit results with stakeholders who do not use the terminal. The markdown table output (`table_print --markdown`) is a step in this direction but a full HTML report would be more polished.

---

## 14. Tag Compliance Audit

- **Category:** Enhancement
- **Priority:** Medium
- **Affected files:** New script: `aws/14-tag-compliance.sh`
- **Description:** Beyond cost-by-tag, a dedicated tag compliance script that checks all discovered resources (EC2, EBS, S3, etc.) against a configurable set of required tags (e.g., `Environment`, `Team`, `CostCenter`, `Project`) and reports non-compliant resources would help enforce tagging standards. The `13-cost-by-tag.sh` script only looks at Cost Explorer data, not individual resource tags.

---

## 15. Configuration File Support

- **Category:** Enhancement
- **Priority:** Medium
- **Affected files:** All scripts, new `config.sh` or `audit.conf`
- **Description:** Hardcoded values scattered across scripts include:
  - Pricing data (multiple scripts)
  - Orphan detection threshold: 90 days (`aws/22-lambda-functions.sh`)
  - Old snapshot threshold: 180 days (`aws/32-ebs-snapshots.sh`)
  - Cost trend period: 6 months (`aws/12-cost-trend.sh`)
  - Cost spike threshold: 20% (`aws/12-cost-trend.sh`)
  - Top-N service count: 20 (`aws/10-cost-current-month.sh`)
  - Output directory: `output/` (all scripts)

  A central configuration file that allows overriding these values would make the tool more flexible without modifying script code.

---

## 16. Cross-Script Resource Correlation

- **Category:** Enhancement
- **Priority:** Low
- **Affected files:** New summary script
- **Description:** The scripts run independently and don't cross-reference data. For example:
  - EBS volumes attached to terminated instances (orphan detection across scripts)
  - Snapshots whose source volume is attached to a terminated instance
  - EC2 instances that are part of ECS or EKS clusters (avoid double-counting)
  A summary/correlation script that reads all JSON output and identifies these cross-resource patterns would add significant value.

---

## 17. Consistent Error Handling Across Scripts

- **Category:** Robustness
- **Priority:** Medium
- **Affected files:** All `aws/*.sh` scripts
- **Description:** Error handling patterns vary across scripts. Some scripts check for specific AWS error codes (e.g., `OptInRequired`, `AccessDeniedException`), while others have less specific error handling. Standardizing on a shared error handler function in `lib/` that categorizes AWS errors and produces consistent remediation messages would improve reliability and maintainability.

---

## 18. `--json-only` and `--table-only` Output Modes

- **Category:** UX
- **Priority:** Medium
- **Affected files:** All audit scripts
- **Description:** Currently every script always writes both table output (stdout) and JSON (file). Adding `--json-only` (suppress table, print JSON to stdout) and `--table-only` (suppress JSON file) modes would make the scripts more composable in pipelines. Example: `./aws/20-ec2-instances.sh --json-only | jq '.[] | select(.is_potential_orphan == true)'`.

---

## 19. Node Group Detail in EKS JSON Output

- **Category:** Enhancement
- **Priority:** Low
- **Affected files:** `aws/23-eks-clusters.sh`
- **Description:** The script builds `ng_details_json` (line 117-161) with detailed node group information using jq, but this data is never included in the final JSON output. The `json_add_object` call at line 169-176 only includes summary fields. The node group details should either be included in the output (which would require extending `json.sh` to support nested objects/arrays) or the `ng_details_json` construction should be removed to avoid wasted API calls and confusing dead code.

---

## 20. Lightsail Total Monthly Cost in Summary

- **Category:** Enhancement
- **Priority:** Low
- **Affected files:** `aws/24-lightsail-instances.sh`
- **Description:** The script accumulates `total_monthly` cost (line 107, 169) but never prints it in the summary section. The EBS, EFS, and FSx scripts all print total estimated monthly cost in their summaries. The Lightsail summary at line 206-215 should include: `info "Total estimated monthly cost: \$$(printf '%.2f' "$total_monthly")"`.

---

## 21. GCP and Azure Script Implementation

- **Category:** Enhancement
- **Priority:** High
- **Affected files:** New directories: `gcp/`, `azure/`
- **Description:** The orchestrator (`audit-all.sh`) detects GCP and Azure CLIs and authentication, but no actual audit scripts exist for these providers. The `gcp/` and `azure/` directories referenced in the README do not exist. Implementing equivalent scripts for GCP (Compute Engine, GKE, Cloud Storage, BigQuery) and Azure (VMs, AKS, Blob Storage, SQL) would fulfill the "multi-cloud" promise of the tool.

---

## 22. Sorted Output Options

- **Category:** UX
- **Priority:** Low
- **Affected files:** `lib/table.sh`, all audit scripts
- **Description:** Tables are currently ordered by region iteration order (for inventory scripts) or by cost descending (for cost scripts). Adding `--sort-by` flag (e.g., `--sort-by cost`, `--sort-by region`, `--sort-by name`) would help users focus on what matters most to them.

---

## Summary by Priority

| Priority | Count |
|----------|-------|
| High     | 6 (#1 parallel scanning, #2 retry logic, #3 CSV export, #4 region filter, #6 savings summary, #8 RDS inventory, #21 GCP/Azure) |
| Medium   | 11 (#5, #7, #9, #10, #11, #12, #13, #14, #15, #17, #18) |
| Low      | 4 (#16, #19, #20, #22) |
