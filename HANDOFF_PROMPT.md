# HANDOFF PROMPT — R2 Backup Uploader (งานค้าง)

> คัดลอกข้อความทั้งหมดด้านล่างนี้ แล้ววางเป็นข้อความแรกของ conversation ใหม่ เพื่อให้ AI เข้าใจงานที่ทำค้างไว้และทำต่อได้ทันที

---

## 1. โปรเจกต์คืออะไร

**R2 Backup Uploader** — Bash tool สำหรับ upload/download ไฟล์ backup ไป/จาก Cloudflare R2 (S3-compatible)

- **Repo:** `/home/zongbao/projects/R2-backup-uploader`
- **Host:** `web` (Linux Ubuntu 24.04), user `zongbao`
- **Bucket จริง:** `banrimkwae-com-backup` (account `4fb09da3c3a3f8e778f78171a318d0f3`)
- **Source folder:** `~/backups/` (มีไฟล์ตัวอย่าง: `test-1790684667.txt`, `testfile.text`, `yadepan/`)
- **Archive folder:** `~/backups/.archive/` (สร้างไว้แล้ว แต่ยังว่าง)

## 2. โครงสร้างไฟล์ (อยู่ครบแล้ว)

```
bin/r2-upload.sh       # ~265 บรรทัด — upload script หลัก
bin/r2-download.sh     # download script (single file หรือ sync prefix)
lib/r2.sh              # ~570 บรรทัด — helpers ทั้งหมด (sourced โดยทั้ง upload/download)
examples/.env.example  # template ของ .env
.env                   # ไฟล์จริง มี credentials live (⚠️ ควร rotate หลังงานเสร็จ)
docs/README.md         # documentation หลัก
.github/workflows/shellcheck.yml  # CI lint
README.md              # landing page สั้นๆ
LICENSE                # MIT
```

## 3. สถานะงานปัจจุบัน

### ✅ ทำเสร็จแล้ว (ใช้งานได้)
1. **Archive Pattern** แทน SOURCE_KEEP_LOCAL/SOURCE_COMPRESS เดิม
   - `SOURCE_DELETE_AFTER=true` + `SOURCE_ARCHIVE_DIR="~/backups/.archive"` + `SOURCE_ARCHIVE_ORGANIZE="$(date)"`
   - หลัง upload สำเร็จ → ย้ายไฟล์ไป archive folder
2. **Tilde expansion** — `~/backups` ใน .env ถูก expand เป็น `/home/zongbao/backups` ผ่าน `r2::abspath`
3. **Server-side checksum verify** — `r2::remote_sha256` ใช้ `s3api get-object-attributes --object-attributes ChecksumSHA256` (ไม่ต้อง download ไฟล์)
4. **Upload ordering** — เพิ่มเข้า UPLOADED_LOCALS ก่อน verify เพื่อไม่ให้ verify fail ทำให้ไฟล์ก่อนหน้าไม่ถูก archive
5. **Email notification** — ผ่าน msmtp (มี optional `EMAIL_FROM`, `EMAIL_ON_SUCCESS/FAILURE`)
6. **CI lint** — shellcheck.yml ทำงาน
7. **MIT license, README, docs** — ครบ

### ⚠️ ปัญหาค้าง (ต้องแก้)

#### 🔴 CRITICAL: AWS CLI ช้ามาก (~60+ วินาทีต่อคำสั่ง) — สาเหตุคือ IPv6 hang

**ผลการ strace** — `aws` process ค้างที่ `connect()` ไปยัง Cloudflare IPv6 (`2606:4700:113::1`) รอ **60 วินาที** ก่อน timeout แล้วค่อย fallback ไป IPv4 ทำให้ทุก AWS CLI call ใช้เวลา ≥ 60 วินาที

หลักฐาน:
- `curl` ไป R2 endpoint = 1.3 วินาที ✅
- `aws s3 ls` = 2 นาที ❌ (strace ยืนยันว่าค้างที่ IPv6 connect)
- ลอง `AWS_EC2_METADATA_DISABLED=true` + `AWS_CONFIG_FILE=/dev/null` แล้ว **ยังช้าเท่าเดิม** (ช้าเพราะ IPv6 connect ไม่ใช่เพราะ IMDS)

