#!/usr/bin/env bash
# filepath: bin/r2-upload.sh
# Upload a file or directory to Cloudflare R2.
#
# Usage:
#   ./bin/r2-upload.sh [--config <env>] [--source <path>] [--dry-run] [--help]
#
# See docs/README.md for full configuration options.

set -euo pipefail

# Tiny pre-load fatal logger: mirrors r2::log's TTY-aware sink + honours an
# externally-set LOG_FILE (cron can set it before invoking the script). Used
# only for CLI parse errors that fire before lib/r2.sh is sourced.
__r2_fatal() {
    local line
    line="$(date -u '+%Y-%m-%dT%H:%M:%SZ') [ERROR] $*"
    if [[ -t 1 ]]; then
        printf '%s\n' "$line"
    else
        printf '%s\n' "$line" >&2
    fi
    if [[ -n "${LOG_FILE:-}" ]]; then
        printf '%s\n' "$line" >> "$LOG_FILE"
    fi
}

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
        *) __r2_fatal "Unknown option: $1"; usage; exit 2 ;;
    esac
done

# -----------------------------------------------------------------------------
# Bootstrap
# -----------------------------------------------------------------------------
r2::start_run upload

# Load .env first so EMAIL_TO is available for -e validation.
r2::load_env "$CONFIG_FILE" || exit 1

# -e/--email handling (post-load so EMAIL_TO is populated).
# Precedence:
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
        r2::log error "-e/--email requested but no EMAIL_TO set in .env and no ADDRESS given"
        exit 2
    fi
fi

# CLI --dry-run overrides env.
if [[ "$DRY_RUN_CLI" == "true" ]]; then
    DRY_RUN=true
fi

r2::require_cmd aws || exit 1
r2::require_vars R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET || exit 1

# Resolve source path.
SRC="${SOURCE_OVERRIDE:-$SOURCE_PATH}"
if [[ -z "${SRC:-}" ]]; then
    r2::error "SOURCE_PATH is not set (use --source or define in .env)"
    exit 1
fi
# Expand a leading "~" to $HOME (the .env loader can't do this because
# quoted values round-trip through the shell unchanged).
SRC="$(r2::abspath "$SRC")"

# -----------------------------------------------------------------------------
# Prepare source
# -----------------------------------------------------------------------------
# Returns the list of files to upload, one per line. For a single file, prints
# that file. For a directory, prints every regular file inside (non-recursive
# by default; we don't try to be clever about recursion since backups are
# usually a flat dump folder).
prepare_source() {
    if [[ -f "$SRC" ]]; then
        printf '%s\n' "$SRC"
        return 0
    fi

    if [[ -d "$SRC" ]]; then
        local f
        local count=0
        while IFS= read -r f; do
            printf '%s\n' "$f"
            count=$((count + 1))
        done < <(find "$SRC" -mindepth 1 -maxdepth 1 -type f)
        if (( count == 0 )); then
            r2::error "SOURCE_PATH is a directory but contains no regular files: $SRC"
            return 1
        fi
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

    exit $rc
}
trap cleanup EXIT INT TERM

# Resolve the list of files to upload.
mapfile -t SOURCE_FILES < <(prepare_source) || exit 1

PREFIX="$(r2::expand_prefix "$R2_PATH_PREFIX")"
PREFIX="${PREFIX%/}"

# Validate archive configuration up-front so we fail before doing work.
if r2::is_true "$ARCHIVE_AFTER_UPLOAD" && [[ -z "${SOURCE_ARCHIVE_DIR:-}" ]]; then
    r2::error "ARCHIVE_AFTER_UPLOAD=true but SOURCE_ARCHIVE_DIR is empty"
    exit 2
fi

r2::record "source_count=${#SOURCE_FILES[@]}"
r2::record "bucket=${R2_BUCKET}"
r2::record "prefix=${PREFIX}"
r2::record "storage_class=${R2_STORAGE_CLASS}"
r2::record "dry_run=${DRY_RUN}"
r2::record "archive_after=${ARCHIVE_AFTER_UPLOAD}"
r2::record "archive_dir=${SOURCE_ARCHIVE_DIR:-}"

