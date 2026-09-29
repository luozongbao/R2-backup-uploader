#!/usr/bin/env bash
# filepath: lib/r2.sh
# Shared helpers for R2 Backup Uploader.
# Sourced by bin/r2-upload.sh and bin/r2-download.sh.

# Guard against double-sourcing.
if [[ -n "${__R2_LIB_SOURCED:-}" ]]; then
    return 0 2>/dev/null || true
fi
__R2_LIB_SOURCED=1

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
# Numeric log levels for comparison.
__R2_LOG_LEVEL_DEBUG=10
__R2_LOG_LEVEL_INFO=20
__R2_LOG_LEVEL_WARN=30
__R2_LOG_LEVEL_ERROR=40

__r2_log_level_num() {
    case "${LOG_LEVEL:-info}" in
        debug) echo $__R2_LOG_LEVEL_DEBUG ;;
        info)  echo $__R2_LOG_LEVEL_INFO ;;
        warn)  echo $__R2_LOG_LEVEL_WARN ;;
        error) echo $__R2_LOG_LEVEL_ERROR ;;
        *)     echo $__R2_LOG_LEVEL_INFO ;;
    esac
}

# r2::log <level> <message...>
r2::log() {
    local level="$1"; shift
    local level_num msg
    case "$level" in
        debug) level_num=$__R2_LOG_LEVEL_DEBUG ;;
        info)  level_num=$__R2_LOG_LEVEL_INFO ;;
        warn)  level_num=$__R2_LOG_LEVEL_WARN ;;
        error) level_num=$__R2_LOG_LEVEL_ERROR ;;
        *)     level_num=$__R2_LOG_LEVEL_INFO ;;
    esac

    local current
    current=$(__r2_log_level_num)
    if (( level_num < current )); then
        return 0
    fi

    msg="$*"
    local line
    line="$(date -u '+%Y-%m-%dT%H:%M:%SZ') [${level^^}] ${msg}"

    if [[ -n "${LOG_FILE:-}" ]]; then
        printf '%s\n' "$line" >> "$LOG_FILE"
    else
        printf '%s\n' "$line" >&2
    fi
}

r2::debug() { r2::log debug "$@"; }
r2::info()  { r2::log info  "$@"; }
r2::warn()  { r2::log warn  "$@"; }
r2::error() { r2::log error "$@"; }