**วิธีแก้ที่ควรลอง (เรียงตามลำดับ):**
1. **แก้ `r2::aws` ใน lib/r2.sh** ให้ disable IPv6 ผ่าน env var `AWS_USE_FIPS_ENDPOINT=false` + ตั้ง `GODEBUG=netdns=1` (ไม่แน่ใจว่าช่วย)
2. **ลอง disable IPv6 ทั้งระบบชั่วคราว** ตอนรัน script: `sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1` (ต้อง sudo)
3. **ตั้ง `RES_OPTIONS="timeout:2 attempts:1"`** ใน .env เพื่อให้ DNS resolve fail เร็ว
4. **ใช้ `--no-sign-request` หรือ `aws --cli-read-timeout 5 --cli-connect-timeout 5`** — ตัด timeout ให้สั้นลง
5. **Fallback: เขียน lib/r2.sh ใหม่** ให้ใช้ curl + AWS Sig V4 แทน aws CLI (ทำงานชัวร์ ไม่ติด IPv6 hang)

### 🟡 งานย่อยที่ค้าง
- ทดสอบ end-to-end ให้ archive folder มีไฟล์จริงหลัง upload สำเร็จ
- แก้ README.md — ลบข้อความ "auto-tar.gz" ที่ docs ยังเหลืออยู่ (อัปเดตแล้วใน docs/README.md แต่ README.md บนสุดยังไม่อัปเดต)
- Rotate R2 credentials ที่อยู่ใน .env (user รับปากไว้)

## 4. รายละเอียดโค้ดสำคัญที่ต้องรู้

### `lib/r2.sh` functions ที่มีอยู่:
```bash
r2::log / debug / info / warn / error    # logging (LOG_LEVEL filter)
r2::load_env <path>                      # .env parser + defaults + tilde expansion
r2::require_vars / r2::require_cmd       # validation
r2::aws <args>                           # wrapper ที่ใส่ credentials/env
r2::retry <count> <delay> <cmd>          # retry helper
r2::confirm <msg>                        # y/N prompt
r2::expand_prefix <tmpl>                 # $(hostname), $(date)
r2::abspath <path>                       # ~/ → $HOME
r2::is_true <val>                        # true|yes|1|on
r2::local_sha256 / r2::remote_sha256     # checksums
r2::verify_checksum                      # returns 0=match, 1=mismatch, 2=inconclusive
r2::archive_target_dir / r2::move_to_archive  # archive logic
r2::start_run / set_status / set_exit_code / record / format_duration / tee_log
r2::resolve_email_recipients / should_email / build_email_body / build_email_subject / send_email
```

### `bin/r2-upload.sh` flow หลัก:
1. Parse CLI: `--config`, `--source`, `--dry-run`, `-e [ADDR]`, `--help`
2. Load .env → set defaults
3. Validate required vars + commands
4. `prepare_source` → list of files
5. Dry-run path (no I/O)
6. Interactive confirm
7. **Upload loop** สำหรับแต่ละไฟล์:
   - Skip if `R2_OVERWRITE=false` และมี key อยู่แล้ว
   - `r2::aws s3 cp ... --checksum-algorithm SHA256` (RETRY 3 ครั้ง)
   - เพิ่มเข้า UPLOADED_KEYS + UPLOADED_LOCALS
   - `r2::verify_checksum` (return code: 2 → remove from lists, 1 → fail exit, 0 → keep)
8. Archive loop: `r2::move_to_archive` สำหรับแต่ละ UPLOADED_LOCALS
9. Trap EXIT → send email + log summary

### `lib/r2.sh` — `r2::aws` function ปัจจุบัน (บรรทัด ~209):
```bash
r2::aws() {
    env \
        AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
        AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
        AWS_DEFAULT_REGION="$R2_REGION" \
        aws --endpoint-url "$R2_ENDPOINT" --region "$R2_REGION" "$@"
}
```

