#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# colors.sh -- Terminal color definitions with automatic TTY detection
#
# Source this file to get color variables for formatted output.
# Colors are automatically disabled when stdout is not a TTY (piped or
# redirected), ensuring clean output in logs and downstream tooling.
# ---------------------------------------------------------------------------

# Detect whether stdout is connected to a terminal.
# If not, all color variables are set to empty strings so callers can use
# them unconditionally without littering non-interactive output with escapes.
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;34m'
    MAGENTA=$'\033[0;35m'
    CYAN=$'\033[0;36m'
    WHITE=$'\033[0;37m'
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    UNDERLINE=$'\033[4m'
    RESET=$'\033[0m'

    # Bold color combinations (convenience)
    BOLD_RED=$'\033[1;31m'
    BOLD_GREEN=$'\033[1;32m'
    BOLD_YELLOW=$'\033[1;33m'
    BOLD_BLUE=$'\033[1;34m'
    BOLD_CYAN=$'\033[1;36m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    MAGENTA=''
    CYAN=''
    WHITE=''
    BOLD=''
    DIM=''
    UNDERLINE=''
    RESET=''

    BOLD_RED=''
    BOLD_GREEN=''
    BOLD_YELLOW=''
    BOLD_BLUE=''
    BOLD_CYAN=''
fi

# ---------------------------------------------------------------------------
# Utility functions for common colored output patterns
# ---------------------------------------------------------------------------

# Print an informational message in cyan.
info() {
    printf '%s[INFO]%s %s\n' "$CYAN" "$RESET" "$*"
}

# Print a success message in green.
ok() {
    printf '%s[ OK ]%s %s\n' "$GREEN" "$RESET" "$*"
}

# Print a warning message in yellow to stderr.
warn() {
    printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*" >&2
}

# Print an error message in red to stderr.
err() {
    printf '%s[ ERR]%s %s\n' "$RED" "$RESET" "$*" >&2
}

# Print a section header in bold.
section() {
    printf '\n%s=== %s ===%s\n' "$BOLD" "$*" "$RESET"
}
