# filepath: README.md
# R2 Backup Uploader

A Bash tool to **upload** and **download** backups to/from [Cloudflare R2](https://developers.cloudflare.com/r2/) (S3-compatible). Per-account configuration via `.env` files.

For full documentation — installation, configuration, examples, and roadmap — see **[docs/README.md](docs/README.md)**.

---

## Quick Start

```bash
# 1. Install AWS CLI v2 (needed for R2 access)
#    Linux:  https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2-linux.html
#    macOS:  brew install awscli

# 2. Clone & configure
git clone https://github.com/yourusername/R2-backup-uploader.git
cd R2-backup-uploader
cp examples/.env.example .env
$EDITOR .env   # fill in your R2 credentials

# 3. Dry-run
./bin/r2-upload.sh --dry-run

# 4. Upload for real
./bin/r2-upload.sh

# 5. Download later
./bin/r2-download.sh
```

## What You Get

- `bin/r2-upload.sh` — uploads a file or directory (each file as a separate object; archives locally after success)
- `bin/r2-download.sh` — downloads by key or syncs a prefix
- `lib/r2.sh` — shared helpers (env loading, logging, retries, AWS CLI wrapper)
- `examples/.env.example` — configuration template
- `examples/crontab.example` — sample cron entries

## Features

- **Upload** files or directories — each file as a separate R2 object
- **Download** a single key or sync an entire prefix
- **Per-account configuration** via `.env` files
- **Auto-archive** verified uploads into a dated folder
- **SHA-256 checksum verification** after every upload
- **Dry-run mode** for safe testing
- **Retry logic** with configurable attempts and delays
- **Email notifications** via `msmtp` (success/failure summaries)
- **Safety checks** (overwrite protection, confirmation prompts)
- **Flexible key prefixes** with `$(hostname)` / `$(date)` expansion
- **Cron-friendly** with non-interactive mode (`REQUIRE_CONFIRM=false`)
- **Detailed logging** with configurable levels and optional log file

## Requirements

- Bash ≥ 4.0
- [AWS CLI v2](https://aws.amazon.com/cli/) (R2 speaks the S3 protocol)
- `msmtp` (optional — only required if you want email notifications; see [Email Notifications](#email-notifications))
- Standard Unix tools: `date`, `hostname`, `sha256sum`/`shasum`

## Email Notifications

Both scripts can send a plain-text email summary at the end of each run (success or failure). The **sender** address is taken from your `~/.msmtprc` file, so configure that once and don't worry about it per-script.

### 1. Install `msmtp`

```bash
# Ubuntu / Debian
sudo apt-get install msmtp msmtp-mta

# macOS
brew install msmtp
```

### 2. Configure `~/.msmtprc`

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
password       your-app-password
```

Then `chmod 600 ~/.msmtprc`.

### 3. Enable in `.env`

```bash
EMAIL_ENABLED="true"
EMAIL_TO="ops@example.com,oncall@example.com"   # comma-separated for multiple
EMAIL_SUBJECT_OK="[R2] OK: $(hostname) at $(date)"
EMAIL_SUBJECT_FAIL="[R2] FAILED: $(hostname) at $(date)"
EMAIL_ON_SUCCESS="true"
EMAIL_ON_FAILURE="true"
MSMTP_ACCOUNT="default"
```

### 4. Use it

```bash
# Use EMAIL_TO from .env (when EMAIL_ENABLED=true)
./bin/r2-upload.sh

# Force email for this run, overriding EMAIL_TO
./bin/r2-upload.sh --email someone@example.com

# Force email for this run with no ADDRESS — uses EMAIL_TO from .env
./bin/r2-upload.sh --email

# Same flags work on the download script
./bin/r2-download.sh --email
```

The email body includes: operation, status, exit code, hostname, start/finish timestamps, duration, a key-value summary of the run (source, destination, bucket, prefix, dry-run flag, etc.), and the full log buffer captured during execution.

> ⚠️ If `-e/--email` is given but neither an address nor `EMAIL_TO` is configured, the script **errors out before doing any work** — so check your config first.

### Disable per-run

- `EMAIL_ON_SUCCESS=false` → no email on success
- `EMAIL_ON_FAILURE=false` → no email on failure
- `EMAIL_ENABLED=false` → no email at all (CLI `-e` still forces `true`)
- Dry-runs never send email.

## Development

```bash
# Lint
shellcheck bin/*.sh lib/*.sh

# Run a single script's help
./bin/r2-upload.sh --help
./bin/r2-download.sh --help
```

## License

[MIT](LICENSE) © 2026 R2 Backup Uploader contributors
