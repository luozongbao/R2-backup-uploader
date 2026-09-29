#!/usr/bin/env bash
# filepath: bin/r2-download.sh
# Download an object (or sync a prefix) from Cloudflare R2.
#
# Usage:
#   ./bin/r2-download.sh [--config <env>] [--key <key> | --prefix <prefix>]
#                        [--dest <dir>] [--delete-remote] [--dry-run] [--help]
#
# If neither --key nor --prefix is given, the expanded R2_PATH_PREFIX is used.
# See docs/README.md for full configuration options.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/r2.sh
source "${SCRIPT_DIR}/../lib/r2.sh"

# -----------------------------------------------------------------------------
# Defaults / CLI parsing
# -----------------------------------------------------------------------------
CONFIG_FILE="./.env"
KEY_OVERRIDE=""
PREFIX_OVERRIDE=""
DEST_OVERRIDE=""
DELETE_REMOTE_CLI=false
DRY_RUN_CLI=false
EMAIL_CLI_FLAG=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --config <path>      Path to .env file (default: ./.env)
  --key <key>          Download a single object key
  --prefix <prefix>    Sync everything under a prefix
  --dest <dir>         Override DOWNLOAD_DEST
  --delete-remote      Delete from R2 after successful download
  --dry-run            Show what would happen, do not download
  -e, --email [ADDR]   Send notification email.
                         If ADDR is provided, override EMAIL_TO for this run.
                         If no ADDR, use EMAIL_TO from .env.
                         Errors if neither is set.
  --help               Show this help

If neither --key nor --prefix is given, the expanded R2_PATH_PREFIX is used.
EOF
}

EMAIL_VALUE=""
while (( $# > 0 )); do
    case "$1" in
        --config)        CONFIG_FILE="$2"; shift 2 ;;
        --key)           KEY_OVERRIDE="$2"; shift 2 ;;
        --prefix)        PREFIX_OVERRIDE="$2"; shift 2 ;;
        --dest)          DEST_OVERRIDE="$2"; shift 2 ;;
        --delete-remote) DELETE_REMOTE_CLI=true; shift ;;
        --dry-run)       DRY_RUN_CLI=true; shift ;;
        -e|--email)
            EMAIL_CLI_FLAG=true
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
r2::start_run download

if [[ "$EMAIL_CLI_FLAG" == "true" ]]; then
    EMAIL_ENABLED=true
    if [[ -n "$EMAIL_VALUE" ]]; then
        __R2_RUN_EMAIL_OVERRIDE="$EMAIL_VALUE"
    fi
    if [[ -z "$EMAIL_VALUE" && -z "${EMAIL_TO:-}" ]]; then
        echo "Error: -e/--email requested but no EMAIL_TO set in .env and no ADDRESS given" >&2
        exit 2
    fi
fi

r2::load_env "$CONFIG_FILE" || exit 1

if [[ "$EMAIL_CLI_FLAG" == "true" ]]; then
    EMAIL_ENABLED=true
    if [[ -n "$EMAIL_VALUE" ]]; then
        __R2_RUN_EMAIL_OVERRIDE="$EMAIL_VALUE"
    fi
fi

if [[ "$DRY_RUN_CLI" == "true" ]]; then
    DRY_RUN=true
fi
if [[ "$DELETE_REMOTE_CLI" == "true" ]]; then
    DOWNLOAD_DELETE_REMOTE=true
fi

r2::require_cmd aws || exit 1
r2::require_vars R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET || exit 1

DEST="${DEST_OVERRIDE:-$DOWNLOAD_DEST}"
DEST="$(r2::abspath "$DEST")"
if [[ -z "$DEST" ]]; then
    r2::error "DOWNLOAD_DEST is empty (set in .env or pass --dest)"
    exit 2
fi

# Trap for cleanup + email summary.
cleanup() {
    local rc=$?
    r2::set_exit_code "$rc"

    if r2::is_true "$DRY_RUN"; then
        r2::set_status dry-run
    elif (( rc == 0 )); then
        r2::set_status success
    else
        r2::set_status failure
    fi

    r2::tee_log info "Exiting with rc=${rc}, status=${__R2_RUN_STATUS}"
    r2::send_email || true
    exit $rc
}
trap cleanup EXIT INT TERM

