# R2 Backup Uploader

A Bash-based tool to upload **and** download backup files and directories to/from Cloudflare R2 (S3-compatible object storage). Designed for easy configuration per Cloudflare R2 account via `.env` files.

---

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Directory Structure](#directory-structure)
- [Installation](#installation)
- [Configuration](#configuration)
- [Usage](#usage)
- [Examples](#examples)
- [Downloading Backups](#downloading-backups)
- [Development Environment](#development-environment)
- [Roadmap](#roadmap)

---

## Overview

R2 Backup Uploader is a lightweight Bash tool that automates **uploading and downloading** backups to/from Cloudflare R2. It uses AWS CLI v2 (which supports R2 via custom endpoints) and provides per-account configuration through `.env` files, making it easy to manage multiple R2 accounts or environments.

---

## Features

- ✅ **Upload** files or directories (each file as a separate object) to R2
- ✅ **Download** individual keys or sync entire prefixes back from R2
- ✅ **Per-account configuration** via `.env` files
- ✅ **Auto-archive** verified uploads into a dated folder
- ✅ **SHA-256 checksum verification** after every upload
- ✅ **Dry-run mode** for safe testing
- ✅ **Retry logic** with configurable attempts and delays
- ✅ **Safety checks** (overwrite protection, confirmation prompts)
- ✅ **Flexible key prefixes** with hostname/date expansion
- ✅ **Detailed logging** with configurable levels
- ✅ **Email notifications** via `msmtp` — success / failure summaries, configurable per-run
- ✅ **Cron-friendly** with non-interactive mode
- ✅ **Cross-platform** support (Linux + macOS)

---

## Directory Structure

```
R2-backup-uploader/
├── docs/
│   ├── About.md
│   └── README.md              # ← this file
├── bin/
│   ├── r2-upload.sh           # upload script
│   └── r2-download.sh         # download script
├── lib/
│   └── r2.sh                  # shared helpers (env, logging, aws CLI wrapper)
├── examples/
│   ├── .env.example           # configuration template (upload + download)
│   └── crontab.example        # sample cron entries
├── .gitignore
├── README.md
└── LICENSE
```

---

## Installation

### Prerequisites

- **Bash** >= 4.0
- **AWS CLI v2** (supports Cloudflare R2 via custom endpoints)
- **msmtp** (optional — only required if you want email notifications; see [Email Notifications](#email-notifications))
- **Standard Unix tools**: `date`, `hostname`, `sed`, `grep`

### Install AWS CLI v2

**Linux:**

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
```

**macOS:**

```bash
brew install awscli
```

### Clone the Repository

```bash
git clone https://github.com/yourusername/R2-backup-uploader.git
cd R2-backup-uploader
chmod +x bin/r2-upload.sh
```

---

## Configuration

### Create Your `.env` File

Copy the example template and customize it for your R2 account:

```bash
cp examples/.env.example .env
```

Edit `.env` with your Cloudflare R2 credentials and preferences:

```bash
# ---- Cloudflare R2 Account ----
R2_ACCOUNT_ID="your_account_id_here"
R2_ACCESS_KEY_ID="your_r2_access_key"
R2_SECRET_ACCESS_KEY="your_r2_secret_key"
R2_ENDPOINT="https://your_account_id.r2.cloudflarestorage.com"
R2_BUCKET="my-backups"

# ---- Upload Behaviour ----
R2_REGION="auto"
R2_STORAGE_CLASS="STANDARD"
R2_PATH_PREFIX="backups/$(hostname)/"
R2_OVERWRITE="false"
R2_MULTIPART_THRESHOLD="64MB"
R2_MULTIPART_CHUNKSIZE="32MB"

# ---- Source (upload only) ----
SOURCE_PATH="/var/backups"            # file OR directory (each file uploaded as separate object)
ARCHIVE_AFTER_UPLOAD="true"          # move uploaded files to archive folder after success
SOURCE_ARCHIVE_DIR="/var/backups/.archive"  # required when ARCHIVE_AFTER_UPLOAD=true
SOURCE_ARCHIVE_ORGANIZE="$(date)"     # subdir under archive; supports $(hostname), $(date)

# ---- Download Behaviour ----
DOWNLOAD_DEST="./downloads/"
DOWNLOAD_OVERWRITE="false"
DOWNLOAD_PATTERN="*"
DOWNLOAD_DELETE_REMOTE="false"

# ---- Safety ----
DRY_RUN="false"
REQUIRE_CONFIRM="true"
RETRY_COUNT="3"
RETRY_DELAY="5"

# ---- Logging ----
LOG_LEVEL="info"
LOG_FILE=""
```

### Configuration Variables

**Cloudflare R2 Account**

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `R2_ACCOUNT_ID` | Your Cloudflare account ID | — | ✅ |
| `R2_ACCESS_KEY_ID` | R2 access key | — | ✅ |
| `R2_SECRET_ACCESS_KEY` | R2 secret key | — | ✅ |
| `R2_ENDPOINT` | R2 endpoint URL | — | ✅ |
| `R2_BUCKET` | Target bucket name | — | ✅ |
| `R2_REGION` | AWS region | `auto` | ❌ |
| `R2_STORAGE_CLASS` | Storage class (`STANDARD` \| `INFREQUENT_ACCESS`) | `STANDARD` | ❌ |
| `R2_PATH_PREFIX` | Key prefix (supports `$(hostname)`, `$(date)`) | `backups/$(hostname)/` | ❌ |
| `R2_OVERWRITE` | Overwrite existing keys on upload | `false` | ❌ |
| `R2_MULTIPART_THRESHOLD` | Multipart upload threshold | `64MB` | ❌ |
| `R2_MULTIPART_CHUNKSIZE` | Multipart chunk size | `32MB` | ❌ |

**Source (upload only)**

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `SOURCE_PATH` | File or directory to upload (each regular file uploaded as a separate object) | — | ✅ for upload |
| `ARCHIVE_AFTER_UPLOAD` | Move uploaded files to `SOURCE_ARCHIVE_DIR` after verified upload | `true` | ❌ |
| `SOURCE_ARCHIVE_DIR` | Local archive directory (required when `ARCHIVE_AFTER_UPLOAD=true`) | — | conditional |
| `SOURCE_ARCHIVE_ORGANIZE` | Subdir pattern under archive; supports `$(hostname)` and `$(date)` | `$(date)` | ❌ |

**Download**

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `DOWNLOAD_DEST` | Local destination directory | `./downloads/` | ✅ for download |
| `DOWNLOAD_OVERWRITE` | Overwrite existing local files | `false` | ❌ |
| `DOWNLOAD_PATTERN` | Glob filter (e.g. `*.sql.gz`) | `*` | ❌ |
| `DOWNLOAD_DELETE_REMOTE` | Delete from R2 after successful download (DR rotation) | `false` | ❌ |

**Safety & Logging**

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `DRY_RUN` | Show actions without uploading/downloading | `false` | ❌ |
| `REQUIRE_CONFIRM` | Prompt before upload/download | `true` | ❌ |
| `RETRY_COUNT` | Number of retry attempts | `3` | ❌ |
| `RETRY_DELAY` | Delay between retries (seconds) | `5` | ❌ |
| `LOG_LEVEL` | Logging level (`debug` \| `info` \| `warn` \| `error`) | `info` | ❌ |
| `LOG_FILE` | Optional log file path. Log lines are emitted to **stdout when interactive** (stdout is a TTY) and **stderr otherwise** (cron, pipes). When this is set, the same lines are also appended to the file regardless of the live sink. | `""` | ❌ |

**Email Notifications** (sender comes from `~/.msmtprc`)

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `EMAIL_ENABLED` | Master switch for notifications | `false` | ❌ |
| `EMAIL_TO` | Recipients (comma-separated supported) | `""` | ✅ if `EMAIL_ENABLED` |
| `EMAIL_SUBJECT_OK` | Subject on success (supports `$(hostname)`, `$(date)`) | `[R2] Upload OK: ...` | ❌ |
| `EMAIL_SUBJECT_FAIL` | Subject on failure | `[R2] Upload FAILED: ...` | ❌ |
| `EMAIL_ON_SUCCESS` | Send on successful run | `true` | ❌ |
| `EMAIL_ON_FAILURE` | Send on failed run | `true` | ❌ |
| `MSMTP_ACCOUNT` | Which `~/.msmtprc` account to use | `default` | ❌ |

---

## Usage

### Basic Syntax

```bash
./bin/r2-upload.sh [OPTIONS]
```

### Options

| Option | Description |
|--------|-------------|
| `--config <path>` | Path to `.env` file (default: `./.env`) |
| `--source <path>` | Override `SOURCE_PATH` from config |
| `--dry-run` | Show what would happen without uploading |
| `-e`, `--email [ADDR]` | Send notification email. If `ADDR` is given it overrides `EMAIL_TO`; if omitted, `EMAIL_TO` from `.env` is used. Errors if neither is set. |
| `--help` | Show help message |

---

## Examples

### Example 1: Dry Run with Default Config

```bash
./bin/r2-upload.sh --dry-run
```

### Example 2: Upload with Explicit Config

```bash
./bin/r2-upload.sh --config ~/work/.env --source /var/backups/db.sql
```

### Example 3: Automated Cron Job

```bash
REQUIRE_CONFIRM=false DRY_RUN=false ./bin/r2-upload.sh --config /etc/r2/prod.env
```

### Example 4: Upload a Single File

```bash
./bin/r2-upload.sh --source /path/to/backup.tar.gz
```

### Example 5: Upload a Directory (Each File Separately)

```bash
./bin/r2-upload.sh --source /var/www/html
```

Each regular file in the top level of `/var/www/html` is uploaded as its own R2 object. After successful upload (and checksum verification), files are moved into `SOURCE_ARCHIVE_DIR/$(date)/` so the next run only sees new/changed files.

> The script does **not** recurse. Backups are expected to be a flat dump folder (e.g. `/var/backups/*.sql.gz`). If you need recursion, pre-stage them or use `find ... -exec cp {} staging/ \;`.

---

### Archive Pattern (Verified Upload → Move Aside)

The default upload flow is designed to keep your backup folder clean while giving you a verifiable, auditable trail:

1. **Discover** — every regular file in `SOURCE_PATH` (top-level only).
2. **Check existing objects** — skip keys that already exist unless `R2_OVERWRITE=true`.
3. **Upload** — `aws s3 cp` with retry, tagged `R2_STORAGE_CLASS`.
4. **Verify** — compute local SHA-256, fetch remote object, compare.
5. **Archive** — on verify-success and `ARCHIVE_AFTER_UPLOAD=true`, move the file to `SOURCE_ARCHIVE_DIR/<$(date) subdir>/`. Name collisions are resolved with a `-<timestamp>` suffix.
6. **Email** — at the end of the run, send a summary (success / failure / dry-run) with counts and durations.

This means the next cron run only sees *new* files in `SOURCE_PATH`, and you always have a local archive folder organised by date for forensics.

**Disabling archive**: set `ARCHIVE_AFTER_UPLOAD=false` to keep files in place after upload. `SOURCE_ARCHIVE_DIR` then becomes optional and is ignored.

---

## Downloading Backups

The `r2-download.sh` script retrieves data from R2. Because R2 is S3-compatible, downloads use the same AWS CLI v2 and the same `.env` credentials.

### Syntax

```bash
./bin/r2-download.sh [OPTIONS]
```

### Options

| Option | Description |
|--------|-------------|
| `--config <path>` | Path to `.env` file (default: `./.env`) |
| `--key <key>` | Download a single object key |
| `--prefix <prefix>` | Sync everything under a prefix (e.g. `backups/web01/`) |
| `--dest <dir>` | Override `DOWNLOAD_DEST` |
| `--delete-remote` | Delete from R2 after successful download (DR rotation) |
| `--dry-run` | Show what would happen without downloading |
| `-e`, `--email [ADDR]` | Send notification email. If `ADDR` is given it overrides `EMAIL_TO`; if omitted, `EMAIL_TO` from `.env` is used. Errors if neither is set. |
| `--help` | Show help message |

> If neither `--key` nor `--prefix` is given, the script syncs the expanded `R2_PATH_PREFIX`.

### Download Examples

**Download the most recent backup for this host** (uses `R2_PATH_PREFIX` expansion):

```bash
./bin/r2-download.sh --config /etc/r2/prod.env
```

**Download a specific file:**

```bash
./bin/r2-download.sh --config .env --key backups/web01/db-2026-09-29.sql.gz
```

**Sync a prefix** (e.g. last week of logs):

```bash
./bin/r2-download.sh --config .env --prefix backups/web01/logs/2026-W39/
```

**Dry run + non-interactive** for automation:

```bash
DRY_RUN=true REQUIRE_CONFIRM=false ./bin/r2-download.sh --config .env
```

**Download and delete from R2** (disaster-recovery rotation):

```bash
./bin/r2-download.sh --config .env --delete-remote
```

> ⚠️ `--delete-remote` is destructive. Run with `--dry-run` first to verify which objects would be removed.

### Restoring a Directory

If you uploaded a directory whose contents are tar.gz archives, restore one with:

```bash
# Download a single backup
./bin/r2-download.sh --config .env --key backups/web01/db-2026-09-29.sql.gz

# Extract
tar -xzf ./downloads/db-2026-09-29.sql.gz -C /var/backups/
```

---

## Email Notifications

Both scripts can send a plain-text email summary at the end of each run (success or failure). The **sender** address is taken from your `~/.msmtprc` file, so configure that once and don't worry about it per-script.

### Install `msmtp`

| Distro | Command |
|--------|---------|
| Ubuntu / Debian | `sudo apt-get install msmtp msmtp-mta` |
| RHEL / Fedora | `sudo dnf install msmtp` |
| macOS | `brew install msmtp` |

### Configure `~/.msmtprc`

```ini
# filepath: ~/.msmtprc
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        ~/.msmtp.log

account        default
host           smtp.gmail.com
port           587
from           your-email@example.com
user           your-email@example.com
passwordeval   "security find-generic-password -ws 'msmtp'"

# Or use a different account:
account        ops
host           smtp.example.com
port           587
from           ops@example.com
user           ops@example.com
password       your-app-password
```

Then `chmod 600 ~/.msmtprc`.

### Enable in `.env`

Set `EMAIL_ENABLED=true` and provide recipients:

```bash
EMAIL_ENABLED="true"
EMAIL_TO="ops@example.com,oncall@example.com"   # comma-separated for multiple
EMAIL_SUBJECT_OK="[R2] OK: $(hostname) at $(date)"
EMAIL_SUBJECT_FAIL="[R2] FAILED: $(hostname) at $(date)"
EMAIL_ON_SUCCESS="true"
EMAIL_ON_FAILURE="true"
MSMTP_ACCOUNT="ops"                             # which account from .msmtprc
```

### Usage

```bash
# Use EMAIL_TO from .env (when EMAIL_ENABLED=true)
./bin/r2-upload.sh

# Force email for this run, overriding EMAIL_TO
./bin/r2-upload.sh --email someone@example.com

# Force email for this run, no ADDRESS — uses EMAIL_TO from .env
./bin/r2-upload.sh --email
```

> ⚠️ If `-e/--email` is given but neither an address nor `EMAIL_TO` is configured, the script **errors out before doing any work** — so check your config first.

### Email Body

The body is plain-text and includes:

- Operation (`upload` / `download`), status (`success` / `failure` / `dry-run`), exit code
- Hostname, start/finish timestamps, duration
- Key-value summary of the run (source, destination, bucket, key, dry-run flag, etc.)
- **Full log buffer** for the run — every `[INFO]` / `[WARN]` / `[ERROR]` line captured during execution

### Disabling Per-Run

- `EMAIL_ON_SUCCESS=false` → no email on success
- `EMAIL_ON_FAILURE=false` → no email on failure
- `EMAIL_ENABLED=false` → no email at all (CLI `-e` still forces `true`)

---

## Development Environment

### Requirements

- **Bash** >= 4.0
- **AWS CLI v2** (install instructions above)
- **tar** (optional; only used in restoration examples)
- **ShellCheck** (optional, for linting)

### Install ShellCheck

**Linux:**

```bash
sudo apt-get install shellcheck
```

**macOS:**

```bash
brew install shellcheck
```

### Lint Scripts

```bash
shellcheck bin/*.sh lib/*.sh
```

### Test the Scripts

```bash
# Upload — dry run
./bin/r2-upload.sh --dry-run --config examples/.env.example

# Upload — real (requires valid R2 credentials)
./bin/r2-upload.sh --config examples/.env.example --source /tmp/test.txt

# Download — dry run
./bin/r2-download.sh --dry-run --config examples/.env.example

# Download — real (requires valid R2 credentials)
./bin/r2-download.sh --config examples/.env.example
```

---

## Roadmap

Future enhancements planned for upcoming versions:

- 🔄 **Multiple account profiles** — switch between R2 accounts easily
- 🔐 **Pre-upload encryption** — encrypt backups with age/gpg before upload
- 🧪 **Automated tests** — GitHub Actions workflow for real R2 round-trip
- 📊 **Upload/download statistics** — track history and metrics
- 📂 **Recursive directory uploads** — walk subdirectories on demand

---

## License

This project is licensed under the MIT License. See `LICENSE` file for details.

---

## Contributing

Contributions are welcome! Please open an issue or submit a pull request on GitHub.

---

## Support

For issues, questions, or feature requests, please open an issue on the GitHub repository.
