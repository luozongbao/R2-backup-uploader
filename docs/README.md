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

- ✅ **Upload** files or directories (auto-compressed as tar.gz) to R2
- ✅ **Download** individual keys or sync entire prefixes back from R2
- ✅ **Per-account configuration** via `.env` files
- ✅ **Automatic compression** (tar.gz) for directory sources
- ✅ **Dry-run mode** for safe testing
- ✅ **Retry logic** with configurable attempts and delays
- ✅ **Safety checks** (overwrite protection, confirmation prompts)
- ✅ **Flexible key prefixes** with hostname/date expansion
- ✅ **Detailed logging** with configurable levels
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
- **tar** (for directory compression)
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
SOURCE_PATH="/var/backups"
SOURCE_COMPRESS="true"
SOURCE_KEEP_LOCAL="false"

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
| `SOURCE_PATH` | File or directory to upload | — | ✅ for upload |
| `SOURCE_COMPRESS` | Compress directories with tar.gz | `true` | ❌ |
| `SOURCE_KEEP_LOCAL` | Keep local files after upload | `false` | ❌ |

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
| `LOG_FILE` | Log file path (empty = stderr only) | `""` | ❌ |

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

### Example 5: Upload a Directory (Auto-Compressed)

```bash
./bin/r2-upload.sh --source /var/www/html
```

The script will automatically create a tar.gz archive of the directory before uploading.

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

### Restoring a Compressed Directory

If the upload was a tar.gz archive (from `SOURCE_COMPRESS=true`), restore with:

```bash
# Download
./bin/r2-download.sh --config .env --key backups/web01/site-2026-09-29.tar.gz

# Extract
tar -xzf ./downloads/site-2026-09-29.tar.gz -C /var/www/
```

---

## Development Environment

### Requirements

- **Bash** >= 4.0
- **AWS CLI v2** (install instructions above)
- **tar** (for directory compression)
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
- 🧪 **Automated tests** — GitHub Actions workflow for CI lint
- 📊 **Upload/download statistics** — track history and metrics
- 🗜️ **Advanced compression options** — support for zstd, bzip2, etc.
- 🔁 **End-to-end verify** — checksum compare after download

---

## License

This project is licensed under the MIT License. See `LICENSE` file for details.

---

## Contributing

Contributions are welcome! Please open an issue or submit a pull request on GitHub.

---

## Support

For issues, questions, or feature requests, please open an issue on the GitHub repository.
