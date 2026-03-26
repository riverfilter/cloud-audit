# Bug Report -- Cloud Cost Audit

Generated: 2026-03-26

---

## lib/json.sh

### Bug 1: Backslash escape produces double backslash instead of JSON backslash

- **File:** `lib/json.sh`, line 45
- **Severity:** Medium
- **Description:** The case branch for escaping a literal backslash character is:
  ```
  '\') out+='\\' ;;
  ```
  In single-quoted context, `'\\'` is the two-character string `\\`. This means a single input backslash gets appended as `\\` (two characters) to `out`, which is correct for JSON output. However, the preceding `'"'` case uses `'\"'` which is only the two-character string `\"` -- also correct. **On closer inspection, this is actually correct.** But there is a subtle issue: the backslash case pattern `'\'` is a single backslash in single quotes, which is technically valid but fragile. Some bash versions may interpret this differently. The real concern is that in the context of `case`, the pattern `'\')` works but can be confused with an unterminated quote by linters and some older bash versions. This is more of a portability concern than a hard bug.

  **Retracted** -- on re-analysis, this is correct for bash 4+. Removing from bug list.

### Bug 2: `_json_escape` fails on NUL byte (0x00)

- **File:** `lib/json.sh`, line 53
- **Severity:** Low
- **Description:** `printf '%d' "'$char"` on a NUL byte (`\0`) will produce `0`, and the `\u0000` escape will be emitted. However, bash variables cannot contain NUL bytes at all, so this code path is unreachable. The `(( ord >= 0 && ord < 32 ))` check will catch other control characters correctly. Not a practical bug -- no fix needed.

  **Retracted** -- unreachable edge case.

---

## aws/10-cost-current-month.sh

### Bug 1: `bc` dependency used but not checked in prerequisites

- **File:** `aws/10-cost-current-month.sh`, lines 119-121
- **Severity:** Medium
- **Description:** The script uses `bc -l` for floating-point arithmetic (e.g., `echo "$total_cost > 0" | bc -l`, `echo "scale=4; ..." | bc -l`) but does not call `require_bin bc` in the prerequisites section. If `bc` is not installed, the script will fail at runtime with a confusing error. The same issue exists in `aws/11-cost-by-account.sh`, `aws/12-cost-trend.sh`, `aws/13-cost-by-tag.sh`, `aws/20-ec2-instances.sh`, and `aws/21-ecs-services.sh`.
- **Affected files:**
  - `aws/10-cost-current-month.sh`
  - `aws/11-cost-by-account.sh`
  - `aws/12-cost-trend.sh`
  - `aws/13-cost-by-tag.sh`
  - `aws/20-ec2-instances.sh`
  - `aws/21-ecs-services.sh`
- **Suggested fix:** Add `require_bin bc || exit 1` to the prerequisites section of each affected script, consistent with `aws/30-s3-buckets.sh`, `aws/31-ebs-volumes.sh`, `aws/32-ebs-snapshots.sh`, `aws/33-efs-filesystems.sh`, and `aws/34-fsx-filesystems.sh` which already check for `bc`.

---

## aws/10-cost-current-month.sh

### Bug 2: December month-end calculation falls back to today's date on failure

- **File:** `aws/10-cost-current-month.sh`, lines 39-40
- **Severity:** High
- **Description:** For December, the fallback in the `||` branch sets `month_end` to today's date (`date +%Y-%m-%d`). If the `date -d` invocation fails (e.g., on macOS which uses BSD `date`), `month_end` becomes something like `2026-12-26` instead of `2027-01-01`. This means the Cost Explorer query would exclude the remaining days of December, producing an incomplete cost report -- silently. The user gets no warning that data is missing.

  This same pattern is repeated in:
  - `aws/11-cost-by-account.sh`, lines 82-83
  - `aws/12-cost-trend.sh`, lines 39-40
  - `aws/13-cost-by-tag.sh`, lines 63-64

- **Suggested fix:** Compute the end-of-December date without relying on `date -d` arithmetic. For December, the answer is always `YYYY+1`-01-01:
  ```bash
  if [[ "$(date +%m)" == "12" ]]; then
      month_end="$(( $(date +%Y) + 1 ))-01-01"
  fi
  ```

