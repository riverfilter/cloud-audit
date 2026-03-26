#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# table.sh -- Portable ASCII / Markdown table formatter
#
# Reads pipe-delimited rows (first row = header) and prints an aligned,
# professional-looking table.  Supports:
#   - ASCII box-drawing with +/-/| characters
#   - Markdown table output (--markdown flag)
#   - Configurable maximum column width with ellipsis truncation
#   - Reading from stdin or from arguments
#
# Usage:
#   # From stdin (pipe-delimited):
#   printf 'Name|Region|Cost\nmy-instance|us-east-1|$45.20\n' | table_print
#
#   # Markdown mode:
#   printf 'Name|Region|Cost\n...' | table_print --markdown
#
#   # Custom max column width (default 50):
#   printf '...' | table_print --max-width 30
#
#   # From arguments (one row per argument):
#   table_print "Name|Region|Cost" "my-instance|us-east-1|\$45.20"
# ---------------------------------------------------------------------------

# Guard against double-sourcing.
[[ -n "${_TABLE_SH_LOADED:-}" ]] && return 0
_TABLE_SH_LOADED=1

# ---------------------------------------------------------------------------
# _table_visible_len  --  Compute the visible (printed) length of a string,
# stripping ANSI escape sequences.  This gives a reasonable approximation;
# full Unicode width calculation would require an external tool.
# ---------------------------------------------------------------------------
_table_visible_len() {
    local str="$1"
    # Strip ANSI escape sequences.
    local clean
    clean="$(printf '%s' "$str" | sed 's/\x1b\[[0-9;]*m//g')"
    echo "${#clean}"
}

# ---------------------------------------------------------------------------
# _table_truncate  --  Truncate a string to max visible width, appending
# an ellipsis if truncated.
# ---------------------------------------------------------------------------
_table_truncate() {
    local str="$1"
    local max="$2"

    [[ "$max" -lt 4 ]] && max=4

    local vlen
    vlen="$(_table_visible_len "$str")"

    if [[ "$vlen" -le "$max" ]]; then
        printf '%s' "$str"
        return
    fi

    # Cut to (max - 3) characters and append "..."
    # Strip ANSI first to get a clean cut, then truncate.
    local clean
    clean="$(printf '%s' "$str" | sed 's/\x1b\[[0-9;]*m//g')"
    printf '%s...' "${clean:0:$((max - 3))}"
}

# ---------------------------------------------------------------------------
# _table_pad  --  Right-pad a string to the given visible width.
# ---------------------------------------------------------------------------
_table_pad() {
    local str="$1"
    local target_width="$2"
    local vlen
    vlen="$(_table_visible_len "$str")"
    local pad=$(( target_width - vlen ))
    printf '%s' "$str"
    if [[ "$pad" -gt 0 ]]; then
        printf '%*s' "$pad" ''
    fi
}

# ---------------------------------------------------------------------------
# _table_separator  --  Print a horizontal separator line.
#   e.g.  +----------+--------+-------+
# ---------------------------------------------------------------------------
_table_separator() {
    local -n _ts_widths=$1
    local out="+"
    local w
    for w in "${_ts_widths[@]}"; do
        out+="$(printf '%*s' "$(( w + 2 ))" '' | tr ' ' '-')+"
    done
    echo "$out"
}

# ---------------------------------------------------------------------------
# _table_row  --  Print a single data row.
#   e.g.  | my-inst  | us-e-1 | $45   |
# ---------------------------------------------------------------------------
_table_row() {
    local -n _tr_widths=$1
    shift
    local -a cells=("$@")
    local out=""
    local i padded
    for i in "${!_tr_widths[@]}"; do
        padded="$(_table_pad "${cells[$i]:-}" "${_tr_widths[$i]}")"
        out+="| ${padded} "
    done
    out+="|"
    echo "$out"
}

# ---------------------------------------------------------------------------
# _table_md_separator  --  Print the Markdown header separator row.
#   e.g.  | --- | --- | --- |
# ---------------------------------------------------------------------------
_table_md_separator() {
    local -n _tms_widths=$1
    local out="|"
    local w
    for w in "${_tms_widths[@]}"; do
        local dashes
        dashes="$(printf '%*s' "$(( w + 2 ))" '' | tr ' ' '-')"
        out+="${dashes}|"
    done
    echo "$out"
}

