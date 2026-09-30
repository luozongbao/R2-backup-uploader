# About R2 Backup Uploader

A Bash tool to **upload** and **download** backup files and directories to/from
[Cloudflare R2](https://developers.cloudflare.com/r2/) (S3-compatible object
storage). Each Cloudflare R2 account gets its own `.env` file, so it's easy to
manage multiple accounts or environments (prod, staging, dev) from one checkout.

---

## Why this exists

Most backup scripts either:

- **Hard-code credentials** (bad — leak into shell history, `ps`, logs).
- **Wrap one specific tool** (rsync, restic, duplicity) and lock you in.
- **Recurse into subdirectories** and silently produce inconsistent archives.

`R2 Backup Uploader` deliberately takes a different shape:

- **Bash + AWS CLI v2** — leverages the AWS Sig V4 machinery and works with
  any S3-compatible endpoint. No new daemon to babysit.
- **Per-account `.env`** — credentials live in `chmod 600` files you control.
  Switch accounts by passing `--config`.
- **Flat, auditable archive flow** — uploads each file as a separate object,
  verifies the SHA-256, then **moves** the local file into a dated archive
  folder. The next run only sees new files; you always have a forensic trail.
- **Cron-first** — every interactive prompt has a non-interactive override,
  every I/O operation has a dry-run, every failure has a retry.

---

## Feature highlights

| Feature | What it does |
|---------|--------------|
| **Per-file upload** | One R2 object per file in the source folder. Failures are isolated. |
| **SHA-256 verify** | After every upload, the script compares local SHA-256 against the server's stored checksum (`get-object-attributes --object-attributes ChecksumSHA256`) — no full download. |
| **Auto-archive** | Verified files move to `SOURCE_ARCHIVE_DIR/<$(date) subdir>/` so the next run starts clean. Name collisions get a timestamp suffix. |
| **Download modes** | `--key` for a single object, `--prefix` for a sync, or no flag for the expanded `R2_PATH_PREFIX`. |
| **DR rotation** | `--delete-remote` removes the remote objects after a successful download (disaster-recovery rotation). |
| **Dry-run** | Every I/O operation has a dry-run path that prints what would happen without writing anything. |
| **Retry** | Network calls retry up to `RETRY_COUNT` times with `RETRY_DELAY` between attempts. |
| **Email notifications** | Plain-text summary via `msmtp` at the end of every run (success / failure). Sender comes from `~/.msmtprc`. |
| **Cross-platform** | Works on Linux (GNU coreutils) and macOS (BSD coreutils). |
| **CI lint** | ShellCheck runs on every push and PR via GitHub Actions. |

---

## Design choices

### 1. Bash, not Python

Backups are usually driven by cron, and cron already speaks Bash. Keeping
the implementation in pure Bash means:

- No virtualenv, no `pip install`, no interpreter version to pin.
- Every helper is a small, named function (`r2::aws`, `r2::retry`, ...) that
  you can `source lib/r2.sh` and reuse from your own scripts.
- Dependencies (`aws`, `tar`, `msmtp`, `sha256sum`) are already on most servers.

### 2. `.env` per account, not per host

Each Cloudflare account gets a `.env` file (`prod.env`, `staging.env`,
`backup-client.env`). Pass it with `--config`. The same script can back up
several buckets in sequence from a single cron entry.

### 3. Archive, not delete

The default flow **moves** successfully-uploaded files into
`SOURCE_ARCHIVE_DIR/$(date)/` instead of deleting them. This means:

- A failed run can be re-run safely — the source folder still has the file.
- You always have a local copy of everything you uploaded, organised by date.
- The next cron run only iterates over new files, so it stays fast.

Set `ARCHIVE_AFTER_UPLOAD=false` if you want to keep files in place.

### 4. Verify, then archive

We track every uploaded file in `UPLOADED_LOCALS`, but we **only archive** the
ones that pass checksum verification. An inconclusive verification leaves the
file in place; a mismatch fails the run.

### 5. Email is best-effort

Notifications never fail the script — if `msmtp` isn't installed, the run
just logs a warning and exits with the real status code.

---

## What it explicitly does **not** do

- **No recursion.** The upload script processes only the top-level files of
  `SOURCE_PATH`. If you need recursion, stage files first
  (`find ... -exec cp {} staging/ \;`).
- **No client-side encryption.** Plaintext uploads to R2. If you need
  encryption, encrypt before staging.
- **No delta sync.** Each file is uploaded in full (multipart if large).
- **No bucket creation.** Bucket must exist; the script won't create it.

These are conscious omissions — the tool is meant to be a small, predictable
piece in a larger backup pipeline.

---

## When to use something else

- **restic / borg** — if you want deduplicated, encrypted, versioned backups
  with snapshots. Heavier; needs a server-side repo.
- **aws s3 sync** — if you just want a one-liner mirror. No archiving, no
  checksum verification, no email.
- **duplicity** — if you want GPG-encrypted, bandwidth-efficient incremental
  backups. Slower; more dependencies.

`R2 Backup Uploader` is for the case where you have a folder of completed
backup artefacts (`db-2026-09-29.sql.gz`, `logs-2026-09-29.tar.zst`, ...) and
you want to ship them to R2 with verification and a notification.

---

## Project layout

```
R2-backup-uploader/
├── bin/
│   ├── r2-upload.sh         # upload script (CLI + entry point)
│   └── r2-download.sh       # download script (CLI + entry point)
├── lib/
│   └── r2.sh                # shared helpers (logging, AWS CLI wrapper, checksum, email)
├── examples/
│   ├── .env.example         # configuration template (upload + download + email)
│   └── crontab.example      # sample cron entries
├── docs/
│   ├── README.md            # full documentation
│   └── About.md             # ← this file
├── .github/
│   └── workflows/
│       └── shellcheck.yml   # CI lint
├── README.md                # landing page
└── LICENSE                  # MIT
```

---

## License

MIT — see [LICENSE](../LICENSE).