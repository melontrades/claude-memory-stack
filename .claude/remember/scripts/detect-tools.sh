#!/bin/bash
# ============================================================================
# detect-tools.sh — Detect python and jq with cross-platform fallbacks
# ============================================================================
#
# DESCRIPTION
#   Finds the correct python and jq commands, handling platform differences:
#     - python3 vs python (Windows only has python by default)
#     - jq presence check with shell fallback for simple JSON reads
#     - CRLF-safe variable capture from Python output (Windows Git Bash)
#
# USAGE
#   source "$(dirname "$0")/detect-tools.sh"
#   # Now PYTHON and JQ are set
#   $PYTHON -m pipeline.shell extract ...
#   val=$($JQ -r '.key' file.json)
#
# ENVIRONMENT (outputs)
#   PYTHON       Path/command for python (python3 or python, validated)
#   JQ           Path/command for jq (jq or _jq_fallback function)
#
# EXIT CODES
#   1   No usable python found
#
# ============================================================================

# --- Detect Python ---
# Try python3 first (macOS/Linux default), fall back to python (Windows).
# On Windows, python3 may resolve to the MS Store stub which exists in PATH
# but cannot actually run Python — validate with --version before trusting.
if command -v python3 >/dev/null 2>&1 && python3 --version >/dev/null 2>&1; then
    PYTHON="python3"
elif command -v python >/dev/null 2>&1 && python --version >/dev/null 2>&1; then
    PYTHON="python"
else
    echo "FATAL: Neither python3 nor python found in PATH" >&2
    exit 1
fi
export PYTHON

# --- Detect jq ---
# jq is optional — provide a Python-based fallback for simple JSON reads.
# On Windows, winget installs jq to a long AppData path not on Git Bash's PATH.
# Probe the known winget location before falling back.
if command -v jq >/dev/null 2>&1; then
    JQ="jq"
elif _winget_jq=$(find "$HOME/AppData/Local/Microsoft/WinGet/Packages" -name "jq.exe" 2>/dev/null | head -1) && [ -x "$_winget_jq" ]; then
    JQ="$_winget_jq"
else
    # Fallback: use Python for JSON queries
    # Supports: jq -r '.key' file.json  (single-level key extraction)
    _jq_fallback() {
        local _jq_flags=""
        while [[ "$1" == -* ]]; do _jq_flags="$_jq_flags $1"; shift; done
        local _jq_query="$1"
        local _jq_file="$2"
        $PYTHON -c "
import json, sys
try:
    data = json.load(open('$_jq_file'))
    keys = '$_jq_query'.strip('.').split('.')
    val = data
    for k in keys:
        if k and isinstance(val, dict):
            val = val.get(k)
        if val is None:
            break
    if val is None:
        sys.exit(0)
    print(val if isinstance(val, (str, int, float, bool)) else json.dumps(val))
except Exception:
    sys.exit(0)
" 2>/dev/null
    }
    JQ="_jq_fallback"
fi
export JQ

# --- CRLF-safe safe_eval ---
# Override safe_eval to strip \r from lines before eval.
# On Windows (Git Bash), Python outputs \r\n. read -r keeps the \r,
# which corrupts variable values (e.g., POSITION="42\r" breaks arithmetic).
safe_eval() {
    while IFS= read -r line; do
        line="${line%$'\r'}"
        if [[ "$line" =~ ^[A-Z_][A-Z0-9_]*= ]]; then
            eval "$line"
        fi
    done
}

# --- CRLF-safe session dir slug ---
# Claude Code names its project dirs by replacing non-alnum chars with dashes.
# On Windows, Claude uses the native path (C:\Users\...) but Git Bash resolves
# PROJECT_DIR to /c/Users/... — producing a different slug. To handle this,
# try the direct slug first, then look for a matching directory by basename.
session_dir_slug() {
    local _direct
    _direct=$(echo "$1" | sed 's/[^a-zA-Z0-9]/-/g')
    local _sessions_base="$HOME/.claude/projects"
    # If the direct slug exists, use it
    if [ -d "$_sessions_base/$_direct" ]; then
        echo "$_direct"
        return
    fi
    # Fallback: find a directory whose name ends with the project basename slug
    local _basename_slug
    _basename_slug=$(basename "$1" | sed 's/[^a-zA-Z0-9]/-/g')
    local _match
    _match=$(ls -d "$_sessions_base/"*"$_basename_slug" 2>/dev/null | head -1)
    if [ -n "$_match" ]; then
        basename "$_match"
        return
    fi
    # Last resort: return the direct slug (will fail downstream)
    echo "$_direct"
}