**← จุดที่ต้องแก้:** เพิ่ม env vars เพื่อแก้ปัญหา IPv6 hang

## 5. วิธีรันทดสอบ (สำหรับ session ใหม่)

```bash
cd /home/zongbao/projects/R2-backup-uploader

# Syntax check ก่อน
bash -n bin/r2-upload.sh && bash -n bin/r2-download.sh && bash -n lib/r2.sh && echo OK

# Dry-run
REQUIRE_CONFIRM=false EMAIL_ENABLED=false ./bin/r2-upload.sh --config .env --dry-run

# Real upload
REQUIRE_CONFIRM=false EMAIL_ENABLED=false ./bin/r2-upload.sh --config .env

# ตรวจ archive
find ~/backups/.archive -type f

# ตรวจ R2
AWS_EC2_METADATA_DISABLED=true AWS_CONFIG_FILE=/dev/null \
    AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... \
    aws --endpoint-url https://4fb09da3c3a3f8e778f78171a318d0f3.r2.cloudflarestorage.com --region auto \
    s3 ls s3://banrimkwae-com-backup/backups/web/
```

## 6. สิ่งที่ต้องทำต่อ (priority order)

1. **[CRITICAL] แก้ AWS CLI slowness** — ลองวิธีที่ 1-5 ในข้อ 3 ด้านบน
2. **[HIGH] ทดสอบ upload จริง + ตรวจ archive folder** ว่ามีไฟล์ย้ายเข้าจริง
3. **[MED] แก้ README.md** — ลบ "(auto-tar.gz)" ที่บรรทัด `bin/r2-upload.sh — uploads a file or directory (auto-tar.gz)` → เปลี่ยนเป็น `(uploads each file as a separate object)`
4. **[LOW] Rotate R2 credentials** ใน .env (account `4fb09da3c3a3f8e778f78171a318d0f3`)
5. **[LOW] ลบไฟล์ test** ที่ค้างใน ~/backups/ ถ้าต้องการเริ่มใหม่

## 7. ข้อมูล credentials (สำหรับทดสอบเท่านั้น — ⚠️ rotate หลังงานเสร็จ)

```
R2_ACCOUNT_ID=4fb09da3c3a3f8e778f78171a318d0f3
R2_ACCESS_KEY_ID=8a3f99f23f3642e9858bb1ddaa96f064
R2_SECRET_ACCESS_KEY=5f689cf842c19f76eaed5f838f836a72ab500dd1b059501ca5d2ffae6673d225
R2_ENDPOINT=https://4fb09da3c3a3f8e778f78171a318d0f3.r2.cloudflarestorage.com
R2_BUCKET=banrimkwae-com-backup
```

## 8. สิ่งที่ห้ามทำ
- ❌ ห้ามลบ `.archive/` folder ที่ `~/backups/.archive/` (มีอยู่แล้ว, archive ใช้ path นี้)
- ❌ ห้ามลบไฟล์ใน `~/backups/` ก่อน verify ว่า upload เสร็จ (SOURCE_DELETE_AFTER=true จะย้ายไปเอง)
- ❌ ห้ามเปลี่ยน `R2_REGION="auto"` — R2 ต้องการ "auto"
- ❌ ห้าม push credentials ขึ้น git (ดู `.gitignore` — `.env` ถูก ignore แล้ว)

---

**TL;DR สำหรับ AI ที่รับงานต่อ:**
> โปรเจกต์ R2 backup uploader ใกล้เสร็จแล้ว เหลือแก้บั๊กเดียว — AWS CLI ค้าง 60+ วินาทีต่อคำสั่งเพราะ IPv6 connect ไป Cloudflare timeout ใน `r2::aws` (lib/r2.sh ~บรรทัด 209) ให้ลอง disable IPv6 หรือเพิ่ม connect timeout หลังจากนั้นทดสอบ upload จริงและตรวจว่า `~/backups/.archive/` มีไฟล์ย้ายเข้าจริง แล้วอัปเดต README.md ที่บรรทัด `bin/r2-upload.sh — uploads a file or directory (auto-tar.gz)`