# -----------------------------------------------------------------------------
# Pre-flight: dry-run
# -----------------------------------------------------------------------------
if r2::is_true "$DRY_RUN"; then
    dry_run_target_dir="$(r2::archive_target_dir 2>/dev/null || true)"
    r2::tee_log info "[DRY-RUN] Would upload ${#SOURCE_FILES[@]} file(s) from: $SRC"
    for f in "${SOURCE_FILES[@]}"; do
        key="${PREFIX}/$(basename "$f")"
        r2::tee_log info "[DRY-RUN]   s3://${R2_BUCKET}/${key}"
    done
    if r2::is_true "$ARCHIVE_AFTER_UPLOAD"; then
        r2::tee_log info "[DRY-RUN] After upload, would move files to: ${dry_run_target_dir:-<no archive dir>}"
    fi
    exit 0
fi

# Interactive confirmation.
r2::confirm "Upload ${#SOURCE_FILES[@]} file(s) from $SRC to s3://${R2_BUCKET}/${PREFIX}/?" || {
    r2::tee_log warn "Aborted by user"
    exit 1
}

# -----------------------------------------------------------------------------
# Upload loop
# -----------------------------------------------------------------------------
declare -a UPLOADED_KEYS=()
declare -a UPLOADED_LOCALS=()
declare -a SKIPPED_KEYS=()

f=""
key=""
verify_rc=0
for f in "${SOURCE_FILES[@]}"; do
    key="${PREFIX}/$(basename "$f")"

    # Skip if exists and overwrite disabled.
    if ! r2::is_true "$R2_OVERWRITE"; then
        if r2::aws s3api head-object --bucket "$R2_BUCKET" --key "$key" >/dev/null 2>&1; then
            r2::tee_log info "Skip (exists, overwrite=false): s3://${R2_BUCKET}/${key}"
            SKIPPED_KEYS+=("$key")
            continue
        fi
    fi

    r2::tee_log info "Uploading $f -> s3://${R2_BUCKET}/${key}"
    if ! r2::retry "$RETRY_COUNT" "$RETRY_DELAY" \
        r2::aws s3 cp "$f" "s3://${R2_BUCKET}/${key}" \
            --storage-class "$R2_STORAGE_CLASS" \
            --checksum-algorithm SHA256; then
        r2::tee_log error "Upload failed: s3://${R2_BUCKET}/${key}"
        exit 1
    fi

    # Track uploaded files now (before verify) so a failed verify of one file
    # doesn't strand earlier successes in the source folder. The verify result
    # only controls whether to KEEP the file tracked for archiving or not.
    UPLOADED_KEYS+=("$key")
    UPLOADED_LOCALS+=("$f")

    # Verify with checksum. verify_rc: 0=match, 1=mismatch, 2=inconclusive.
    verify_rc=0
    if ! r2::verify_checksum "$f" "$R2_BUCKET" "$key"; then
        verify_rc=$?
    fi
    if (( verify_rc == 2 )); then
        # Could not compute — don't archive, don't fail (file stays in place).
        r2::warn "Checksum verification inconclusive for $f; not archiving"
        # Remove from upload lists so archive step leaves it alone.
        unset "UPLOADED_KEYS[$((${#UPLOADED_KEYS[@]}-1))]"
        unset "UPLOADED_LOCALS[$((${#UPLOADED_LOCALS[@]}-1))]"
    elif (( verify_rc == 1 )); then
        r2::error "Checksum verification FAILED for $f; leaving local file in place"
        unset "UPLOADED_KEYS[$((${#UPLOADED_KEYS[@]}-1))]"
        unset "UPLOADED_LOCALS[$((${#UPLOADED_LOCALS[@]}-1))]"
        exit 1
    fi
done

r2::tee_log info "Uploaded ${#UPLOADED_KEYS[@]} file(s); skipped ${#SKIPPED_KEYS[@]}"

# -----------------------------------------------------------------------------
# Archive (move to archive folder)
# -----------------------------------------------------------------------------
if r2::is_true "$ARCHIVE_AFTER_UPLOAD" && (( ${#UPLOADED_LOCALS[@]} > 0 )); then
    for f in "${UPLOADED_LOCALS[@]}"; do
        if ! r2::move_to_archive "$f"; then
            r2::error "Failed to archive $f; leaving local file in place"
            exit 1
        fi
    done
fi

exit 0

