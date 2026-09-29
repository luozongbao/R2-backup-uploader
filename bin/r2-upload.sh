#!/usr/bin/env bash
# filepath: bin/r2-upload.sh
# Upload a file or directory to Cloudflare R2.
#
# Usage:
#   ./bin/r2-upload.sh [--config <env>] [--source <path>] [--dry-run] [--help]
#
# See docs/README.md for full configuration options.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/r2.sh
source "${SCRIPT_DIR}/../lib/r2.sh"

# -----------------------------------------------------------------------------
# Defaults / CLI parsing
# -----------------------------------------------------------------------------
CONFIG_FILE="./.env"
SOURCE_OVERRIDE=""
DRY_RUN_CLI=false
EMAIL_CLI_FLAG=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --config <path>      Path to .env file (default: ./.env)
  --source <path>      Override SOURCE_PATH from config
  --dry-run            Show what would happen, do not upload
  -e, --email [ADDR]   Send notification email.
                         If ADDR is provided, override EMAIL_TO for this run.
                         If no ADDR, use EMAIL_TO from .env.
                         Errors if neither is set.
  --help               Show this help
EOF
}

# -e / --email supports an *optional* value (only when separated by a space).
# To handle "-e user@x.com" vs "-e" with no arg, we peek at the next token.
EMAIL_VALUE=""
while (( $# > 0 )); do
    case "$1" in
        --config)        CONFIG_FILE="$2"; shift 2 ;;
        --source)        SOURCE_OVERRIDE="$2"; shift 2 ;;
        --dry-run)       DRY_RUN_CLI=true; shift ;;
        -e|--email)
            EMAIL_CLI_FLAG=true
            # Optional value: only consume next arg if it doesn't start with '-'.
            if (( $# > 1 )) && [[ "$2" != -* ]]; then
                EMAIL_VALUE="$2"; shift 2
            else
                shift
            fi
            ;;
        --help|-h)       usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

# -----------------------------------------------------------------------------
# Bootstrap
# -----------------------------------------------------------------------------
r2::start_run upload

# -e/--email handling. Precedence:
#   - if CLI flag was passed AND a value was given, use that (overrides EMAIL_TO)
#   - if CLI flag was passed without a value, force EMAIL_ENABLED=true (use EMAIL_TO)
#   - if CLI flag absent, leave EMAIL_ENABLED as-is from .env
if [[ "$EMAIL_CLI_FLAG" == "true" ]]; then
    EMAIL_ENABLED=true
    if [[ -n "$EMAIL_VALUE" ]]; then
        __R2_RUN_EMAIL_OVERRIDE="$EMAIL_VALUE"
    fi
    # Validate that we have at least one source of recipients.
    if [[ -z "$EMAIL_VALUE" && -z "${EMAIL_TO:-}" ]]; then
        echo "Error: -e/--email requested but no EMAIL_TO set in .env and no ADDRESS given" >&2
        exit 2
    fi
fi

r2::load_env "$CONFIG_FILE" || exit 1

# Re-apply email override after .env load (in case it overrode it — though our
# new parser preserves caller env, this is belt-and-braces).
if [[ "$EMAIL_CLI_FLAG" == "true" ]]; then
    EMAIL_ENABLED=true
    if [[ -n "$EMAIL_VALUE" ]]; then
        __R2_RUN_EMAIL_OVERRIDE="$EMAIL_VALUE"
    fi
fi

# CLI --dry-run overrides env.
if [[ "$DRY_RUN_CLI" == "true" ]]; then
    DRY_RUN=true
fi

r2::require_cmd aws tar || exit 1
r2::require_vars R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET || exit 1

# Resolve source path.
SRC="${SOURCE_OVERRIDE:-$SOURCE_PATH}"
if [[ -z "${SRC:-}" ]]; then
    r2::error "SOURCE_PATH is not set (use --source or define in .env)"
    exit 1
fi

# -----------------------------------------------------------------------------
# Prepare source
# -----------------------------------------------------------------------------
TEMP_TARBALL=""
prepare_source() {
    if [[ -f "$SRC" ]]; then
        echo "$SRC"
        return 0
    fi

    if [[ -d "$SRC" ]]; then
        if ! r2::is_true "$SOURCE_COMPRESS"; then
            r2::error "SOURCE_PATH is a directory but SOURCE_COMPRESS=false; set SOURCE_COMPRESS=true or pass a file"
            return 1
        fi
        local base name
        base="$(basename "$SRC")"
        name="${base}-$(date -u '+%Y%m%dT%H%M%SZ').tar.gz"
        TEMP_TARBALL="$(mktemp -t "${name}.XXXXXX")"
        r2::info "Compressing directory $SRC -> $TEMP_TARBALL"
        tar -czf "$TEMP_TARBALL" -C "$(dirname "$SRC")" "$base"
        echo "$TEMP_TARBALL"
        return 0
    fi

    r2::error "SOURCE_PATH does not exist or is not a regular file/directory: $SRC"
    return 1
}

cleanup() {
    local rc=$?
    r2::set_exit_code "$rc"

    # Decide final status for the email summary.
    if r2::is_true "$DRY_RUN"; then
        r2::set_status dry-run
    elif (( rc == 0 )); then
        r2::set_status success
    else
        r2::set_status failure
    fi

    # Add a final summary line to the buffer.
    r2::tee_log info "Exiting with rc=${rc}, status=${__R2_RUN_STATUS}"

    # Send notification email (best-effort; never fails the script).
    r2::send_email || true

    if [[ -n "$TEMP_TARBALL" && -f "$TEMP_TARBALL" ]]; then
        rm -f "$TEMP_TARBALL"
        r2::debug "Removed temp tarball $TEMP_TARBALL"
    fi
    exit $rc
}
trap cleanup EXIT INT TERM

UPLOAD_FILE="$(prepare_source)" || exit 1
FILENAME="$(basename "$UPLOAD_FILE")"

PREFIX="$(r2::expand_prefix "$R2_PATH_PREFIX")"
# Strip trailing slash for clean join.
PREFIX="${PREFIX%/}"
KEY="${PREFIX}/${FILENAME}"

r2::record "source=${UPLOAD_FILE}"
r2::record "destination=s3://${R2_BUCKET}/${KEY}"
r2::record "bucket=${R2_BUCKET}"
r2::record "key=${KEY}"
r2::record "storage_class=${R2_STORAGE_CLASS}"
r2::record "dry_run=${DRY_RUN}"

# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------
if r2::is_true "$DRY_RUN"; then
    r2::tee_log info "[DRY-RUN] Would upload: $UPLOAD_FILE"
    r2::tee_log info "[DRY-RUN]       to:   s3://${R2_BUCKET}/${KEY}"
    r2::tee_log info "[DRY-RUN]       storage-class: $R2_STORAGE_CLASS"
    exit 0
fi

# Check for existing key unless overwrite is enabled.
if ! r2::is_true "$R2_OVERWRITE"; then
    if r2::aws s3api head-object --bucket "$R2_BUCKET" --key "$KEY" >/dev/null 2>&1; then
        r2::tee_log warn "Object already exists and R2_OVERWRITE=false: s3://${R2_BUCKET}/${KEY}"
        exit 0
    fi
fi

# Interactive confirmation.
r2::confirm "Upload $UPLOAD_FILE to s3://${R2_BUCKET}/${KEY}?" || {
    r2::tee_log warn "Aborted by user"
    exit 1
}

# -----------------------------------------------------------------------------
# Upload
# -----------------------------------------------------------------------------
r2::tee_log info "Uploading $UPLOAD_FILE -> s3://${R2_BUCKET}/${KEY}"
if ! r2::retry "$RETRY_COUNT" "$RETRY_DELAY" \
    r2::aws s3 cp "$UPLOAD_FILE" "s3://${R2_BUCKET}/${KEY}" \
        --storage-class "$R2_STORAGE_CLASS"; then
    r2::tee_log error "Upload failed: s3://${R2_BUCKET}/${KEY}"
    exit 1
fi

r2::tee_log info "Upload complete: s3://${R2_BUCKET}/${KEY}"

# Optionally remove local source.
if [[ -n "${SOURCE_OVERRIDE:-}" ]] || r2::is_true "$SOURCE_KEEP_LOCAL"; then
    :
else
    # Only auto-remove if source was the configured path (avoid clobbering
    # user-supplied --source).
    if [[ -z "${SOURCE_OVERRIDE:-}" && "$UPLOAD_FILE" != "$SRC" ]]; then
        # Uploaded a temp tarball; already cleaned up by trap.
        :
    fi
fi

exit 0
