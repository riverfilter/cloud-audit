#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# prereqs.sh -- Prerequisite checks for binaries and cloud authentication
#
# Provides functions to verify that required CLI tools are installed (with
# optional minimum-version enforcement) and that cloud provider credentials
# are active.  Every failure prints a clear, actionable remediation message
# and returns a non-zero exit code so callers can decide whether to abort or
# skip a provider.
# ---------------------------------------------------------------------------

# Guard against double-sourcing.
[[ -n "${_PREREQS_SH_LOADED:-}" ]] && return 0
_PREREQS_SH_LOADED=1

# Source colors if not already loaded (resolve relative to this file).
_PREREQS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=colors.sh
source "${_PREREQS_DIR}/colors.sh"

# ---------------------------------------------------------------------------
# _version_to_comparable  --  convert a dotted version string to a
# zero-padded comparable string so that lexicographic comparison works.
#   e.g.  "2.14.3" -> "00002.00014.00003"
# ---------------------------------------------------------------------------
_version_to_comparable() {
    local ver="$1"
    local IFS='.'
    local parts=()
    read -ra parts <<< "$ver"
    local out=""
    local i
    for i in "${parts[@]}"; do
        # Strip any non-numeric suffix (e.g. "3-beta" -> "3")
        i="${i%%[^0-9]*}"
        printf -v padded '%05d' "${i:-0}"
        out="${out}${out:+.}${padded}"
    done
    echo "$out"
}

# ---------------------------------------------------------------------------
# _extract_version  --  attempt to extract a version number from a tool's
# own version output.  Handles common formats:
#   aws-cli/2.15.0 ...
#   Google Cloud SDK 467.0.0
#   jq-1.7
#   1.2.3
# ---------------------------------------------------------------------------
_extract_version() {
    local raw="$1"
    # Match the first semver-ish token (digits separated by dots).
    if [[ "$raw" =~ ([0-9]+\.[0-9]+(\.[0-9]+)?) ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# require_bin <name> [min_version]
#
# Check that <name> exists on PATH.  If min_version is given, also verify
# that the installed version is >= min_version.
#
# Returns 0 on success, 1 on failure (with a remediation message to stderr).
# ---------------------------------------------------------------------------
require_bin() {
    local name="${1:?require_bin: binary name required}"
    local min_version="${2:-}"

    if ! command -v "$name" &>/dev/null; then
        err "'$name' is not installed or not in PATH."
        case "$name" in
            aws)
                err "  Install the AWS CLI: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" ;;
            gcloud)
                err "  Install the Google Cloud SDK: https://cloud.google.com/sdk/docs/install" ;;
            az)
                err "  Install the Azure CLI: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli" ;;
            jq)
                err "  Install jq: https://jqlang.github.io/jq/download/" ;;
            column)
                err "  Install 'column' (part of util-linux / bsdmainutils)." ;;
            *)
                err "  Please install '$name' and ensure it is on your PATH." ;;
        esac
        return 1
    fi

    # If no minimum version requested, we are done.
    [[ -z "$min_version" ]] && return 0

    # Attempt to get the installed version.
    local version_output=""
    # Try common version flags in order.
    for flag in --version -version -v version; do
        version_output="$("$name" "$flag" 2>&1 || true)"
        if [[ -n "$version_output" ]]; then
            break
        fi
    done

    local installed_version
    if ! installed_version="$(_extract_version "$version_output")"; then
        warn "Could not determine version of '$name'. Skipping version check."
        return 0
    fi

    local cmp_installed cmp_required
    cmp_installed="$(_version_to_comparable "$installed_version")"
    cmp_required="$(_version_to_comparable "$min_version")"

    if [[ "$cmp_installed" < "$cmp_required" ]]; then
        err "'$name' version $installed_version is below the required minimum $min_version."
        err "  Please upgrade '$name' to at least version $min_version."
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# require_auth_aws
#
# Verify that the AWS CLI is installed and that valid credentials are
# configured by calling `aws sts get-caller-identity`.
# ---------------------------------------------------------------------------
require_auth_aws() {
    if ! require_bin aws; then
        return 1
    fi

    local sts_output
    if ! sts_output="$(aws sts get-caller-identity 2>&1)"; then
        err "AWS credentials are not configured or have expired."
        err "  Output: $sts_output"
        err "  Remediation:"
        err "    - Run 'aws configure' to set up access keys, or"
        err "    - Run 'aws sso login' if using AWS SSO, or"
        err "    - Export AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, or"
        err "    - Attach an IAM instance profile if running on EC2."
        return 1
    fi

    ok "AWS authenticated ($(echo "$sts_output" | grep -o '"Arn": *"[^"]*"' | head -1 || echo 'identity confirmed'))"
    return 0
}

# ---------------------------------------------------------------------------
# require_auth_gcp
#
# Verify that the gcloud CLI is installed and that an active account is
# configured.
# ---------------------------------------------------------------------------
require_auth_gcp() {
    if ! require_bin gcloud; then
        return 1
    fi

    local active_account
    active_account="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null)"

    if [[ -z "$active_account" ]]; then
        err "No active GCP account found."
        err "  Remediation:"
        err "    - Run 'gcloud auth login' to authenticate, or"
        err "    - Run 'gcloud auth application-default login' for application credentials, or"
        err "    - Set GOOGLE_APPLICATION_CREDENTIALS to a service account key file."
        return 1
    fi

    ok "GCP authenticated as $active_account"
    return 0
}

# ---------------------------------------------------------------------------
# require_auth_azure
#
# Verify that the Azure CLI is installed and that an active session exists.
# ---------------------------------------------------------------------------
require_auth_azure() {
    if ! require_bin az; then
        return 1
    fi

    local az_output
    if ! az_output="$(az account show 2>&1)"; then
        err "Azure CLI is not authenticated or the session has expired."
        err "  Output: $az_output"
        err "  Remediation:"
        err "    - Run 'az login' to authenticate interactively, or"
        err "    - Run 'az login --service-principal' for CI/CD environments, or"
        err "    - Run 'az login --use-device-code' for headless environments."
        return 1
    fi

    local sub_name
    sub_name="$(echo "$az_output" | grep -o '"name": *"[^"]*"' | head -1 || echo '')"
    ok "Azure authenticated (${sub_name:-subscription confirmed})"
    return 0
}