# -----------------------------------------------------------------------------
# Resolve mode
# -----------------------------------------------------------------------------
MODE=""
REMOTE=""
EXTRA_ARGS=()

if [[ -n "$KEY_OVERRIDE" ]]; then
    MODE="single"
    REMOTE="s3://${R2_BUCKET}/${KEY_OVERRIDE#/}"
    # Ensure destination exists.
    mkdir -p "$DEST"
    LOCAL_PATH="${DEST%/}/$(basename "$REMOTE")"
elif [[ -n "$PREFIX_OVERRIDE" ]]; then
    MODE="sync"
    # Strip leading slash, ensure trailing slash for prefix semantics.
    PREFIX_CLEAN="${PREFIX_OVERRIDE#/}"
    PREFIX_CLEAN="${PREFIX_CLEAN%/}/"
    REMOTE="s3://${R2_BUCKET}/${PREFIX_CLEAN}"
    mkdir -p "$DEST"
    LOCAL_PATH="$DEST"
else
    MODE="sync"
    PREFIX_EXPANDED="$(r2::expand_prefix "$R2_PATH_PREFIX")"
    PREFIX_EXPANDED="${PREFIX_EXPANDED%/}/"
    REMOTE="s3://${R2_BUCKET}/${PREFIX_EXPANDED}"
    mkdir -p "$DEST"
    LOCAL_PATH="$DEST"
fi

# Apply pattern filter (single mode only uses shell-side check).
if [[ "$DOWNLOAD_PATTERN" != "*" ]]; then
    EXTRA_ARGS+=(--exclude "*" --include "$DOWNLOAD_PATTERN")
fi

r2::record "mode=${MODE}"
r2::record "remote=${REMOTE}"
r2::record "local=${LOCAL_PATH}"
r2::record "pattern=${DOWNLOAD_PATTERN}"
r2::record "delete_remote=${DOWNLOAD_DELETE_REMOTE}"
r2::record "dry_run=${DRY_RUN}"

# -----------------------------------------------------------------------------
# Pre-flight
# -----------------------------------------------------------------------------
if r2::is_true "$DRY_RUN"; then
    r2::tee_log info "[DRY-RUN] Mode:        $MODE"
    r2::tee_log info "[DRY-RUN] Remote:      $REMOTE"
    r2::tee_log info "[DRY-RUN] Local dest:  $LOCAL_PATH"
    if r2::is_true "$DOWNLOAD_DELETE_REMOTE"; then
        r2::tee_log info "[DRY-RUN] Would delete remote objects after download"
    fi
    exit 0
fi

r2::confirm "Download ${MODE} from $REMOTE to $LOCAL_PATH?" || {
    r2::tee_log warn "Aborted by user"
    exit 1
}

# -----------------------------------------------------------------------------
# Download
# -----------------------------------------------------------------------------
run_download() {
    if [[ "$MODE" == "single" ]]; then
        r2::aws s3 cp "$REMOTE" "$LOCAL_PATH" --only-show-errors
    else
        # shellcheck disable=SC2086
        r2::aws s3 sync "$REMOTE" "$LOCAL_PATH" --only-show-errors ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
    fi
}

r2::tee_log info "Downloading $REMOTE -> $LOCAL_PATH"
if ! r2::retry "$RETRY_COUNT" "$RETRY_DELAY" run_download; then
    r2::tee_log error "Download failed: $REMOTE"
    exit 1
fi

# -----------------------------------------------------------------------------
# Optional remote delete (DR rotation)
# -----------------------------------------------------------------------------
if r2::is_true "$DOWNLOAD_DELETE_REMOTE"; then
    r2::tee_log warn "DOWNLOAD_DELETE_REMOTE=true — removing remote objects after download"
    run_delete() {
        if [[ "$MODE" == "single" ]]; then
            r2::aws s3 rm "$REMOTE" --only-show-errors
        else
            # shellcheck disable=SC2086
            r2::aws s3 rm "$REMOTE" --recursive --only-show-errors ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
        fi
    }
    if ! r2::retry "$RETRY_COUNT" "$RETRY_DELAY" run_delete; then
        r2::tee_log error "Remote delete failed; local copy is safe at $LOCAL_PATH"
        exit 1
    fi
    r2::tee_log info "Remote objects removed"
fi

r2::tee_log info "Download complete: $LOCAL_PATH"
exit 0