---

## aws/12-cost-trend.sh

### Bug 3: `date -d` for trend_start is not portable (macOS/BSD)

- **File:** `aws/12-cost-trend.sh`, line 37
- **Severity:** Medium
- **Description:** `date -d "$(date +%Y-%m-01) -6 months"` uses GNU `date` syntax. On macOS/BSD, this will fail and the script will exit immediately due to `set -e`, with no descriptive error message. There is no fallback like the December case has.
- **Suggested fix:** Add a BSD `date` fallback:
  ```bash
  trend_start="$(date -d "$(date +%Y-%m-01) -6 months" +%Y-%m-%d 2>/dev/null \
      || date -v-6m -v1d +%Y-%m-%d 2>/dev/null \
      || { err "Cannot compute date 6 months ago. GNU or BSD date required."; exit 1; })"
  ```

---

## aws/01-enumerate-accounts.sh

### Bug 4: Missing pagination for `aws organizations list-accounts`

- **File:** `aws/01-enumerate-accounts.sh`, line 59
- **Severity:** High
- **Description:** The `aws organizations list-accounts` call does not handle pagination. The default page size is 20 accounts. Organizations with more than 20 accounts will have their account list silently truncated. The returned JSON will contain a `NextToken` field that is never consumed.
- **Suggested fix:** Implement pagination using `--starting-token` in a loop, or use `aws organizations list-accounts --no-paginate` (which auto-paginates in CLI v2), or use `--max-items` with a token loop.

---

## aws/11-cost-by-account.sh

### Bug 5: Missing pagination for `aws organizations list-accounts` (account name mapping)

- **File:** `aws/11-cost-by-account.sh`, line 48
- **Severity:** High
- **Description:** Same as Bug 4 above. The `account_names` associative array will only contain the first page of accounts (up to 20). Accounts beyond the first page will show "N/A" for their name in the cost report.
- **Suggested fix:** Same as Bug 4.

---

## aws/21-ecs-services.sh

### Bug 6: Missing pagination for `aws ecs list-services`

- **File:** `aws/21-ecs-services.sh`, lines 108-111
- **Severity:** High
- **Description:** The `aws ecs list-services` call has a default max of 10 results per page. Clusters with more than 10 services will have services silently truncated. The script correctly handles `describe-services` in batches of 10, but never paginates the `list-services` call itself.
- **Suggested fix:** Implement pagination with `--next-token` / `NextToken` loop for `list-services`.

---

## aws/21-ecs-services.sh

### Bug 7: Missing pagination for `aws ecs list-clusters`

- **File:** `aws/21-ecs-services.sh`, line 90
- **Severity:** Medium
- **Description:** The `aws ecs list-clusters` call has a default max of 100 results. Accounts with more than 100 ECS clusters (rare but possible) will have clusters silently truncated. No pagination handling is implemented.
- **Suggested fix:** Implement pagination loop.

---

## aws/23-eks-clusters.sh

### Bug 8: Missing pagination for `aws eks list-clusters` and `aws eks list-nodegroups`

- **File:** `aws/23-eks-clusters.sh`, lines 68, 104
- **Severity:** Medium
- **Description:** `eks list-clusters` returns max 100 clusters and `eks list-nodegroups` returns max 100 node groups per call. No pagination is implemented for either. Truncation is silent.
- **Suggested fix:** Implement `--next-token` pagination loops.

---

## aws/24-lightsail-instances.sh

### Bug 9: `declare -A bundle_prices` inside a loop overwrites without proper scoping

- **File:** `aws/24-lightsail-instances.sh`, line 89
- **Severity:** Medium
- **Description:** `declare -A bundle_prices=()` is called inside the `for region` loop. While `unset bundle_prices` is called at line 135, the `declare -A` inside the loop body re-declares the variable in the function scope (or global scope since this is not inside a function). On the second iteration, `declare -A bundle_prices=()` correctly resets it. However, the same pattern with `declare -A db_bundle_prices=()` at line 151 is also fine.

  **On closer inspection:** The `unset` at lines 135 and 196 ensures cleanup. The `declare -A` re-initialization at the top of each iteration creates a fresh associative array. This is actually correct behavior in bash, though slightly fragile.

  **Retracted** -- this works correctly.

