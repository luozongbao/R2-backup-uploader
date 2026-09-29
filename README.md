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

## Requirements

- Bash ≥ 4.0
- [AWS CLI v2](https://aws.amazon.com/cli/) (R2 speaks the S3 protocol)
- `tar` (for compressing directory uploads)

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
