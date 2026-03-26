#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# json.sh -- Incremental JSON array builder for bash
#
# Build a JSON array of objects entirely in bash, without requiring jq at
# call sites.  Handles proper escaping of special characters (quotes,
# backslashes, newlines, tabs, control characters).
#
# Usage:
#   source lib/json.sh
#
#   json_start_array
#   json_add_object "name=my-instance" "region=us-east-1" "cost=45.20"
#   json_add_object "name=other-inst" "region=eu-west-1" "cost=12.50"
#   json_end_array
#   json_write /tmp/report.json
#
#   # Or capture to a variable:
#   output="$(json_dump)"
# ---------------------------------------------------------------------------

# Guard against double-sourcing.
[[ -n "${_JSON_SH_LOADED:-}" ]] && return 0
_JSON_SH_LOADED=1

# Internal state: accumulated JSON fragments.
_JSON_BUFFER=""
_JSON_OBJECT_COUNT=0

# ---------------------------------------------------------------------------
# _json_escape  --  Escape a string for safe inclusion in a JSON value.
#
# Handles: backslash, double-quote, newline, carriage return, tab, and
# other control characters (U+0000 through U+001F).
# ---------------------------------------------------------------------------
_json_escape() {
    local s="$1"
    local out=""
    local i char ord

    for (( i=0; i<${#s}; i++ )); do
        char="${s:$i:1}"
        case "$char" in
            '"')  out+='\"' ;;
            '\') out+='\\' ;;
            $'\n') out+='\\n' ;;
            $'\r') out+='\\r' ;;
            $'\t') out+='\\t' ;;
            $'\b') out+='\\b' ;;
            $'\f') out+='\\f' ;;
            *)
                # Check for other control characters (0x00-0x1F).
                ord="$(printf '%d' "'$char" 2>/dev/null || echo 0)"
                if (( ord >= 0 && ord < 32 )); then
                    printf -v escaped '\\u%04x' "$ord"
                    out+="$escaped"
                else
                    out+="$char"
                fi
                ;;
        esac
    done

    printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# _json_is_number  --  Return 0 if the string looks like a JSON number.
# ---------------------------------------------------------------------------
_json_is_number() {
    local val="$1"
    [[ "$val" =~ ^-?[0-9]+\.?[0-9]*([eE][+-]?[0-9]+)?$ ]]
}

# ---------------------------------------------------------------------------
# _json_is_bool_or_null  --  Return 0 if the string is a JSON literal.
# ---------------------------------------------------------------------------
_json_is_bool_or_null() {
    local val="$1"
    [[ "$val" == "true" || "$val" == "false" || "$val" == "null" ]]
}

# ---------------------------------------------------------------------------
# json_start_array  --  Begin a new JSON array.  Resets internal state.
# ---------------------------------------------------------------------------
json_start_array() {
    _JSON_BUFFER=""
    _JSON_OBJECT_COUNT=0
}

# ---------------------------------------------------------------------------
# json_add_object <key=val> [key=val ...]
#
# Append an object to the array.  Each argument is a key=value pair.
# The key becomes the JSON object key (string).  The value is auto-typed:
#   - Numbers are emitted unquoted.
#   - "true", "false", "null" are emitted as literals.
#   - Everything else is emitted as a quoted string.
#
# To force a value to be a string even if it looks like a number, prefix
# the value with 's:' -- e.g. "zip=s:07030".
# ---------------------------------------------------------------------------
json_add_object() {
    local obj="{"
    local first=1
    local arg

    for arg in "$@"; do
        # Split on the first '=' only.
        local key="${arg%%=*}"
        local val="${arg#*=}"

        if (( first == 0 )); then
            obj+=", "
        fi
        first=0

        # Escape the key.
        local escaped_key
        escaped_key="$(_json_escape "$key")"

        # Determine value type.
        local force_string=0
        if [[ "$val" == s:* ]]; then
            val="${val#s:}"
            force_string=1
        fi

        if (( force_string == 0 )) && _json_is_bool_or_null "$val"; then
            obj+="\"${escaped_key}\": ${val}"
        elif (( force_string == 0 )) && _json_is_number "$val"; then
            obj+="\"${escaped_key}\": ${val}"
        else
            local escaped_val
            escaped_val="$(_json_escape "$val")"
            obj+="\"${escaped_key}\": \"${escaped_val}\""
        fi
    done

    obj+="}"

    if (( _JSON_OBJECT_COUNT > 0 )); then
        _JSON_BUFFER+=","
    fi
    _JSON_BUFFER+=$'\n'"  ${obj}"
    _JSON_OBJECT_COUNT=$(( _JSON_OBJECT_COUNT + 1 ))
}

# ---------------------------------------------------------------------------
# json_end_array  --  Finalize the array.  After this call, use json_dump
# or json_write to retrieve the output.
# ---------------------------------------------------------------------------
json_end_array() {
    # Nothing strictly required; the dump/write functions close the array.
    :
}

# ---------------------------------------------------------------------------
# json_dump  --  Print the completed JSON array to stdout.
# ---------------------------------------------------------------------------
json_dump() {
    if (( _JSON_OBJECT_COUNT == 0 )); then
        echo "[]"
    else
        echo "[${_JSON_BUFFER}"
        echo "]"
    fi
}

# ---------------------------------------------------------------------------
# json_write <file>  --  Write the completed JSON array to a file.
#
# Creates parent directories if they do not exist.
# ---------------------------------------------------------------------------
json_write() {
    local file="${1:?json_write: file path required}"
    local dir
    dir="$(dirname "$file")"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
    fi
    json_dump > "$file"
}