---

## aws/24-lightsail-instances.sh

### Bug 10: Missing pagination for Lightsail `get-instances` and `get-relational-databases`

- **File:** `aws/24-lightsail-instances.sh`, lines 74, 140
- **Severity:** Medium
- **Description:** Both `aws lightsail get-instances` and `aws lightsail get-relational-databases` return paginated results (via `pageToken`/`nextPageToken`). Accounts with many Lightsail resources in a region will have results silently truncated.
- **Suggested fix:** Implement `--page-token` pagination loops.

---

## aws/30-s3-buckets.sh

### Bug 11: CloudWatch `cw_start` date computation fails silently on some systems

- **File:** `aws/30-s3-buckets.sh`, line 97
- **Severity:** Medium
- **Description:** The script tries GNU `date -d '3 days ago'` and then BSD `date -v-3d` as a fallback. If both fail, `cw_start` is set to empty string `""`. When `cw_start` is empty, the entire CloudWatch size/object-count block (lines 121-159) is skipped, meaning all buckets will show `0 B` size and `0` object count with no warning to the user. The user has no indication that the size data is unavailable.
- **Suggested fix:** Add a warning when `cw_start` is empty:
  ```bash
  if [[ -z "$cw_start" ]]; then
      warn "Could not compute date offset. Bucket sizes will not be available."
  fi
  ```

---

## aws/32-ebs-snapshots.sh

### Bug 12: `age_days` written as string in JSON but should be numeric

- **File:** `aws/32-ebs-snapshots.sh`, line 186
- **Severity:** Low
- **Description:** The JSON field `age_days` is written with `"age_days=s:${age_days}"` which forces it to be a string. When `age_days` is a valid integer (e.g., `45`), it would be more correct and useful as a numeric JSON value. The `s:` prefix forces string encoding even for numeric values. This makes downstream JSON processing (e.g., `jq 'select(.age_days > 180)'`) fail because the value is a string, not a number.
- **Suggested fix:** Use `"age_days=${age_days}"` without the `s:` prefix. Add a special case for when `age_days` is `-` (unknown) to emit `null`:
  ```bash
  if [[ "$age_days" == "-" ]]; then
      "age_days=null"
  else
      "age_days=${age_days}"
  fi
  ```

---

## aws/20-ec2-instances.sh

### Bug 13: `monthly_est_cost` written as string in JSON, mixing "N/A" with numbers

- **File:** `aws/20-ec2-instances.sh`, line 171
- **Severity:** Low
- **Description:** The `monthly_est_cost` field is always forced to string with `s:` prefix. When the cost is `N/A` (unknown instance type), this is fine. But when it is a numeric value like `67.89`, forcing it to a string makes downstream numeric aggregation impossible without extra parsing. A better approach would be to emit `null` for unknown costs and a number for known costs.
- **Suggested fix:** Remove `s:` prefix and handle N/A as null:
  ```bash
  if [[ "$monthly_cost" == "N/A" ]]; then
      "monthly_est_cost=null"
  else
      "monthly_est_cost=${monthly_cost}"
  fi
  ```

  The same pattern affects `aws/31-ebs-volumes.sh` (line 176), `aws/33-efs-filesystems.sh` (line 180), and `aws/34-fsx-filesystems.sh` (line 154).

---

## aws/22-lambda-functions.sh

### Bug 14: CloudWatch `get-metric-statistics` has a 1440-datapoint limit

- **File:** `aws/22-lambda-functions.sh`, lines 125-134
- **Severity:** Medium
- **Description:** The script requests 90 days of data with `--period 86400` (daily). That is 90 datapoints, well within the 1440 limit. **However**, the request is made once per Lambda function per region. For accounts with hundreds or thousands of Lambda functions, this creates a massive number of CloudWatch API calls, which will be throttled (CloudWatch has a default rate of 400 GetMetricStatistics calls/second with burst to 20). There is no retry/backoff logic, so throttled calls will silently fail (stderr is redirected to `/dev/null`), and throttled functions will incorrectly be marked as orphaned.
- **Suggested fix:** Add retry logic with exponential backoff for CloudWatch calls, or batch the orphan detection using `get-metric-data` (which supports multiple metrics per call). At minimum, add a small sleep between calls or detect throttling errors.