# ---------------------------------------------------------------------------
# table_print  --  Main entry point.
#
# Flags (must come before data arguments):
#   --markdown       Emit a Markdown table instead of ASCII.
#   --max-width N    Maximum column width (default: 50).
#
# Data: either pipe-delimited lines on stdin, or one row per argument.
# The first row is always treated as the header.
# ---------------------------------------------------------------------------
table_print() {
    local markdown=0
    local max_width=50
    local -a arg_rows=()

    # Parse flags.
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --markdown)
                markdown=1
                shift
                ;;
            --max-width)
                max_width="${2:?--max-width requires a value}"
                shift 2
                ;;
            --)
                shift
                break
                ;;
            *)
                break
                ;;
        esac
    done

    # Remaining positional arguments are treated as rows.
    while [[ $# -gt 0 ]]; do
        arg_rows+=("$1")
        shift
    done

    # Collect all rows into an array.  Read from stdin if no arg rows and
    # stdin is not a terminal.
    local -a all_rows=()

    if [[ ${#arg_rows[@]} -gt 0 ]]; then
        all_rows=("${arg_rows[@]}")
    elif [[ ! -t 0 ]]; then
        local line
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" ]] && continue
            all_rows+=("$line")
        done
    fi

    if [[ ${#all_rows[@]} -eq 0 ]]; then
        return 0
    fi

    # Split every row into cells and compute column widths.
    local -a col_widths=()
    local -a rows_split=()   # flattened: row0_col0 row0_col1 ... row1_col0 ...
    local num_cols=0

    local row_idx=0
    local raw_row
    for raw_row in "${all_rows[@]}"; do
        local -a cells=()
        IFS='|' read -ra cells <<< "$raw_row"

        # Establish column count from the first (header) row.
        if [[ "$row_idx" -eq 0 ]]; then
            num_cols=${#cells[@]}
            col_widths=()
            local ci
            for (( ci=0; ci<num_cols; ci++ )); do
                col_widths+=(0)
            done
        fi

        local ci
        for (( ci=0; ci<num_cols; ci++ )); do
            local cell="${cells[$ci]:-}"
            # Trim leading/trailing whitespace.
            cell="${cell#"${cell%%[![:space:]]*}"}"
            cell="${cell%"${cell##*[![:space:]]}"}"
            # Truncate to max width.
            cell="$(_table_truncate "$cell" "$max_width")"
            rows_split+=("$cell")

            local vlen
            vlen="$(_table_visible_len "$cell")"
            if [[ "$vlen" -gt "${col_widths[$ci]}" ]]; then
                col_widths[$ci]=$vlen
            fi
        done

        row_idx=$(( row_idx + 1 ))
    done

    local total_rows=$row_idx

    # --------------- Render ---------------

    if [[ "$markdown" -eq 1 ]]; then
        # Markdown mode.
        local ri
        for (( ri=0; ri<total_rows; ri++ )); do
            local -a row_cells=()
            local ci
            for (( ci=0; ci<num_cols; ci++ )); do
                row_cells+=("${rows_split[ ri * num_cols + ci ]}")
            done
            _table_row col_widths "${row_cells[@]}"

            # After the header row, emit the separator.
            if [[ "$ri" -eq 0 ]]; then
                _table_md_separator col_widths
            fi
        done
    else
        # ASCII mode.
        _table_separator col_widths

        local ri
        for (( ri=0; ri<total_rows; ri++ )); do
            local -a row_cells=()
            local ci
            for (( ci=0; ci<num_cols; ci++ )); do
                row_cells+=("${rows_split[ ri * num_cols + ci ]}")
            done
            _table_row col_widths "${row_cells[@]}"

            # After the header row, print another separator.
            if [[ "$ri" -eq 0 ]]; then
                _table_separator col_widths
            fi
        done

        _table_separator col_widths
    fi
}