# -----------------------------------------------------------------------------
# Environment loading + validation
# -----------------------------------------------------------------------------
# r2::load_env <path-to-env-file>
# Sources the file, sets defaults for optional vars, and validates required
# variables. Pre-existing environment variables (from the calling shell) take
# precedence over values defined in the file — this lets users do things like
# `DRY_RUN=true ./bin/r2-upload.sh` without editing .env.
r2::load_env() {
    local env_file="${1:-./.env}"

    if [[ ! -f "$env_file" ]]; then
        r2::error "Config file not found: $env_file"
        return 1
    fi

    # Source the .env file, but only set variables that are not already set
    # in the environment. This preserves caller-provided overrides.
    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Strip leading whitespace and skip blank lines.
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" ]] && continue

        # Skip full-line comments (lines starting with optional whitespace + #).
        [[ "$line" =~ ^# ]] && continue

        # Strip inline comments: anything from " #" to end of line, but not
        # inside quoted strings.
        local stripped=""
        local i ch in_sq in_dq
        in_sq=0
        in_dq=0
        for (( i=0; i<${#line}; i++ )); do
            ch="${line:$i:1}"
            if (( in_sq == 0 )) && [[ "$ch" == '"' ]]; then
                in_dq=$((1-in_dq))
            elif (( in_dq == 0 )) && [[ "$ch" == "'" ]]; then
                in_sq=$((1-in_sq))
            fi
            # Detect " #" start-of-comment outside quotes.
            if (( in_sq == 0 && in_dq == 0 )) && [[ "$ch" == " " ]]; then
                local rest="${line:$i}"
                if [[ "$rest" =~ ^\ +# ]]; then
                    break
                fi
            fi
            stripped+="$ch"
        done
        line="$stripped"

        # Skip if line became empty after comment strip.
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue

        # Match KEY=VALUE (or KEY="VALUE").
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            # Strip surrounding quotes if present.
            if [[ "$val" =~ ^\"(.*)\"$ ]] || [[ "$val" =~ ^\'(.*)\'$ ]]; then
                val="${BASH_REMATCH[1]}"
            fi
            # Only assign if not already exported.
            if [[ -z "${!key:-}" ]]; then
                printf -v "$key" '%s' "$val"
                export "$key"
            fi
        fi
    done < "$env_file"

    # Defaults for optional vars.
    : "${R2_REGION:=auto}"
    : "${R2_STORAGE_CLASS:=STANDARD}"
    : "${R2_PATH_PREFIX:=backups/$(hostname)/}"
    : "${R2_OVERWRITE:=false}"
    : "${R2_MULTIPART_THRESHOLD:=64MB}"
    : "${R2_MULTIPART_CHUNKSIZE:=32MB}"

    : "${SOURCE_COMPRESS:=true}"
    : "${SOURCE_KEEP_LOCAL:=false}"

    : "${DOWNLOAD_DEST:=./downloads/}"
    : "${DOWNLOAD_OVERWRITE:=false}"
    : "${DOWNLOAD_PATTERN:=*}"
    : "${DOWNLOAD_DELETE_REMOTE:=false}"

    : "${DRY_RUN:=false}"
    : "${REQUIRE_CONFIRM:=true}"
    : "${RETRY_COUNT:=3}"
    : "${RETRY_DELAY:=5}"
    : "${LOG_LEVEL:=info}"
    : "${LOG_FILE:=}"

    r2::debug "Loaded env from $env_file"
}

# r2::require_vars <var1> <var2> ...
# Errors out (returns 1) if any listed variable is empty.
r2::require_vars() {
    local missing=()
    local v
    for v in "$@"; do
        if [[ -z "${!v:-}" ]]; then
            missing+=("$v")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        r2::error "Missing required variables: ${missing[*]}"
        return 1
    fi
}

# r2::require_cmd <cmd1> <cmd2> ...
# Errors out if any command is not on PATH.
r2::require_cmd() {
    local missing=()
    local c
    for c in "$@"; do
        if ! command -v "$c" >/dev/null 2>&1; then
            missing+=("$c")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        r2::error "Missing required commands: ${missing[*]}"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# AWS CLI wrapper
# -----------------------------------------------------------------------------
# r2::aws <args...>
# Wraps the aws CLI with the R2 endpoint, region, and credentials. We use env
# so credentials don't appear in `ps` output. Note: `VAR=val cmd args` in Bash
# returns the exit of `cmd`, but here we run inside a function — the actual
# exit code of `aws` is preserved by `env` which we use to avoid the
# assignment-prefix ambiguity.
r2::aws() {
    env \
        AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
        AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
        AWS_DEFAULT_REGION="$R2_REGION" \
        aws --endpoint-url "$R2_ENDPOINT" --region "$R2_REGION" "$@"
}

# -----------------------------------------------------------------------------
# Retry helper
# -----------------------------------------------------------------------------
# r2::retry <count> <delay-seconds> <cmd...>
# Runs <cmd...>, retrying on failure up to <count> times with <delay-seconds>
# between attempts. Returns the exit code of the last attempt.
r2::retry() {
    local count="$1"; shift
    local delay="$1"; shift
    local attempt=1 rc=0

    while (( attempt <= count )); do
        if "$@"; then
            return 0
        fi
        rc=$?
        if (( attempt >= count )); then
            r2::error "Command failed after ${count} attempts: $*"
            return $rc
        fi
        r2::warn "Attempt ${attempt}/${count} failed (rc=${rc}); retrying in ${delay}s"
        sleep "$delay"
        attempt=$((attempt + 1))
    done
}

# -----------------------------------------------------------------------------
# Confirmation prompt
# -----------------------------------------------------------------------------
# r2::confirm <message>
# Asks the user for y/N. Returns 0 on yes, 1 on no. Skipped when
# REQUIRE_CONFIRM=false or stdin is not a TTY.
r2::confirm() {
    local msg="$1"
    if [[ "${REQUIRE_CONFIRM:-true}" != "true" ]]; then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        # Non-interactive (cron/CI): require explicit opt-in via env.
        r2::warn "Non-interactive shell but REQUIRE_CONFIRM=true; aborting."
        return 1
    fi
    local reply
    read -r -p "${msg} [y/N] " reply
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# -----------------------------------------------------------------------------
# Prefix / path expansion
# -----------------------------------------------------------------------------
# r2::expand_prefix <template>
# Expands $(hostname) and $(date) placeholders.
r2::expand_prefix() {
    local template="$1"
    local hn
    hn="$(hostname 2>/dev/null || echo unknown)"
    local dt
    dt="$(date -u '+%Y-%m-%d')"
    template="${template//\$(hostname)/$hn}"
    template="${template//\$(date)/$dt}"
    printf '%s' "$template"
}

# -----------------------------------------------------------------------------
# Truthy helper
# -----------------------------------------------------------------------------
# r2::is_true <value> — returns 0 if value is "true"/"yes"/"1", else 1.
r2::is_true() {
    case "${1,,}" in
        true|yes|1|on) return 0 ;;
        *) return 1 ;;
    esac
}

# -----------------------------------------------------------------------------
# Run summary / email notifications
# -----------------------------------------------------------------------------
# Per-run state captured in associative-like global variables so the email
# helper at exit can summarise what happened.
__R2_RUN_OPERATION="${__R2_RUN_OPERATION:-unknown}"   # upload | download
__R2_RUN_STATUS="${__R2_RUN_STATUS:-unknown}"         # success | failure | dry-run
__R2_RUN_EXIT_CODE="${__R2_RUN_EXIT_CODE:-0}"
__R2_RUN_START_TS="${__R2_RUN_START_TS:-$(date +%s)}"
__R2_RUN_DETAILS="${__R2_RUN_DETAILS:-}"             # free-form key=value;...
__R2_RUN_LOG_BUFFER="${__R2_RUN_LOG_BUFFER:-}"       # accumulated log lines
__R2_RUN_EMAIL_OVERRIDE="${__R2_RUN_EMAIL_OVERRIDE:-}" # set by -e/--email ADDRESS

# r2::start_run <operation>
# Resets per-run state. Call once at the top of each script.
r2::start_run() {
    __R2_RUN_OPERATION="$1"
    __R2_RUN_STATUS="running"
    __R2_RUN_EXIT_CODE=0
    __R2_RUN_START_TS="$(date +%s)"
    __R2_RUN_DETAILS=""
    __R2_RUN_LOG_BUFFER=""
}

# r2::set_status <status> — record final status for the email summary.
r2::set_status() {
    __R2_RUN_STATUS="$1"
}

# r2::set_exit_code <n>
r2::set_exit_code() {
    __R2_RUN_EXIT_CODE="$1"
}

# r2::record <key>=<value> — append a key=value pair to the summary.
r2::record() {
    if [[ -n "$__R2_RUN_DETAILS" ]]; then
        __R2_RUN_DETAILS+=$'\n'
    fi
    __R2_RUN_DETAILS+="$1"
}

# r2::format_duration <seconds> — human-readable "1h 2m 3s" / "4s".
r2::format_duration() {
    local total="$1"
    local h=$((total / 3600))
    local m=$(( (total % 3600) / 60 ))
    local s=$((total % 60))
    local out=""
    (( h > 0 )) && out+="${h}h "
    (( m > 0 )) && out+="${m}m "
    out+="${s}s"
    printf '%s' "$out"
}

# Internal: tee every log line into the run buffer as well as the configured
# sink (stderr / LOG_FILE). We override r2::log via a wrapper.
__r2_log_sink() {
    local line="$1"
    __R2_RUN_LOG_BUFFER+="${line}"$'\n'
}

# r2::tee_log <level> <message...>
# Behaves like r2::log but also stores the line in the run buffer for the
# email summary. Call this from scripts in addition to (or instead of)
# r2::log when you want the line in the email body.
r2::tee_log() {
    r2::log "$@"
    local line
    line="$(date -u '+%Y-%m-%dT%H:%M:%SZ') [${1^^}] $*"
    __r2_log_sink "$line"
}

# r2::resolve_email_recipients
# Returns 0 and prints recipients if any are configured; returns 1 otherwise.
# Resolution order:
#   1. --email ADDRESS from CLI (stored in __R2_RUN_EMAIL_OVERRIDE)
#   2. EMAIL_TO from .env (comma-separated supported)
r2::resolve_email_recipients() {
    local recipients=""
    if [[ -n "$__R2_RUN_EMAIL_OVERRIDE" ]]; then
        recipients="$__R2_RUN_EMAIL_OVERRIDE"
    elif [[ -n "${EMAIL_TO:-}" ]]; then
        recipients="$EMAIL_TO"
    fi

    if [[ -z "$recipients" ]]; then
        return 1
    fi

    # Normalise whitespace + commas into spaces, then space-separated output.
    recipients="${recipients//,/ }"
    recipients="${recipients//  / }"
    recipients="${recipients#"${recipients%%[![:space:]]*}"}"
    recipients="${recipients%"${recipients##*[![:space:]]}"}"
    printf '%s' "$recipients"
    return 0
}

# r2::should_email
# Returns 0 if we should send an email given the configured flags and current
# run status. Honours EMAIL_ENABLED + EMAIL_ON_SUCCESS / EMAIL_ON_FAILURE.
r2::should_email() {
    r2::is_true "${EMAIL_ENABLED:-false}" || return 1

    case "$__R2_RUN_STATUS" in
        success)
            r2::is_true "${EMAIL_ON_SUCCESS:-true}" || return 1
            ;;
        failure)
            r2::is_true "${EMAIL_ON_FAILURE:-true}" || return 1
            ;;
        dry-run)
            # Dry-runs never send email.
            return 1
            ;;
    esac
    return 0
}

# r2::build_email_body
# Prints the plain-text email body.
r2::build_email_body() {
    local now duration
    now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    duration=$(($(date +%s) - __R2_RUN_START_TS))
    local duration_str
    duration_str="$(r2::format_duration "$duration")"

    cat <<EOF
R2 Backup Uploader — run report
================================

Operation : ${__R2_RUN_OPERATION}
Status    : ${__R2_RUN_STATUS}
Exit code : ${__R2_RUN_EXIT_CODE}
Host      : $(hostname 2>/dev/null || echo unknown)
Started   : $(date -u -d "@${__R2_RUN_START_TS}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "${__R2_RUN_START_TS}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "${__R2_RUN_START_TS}")
Finished  : ${now}
Duration  : ${duration_str}

Details
-------
${__R2_RUN_DETAILS}

Full log
--------
${__R2_RUN_LOG_BUFFER}
EOF
}

# r2::build_email_subject
# Prints the email subject, based on EMAIL_SUBJECT_OK / EMAIL_SUBJECT_FAIL
# with $(hostname) and $(date) expanded.
r2::build_email_subject() {
    local template
    if [[ "$__R2_RUN_STATUS" == "success" ]]; then
        template="${EMAIL_SUBJECT_OK:-[R2] ${__R2_RUN_OPERATION} OK: $(hostname)}"
    else
        template="${EMAIL_SUBJECT_FAIL:-[R2] ${__R2_RUN_OPERATION} FAILED: $(hostname)}"
    fi
    r2::expand_prefix "$template"
}

# r2::send_email
# Sends the notification email using msmtp. Errors are logged but never cause
# the script to fail (email is best-effort).
r2::send_email() {
    local recipients
    if ! recipients="$(r2::resolve_email_recipients)"; then
        r2::warn "Email notification requested but no recipients configured (use -e ADDRESS or set EMAIL_TO)"
        return 0
    fi

    if ! r2::should_email; then
        r2::debug "Email skipped (EMAIL_ENABLED or per-status flag disabled)"
        return 0
    fi

    if ! command -v msmtp >/dev/null 2>&1; then
        r2::error "msmtp not found on PATH; cannot send email notification"
        return 0
    fi

    local subject body
    subject="$(r2::build_email_subject)"
    body="$(r2::build_email_body)"

    # Build a temp file so we don't need to worry about quoting in -s/-a flags.
    local tmp
    tmp="$(mktemp)"
    printf '%s\n' "$body" > "$tmp"

    local rc=0
    # shellcheck disable=SC2086
    env \
        EMAIL_ENABLED="$EMAIL_ENABLED" \
        MSMTP_ACCOUNT="${MSMTP_ACCOUNT:-default}" \
        msmtp --account "${MSMTP_ACCOUNT:-default}" $recipients <<EOF || rc=$?
Subject: ${subject}
From: ${MSMTP_ACCOUNT:-default}
To: ${recipients// /, }
Content-Type: text/plain; charset=UTF-8

$(cat "$tmp")
EOF
    rm -f "$tmp"

    if (( rc != 0 )); then
        r2::error "msmtp exited with rc=${rc}; notification email not sent"
    else
        r2::info "Notification email sent to: ${recipients// /, }"
    fi
    return 0
}
