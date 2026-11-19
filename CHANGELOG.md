# Changelog

All notable changes to tmedia are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/).

## [1.2.0] — 2026-11-19

### Added — universal access / multi-account
- ONE `api_id`/`api_hash` pair now drives **every authorised session** found on
  the machine. Sessions are registered (dedup by content hash) in
  `~/.config/tmedia/accounts/` with mode `0600`; originals are never modified.
- `--account NAME`, `--session PATH`, `TMEDIA_ACCOUNT`, `TMEDIA_SESSION` — pin
  the account that can see the post. Pinning is persisted in `active_account`.
- `--add-account NAME [--session PATH]` and `--list-accounts` — register/inspect
  logins offline with **zero new login code**.
- `AccountPool` automatic fallback: when Telegram reports the primary account
  cannot see a private/restricted post, the next account is connected lazily and
  retried (up to 8). `--single-account` / `TMEDIA_SINGLE_ACCOUNT` disables it.
- `is_access_error()` distinguishes "this account cannot see it" from a real
  download failure; batch mode still continues after per-link failures.
- Fresh-session private resolution now tries `types.PeerChannel(...)`,
  `channels.GetChannels` and dialog-cache warming before giving up.
- `?comment=<id>` / `?reply=<id>` discussion replies, `?thread=<id>` and forum
  topic ids are parsed and resolved best effort.
- `tests/test_v12.py` and `tests/test_engine.py`: offline suites for accounts,
  fallback, private resolution, exact bytes, mtime, batch, menu and link files;
  both run in CI.

### Changed
- `--doctor` reports usable accounts and the pinned account.
- Session panel shows the active account label and fallback count.
- `open_client()` accepts a session path and never prompts for a login code on
  a fallback account; `interactive_login()` shows the actual session path.
- `harden_session_permissions()` also covers `accounts/` and `active_account`.
- Installer / upgrader embed the v1.2.0 source; upgrader accepts v1.0.x and
  v1.1.x installs and still preserves `~/.config/tmedia`.

### Notes
- Telegram's server-side rules are unchanged: a private channel post is visible
  only to member accounts, and protected (`noforwards`) content stays
  restricted. tmedia now uses the account that has legitimate access instead of
  failing with the wrong one.

## [1.1.0] — 2026-11-18

### Added — zero-login credential & session recovery
- `discover_credentials()` — recovers `api_id` / `api_hash` / `phone` from
  `~/.config/tmedia/config.json`, environment variables (`TMEDIA_*`,
  `TELEGRAM_*`, `TG_*`, `API_*`) and local `.env` / JSON configs of other
  Telegram tools. No prompt when anything is found; own config outranks env so
  an unrelated `API_ID` cannot break the tool.
- `auto_import_session()` — validates a Telethon `SQLiteSession` (real
  `auth_key`) and reuses tmedia's own session or copies an existing authorised
  `*.session` found on the machine (bounded, read-only scan; mode `0600`).
  **No login code required** in either case.
- `tmedia --export-profile [FILE]` / `tmedia --import-profile FILE` — move a
  complete login between PCs with zero new registration. Archives are `0600`,
  import whitelists member names and rejects path traversal.
- `tmedia --doctor` — offline report of credentials source, session validity,
  detected Telegram Desktop, download dir, Python/platform.
- Compact 7-line `>` first-run guide, shown **only** when nothing is
  recoverable. If Telegram Desktop is installed it explains why `tdata` cannot
  be imported and points to the profile route.
- `--api-id`, `--api-hash`, `--phone` for non-interactive credential setup.
- `TMEDIA_CONFIG_DIR` and `TMEDIA_DOWNLOAD_DIR` path overrides (Termux / Windows
  / portable profiles).
- `upgrade_tmedia.sh` — idempotent, rollback-safe in-place upgrade that **never
  touches** `~/.config/tmedia`.
- Platform assets: `assets/setup_windows.ps1`, `assets/setup_termux.sh`.
- `scripts/publish_github.sh` and `.github/workflows/ci.yml`.

### Changed
- `interactive_login()` asks for the phone number only when a login code is
  actually needed (env-provided credentials may omit it).
- Overall batch progress row now renders `3/3 links` instead of a bogus
  `3/3 bytes` / transfer speed; per-file rows keep byte size, speed and ETA.
- `--version` reports `1.1.0`; README rewritten for a public repository.

### Notes
- Telegram Desktop's encrypted `tdata` is intentionally **not** imported, and
  the official Telegram Desktop app credentials are **not** bundled: doing so
  would violate Telegram's ToS. Only credentials/sessions the user owns are
  recovered.

## [1.0.0] — 2026-11-18

### Added
- Telethon/MTProto engine with async strided parallel chunk downloads and an
  automatic byte-verified `download_media()` fallback.
- Exact original filename / extension / raw bytes, message-date `mtime`,
  atomic `.part` → `os.replace()` writes, no silent `(1)` renaming.
- Public and private (`t.me/c/…`) links with dialog-cache entity recovery.
- First-run API ID / HASH / phone login, session persisted at
  `~/.config/tmedia/session.session` (dir `0700`, files `0600`).
- Rich ASCII banner, status panels, interactive `[1]/[2]` menu, progress bars
  with size / speed / ETA, per-file + overall batch progress and summary.
- `zenity` GUI file picker with a guaranteed headless terminal fallback.
- Human-readable errors everywhere, no raw tracebacks, batch continues past
  failures.
- `install_tmedia.sh` — single-file, idempotent, PEP-668-safe, self-deleting
  system-wide installer.
