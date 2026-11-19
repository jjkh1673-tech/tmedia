<div align="center">

```
████████╗███╗   ███╗███████╗██████╗ ██╗█████╗
╚══██╔══╝████╗ ████║██╔════╝██╔══██╗██║██╔══██╗
   ██║   ██╔████╔██║█████╗  ██║  ██║██║███████║
   ██║   ██║╚██╔╝██║██╔══╝  ██║  ██║██║██╔══██║
   ██║   ██║ ╚═╝ ██║███████╗██████╔╝██║██║  ██║
   ╚═╝   ╚═╝     ╚═╝╚══════╝╚═════╝ ╚═╝╚═╝  ╚═╝
```

# tmedia

**Telegram media downloader for the terminal — exact original files, zero fuss.**

![Python](https://img.shields.io/badge/python-3.8%2B-blue) ![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20Windows%20%7C%20Termux-lightgrey) ![License](https://img.shields.io/badge/license-MIT-green) ![Status](https://img.shields.io/badge/release-v1.1.0-cyan)

[Features](#features) · [Zero-login setup](#zero-login-setup) · [Install](#install) · [Usage](#usage) · [CLI](#cli-reference) · [Security](#security--privacy) · [Contributing](#contributing)

</div>

---

## Why tmedia?

`curl` / `wget` cannot download a `t.me` **message** link — Telegram media is served
over MTProto, not HTTP. `tmedia` talks to the Telegram API directly with
[Telethon](https://github.com/LonamiWebs/Telethon), streams the raw bytes to
disk, and keeps the **exact original filename, extension and embedded metadata**.

No re-encoding. No `file (1).mkv`. No raw Python tracebacks. No re-login on
every machine you own.

---

## Features

| | |
|---|---|
| 🔐 **Zero-login recovery** | Auto-discovers API credentials and reuses an existing authorised session. Set it up once, use it everywhere. |
| 📦 **Portable profile** | `tmedia --export-profile` → `tmedia --import-profile` moves a login between PCs with **no new code**. |
| 🧭 **Compact `>` guide** | Only when nothing can be recovered; 7 short lines instead of a wall of text. |
| ⚡ **Async + parallel** | Up to `--workers` concurrent 256 KiB MTProto chunk streams, with automatic byte-verified fallback. |
| 🎯 **Exact fidelity** | `DocumentAttributeFilename` verbatim, raw byte stream, message date as `mtime`, atomic commit. |
| 🔗 **Public + private** | `t.me/user/123` and `t.me/c/…/…` (incl. forum-topic links) → `-100…` with dialog-cache recovery. |
| 🖥️ **Beautiful CLI** | [Rich](https://github.com/Textualize/rich) banner, panels, speed / ETA / size bars, overall batch tracker. |
| 📂 **Batch mode** | `zenity` file picker with a guaranteed headless fallback; one bad link never aborts the batch. |
| 🛡️ **Human errors** | Invalid URLs, non-member channels, deleted posts, `FloodWait`, network drops → one calm line each. |
| 🧩 **Cross-platform** | Ubuntu/BackBox installer, Windows PowerShell setup, Termux setup. |

---

## Zero-login setup

> **This is the answer to "I don't want to log in anywhere again just to get an API key".**

Telegram requires every third-party client to have an `api_id` / `api_hash`
pair (from <https://my.telegram.org>). tmedia obtains them **once** and then
never asks again:

```
  tmedia --doctor
        │
        ├─ 1. ~/.config/tmedia/config.json ............ found → reuse ✔
        ├─ 2. TMEDIA_API_ID / TMEDIA_API_HASH env .... found → reuse ✔
        ├─ 3. local .env / other Telegram tool configs  found → reuse ✔
        └─ 4. nothing found ........................... show compact '>' guide
```

Session recovery runs in parallel:

```
  tmedia  →  ~/.config/tmedia/session.session valid? ── yes ─→ zero login ✔
             └─ no → scan for any authorised Telethon *.session on this
                     machine → copy it (0600) → zero login ✔
```

### Move your existing login from PC-1 to the laptop (recommended)

```bash
# On PC-1 (where tmedia is already logged in):
tmedia --export-profile
# → ./tmedia-profile-20261118-2030.tar.gz   (mode 0600)

# Copy that file to the laptop (USB / scp / encrypted channel), then:
tmedia --import-profile ~/tmedia-profile-20261118-2030.tar.gz
tmedia --doctor     # credentials: config.json | session: valid (no login needed)
```

That is **zero new login, zero new API registration**. The profile contains
`config.json` + `session.session` only.

### Or use environment variables (great for dotfiles / multiple machines)

```bash
# add to ~/.bashrc, ~/.profile or ~/.config/environment.d/tmedia.conf
export TMEDIA_API_ID=12345678
export TMEDIA_API_HASH=0123456789abcdef0123456789abcdef
export TMEDIA_PHONE=+8801XXXXXXXXX          # optional if a session exists
export TMEDIA_DOWNLOAD_DIR="$HOME/Downloads" # optional
```

Accepted aliases: `TELEGRAM_API_ID`, `TG_API_ID`, `API_ID` (and the matching
`*_HASH` / `*_PHONE` keys), plus `.env` files (`export KEY=VALUE` supported).

### Or set them once, non-interactively

```bash
tmedia --api-id 12345678 --api-hash 0123456789abcdef0123456789abcdef --phone +8801XXXXXXXXX
```

### First-ever run, when nothing is recoverable

A small `>` guide appears inline — no full-screen panel, no confusion:

```text
> No API credentials found here. One-time setup (~60s), no new app install:
>   1. https://my.telegram.org  ->  phone login  ->  'API development tools'
>   2. Create an app -> copy App api_id (number) + App api_hash (32 chars)
>   3. Paste below. Saved once; tmedia never asks again.
>   Telegram Desktop detected (/opt/Telegram/Telegram); its encrypted tdata is NOT importable
>   by third-party clients. To reuse PC-1's login with ZERO new login:
>       tmedia --export-profile  ->  copy .tar.gz  ->  tmedia --import-profile <file>
>   Or export TMEDIA_API_ID / TMEDIA_API_HASH (and TMEDIA_PHONE) in your shell.
```

> **Honest technical note.** Telegram Desktop stores its login in encrypted
> `tdata`, a completely different format that **no third-party MTProto client
> can import**. Its bundled official-app `api_id`/`api_hash` are also not
> reused here — using another application's credentials violates Telegram's
> ToS and risks account limits. tmedia therefore recovers what is legitimately
> portable: your own API pair, your own Telethon sessions, and your own
> exported profile. Telegram Desktop is auto-detected only to explain this
> and to point you at the zero-login profile route.

---

## Install

### Linux — fresh install (Ubuntu / BackBox / Debian)

```bash
chmod +x install_tmedia.sh
sudo bash install_tmedia.sh       # deletes itself on success; keep a copy first
tmedia
```

The installer: escalates with `sudo`, detects `$SUDO_USER` (so `~` is **your**
home, not `/root`), installs only missing `python3 / python3-venv / python3-pip
/ zenity`, creates a PEP-668-safe venv at `/opt/tmedia/venv` with
`Telethon / rich / cryptg`, embeds `src/tmedia.py` into `/opt/tmedia/tmedia.py`,
and registers `/usr/local/bin/tmedia`. On success an `EXIT` trap removes all
temp files, the pip cache and the installer itself.

> Keep a copy: `cp install_tmedia.sh ~/install_tmedia.sh && sudo bash ~/install_tmedia.sh`

### Linux — upgrade an already-installed v1.0.x (your case)

```bash
chmod +x upgrade_tmedia.sh
sudo bash upgrade_tmedia.sh
tmedia --doctor
tmedia
```

It replaces **only** `/opt/tmedia/tmedia.py`, preserves
`~/.config/tmedia/{config.json,session.session}`, rolls back automatically on
failure, and is idempotent. **No new login.**

### Windows

```powershell
powershell -ExecutionPolicy Bypass -File .\assets\setup_windows.ps1
# reopen the terminal, then:
tmedia --doctor
```

Creates `%LOCALAPPDATA%\tmedia\{venv,tmedia.py,tmedia.cmd}` and adds that
folder to the user `PATH`. `zenity` and `os.pwrite` don't exist on Windows, so
the terminal file-picker fallback and Telethon's `download_media` path are used
automatically — no code changes needed.

### Termux (Android)

```bash
bash assets/setup_termux.sh
termux-setup-storage          # grant shared storage, once
tmedia
```

Installs into `$HOME/.tmedia/venv`, creates `$PREFIX/bin/tmedia`, and points
downloads at `~/storage/downloads` (falls back to `~/Downloads`).

---

## Usage

```text
╭─ Main Menu ───────────────────────────────────────╮
│   [1] Download Media via Direct Link               │
│   [2] Download Media from a Text File (Batch Mode) │
│   [0] Exit                                        │
╰───────────────────────────────────────────────────╯
```

```bash
tmedia                                          # interactive menu
tmedia -l https://t.me/c/1234567890/42          # one private-channel post
tmedia -b ~/links.txt                           # batch, no GUI picker
tmedia -b ~/links.txt -j 3                      # 3 concurrent links
tmedia -o ~/Videos -w 8                         # custom dir, 8 chunk workers
tmedia --doctor                                 # offline self-diagnosis
```

Batch file (`examples/links.example.txt`): one link per line; blank lines and
`#` comments are ignored, duplicates are skipped, invalid lines are reported
and the rest still download.

---

## CLI reference

| Flag | Default | Meaning |
|---|---|---|
| `-l, --link URL` | — | Download one link, no menu |
| `-b, --batch FILE` | — | Batch file (skips the GUI picker) |
| `-o, --output DIR` | `$TMEDIA_DOWNLOAD_DIR` or `~/Downloads` | Destination |
| `-j, --jobs N` | `1` | Concurrent links in batch (`1` = sequential) |
| `-w, --workers N` | `4` | Parallel chunk streams per large file |
| `--no-parallel` | off | Always use Telethon's single-stream downloader |
| `--overwrite` / `--skip-existing` | ask / skip | Collision policy (never auto-renames) |
| `--api-id`, `--api-hash`, `--phone` | — | Set/save credentials non-interactively |
| `--export-profile [FILE]` | `./tmedia-profile-<date>.tar.gz` | Bundle login for another PC |
| `--import-profile FILE` | — | Restore login with zero new code |
| `--doctor` | — | Offline credentials / session / Desktop check |
| `--logout` | — | Delete local session + credentials |
| `--no-banner` | off | Suppress ASCII banner |
| `-V, --version` | — | Print version |

Environment: `TMEDIA_CONFIG_DIR`, `TMEDIA_DOWNLOAD_DIR`, `TMEDIA_API_ID`,
`TMEDIA_API_HASH`, `TMEDIA_PHONE` (+ aliases listed above).

---

## Supported links

| Link | Result |
|---|---|
| `https://t.me/durov/123` | Public post |
| `t.me/durov/123?single` | Public post (scheme optional) |
| `https://t.me/c/1234567890/42` | Private / restricted post |
| `https://t.me/c/1234567890/12/987` | Post inside a forum topic |
| `https://telegram.me/name/9` | Legacy host aliases |

Private `/c/` links become the MTProto id `-100…`; if Telethon has not cached
the channel yet, tmedia warms the entity cache from your dialogs and retries.
**You must already be a member** — this is not an access-control bypass.

Not supported: invite links (`t.me/+…`, `joinchat`), stories (`/s/…`),
`?comment=` replies (the parent post is downloaded), and album siblings (only
the linked message is fetched).

---

## Fidelity, speed and errors

* **Bytes**: streamed verbatim from MTProto → hidden `.tmedia-*.part` →
  `os.replace()` atomic commit. EXIF / ID3 / subtitles / container metadata
  survive. No partial files. `mtime`/`atime` = Telegram message date; mode `0644`.
* **Filename**: `DocumentAttributeFilename` untouched except for path
  traversal, NUL/control chars and `NAME_MAX`. Photos (which have no Telegram
  filename) get `photo_YYYY-MM-DD_HH-MM-SS_<msgid>.jpg`.
* **Speed**: asyncio + strided `iter_download` with `os.pwrite` into a
  pre-allocated file; any failure (CDN redirect, expired file reference,
  odd media, Windows, older Telethon) falls back to `download_media()` after a
  byte-count verification. `cryptg` accelerates decryption when available.
* **Errors**: every exception becomes one human line — no tracebacks, ever.
  Batch mode continues past failures and prints a final
  `Downloaded / Skipped / Failed` summary.

---

## Security & privacy

* `~/.config/tmedia/` → `0700`; `config.json`, `session.session*`, exported
  profiles → `0600`.
* **A session file contains a live Telegram auth key.** Never commit, paste or
  share it. `.gitignore` blocks `*.session`, `config.json`, `.env` and
  `*.tar.gz` profiles. Profile archives strictly whitelist member names
  (no path traversal on import).
* `tmedia --logout` deletes local credentials/session. Revoke a device on
  Telegram: *Settings → Privacy and Security → Active Sessions*.
* Only download content your account is authorised to access. Respect
  Telegram's ToS and third-party copyright. This project is not affiliated
  with Telegram.

---

## Repository layout

```
tmedia/
├── README.md                     ← this file
├── LICENSE                       MIT
├── CHANGELOG.md
├── CONTRIBUTING.md
├── .gitignore
├── src/tmedia.py                 canonical, complete Python source
├── install_tmedia.sh             fresh install (embeds src/tmedia.py)
├── upgrade_tmedia.sh             in-place upgrade (embeds src/tmedia.py)
├── assets/
│   ├── setup_windows.ps1
│   └── setup_termux.sh
├── examples/links.example.txt
├── scripts/publish_github.sh     one-command public repo publish (gh CLI)
└── .github/workflows/ci.yml      syntax + embedded-source sync checks
```

The two shell scripts embed `src/tmedia.py` verbatim; CI fails if they drift
out of sync. CI also runs `bash -n`, `ast.parse`, `--version` and `--help`.

### Publish to GitHub (public)

Arena has no GitHub connector in this session, so push from your own machine:

```bash
cd tmedia-repo
gh auth login                       # once
bash scripts/publish_github.sh      # creates <you>/tmedia --public and pushes
# or: bash scripts/publish_github.sh my-user/my-repo
```

The script refuses to stage any `*.session`, `config.json` or profile archive.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `tmedia: command not found` | Re-run the installer; reopen the terminal (Windows PATH). |
| `tmedia --doctor` says `API credentials: NOT FOUND` | `tmedia --import-profile <file>` or set `TMEDIA_API_ID` / `TMEDIA_API_HASH`, or follow the `>` guide once. |
| `You are not a member of this private channel` | Join with the same account, then retry. |
| Login code rejected / expired | Restart `tmedia`; codes expire quickly. |
| `session is no longer valid` | `tmedia --logout`, then re-import a profile or log in once. |
| GUI file dialog missing | Expected on headless/Windows/Termux → terminal path prompt. |
| Slow downloads | Install `cryptg`, try `-w 8`; avoid very high `-j` (rate limits). |

## Uninstall

```bash
tmedia --logout
sudo rm -rf /opt/tmedia /usr/local/bin/tmedia      # Linux
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Issues, forks and reviews are very
welcome — especially platform fixes, album support and translations.

## License

[MIT](LICENSE) · © 2026 tmedia contributors. Not affiliated with Telegram.