---

## audit-all.sh

### Bug 15: `(( audit_failures++ ))` inside function does not propagate to outer scope

- **File:** `audit-all.sh`, line 139
- **Severity:** High
- **Description:** The variable `audit_failures` is defined at line 118 in the outer scope. The function `run_provider_audit` (line 120-141) increments it with `(( audit_failures++ ))`. In bash, `(( audit_failures++ ))` inside a function **does** modify the global variable because bash functions do not have their own scope by default. However, there is a subtle interaction with `set -e`: when `audit_failures` is `0`, `(( audit_failures++ ))` evaluates `0++` which first returns the current value `0` (falsy), causing `set -e` to trigger a script exit. The `|| true` guard that other scripts use is missing here.

  When the first provider audit fails, `audit_failures` is `0`, so `(( audit_failures++ ))` returns exit code 1 (because the expression evaluates to 0 before increment), and `set -e` terminates the entire script before it can run remaining provider audits.

- **Suggested fix:** Change line 139 to:
  ```bash
  (( audit_failures++ )) || true
  ```

---

## aws/34-fsx-filesystems.sh

### Bug 16: Lustre `PerUnitStorageThroughput` is not the total throughput

- **File:** `aws/34-fsx-filesystems.sh`, lines 164-165
- **Severity:** Low
- **Description:** For Lustre file systems, `PerUnitStorageThroughput` is a per-TiB value (e.g., 50, 100, 200 MB/s/TiB), not the total throughput of the file system. Displaying it as "50 MB/s" is misleading because the actual throughput is `PerUnitStorageThroughput * StorageCapacity / 1024`. For Windows, ONTAP, and OpenZFS, `ThroughputCapacity` is the actual total throughput, so those are correctly displayed.
- **Suggested fix:** For Lustre, either compute the total throughput (`PerUnitStorageThroughput * StorageCapacity / 1024`) or label the column differently for Lustre (e.g., "50 MB/s/TiB").

---

## lib/table.sh

### Bug 17: ANSI codes in table cells corrupt column width calculations for colored rows

- **File:** `lib/table.sh`, line 65 (in `_table_truncate`)
- **Severity:** Medium
- **Description:** `_table_truncate` strips ANSI codes to measure visible length, and if truncation is needed, it strips ANSI codes entirely and then truncates the clean string. This means that if a cell contains ANSI color codes (as used by `aws/12-cost-trend.sh` for red-highlighted rows), the color codes are **lost** after truncation. The truncated text will appear without color formatting. While this is a minor visual issue, the more significant problem is in the **column width calculation**: `_table_visible_len` correctly measures without ANSI, but `_table_pad` adds padding based on visible length. If a cell has ANSI codes and the visible content is shorter than the column width, the padding calculation is correct. However, the **total line width** will be wider than expected because the padding does not account for the invisible ANSI bytes when the terminal renders it. This can cause alignment issues in mixed rows where some rows have ANSI codes and others do not.

  In practice, this manifests in `12-cost-trend.sh` where highlighted rows may have slightly misaligned columns compared to non-highlighted rows.

- **Suggested fix:** This is inherently hard to fix in a pure-bash table formatter. The current approach is a reasonable best-effort. One improvement: apply ANSI codes per-cell (wrapping the padded content) rather than embedding them in the cell value. This would require the table formatter to support a color parameter.

---

## Summary by Severity

| Severity | Count | Bug IDs |
|----------|-------|---------|
| Critical | 0     | -- |
| High     | 4     | #2 (December date fallback), #4 (orgs pagination), #5 (orgs pagination), #6 (ECS list-services pagination), #15 (audit_failures set -e) |
| Medium   | 8     | #1 (bc not checked), #3 (date -d portability), #7 (ECS list-clusters pagination), #8 (EKS pagination), #10 (Lightsail pagination), #11 (cw_start silent failure), #14 (CloudWatch throttling), #17 (ANSI table alignment) |
| Low      | 3     | #12 (age_days string in JSON), #13 (monthly_cost string in JSON), #16 (Lustre throughput label) |
