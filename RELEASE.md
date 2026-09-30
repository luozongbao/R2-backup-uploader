# filepath: RELEASE.md
# Release Notes

All notable changes to **R2 Backup Uploader** are documented here.
This project follows [Semantic Versioning](https://semver.org/) and the
[Keep a Changelog](https://keepachangelog.com/) format.

> **Pre-1.0 tag in repo history:** `v.1.0b` — the initial beta cut, kept as a
> historical marker. The first **stable** release is `1.0.0` (this document).

---

## [1.0.0] — 2026-09-30 · First stable release

The first production-ready release of R2 Backup Uploader. The upload and
download scripts, library helpers, examples, and documentation have all
stabilised; the API (CLI surface and `.env` contract) is now considered
stable and will be honoured by future `1.x` releases with deprecation notices.

### Highlights

- **Upload** files or directories to Cloudflare R2 — each regular file becomes
  a separate object, verified server-side via SHA-256.
- **Download** by exact key or by prefix sync, with the same credentials and
  retry/dry-run safety as upload.
- **Auto-archive** verified uploads into a dated local folder (`SOURCE_ARCHIVE_DIR`)
  so the next run only sees new files.
- **Per-account `.env` configuration** with safe defaults, tilde expansion, and
  per-run overrides for source / destination / dry-run / email.
- **Email notifications** via `msmtp` — success / failure summaries with full
  log body, optional override of `EMAIL_TO` from the CLI.
- **Cron-friendly** — `REQUIRE_CONFIRM=false` enables unattended operation;
  example crontab ships in [`examples/crontab.example`](examples/crontab.example).
- **Cross-platform** Bash (Linux + macOS) with optional `shellcheck` CI.

### Added

- `bin/r2-upload.sh` — upload CLI with `--config`, `--source`, `--dry-run`,
  `-e/--email [ADDR]`, `--help`.
- `bin/r2-download.sh` — download CLI with `--config`, `--key`, `--prefix`,
  `--dest`, `--delete-remote`, `--dry-run`, `-e/--email [ADDR]`, `--help`.
- `lib/r2.sh` — shared library: logging (`r2::log/debug/info/warn/error`),
  `.env` loader with defaults and `~` expansion, AWS CLI wrapper that keeps
  credentials out of `ps`, retry helper, checksum computation + remote
  verification, archive logic, and msmtp-based email sender.
- `examples/.env.example` — fully commented configuration template.
- `examples/crontab.example` — sample cron entries (daily upload, weekly
  non-destructive download review, hourly staging sync).
- `.github/workflows/shellcheck.yml` — CI lint for `bin/*.sh` and `lib/*.sh`.
- `README.md` — landing page with quick-start, requirements, features,
  email notification setup, and development notes.
- `docs/README.md` — full documentation: configuration tables, upload flow,
  download examples, email setup, development environment, roadmap.
- `docs/About.md` — design rationale, non-goals, and "when to use something
  else" comparison (restic / borg / `aws s3 sync` / duplicity).
- `LICENSE` — MIT.

### Configuration surface (stable)

| Variable | Purpose |
|---|---|
| `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ENDPOINT`, `R2_BUCKET` | Required R2 credentials |
| `R2_REGION`, `R2_STORAGE_CLASS`, `R2_PATH_PREFIX`, `R2_OVERWRITE`, `R2_MULTIPART_THRESHOLD`, `R2_MULTIPART_CHUNKSIZE` | Upload tuning |
| `SOURCE_PATH`, `ARCHIVE_AFTER_UPLOAD`, `SOURCE_ARCHIVE_DIR`, `SOURCE_ARCHIVE_ORGANIZE` | Source / archive behaviour |
| `DOWNLOAD_DEST`, `DOWNLOAD_OVERWRITE`, `DOWNLOAD_PATTERN`, `DOWNLOAD_DELETE_REMOTE` | Download behaviour |
| `DRY_RUN`, `REQUIRE_CONFIRM`, `RETRY_COUNT`, `RETRY_DELAY` | Safety & retries |
| `LOG_LEVEL`, `LOG_FILE` | Logging |
| `EMAIL_ENABLED`, `EMAIL_TO`, `EMAIL_SUBJECT_OK`, `EMAIL_SUBJECT_FAIL`, `EMAIL_ON_SUCCESS`, `EMAIL_ON_FAILURE`, `MSMTP_ACCOUNT` | Email notifications |

### Security notes

- `.env` is excluded from git via `.gitignore` (`.env`, `.env.*`, with
  `!.env.example` allow-list).
- R2 credentials are injected into the `aws` subprocess via `env VAR=val …`
  in `lib/r2.sh`'s `r2::aws` wrapper, so they never appear in shell `ps`
  output as positional arguments.
- `~/.msmtprc` holds SMTP credentials out-of-repo and is referenced by name
  only (`MSMTP_ACCOUNT`).

### Known limitations

- **No recursion.** Uploads walk only the top level of `SOURCE_PATH`. Pre-stage
  with `find … -exec cp {} staging/ \;` if you need recursion.
- **No client-side encryption.** Plaintext upload; encrypt before staging if
  needed.
- **No delta sync.** Each file is uploaded in full (multipart if large).
- **No bucket creation.** The bucket must already exist.
- **AWS CLI dependency.** Slowdowns in `aws s3 …` calls (e.g. due to IPv6 DNS
  hangs in some environments) affect every operation. See Roadmap.

### Upgrade notes

- If you tracked the pre-1.0 `v.1.0b` tag, no API change is required — the
  `.env` and CLI surfaces are the same as in beta.
- The variable previously known as `SOURCE_DELETE_AFTER` has been renamed to
  **`ARCHIVE_AFTER_UPLOAD`** for accuracy (the code *moves* files, it does
  not delete them). A temporary back-compat shim can be added in
  `lib/r2.sh` if you still have `SOURCE_DELETE_AFTER` in your live `.env`.
  See `git log` for the rename commit.

### Roadmap (post-1.0)

- Multiple account profiles (easy switching between R2 accounts)
- Pre-upload encryption (`age` / `gpg`)
- Automated tests in CI (real R2 round-trip against a test bucket)
- Upload / download statistics and history
- Recursive directory uploads on demand

---

## Pre-1.0

### `v.1.0b` — initial beta

The initial beta cut. Functionally equivalent to 1.0.0; promoted to stable
without API changes after documentation, examples, and CI lint were
finalised. Kept as a tag for historical reference.

---

[1.0.0]: #100--2026-09-30--first-stable-release
[Keep a Changelog]: https://keepachangelog.com/
[Semantic Versioning]: https://semver.org/
