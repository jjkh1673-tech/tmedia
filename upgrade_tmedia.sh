#!/usr/bin/env bash
# =============================================================================
#  upgrade_tmedia.sh  --  in-place upgrade for an ALREADY INSTALLED tmedia
#  Target : BackBox / Ubuntu / Debian (v1.0.x / v1.1.x -> v1.2.0)
#
#  • Replaces ONLY /opt/tmedia/tmedia.py with the embedded v1.2.0 source.
#  • NEVER touches ~/.config/tmedia (API credentials + session stay intact).
#  • Idempotent: safe to run repeatedly. Rolls back automatically on failure.
#  • Does NOT delete itself (keep it in the repo for future upgrades).
#
#  New in v1.2.0: ONE API pair + every logged-in account, automatic
#  account fallback for private posts, --account / --list-accounts /
#  --add-account, channels.GetChannels resolution, ?comment= replies.
#  Also keeps all v1.1.0 zero-login recovery and portable profiles.
# =============================================================================
set -Eeuo pipefail

readonly TM_VERSION="1.2.0"
readonly TM_PREFIX="/opt/tmedia"
readonly TM_PY="$TM_PREFIX/tmedia.py"
readonly TM_VENV="$TM_PREFIX/venv"
readonly TM_BIN="/usr/local/bin/tmedia"
readonly TM_SELF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && printf '%s/%s' "$PWD" "$(basename -- "${BASH_SOURCE[0]}")")"

if (( EUID != 0 )); then
    if ! command -v sudo >/dev/null 2>&1; then
        printf '[!] Root privileges required. Run: sudo bash %s\n' "$TM_SELF" >&2
        exit 1
    fi
    printf '[*] Root privileges required - re-running with sudo...\n'
    exec sudo bash "$TM_SELF" "$@"
fi

REAL_USER="${SUDO_USER:-root}"
[[ "$REAL_USER" == "root" ]] && REAL_USER="$(logname 2>/dev/null || printf 'root')"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
[[ -n "$REAL_HOME" ]] || REAL_HOME="${HOME:-/root}"

step() { printf '\n[+] %s\n' "$1"; }
fail() { printf '\n[!] %s\n' "$1" >&2; exit 1; }

# --- sanity: this is an UPGRADE, not a fresh installer -----------------------
[[ -x "$TM_VENV/bin/python" ]] || fail "No virtualenv at $TM_VENV. Run install_tmedia.sh first."
[[ -f "$TM_BIN" ]] || printf '[i] Warning: %s is missing; it will be recreated.\n' "$TM_BIN"

# --- rollback safety net ----------------------------------------------------
BACKUP=""
if [[ -f "$TM_PY" ]]; then
    BACKUP="$(mktemp /tmp/tmedia-source-backup.XXXXXXXX)"
    cp -p -- "$TM_PY" "$BACKUP"
fi
cleanup() {
    local rc=$?
    set +e
    trap - EXIT
    if (( rc != 0 )) && [[ -n "$BACKUP" && -f "$BACKUP" ]]; then
        cp -p -- "$BACKUP" "$TM_PY"
        printf '[!] Upgrade failed - previous source restored.\n' >&2
    fi
    [[ -n "$BACKUP" ]] && rm -f -- "$BACKUP"
    rm -rf -- /tmp/tmedia-upgrade-pip-cache
    return "$rc"
}
trap cleanup EXIT

# --- 1. dependencies (only if the venv is incomplete) -----------------------
step "Checking Python dependencies..."
if ! "$TM_VENV/bin/python" -c 'import telethon, rich' >/dev/null 2>&1; then
    printf '    installing missing libraries...\n'
    PIP_ENV=( "PIP_DISABLE_PIP_VERSION_CHECK=1" "PYTHONDONTWRITEBYTECODE=1"
              "PIP_CACHE_DIR=/tmp/tmedia-upgrade-pip-cache"
              "PIP_ROOT_USER_ACTION=ignore" )
    env "${PIP_ENV[@]}" "$TM_VENV/bin/python" -m pip install --quiet --no-input \
        --disable-pip-version-check --retries 2 --timeout 30 \
        "Telethon>=1.36,<2" "rich>=13,<15" \
        || fail "Could not install Telethon / rich (check your network)."
    rm -rf -- /tmp/tmedia-upgrade-pip-cache
else
    printf '    Telethon + rich already present\n'
fi

# --- 2. replace ONLY the application source ---------------------------------
step "Upgrading application source to v$TM_VERSION ..."
mkdir -p -- "$TM_PREFIX"
cat > "$TM_PY" <<'__TMEDIA_PY_SOURCE_9F3C21__'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tmedia -- a system-wide Telegram media downloader for Linux (BackBox / Ubuntu).
==============================================================================

Design goals
------------
* Download Telegram media through the real MTProto API (Telethon), because
  ``curl``/``wget`` cannot read ``t.me`` message links.
* Keep the **exact original bytes, filename and extension**. Nothing is
  re-encoded, renamed or resized. EXIF / ID3 / container metadata therefore
  survives untouched; the file's mtime is set to the Telegram message date.
* Public links (``https://t.me/channel/123``) and private/restricted links
  (``https://t.me/c/123456789/123``) are both supported.
* One-time interactive login; the session is reused on every later run.
* Zero-login recovery (v1.1): API credentials are auto-discovered from the
  local config, environment variables or other Telegram tool configs, and an
  existing authorised Telethon session anywhere on the machine is reused.
  `--export-profile` / `--import-profile` move a login between PCs with no
  new code. Only if nothing is recoverable is a compact `>` guide shown.
* Universal access (v1.2): ONE api_id/api_hash pair drives every authorised
  session on this machine. Pin the account that can see the post with
  `--account`; otherwise tmedia automatically tries the other logged-in
  accounts when a private/restricted post is invisible, so public and private
  links both resolve with zero new login.
* Async I/O plus an optional multi-connection (strided chunk) downloader for
  large documents, with an automatic, transparent fallback to Telethon's
  battle-tested ``download_media`` if the fast path cannot be used.
* Human-readable errors only. No raw tracebacks ever reach the user.

The file is intentionally a single, self-contained module so it can be
embedded verbatim in ``install_tmedia.sh`` and dropped into
``/opt/tmedia/tmedia.py``. It is organised in clearly separated sections:

    1. Imports, constants and small helpers
    2. Errors and friendly error mapping
    3. Telegram link parsing / validation
    4. Credentials, session and login
    5. Message resolution and media inspection
    6. Download engines (parallel + fallback), atomic writes, metadata
    7. Terminal UI (banner, panels, progress reporter, file picker)
    8. Workflows (single link, batch file, interactive menu)
    9. CLI entry point
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import math
import mimetypes
import os
import platform
import re
import shutil
import sqlite3
import subprocess
import sys
import tarfile
import uuid
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Optional, Sequence, Union
from urllib.parse import parse_qs, unquote, urlparse

__version__ = "1.2.0"
APP_NAME = "tmedia"

# ---------------------------------------------------------------------------
# 1. Imports, constants and small helpers
# ---------------------------------------------------------------------------

try:
    from telethon import TelegramClient, functions
    import telethon.errors as tg_errors
    from telethon.tl import types

    from rich.console import Console
    from rich.markup import escape
    from rich.panel import Panel
    from rich.prompt import Confirm, Prompt
    from rich.progress import (
        BarColumn,
        DownloadColumn,
        Progress,
        ProgressColumn,
        SpinnerColumn,
        TaskProgressColumn,
        TextColumn,
        TimeRemainingColumn,
        TransferSpeedColumn,
    )
    from rich.table import Table
    from rich.text import Text
except ImportError as _exc:  # A broken venv must not produce a traceback.
    sys.stderr.write(
        "[!] Error: a required Python package is missing ({0}).\n".format(
            getattr(_exc, "name", None) or _exc
        )
        + "    Fix: /opt/tmedia/venv/bin/python -m pip install Telethon rich cryptg\n"
        + "    (or simply re-run install_tmedia.sh)\n"
    )
    raise SystemExit(1)


# Paths can be relocated with env vars (useful on Termux / Windows / portable
# profiles). Defaults are exactly the Linux specification: ~/.config/tmedia
# and ~/Downloads.
CONFIG_DIR = Path(
    os.environ.get("TMEDIA_CONFIG_DIR") or (Path.home() / ".config" / APP_NAME)
).expanduser()
CONFIG_FILE = CONFIG_DIR / "config.json"
SESSION_FILE = CONFIG_DIR / "session.session"
DEFAULT_DOWNLOAD_DIR = Path.home() / "Downloads"

# Credential auto-discovery order. Set the first pair anywhere (shell profile,
# systemd user env, .env) and tmedia never asks again on any machine.
ENV_API_ID_KEYS = ("TMEDIA_API_ID", "TELEGRAM_API_ID", "TG_API_ID", "API_ID")
ENV_API_HASH_KEYS = ("TMEDIA_API_HASH", "TELEGRAM_API_HASH", "TG_API_HASH", "API_HASH")
ENV_PHONE_KEYS = ("TMEDIA_PHONE", "TELEGRAM_PHONE", "TG_PHONE", "PHONE")
PROFILE_MEMBERS = ("config.json", "session.session")

# v1.2: ONE API pair, many authorised accounts. Sessions are kept separately
# so the account that can actually see a private post is never silently lost.
ACCOUNTS_DIR = CONFIG_DIR / "accounts"
ACTIVE_ACCOUNT_FILE = CONFIG_DIR / "active_account"
MAX_EXTRA_ACCOUNTS = 8

# All spellings accepted in JSON / .env configs (canonical first).
API_ID_ALIASES = ("api_id", "API_ID", "apiId", "app_id") + ENV_API_ID_KEYS + tuple(
    key.lower() for key in ENV_API_ID_KEYS
)
API_HASH_ALIASES = ("api_hash", "API_HASH", "apiHash", "app_hash") + ENV_API_HASH_KEYS + tuple(
    key.lower() for key in ENV_API_HASH_KEYS
)
PHONE_ALIASES = ("phone", "phone_number", "PHONE") + ENV_PHONE_KEYS + tuple(
    key.lower() for key in ENV_PHONE_KEYS
)

TELEGRAM_HOSTS = {
    "t.me",
    "www.t.me",
    "telegram.me",
    "www.telegram.me",
    "telegram.dog",
    "www.telegram.dog",
}

# Telegram's GetFileRequest wants request sizes that are multiples of 4 KiB and
# no larger than 512 KiB. 256 KiB gives a good parallelism/overhead balance.
CHUNK_SIZE = 256 * 1024
DEFAULT_WORKERS = 4
MAX_FILENAME_BYTES = 255  # ext4 / xfs NAME_MAX

console = Console(highlight=False)

BANNER = r"""
████████╗███╗   ███╗███████╗██████╗ ██╗█████╗
╚══██╔══╝████╗ ████║██╔════╝██╔══██╗██║██╔══██╗
   ██║   ██╔████╔██║█████╗  ██║  ██║██║███████║
   ██║   ██║╚██╔╝██║██╔══╝  ██║  ██║██║██╔══██║
   ██║   ██║ ╚═╝ ██║███████╗██████╔╝██║██║  ██║
   ╚═╝   ╚═╝     ╚═╝╚══════╝╚═════╝ ╚═╝╚═╝  ╚═╝
"""


def human_size(num: Optional[Union[int, float]]) -> str:
    """Byte count -> compact human readable string."""
    if num is None or num < 0:
        return "unknown size"
    value = float(num)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024.0 or unit == "TB":
            return "{0:d} B".format(int(value)) if unit == "B" else "{0:.1f} {1}".format(value, unit)
        value /= 1024.0
    return "{0:.1f} TB".format(value)


def shorten(text: str, width: int = 38) -> str:
    """Keep progress-bar labels from eating the whole terminal."""
    if len(text) <= width:
        return text
    head = width // 2 - 2
    return text[:head] + "…" + text[-(width - head - 1) :]


def print_banner() -> None:
    console.print(Text(BANNER.strip("\n"), style="bold cyan"))
    line = Text()
    line.append("   TMEDIA ", style="bold white")
    line.append("v" + __version__, style="cyan")
    line.append("  •  Telegram MTProto media downloader", style="dim")
    console.print(line)
    console.print(Text("   " + "─" * 58, style="dim cyan"))
    console.print()


# ---------------------------------------------------------------------------
# 2. Errors and friendly error mapping
# ---------------------------------------------------------------------------


class TMediaError(Exception):
    """An error whose message is already safe and useful for a human."""


class AccountAccessError(TMediaError):
    """This account cannot see the post; another account should be tried."""


def flood_seconds(exc: BaseException) -> Optional[int]:
    """Extract a FloodWait delay without depending on a specific class import."""
    if type(exc).__name__ != "FloodWaitError":
        return None
    seconds = getattr(exc, "seconds", None)
    return int(seconds) if isinstance(seconds, (int, float)) else None


def humanize_error(exc: BaseException) -> str:
    """
    Translate *any* exception into a single, calm, one-line message.

    Matching is done on the exception class name (plus ``isinstance`` for
    stdlib errors) so this keeps working across Telethon 1.x releases and
    never leaks a Python traceback to the terminal.
    """
    if isinstance(exc, TMediaError):
        return str(exc)

    name = type(exc).__name__
    detail = " ".join(str(exc).split())[:180]

    if name == "FloodWaitError":
        secs = flood_seconds(exc)
        return "Telegram rate limit reached. Wait {0} seconds and try again.".format(secs or "a few")

    if name in {
        "ChannelPrivateError",
        "ChatForbiddenError",
        "ChatAdminRequiredError",
        "UserNotParticipantError",
        "ChannelPublicGroupNaError",
    }:
        return "You are not a member of this private channel. Join it in Telegram first."

    if name in {"InviteHashInvalidError", "InviteHashExpiredError", "InviteRequestSentError"}:
        return "That is an invite link, not a message link. Paste a link like https://t.me/c/123456/789"

    if name in {"ChannelInvalidError", "PeerIdInvalidError", "InputConstructorInvalidError"}:
        return "This chat could not be found. Check the link (and that your account can see it)."

    if name in {"MediaEmptyError", "FileIdInvalidError", "LocationInvalidError"}:
        return "Telegram returned empty media for this message. It may have been deleted."

    if name in {"FileReferenceExpiredError", "FilerefUpgradeNeededError"}:
        return "The media reference expired. tmedia retries automatically; please run it again."

    if name in {
        "AuthKeyError",
        "AuthKeyUnregisteredError",
        "AuthKeyInvalidError",
        "UnauthorizedError",
        "SessionRevokedError",
        "UserDeactivatedError",
        "UserDeactivatedBanError",
    }:
        return "Your saved session is no longer valid. Run 'tmedia --logout' and log in again."

    if name in {"ApiIdInvalidError", "ApiIdPublishedFloodError", "AccessTokenInvalidError"}:
        return "Invalid API ID / API HASH. Check https://my.telegram.org, then run 'tmedia --logout'."

    if name in {"PhoneNumberInvalidError", "PhoneNumberBannedError"}:
        return "That phone number is not valid for this Telegram account."

    if name in {"PhoneCodeInvalidError", "PhoneCodeEmptyError", "PasswordHashInvalidError"}:
        return "Wrong login code or 2FA password. Please try again."

    if name in {"PhoneCodeExpiredError", "PhoneCodeHashEmptyError"}:
        return "The login code expired. Start tmedia again to request a new one."

    if name == "SessionPasswordNeededError":
        return "Two-step verification is enabled; your 2FA password is required."

    if isinstance(exc, sqlite3.OperationalError):
        return "The session file is locked by another tmedia process. Close it and retry."

    if isinstance(exc, PermissionError):
        return "Permission denied writing to ~/Downloads. Check the folder's ownership."

    if isinstance(exc, FileNotFoundError):
        return "A required file was not found: {0}".format(detail)

    if isinstance(exc, (ConnectionError, OSError, asyncio.TimeoutError, TimeoutError)):
        return "Network problem while talking to Telegram ({0}). Check your connection and retry.".format(
            name
        )

    if isinstance(exc, ValueError):
        return "The link / chat could not be resolved ({0}). Check the URL.".format(detail or "invalid value")

    if isinstance(exc, KeyboardInterrupt):
        return "Cancelled."

    return "{0}: {1}".format(name, detail or "unexpected error")


# Errors that mean "THIS account cannot see it", not "the link is broken".
ACCESS_ERROR_NAMES = {
    "ChannelPrivateError", "ChatForbiddenError", "ChatAdminRequiredError",
    "UserNotParticipantError", "ChannelPublicGroupNaError", "ChannelInvalidError",
    "PeerIdInvalidError", "InputConstructorInvalidError", "MessageIdInvalidError",
    "InviteHashInvalidError", "EntityNotFoundError",
}


def is_access_error(exc: BaseException) -> bool:
    """True when another logged-in account may be able to see this post."""
    if isinstance(exc, AccountAccessError):
        return True
    if type(exc).__name__ in ACCESS_ERROR_NAMES:
        return True
    if isinstance(exc, TMediaError):
        text = str(exc).lower()
        return any(word in text for word in (
            "not a member", "not visible", "cannot see", "could not be found",
            "deleted or does not exist", "no logged-in account", "not authorised",
        ))
    # Telethon raises ValueError("Could not find the input entity for ...")
    return isinstance(exc, ValueError)


# ---------------------------------------------------------------------------
# 3. Telegram link parsing / validation
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class TelegramLink:
    """A validated, normalised Telegram message link."""

    raw: str
    entity: Union[str, int]  # username for public links, -100… id for private
    message_id: int
    channel_id: Optional[int]  # positive id without the -100 prefix
    kind: str  # "public" | "private"
    topic_id: Optional[int] = None    # forum topic in /c/<chat>/<topic>/<msg>
    comment_id: Optional[int] = None  # ?comment=<id> discussion reply
    thread_id: Optional[int] = None   # ?thread=<id>


def parse_link(raw: str) -> TelegramLink:
    """
    Accepts and validates:
        https://t.me/durov/123
        t.me/durov/123?single
        https://t.me/c/1234567890/123
        https://t.me/c/1234567890/12/987      (topic link)
        https://telegram.me/durov/123
        https://t.me/durov/123?comment=45       (discussion reply)

    Rejects invite links, stories, album-less links and everything else with
    a short explanation instead of an exception traceback.
    """
    text = (raw or "").strip().strip("\"'<>,;")
    if not text:
        raise TMediaError("Empty URL. Paste a link like https://t.me/channel/123")

    if "://" not in text:
        text = "https://" + text.lstrip("/")

    parsed = urlparse(text)
    host = (parsed.hostname or "").lower()
    if host not in TELEGRAM_HOSTS:
        raise TMediaError("Not a Telegram link. Expected a t.me / telegram.me message URL.")

    parts = [unquote(p) for p in parsed.path.split("/") if p]
    if not parts:
        raise TMediaError("Incomplete link. A message URL must end with a message number.")

    query = parse_qs(parsed.query or "")

    def query_int(key: str) -> Optional[int]:
        for value in query.get(key, []):
            if re.fullmatch(r"\d+", value or ""):
                return int(value)
        return None

    comment_id = query_int("comment") or query_int("reply")
    thread_id = query_int("thread") or query_int("topic")
    head = parts[0].lower()

    if head.startswith("+") or head in {
        "joinchat",
        "addstickers",
        "addtheme",
        "setlanguage",
        "share",
        "s",
    }:
        raise TMediaError("That is an invite / story link, not a message link. Copy the post link instead.")

    if head == "c":
        # /c/<chat_id>/<msg_id>  or  /c/<chat_id>/<topic_id>/<msg_id>
        nums = parts[1:]
        if len(nums) < 2 or not all(re.fullmatch(r"-?\d+", n) for n in nums):
            raise TMediaError("Malformed private link. Expected https://t.me/c/123456789/123")

        raw_chat = nums[0]
        if raw_chat.startswith("-100"):
            channel_id = int(raw_chat[4:])
            entity: Union[str, int] = int(raw_chat)
        else:
            channel_id = int(raw_chat)
            entity = int("-100" + str(channel_id))
        message_id = int(nums[-1])
        topic_id = int(nums[1]) if len(nums) >= 3 else thread_id

        if channel_id <= 0 or message_id <= 0:
            raise TMediaError("Malformed private link: chat and message ids must be positive.")
        return TelegramLink(text, entity, message_id, channel_id, "private", topic_id, comment_id, thread_id)

    # Public link: /<username>/<message_id>[/<reply_id>]
    if len(parts) < 2 or not re.fullmatch(r"\d+", parts[-1]):
        raise TMediaError("Link must point to a single message, e.g. https://t.me/channel/123")
    username = parts[0].lstrip("@")
    if not re.fullmatch(r"[A-Za-z0-9_]+", username):
        raise TMediaError("Invalid channel username in the link.")
    message_id = int(parts[-1])
    if message_id <= 0:
        raise TMediaError("Invalid message number in the link.")
    return TelegramLink(text, username, message_id, None, "public", thread_id, comment_id, thread_id)


def safe_filename(name: str) -> str:
    """
    Keep Telegram's filename exactly, but strip anything that could escape the
    destination directory (path traversal, NUL, control characters) and cap it
    at the filesystem NAME_MAX while preserving the extension.
    """
    cleaned = name.replace("\x00", "").replace("\\", "/")
    cleaned = os.path.basename(cleaned)
    cleaned = "".join(ch for ch in cleaned if ch.isprintable()).strip()
    if cleaned in {"", ".", ".."}:
        raise TMediaError("Telegram returned an unusable filename for this media.")

    if len(cleaned.encode("utf-8", "ignore")) <= MAX_FILENAME_BYTES:
        return cleaned

    stem, ext = os.path.splitext(cleaned)
    ext_bytes = ext.encode("utf-8", "ignore")[:32]
    stem_bytes = stem.encode("utf-8", "ignore")[: MAX_FILENAME_BYTES - len(ext_bytes)]
    return stem_bytes.decode("utf-8", "ignore") + ext_bytes.decode("utf-8", "ignore")


# ---------------------------------------------------------------------------
# 4. Credentials, session and login
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Credentials:
    api_id: int
    api_hash: str
    phone: str


def ensure_config_dir() -> None:
    try:
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        os.chmod(CONFIG_DIR, 0o700)  # session + api credentials are private
    except OSError as exc:
        raise TMediaError("Cannot create {0}: {1}".format(CONFIG_DIR, humanize_error(exc)))


def harden_session_permissions() -> None:
    """chmod 600 every session file Telethon/SQLite may have created."""
    try:
        os.chmod(CONFIG_DIR, 0o700)
        for item in CONFIG_DIR.glob("session.session*"):
            os.chmod(item, 0o600)
        if ACCOUNTS_DIR.is_dir():
            os.chmod(ACCOUNTS_DIR, 0o700)
            for item in ACCOUNTS_DIR.glob("*.session*"):
                os.chmod(item, 0o600)
        if ACTIVE_ACCOUNT_FILE.exists():
            os.chmod(ACTIVE_ACCOUNT_FILE, 0o600)
    except OSError:
        pass  # never let a cosmetic chmod break a successful download


def save_credentials(creds: Credentials) -> None:
    """Atomic, mode-0600 write of the API credentials."""
    ensure_config_dir()
    payload = json.dumps(
        {"api_id": creds.api_id, "api_hash": creds.api_hash, "phone": creds.phone}, indent=2
    )
    tmp = CONFIG_DIR / (".config.json." + uuid.uuid4().hex + ".tmp")
    try:
        fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(payload + "\n")
        os.replace(tmp, CONFIG_FILE)
        os.chmod(CONFIG_FILE, 0o600)
    except OSError as exc:
        tmp.unlink(missing_ok=True)
        raise TMediaError("Could not save credentials: {0}".format(humanize_error(exc)))


def valid_credentials(api_id, api_hash, phone: str = "") -> Optional[Credentials]:
    """Normalise + validate a credential triple; phone is optional when a
    session already exists (it is only needed to request a login code)."""
    try:
        ident = int(str(api_id).strip())
    except (TypeError, ValueError):
        return None
    digest = str(api_hash or "").strip()
    number = re.sub(r"[\s()\-]", "", str(phone or ""))
    if ident <= 0 or not re.fullmatch(r"[0-9a-fA-F]{32}", digest):
        return None
    if number and not re.fullmatch(r"\+?\d{7,15}", number):
        number = ""
    return Credentials(ident, digest, number)


def credentials_from_mapping(data) -> Optional[Credentials]:
    if not isinstance(data, dict):
        return None

    def pick(*keys):
        for key in keys:
            value = data.get(key)
            if value not in (None, ""):
                return value
        return None

    return valid_credentials(pick(*API_ID_ALIASES), pick(*API_HASH_ALIASES), pick(*PHONE_ALIASES))


def parse_env_file(path: Path) -> dict:
    """Tiny KEY=VALUE reader (also accepts `export KEY=VALUE`)."""
    result = {}
    try:
        if path.stat().st_size > 64 * 1024:
            return result
        for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.lower().startswith("export "):
                line = line[7:].strip()
            if "=" not in line:
                continue
            key, value = line.split("=", 1)
            result[key.strip()] = value.strip().strip('"').strip("'")
    except OSError:
        pass
    return result


def discover_credentials():
    """
    Find API credentials WITHOUT asking the user. Priority:
      1. tmedia's own config.json
      2. environment variables (TMEDIA_*, TELEGRAM_*, TG_*, API_*)
      3. local .env / JSON configs, incl. other Telethon-based tools
    Returns (Credentials, origin) or None. Reading only; nothing is changed.
    """
    if CONFIG_FILE.exists():
        try:
            found = credentials_from_mapping(json.loads(CONFIG_FILE.read_text(encoding="utf-8")))
            if found:
                return found, str(CONFIG_FILE)
        except Exception:
            pass

    environ = {key.upper(): value for key, value in os.environ.items()}
    mapping = {}
    for group, field in (
        (ENV_API_ID_KEYS, "api_id"),
        (ENV_API_HASH_KEYS, "api_hash"),
        (ENV_PHONE_KEYS, "phone"),
    ):
        for key in group:
            if environ.get(key):
                mapping[field] = environ[key]
                break
    found = credentials_from_mapping(mapping)
    if found:
        return found, "environment variables"

    home = Path.home()
    candidates = [
        CONFIG_DIR / ".env",
        home / ".tmedia.env",
        home / ".config" / "telegram-api.json",
        home / ".config" / "telegram" / "api.json",
        home / ".config" / "tmedia" / "credentials.json",
    ]
    try:
        # Shallow, bounded look at other tools' config.json files.
        for extra in sorted((home / ".config").glob("*/config.json"))[:120]:
            if extra != CONFIG_FILE:
                candidates.append(extra)
    except OSError:
        pass

    for path in candidates:
        try:
            if not path.is_file() or path.stat().st_size > 64 * 1024:
                continue
            if path.suffix in ("", ".env"):
                data = parse_env_file(path)
            else:
                data = json.loads(path.read_text(encoding="utf-8", errors="ignore"))
        except Exception:
            continue
        found = credentials_from_mapping(data)
        if found:
            return found, str(path)
    return None


def desktop_telegram_path() -> Optional[str]:
    """Detect an installed Telegram Desktop (informational only)."""
    for name in ("telegram-desktop", "telegram", "Telegram"):
        found = shutil.which(name)
        if found:
            return found
    candidates = [
        Path("/opt/Telegram/Telegram"),
        Path("/usr/bin/telegram-desktop"),
        Path.home() / ".local" / "share" / "TelegramDesktop" / "tdata",
        Path.home() / ".config" / "TelegramDesktop",
    ]
    if os.name == "nt" and os.environ.get("LOCALAPPDATA"):
        candidates.append(Path(os.environ["LOCALAPPDATA"]) / "Telegram Desktop" / "tdata")
    for path in candidates:
        try:
            if path.exists():
                return str(path)
        except OSError:
            pass
    return None


def print_api_guide() -> None:
    """Compact `>` guide shown ONLY when no credentials can be recovered."""
    desktop = desktop_telegram_path()
    lines = [
        "> No API credentials found here. One-time setup (~60s), no new app install:",
        ">   1. https://my.telegram.org  ->  phone login  ->  'API development tools'",
        ">   2. Create an app -> copy App api_id (number) + App api_hash (32 chars)",
        ">   3. Paste below. Saved once; tmedia never asks again.",
    ]
    if desktop:
        lines.append(
            ">   Telegram Desktop detected ({0}); its encrypted tdata is NOT importable".format(desktop)
        )
        lines.append(">   by third-party clients. To reuse PC-1's login with ZERO new login:")
    else:
        lines.append(">   Already set up tmedia on another PC? Reuse it with ZERO new login:")
    lines.append(">       tmedia --export-profile  ->  copy .tar.gz  ->  tmedia --import-profile <file>")
    lines.append(">   Or export TMEDIA_API_ID / TMEDIA_API_HASH (and TMEDIA_PHONE) in your shell.")
    console.print(Text("\n".join(lines), style="cyan"), soft_wrap=True)
    console.print()


def is_telethon_session(path: Path) -> bool:
    """True when `path` is a Telethon SQLiteSession holding a real auth key."""
    connection = None
    try:
        if not path.is_file() or path.stat().st_size > 8 * 1024 * 1024:
            return False
        connection = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=1)
        if not connection.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='sessions'"
        ).fetchone():
            return False
        columns = [row[1] for row in connection.execute("PRAGMA table_info(sessions)")]
        if "auth_key" not in columns:
            return False
        count = connection.execute(
            "SELECT COUNT(*) FROM sessions WHERE auth_key IS NOT NULL AND LENGTH(auth_key) > 0"
        ).fetchone()[0]
        return bool(count)
    except Exception:
        return False
    finally:
        if connection is not None:
            try:
                connection.close()
            except Exception:
                pass


def iter_session_files():
    """Bounded, read-only scan for Telethon `*.session` files on this machine."""
    seen = set()
    skip_dirs = {
        ".cache", ".git", "node_modules", "venv", ".venv", "__pycache__",
        "site-packages", ".npm", ".cargo", ".rustup", "proc", "sys", "dev",
    }

    def offer(path: Path):
        try:
            resolved = path.resolve()
            if resolved not in seen and resolved.is_file() and resolved.suffix == ".session":
                seen.add(resolved)
                yield resolved
        except OSError:
            return

    yield from offer(SESSION_FILE)
    count = 0
    for root in (
        Path.home(),
        Path.home() / ".config",
        Path.home() / ".local" / "share",
        CONFIG_DIR.parent,  # custom/portable profiles may live outside $HOME
        Path.cwd(),
    ):
        if count > 4000:
            return
        if not root.is_dir():
            continue
        for dirpath, dirnames, filenames in os.walk(root, onerror=lambda _e: None):
            try:
                depth = len(Path(dirpath).relative_to(root).parts)
            except ValueError:
                depth = 0
            dirnames[:] = [d for d in dirnames if d not in skip_dirs and not d.startswith(".")]
            if depth >= 3:
                dirnames[:] = []
            for name in filenames:
                if name.endswith(".session"):
                    count += 1
                    if count > 4000:
                        return
                    yield Path(dirpath) / name


def auto_import_session() -> Optional[str]:
    """
    Self-healing session recovery: reuse tmedia's own session, otherwise copy
    any existing authorised Telethon session found on this machine. Copying
    (not moving) keeps the other application's session untouched.
    """
    ensure_config_dir()
    if SESSION_FILE.exists() and is_telethon_session(SESSION_FILE):
        return "existing tmedia session (no login needed)"
    own = SESSION_FILE.resolve()
    for candidate in iter_session_files():
        try:
            if candidate.resolve() == own or not is_telethon_session(candidate):
                continue
            shutil.copyfile(candidate, SESSION_FILE)
            os.chmod(SESSION_FILE, 0o600)
            return "recovered an existing Telethon session from {0} (no login code needed)".format(candidate)
        except OSError:
            continue
    return None


# ---------------------------------------------------------------------------
# 4b. Multi-account sessions (v1.2) -- ONE API pair, every authorised login
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Account:
    label: str
    path: Path
    primary: bool = False


def sanitize_label(text: str) -> str:
    label = re.sub(r"[^A-Za-z0-9_.-]+", "-", str(text).strip()).strip("-.")
    return (label or "account")[:48]


def ensure_accounts_dir() -> None:
    ensure_config_dir()
    try:
        ACCOUNTS_DIR.mkdir(parents=True, exist_ok=True)
        os.chmod(ACCOUNTS_DIR, 0o700)
    except OSError as exc:
        raise TMediaError("Cannot create {0}: {1}".format(ACCOUNTS_DIR, humanize_error(exc)))


def session_signature(path: Path) -> Optional[str]:
    """Content hash, used so the same login is never registered twice."""
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError:
        return None


def read_active_account() -> Optional[str]:
    try:
        return ACTIVE_ACCOUNT_FILE.read_text(encoding="utf-8").strip() or None
    except OSError:
        return None


def write_active_account(label: str) -> None:
    ensure_config_dir()
    tmp = CONFIG_DIR / (".active_account." + uuid.uuid4().hex + ".tmp")
    try:
        tmp.write_text(label + "\n", encoding="utf-8")
        os.chmod(tmp, 0o600)
        os.replace(tmp, ACTIVE_ACCOUNT_FILE)
    except OSError as exc:
        tmp.unlink(missing_ok=True)
        raise TMediaError("Could not pin the account: {0}".format(humanize_error(exc)))


def registered_accounts():
    """Primary tmedia session + every valid named session in accounts/."""
    found = []
    seen = set()
    if SESSION_FILE.exists() and is_telethon_session(SESSION_FILE):
        found.append(Account("main", SESSION_FILE, True))
        seen.add(session_signature(SESSION_FILE))
    if ACCOUNTS_DIR.is_dir():
        for path in sorted(ACCOUNTS_DIR.glob("*.session")):
            if not is_telethon_session(path):
                continue
            signature = session_signature(path)
            if signature and signature in seen:
                continue
            seen.add(signature)
            found.append(Account(path.stem, path, not found))
    return found


def register_session(source: Path, label: Optional[str] = None) -> Account:
    """Copy an authorised Telethon session into accounts/ (zero login)."""
    source = Path(source).expanduser()
    if not source.is_file() or not is_telethon_session(source):
        raise TMediaError("Not an authorised Telethon .session file: {0}".format(source))
    ensure_accounts_dir()
    signature = session_signature(source)
    for existing in ACCOUNTS_DIR.glob("*.session"):
        if session_signature(existing) == signature:
            return Account(existing.stem, existing, False)
    name = sanitize_label(label or source.stem)
    target = ACCOUNTS_DIR / (name + ".session")
    try:
        shutil.copyfile(source, target)
        os.chmod(target, 0o600)
    except OSError as exc:
        raise TMediaError("Could not register the session: {0}".format(humanize_error(exc)))
    return Account(name, target, False)


def auto_register_sessions(limit: int = MAX_EXTRA_ACCOUNTS) -> int:
    """Bounded, read-only discovery of the other logged-in accounts on this PC."""
    ensure_accounts_dir()
    known = {session_signature(acc.path) for acc in registered_accounts()}
    added = 0
    for candidate in iter_session_files():
        if added >= limit:
            break
        try:
            if candidate.resolve().parent == ACCOUNTS_DIR.resolve():
                continue
            signature = session_signature(candidate)
            if not signature or signature in known or not is_telethon_session(candidate):
                continue
            register_session(candidate)
            known.add(signature)
            added += 1
        except (OSError, TMediaError):
            continue
    return added


def resolve_account_choice(args):
    """Ordered accounts: pinned account first, then the rest as fallbacks."""
    accounts = registered_accounts()
    explicit = getattr(args, "session", None) or os.environ.get("TMEDIA_SESSION")
    label = getattr(args, "account", None) or os.environ.get("TMEDIA_ACCOUNT")

    def with_first(first: Account):
        rest = [Account(a.label, a.path, False) for a in accounts
                if a.path.resolve() != first.path.resolve()]
        return [Account(first.label, first.path, True)] + rest

    if explicit:
        path = Path(explicit).expanduser()
        if not path.is_file() or not is_telethon_session(path):
            raise TMediaError("Not an authorised Telethon session: {0}".format(path))
        write_active_account(path.resolve().as_posix())
        return with_first(Account(sanitize_label(path.stem), path, True))

    wanted = label or read_active_account()
    if wanted:
        if "/" in wanted:
            path = Path(wanted)
            if path.is_file() and is_telethon_session(path):
                return with_first(Account(sanitize_label(path.stem), path, True))
        for acc in accounts:
            if acc.label == wanted:
                if label:
                    write_active_account(wanted)
                return with_first(acc)
        if label:
            raise TMediaError("No account named '{0}'. Run 'tmedia --list-accounts'.".format(label))
    return accounts


def list_accounts() -> int:
    """Offline report of every usable login; no Telegram connection needed."""
    auto_register_sessions()
    accounts = registered_accounts()
    active = read_active_account()
    head = Table.grid(padding=(0, 2))
    head.add_row(Text("Config dir", style="dim"), Text(str(CONFIG_DIR), style="white"))
    head.add_row(Text("Accounts", style="dim"), Text(str(len(accounts)), style="bold white"))
    head.add_row(Text("Pinned", style="dim"), Text(active or "(auto: first account)", style="white"))
    console.print(Panel(head, title="tmedia --list-accounts", border_style="cyan", title_align="left"))
    if not accounts:
        console.print(Text(
            "[!] No authorised session found. Run 'tmedia' once, or use --import-profile.",
            style="yellow"))
        return 0
    grid = Table.grid(padding=(0, 2))
    grid.add_row(Text("ACCOUNT", style="bold"), Text("SESSION", style="bold"), Text("ROLE", style="bold"))
    for acc in accounts:
        mark = "* " if acc.label == active else "  "
        grid.add_row(
            Text(mark + acc.label, style="bold white"),
            Text(str(acc.path), style="dim"),
            Text("primary" if acc.primary else "fallback", style="green" if acc.primary else "cyan"),
        )
    console.print(grid)
    console.print(Text(
        "> Pin one:  tmedia --account <name> -l <link>     |  --single-account disables fallback",
        style="cyan"), soft_wrap=True)
    return 0


def add_account(label: str, source: Optional[Path]) -> int:
    """Register a second/third login so private posts are always reachable."""
    if source is None:
        for candidate in iter_session_files():
            if (candidate.resolve() != SESSION_FILE.resolve()
                    and candidate.resolve().parent != ACCOUNTS_DIR.resolve()
                    and is_telethon_session(candidate)):
                source = candidate
                break
        if source is None:
            raise TMediaError("No other authorised session found. Pass --session /path/to/x.session.")
    acc = register_session(Path(source), label)
    write_active_account(acc.label)
    console.print(Text(
        "[+] Account '{0}' registered at {1} (no login code needed).".format(acc.label, acc.path),
        style="bold green"))
    console.print(Text("    Use it:  tmedia --account {0} -l <link>".format(acc.label), style="dim"))
    return 0


def load_credentials(args) -> Credentials:
    """Never ask for API credentials if they can be recovered automatically."""
    ensure_config_dir()

    # Explicit CLI overrides (also usable to fix a bad saved config).
    if getattr(args, "api_id", None) or getattr(args, "api_hash", None):
        discovered = discover_credentials()
        base = discovered[0] if discovered else None
        creds = valid_credentials(
            args.api_id or (base.api_id if base else None),
            args.api_hash or (base.api_hash if base else None),
            args.phone or (base.phone if base else ""),
        )
        if not creds:
            raise TMediaError("Invalid --api-id / --api-hash. api_hash must be 32 hex characters.")
        save_credentials(creds)
        console.print(Text("[+] API credentials saved to {0}".format(CONFIG_FILE), style="bold green"))
        return creds

    discovered = discover_credentials()
    if discovered:
        creds, origin = discovered
        console.print(
            Text("[*] API credentials recovered from {0} - no setup needed.".format(origin), style="dim green")
        )
        if origin != str(CONFIG_FILE):
            save_credentials(creds)  # persist so later runs are deterministic
        return creds

    # Last resort: compact `>` guide + the original one-time prompt.
    print_api_guide()
    while True:
        raw = Prompt.ask("[bold]API ID[/]").strip()
        if raw.isdigit() and int(raw) > 0:
            api_id = int(raw)
            break
        console.print(Text("[!] API ID must be a positive number.", style="bold red"))

    while True:
        api_hash = Prompt.ask("[bold]API HASH[/]").strip()
        if re.fullmatch(r"[0-9a-fA-F]{32}", api_hash):
            break
        console.print(Text("[!] API HASH must be 32 hexadecimal characters.", style="bold red"))

    while True:
        phone = Prompt.ask("[bold]Phone (international, e.g. +8801XXXXXXXXX)[/]").strip()
        normalised = re.sub(r"[\s()\-]", "", phone)
        if re.fullmatch(r"\+?\d{7,15}", normalised):
            break
        console.print(Text("[!] Please enter a valid phone number with country code.", style="bold red"))

    creds = Credentials(api_id, api_hash, normalised)
    save_credentials(creds)
    return creds


def export_profile(target: Optional[Path]) -> int:
    """Bundle config.json + session.session so another PC needs ZERO login."""
    ensure_config_dir()
    files = [path for path in (CONFIG_FILE, SESSION_FILE) if path.is_file()]
    if not files:
        console.print(Text("[!] Nothing to export yet - run tmedia once first.", style="bold red"))
        return 1
    destination = (
        target or Path.cwd() / ("tmedia-profile-" + datetime.now().strftime("%Y%m%d-%H%M%S") + ".tar.gz")
    ).expanduser().resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    tmp = destination.with_name(destination.name + ".tmp")
    try:
        with tarfile.open(str(tmp), "w:gz") as archive:
            for path in files:
                archive.add(str(path), arcname=path.name)
        os.chmod(tmp, 0o600)
        os.replace(tmp, destination)
    except Exception as exc:
        tmp.unlink(missing_ok=True)
        raise TMediaError("Could not write profile: {0}".format(humanize_error(exc)))

    message = Text()
    message.append("[+] Profile: ", style="bold green")
    message.append(str(destination), style="white")
    message.append("\n[!] Contains a LIVE Telegram auth key - keep private, NEVER commit it.", style="bold red")
    message.append("\n    On the new machine: ", style="dim")
    message.append("tmedia --import-profile " + str(destination), style="bold cyan")
    console.print(message)
    return 0


def import_profile(source: Path) -> int:
    """Restore a profile; member names are strictly whitelisted (no traversal)."""
    archive_path = source.expanduser()
    if not archive_path.is_file():
        raise TMediaError("Profile not found: {0}".format(archive_path))
    ensure_config_dir()
    imported = []
    try:
        with tarfile.open(str(archive_path), "r:gz") as archive:
            for member in archive.getmembers():
                name = os.path.basename(member.name)
                if name not in PROFILE_MEMBERS or not member.isfile() or member.size > 8 * 1024 * 1024:
                    continue
                handle = archive.extractfile(member)
                if handle is None:
                    continue
                data = handle.read()
                tmp = CONFIG_DIR / ("." + name + "." + uuid.uuid4().hex + ".tmp")
                fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(fd, "wb") as out:
                    out.write(data)
                os.replace(tmp, CONFIG_DIR / name)
                os.chmod(CONFIG_DIR / name, 0o600)
                imported.append(name)
    except Exception as exc:
        raise TMediaError("Profile is invalid or unreadable: {0}".format(humanize_error(exc)))
    if not imported:
        raise TMediaError("No usable config.json / session.session found in that profile.")
    console.print(
        Text("[+] Imported {0} - run 'tmedia' with no new login.".format(", ".join(imported)), style="bold green")
    )
    return 0


def doctor() -> int:
    """Offline self-diagnosis of credentials, session and Telegram Desktop."""
    discovered = discover_credentials()
    desktop = desktop_telegram_path()
    if not SESSION_FILE.exists():
        session_state = "not found (one login code will be needed)"
    elif is_telethon_session(SESSION_FILE):
        session_state = "valid (no login needed)"
    else:
        session_state = "present but invalid (will be auto-recovered if possible)"
    downloads = os.environ.get("TMEDIA_DOWNLOAD_DIR") or str(DEFAULT_DOWNLOAD_DIR)

    grid = Table.grid(padding=(0, 2))
    grid.add_row(Text("tmedia", style="dim"), Text("v" + __version__, style="bold white"))
    grid.add_row(Text("Config dir", style="dim"), Text(str(CONFIG_DIR), style="white"))
    grid.add_row(Text("API credentials", style="dim"), Text(discovered[1] if discovered else "NOT FOUND", style="green" if discovered else "bold red"))
    grid.add_row(Text("Session", style="dim"), Text(session_state, style="green" if "valid" in session_state else "yellow"))
    auto_register_sessions()
    found_accounts = registered_accounts()
    grid.add_row(
        Text("Accounts", style="dim"),
        Text("{0} usable; active: {1}".format(len(found_accounts), read_active_account() or "auto"),
             style="green" if found_accounts else "yellow"),
    )
    grid.add_row(Text("Telegram Desktop", style="dim"), Text(desktop or "not detected", style="white"))
    grid.add_row(Text("Downloads", style="dim"), Text(downloads, style="white"))
    grid.add_row(Text("Python", style="dim"), Text(platform.python_version() + " on " + platform.system(), style="white"))
    console.print(Panel(grid, title="tmedia --doctor", border_style="cyan", title_align="left"))
    if not discovered:
        print_api_guide()
    return 0


def do_logout() -> int:
    """Delete the local session + credentials (does not close remote sessions)."""
    files = [CONFIG_FILE] + sorted(CONFIG_DIR.glob("session.session*"))
    if not any(p.exists() for p in files):
        console.print(Text("[i] Nothing to remove - no local session found.", style="yellow"))
        return 0
    if not Confirm.ask("[bold]Delete the saved tmedia session and API credentials?[/]", default=False):
        console.print(Text("[i] Cancelled.", style="yellow"))
        return 0
    for path in files:
        try:
            path.unlink(missing_ok=True)
        except OSError as exc:
            console.print(Text("[!] Could not remove {0}: {1}".format(path, exc), style="bold red"))
    console.print(Text("[+] Local session removed. Run 'tmedia' to log in again.", style="bold green"))
    console.print(Text("    To revoke the device remotely, use Telegram > Settings > Privacy and Security > Active Sessions.", style="dim"))
    return 0


async def interactive_login(client: TelegramClient, phone: str,
                           session_path: Optional[Path] = None) -> None:
    """Clean Rich-based login (code + optional 2FA), no Telethon print() noise."""
    note = Text()
    note.append("Telegram will send a login code to your app / SMS.\n", style="white")
    note.append("Session will be saved at ", style="dim")
    note.append(str(session_path or SESSION_FILE), style="dim bold")
    console.print(Panel(note, title="Login", border_style="cyan"))

    # Credentials recovered from env / a shared config may legitimately have no
    # phone number. Ask for it ONLY when a login code is actually required.
    phone = re.sub(r"[\s()\-]", "", str(phone or ""))
    while not re.fullmatch(r"\+?\d{7,15}", phone):
        phone = re.sub(
            r"[\s()\-]", "", Prompt.ask("[bold]Phone number (only for this first login)[/]").strip()
        )
    await client.send_code_request(phone)
    for attempt in range(3):
        code = Prompt.ask("[bold]Login code[/]").strip().replace("-", "").replace(" ", "")
        if not code:
            continue
        try:
            await client.sign_in(phone=phone, code=code)
            console.print(Text("[+] Login successful.", style="bold green"))
            return
        except tg_errors.SessionPasswordNeededError:
            for _ in range(3):
                password = Prompt.ask("[bold]Two-step verification password[/]", password=True)
                try:
                    await client.sign_in(phone=phone, password=password)
                    console.print(Text("[+] Login successful.", style="bold green"))
                    return
                except tg_errors.PasswordHashInvalidError:
                    console.print(Text("[!] Wrong 2FA password, try again.", style="bold red"))
            raise TMediaError("Too many failed 2FA attempts.")
        except (tg_errors.PhoneCodeInvalidError, tg_errors.PhoneCodeEmptyError):
            console.print(Text("[!] Invalid code. {0} attempt(s) left.".format(2 - attempt), style="bold red"))
        except (tg_errors.PhoneCodeExpiredError, tg_errors.PhoneCodeHashEmptyError):
            raise TMediaError("The login code expired. Start tmedia again for a new one.")
    raise TMediaError("Too many failed login attempts. Start tmedia again.")


async def open_client(creds: Credentials, session_path: Optional[Path] = None,
                      allow_login: bool = True) -> TelegramClient:
    """Connect once. Only the primary account may prompt for a login code."""
    session_path = Path(session_path) if session_path else SESSION_FILE
    client = TelegramClient(
        str(session_path),
        creds.api_id,
        creds.api_hash,
        device_model="TMEDIA CLI",
        system_version="{0} {1}".format(platform.system(), platform.release()),
        app_version=__version__,
        lang_code="en",
        flood_sleep_threshold=60,  # Telethon auto-sleeps on short FloodWaits
        request_retries=4,
        connection_retries=4,
        timeout=15,
    )
    await client.connect()
    try:
        if not await client.is_user_authorized():
            if not allow_login:
                raise AccountAccessError(
                    "Saved session '{0}' is not authorised; skipping it.".format(session_path.name)
                )
            await interactive_login(client, creds.phone, session_path)
        harden_session_permissions()
    except BaseException:
        await client.disconnect()
        raise
    return client


class AccountPool:
    """
    ONE api_id/api_hash pair, several authorised accounts.

    Clients are opened lazily: the pinned/primary account is tried first and
    the others are connected only when Telegram says that account cannot see
    the post. Every session is reused as-is, so no extra login is requested.
    """

    def __init__(self, creds: Credentials, accounts, try_all: bool = True):
        self.creds = creds
        self.accounts = list(accounts)
        self.try_all = try_all
        self._clients = {}
        self._lock = None  # created inside the running loop (Python 3.8 safe)

    def __len__(self) -> int:
        return len(self.accounts)

    async def _open(self, acc: Account):
        if acc.label in self._clients:
            return self._clients[acc.label]
        if self._lock is None:
            self._lock = asyncio.Lock()
        async with self._lock:
            if acc.label in self._clients:
                return self._clients[acc.label]
            try:
                client = await open_client(self.creds, acc.path, allow_login=acc.primary)
            except Exception as exc:  # one unusable extra account must not abort
                self._clients[acc.label] = None
                console.print(Text(
                    "[i] Skipping unusable account '{0}': {1}".format(acc.label, humanize_error(exc)),
                    style="dim yellow"))
                return None
            self._clients[acc.label] = client
            return client

    async def primary(self):
        if not self.accounts:
            raise TMediaError("No authorised Telegram session found. Run 'tmedia' once, or import a profile.")
        client = await self._open(self.accounts[0])
        if client is None:
            raise TMediaError("The primary account could not connect. Try 'tmedia --list-accounts'.")
        return client

    async def candidates(self):
        targets = self.accounts if self.try_all else self.accounts[:1]
        for acc in targets:
            client = await self._open(acc)
            if client is not None:
                yield acc, client

    async def aclose(self) -> None:
        for client in self._clients.values():
            if client is not None:
                try:
                    await client.disconnect()
                except Exception:
                    pass
        harden_session_permissions()


# ---------------------------------------------------------------------------
# 5. Message resolution and media inspection
# ---------------------------------------------------------------------------


async def resolve_private_chat(client: TelegramClient, channel_id: int) -> object:
    """
    Turn a bare ``-100…`` id into an entity with an access_hash.

    A fresh session has no entity cache: try the cache/API, then a direct
    channels.GetChannels (works when the account is a member), then warm the
    cache from the dialog list. Failure is *per-account*: AccountPool simply
    moves on to the next logged-in account.
    """
    peer_id = int("-100" + str(channel_id))
    for candidate in (peer_id, types.PeerChannel(channel_id)):
        for resolver in (client.get_input_entity, client.get_entity):
            try:
                return await resolver(candidate)
            except Exception:
                pass

    try:
        result = await client(
            functions.channels.GetChannelsRequest(id=[types.PeerChannel(channel_id)])
        )
        for chat in getattr(result, "chats", None) or []:
            if getattr(chat, "id", None) == channel_id:
                return chat
    except Exception:
        pass

    try:
        async for dialog in client.iter_dialogs():
            entity = dialog.entity
            if getattr(entity, "id", None) == channel_id:
                return entity
    except Exception:
        pass

    raise AccountAccessError(
        "This account is not a member of private channel {0} (or the link is invalid).".format(channel_id)
    )


async def resolve_comment(client, link: TelegramLink, base_message):
    """Resolve a ``?comment=<id>`` discussion reply (best effort)."""
    if not link.comment_id:
        return base_message
    try:
        message = await client.get_messages(link.entity, ids=link.comment_id)
        if message is not None:
            return message
    except Exception:
        pass
    try:
        replies = await client.get_messages(link.entity, reply_to=link.message_id, limit=200)
        for message in replies or []:
            if getattr(message, "id", None) == link.comment_id:
                return message
    except Exception:
        pass
    try:
        result = await client(
            functions.messages.GetDiscussionMessageRequest(peer=link.entity, msg_id=link.message_id)
        )
        for message in getattr(result, "messages", None) or []:
            if getattr(message, "id", None) == link.comment_id:
                return message
    except Exception:
        pass
    return base_message


async def resolve_message(client: TelegramClient, link: TelegramLink):
    """Fetch one message, trying every way this account can legitimately see it."""
    message = None
    last_error = None

    try:
        message = await client.get_messages(link.entity, ids=link.message_id)
    except Exception as exc:
        last_error = exc

    if message is None and link.kind == "private":
        try:
            message = await client.get_messages(types.PeerChannel(link.channel_id), ids=link.message_id)
        except Exception as exc:
            if last_error is None:
                last_error = exc

    if message is None and link.kind == "private":
        try:
            entity = await resolve_private_chat(client, link.channel_id)
            message = await client.get_messages(entity, ids=link.message_id)
        except Exception as exc:
            if last_error is None:
                last_error = exc

    if message is None and link.kind == "public":
        try:
            entity = await client.get_entity(link.entity)
            message = await client.get_messages(entity, ids=link.message_id)
        except Exception as exc:
            if last_error is None:
                last_error = exc

    if message is None:
        if last_error is not None:
            raise last_error
        raise AccountAccessError(
            "Message #{0} is not visible to this account (deleted, or this account cannot see the post).".format(
                link.message_id
            )
        )
    return await resolve_comment(client, link, message)


@dataclass(frozen=True)
class MediaInfo:
    name: str
    size: Optional[int]
    mime_type: str
    date: Optional[datetime]
    document: Optional[object]  # telethon.tl.types.Document when applicable


def inspect_media(message, link: TelegramLink) -> MediaInfo:
    """Extract the exact original filename/extension/mime/size, or fail nicely."""
    media_file = getattr(message, "file", None)
    if media_file is None:
        raise TMediaError(
            "Message #{0} contains no downloadable media (text-only post, poll or service message).".format(
                link.message_id
            )
        )

    mime = getattr(media_file, "mime_type", None) or "application/octet-stream"
    size = getattr(media_file, "size", None)
    date = getattr(message, "date", None)
    try:
        file_ext = getattr(media_file, "ext", None)
    except Exception:  # exotic media can make mimetypes.guess_extension() grumpy
        file_ext = None

    document = getattr(message.media, "document", None) or getattr(message, "document", None)
    is_document = isinstance(document, types.Document)

    original = getattr(media_file, "name", None)
    if original:
        # DocumentAttributeFilename: the *exact* original name. Only supply an
        # extension when Telegram stored none (some bots do that); the base
        # name is never touched.
        name = str(original)
        if not os.path.splitext(name)[1] and file_ext:
            name += file_ext
    else:
        # Photos / unnamed media have no filename on Telegram's side. Use
        # Telethon-style a deterministic name; message id avoids collisions.
        is_photo = isinstance(getattr(message, "media", None), types.MessageMediaPhoto)
        ext = ".jpg" if is_photo else (file_ext or mimetypes.guess_extension(mime) or "")
        stamp = (date or datetime.now()).strftime("%Y-%m-%d_%H-%M-%S")
        name = "{0}_{1}_{2}{3}".format("photo" if is_photo else "media", stamp, message.id, ext)

    return MediaInfo(safe_filename(name), size, mime, date, document if is_document else None)


def media_panel(info: MediaInfo, destination: Path, link: TelegramLink) -> Panel:
    grid = Table.grid(padding=(0, 2))
    grid.add_row(Text("Filename", style="dim"), Text(info.name, style="bold white"))
    grid.add_row(Text("Size", style="dim"), Text(human_size(info.size), style="white"))
    grid.add_row(Text("MIME", style="dim"), Text(info.mime_type, style="white"))
    grid.add_row(Text("Message", style="dim"), Text("#{0}  ({1})".format(link.message_id, link.kind), style="white"))
    stamp = info.date.strftime("%Y-%m-%d %H:%M:%S UTC") if info.date else "unknown"
    grid.add_row(Text("Posted", style="dim"), Text(stamp, style="white"))
    grid.add_row(Text("Save to", style="dim"), Text(str(destination), style="cyan"))
    return Panel(grid, title="Media found", border_style="cyan", title_align="left")


# ---------------------------------------------------------------------------
# 6. Download engines, atomic writes and metadata
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Options:
    output: Path
    workers: int
    parallel: bool
    jobs: int
    overwrite: bool
    skip_existing: bool
    interactive: bool


async def parallel_download(client, document, tmp: Path, size: int, reporter, task) -> bool:
    """
    Fast path: ``workers`` concurrent strided ``iter_download`` streams, each
    writing its own chunks with ``os.pwrite`` into a pre-allocated temp file.

    Returns False (after cleaning up) on *any* problem so the caller can fall
    back to Telethon's ``download_media``. This covers CDN-redirected files,
    expired file references, older Telethon builds and odd media types.
    """
    if size <= 0 or not isinstance(document, types.Document):
        return False

    location = types.InputDocumentFileLocation(
        id=document.id,
        access_hash=document.access_hash,
        file_reference=document.file_reference,
        thumb_size="",
    )
    chunk = CHUNK_SIZE
    workers = max(1, min(max(1, reporter.workers), math.ceil(size / chunk)))
    stride = workers * chunk
    completed = 0
    fd = -1

    async def worker(index: int) -> None:
        nonlocal completed
        offset = index * chunk
        parts = math.ceil((size - offset) / stride)
        stream = client.iter_download(
            location,
            offset=offset,
            stride=stride,
            request_size=chunk,
            chunk_size=chunk,
            file_size=size,
            limit=parts,
            dc_id=getattr(document, "dc_id", None),
        )
        position = offset
        try:
            async for piece in stream:
                data = bytes(piece)
                if position + len(data) > size:
                    data = data[: size - position]
                if not data:
                    break
                os.pwrite(fd, data, position)
                position += stride
                completed += len(data)
                reporter.update(task, completed)
        finally:
            await stream.close()

    try:
        fd = os.open(str(tmp), os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
        os.ftruncate(fd, size)  # sparse pre-allocation; pwrite fills the holes
        tasks = [asyncio.create_task(worker(i)) for i in range(workers)]
        done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_EXCEPTION)
        for pending_task in pending:
            pending_task.cancel()
        if pending:
            await asyncio.gather(*pending, return_exceptions=True)
        for finished in done:
            error = finished.exception()
            if error is not None:
                raise error
        os.fsync(fd)
    except Exception:
        reporter.reset(task)
        return False
    finally:
        if fd >= 0:
            os.close(fd)

    # A sparse pre-allocated file always *reports* the right size, so also
    # verify that every worker actually wrote every byte it was assigned.
    # Any shortfall triggers the download_media() fallback.
    return completed == size and tmp.exists() and tmp.stat().st_size == size


def apply_metadata(path: Path, date: Optional[datetime]) -> None:
    """Restore Telegram's message date as mtime/atime; bytes were never touched."""
    try:
        if date is not None:
            stamp = date.timestamp()
            os.utime(path, (stamp, stamp))
        os.chmod(path, 0o644)
    except OSError:
        pass


def decide_existing(path: Path, opts: Options) -> str:
    """Never silently rename a file: overwrite, skip, or ask (interactive)."""
    if not path.exists():
        return "download"
    if opts.overwrite:
        return "overwrite"
    if opts.skip_existing or not opts.interactive:
        return "skip"
    return (
        "overwrite"
        if Confirm.ask("[bold yellow]'{0}' already exists. Overwrite?[/]".format(escape(path.name)), default=False)
        else "skip"
    )


async def download_once(client, link: TelegramLink, opts: Options, reporter) -> str:
    """Fetch + save one link. Returns 'downloaded', 'skipped' or raises."""
    message = await resolve_message(client, link)
    info = inspect_media(message, link)

    destination = (opts.output / info.name).resolve()
    if destination.parent != opts.output.resolve():
        raise TMediaError("Refusing to write outside the download directory (unsafe filename).")

    if decide_existing(destination, opts) == "skip":
        reporter.say("[!] Skipped: '{0}' already exists in {1}".format(info.name, opts.output), "yellow")
        return "skipped"

    if opts.interactive:
        reporter.info(media_panel(info, destination, link))

    # Short hidden temp name: immune to NAME_MAX limits and to Telethon's
    # "file (1).ext" auto-renaming. os.replace() makes the final write atomic.
    tmp = opts.output / (".tmedia-" + uuid.uuid4().hex + ".part")
    task = reporter.new_file(info.name, info.size)
    try:
        used_parallel = False
        if opts.parallel and info.size:
            used_parallel = await parallel_download(client, info.document, tmp, info.size, reporter, task)

        if not used_parallel:
            # Robust path: handles photos, stickers, web media, thumbnails,
            # CDN redirects and expired file references itself.
            reporter.reset(task)

            def on_progress(received, total):
                reporter.update(task, received)

            result = await client.download_media(message, file=str(tmp), progress_callback=on_progress)
            if isinstance(result, (str, Path)) and Path(result) != tmp:
                os.replace(str(result), tmp)

        if not tmp.exists() or tmp.stat().st_size == 0:
            raise TMediaError("Telegram returned an empty file for message #{0}.".format(link.message_id))
        if info.document is not None and info.size and tmp.stat().st_size != info.size:
            raise TMediaError(
                "Incomplete download ({0} of {1} bytes). Removed the partial file; please retry.".format(
                    human_size(tmp.stat().st_size), human_size(info.size)
                )
            )

        os.replace(tmp, destination)
        apply_metadata(destination, info.date)
        reporter.say("[+] Saved: {0}  ({1})".format(destination, human_size(destination.stat().st_size)), "bold green")
        return "downloaded"
    finally:
        reporter.finish_file(task)
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass


async def download_with_accounts(pool: AccountPool, link: TelegramLink,
                                 opts: Options, reporter) -> str:
    """
    Try the pinned account first; if Telegram says it cannot see the post,
    continue with the other logged-in accounts (all using the ONE API pair).
    """
    errors = []
    tried = 0
    previous = ""
    async for account, client in pool.candidates():
        tried += 1
        if tried > 1:
            reporter.say(
                "[i] '{0}' cannot see this post - trying account '{1}'…".format(previous, account.label),
                "yellow",
            )
        try:
            return await download_once(client, link, opts, reporter)
        except Exception as exc:
            if not is_access_error(exc):
                raise
            errors.append((account.label, humanize_error(exc)))
            previous = account.label
    if tried == 0:
        raise TMediaError("No usable Telegram account is logged in. Run 'tmedia' once, or import a profile.")
    if tried > 1:
        raise TMediaError(
            "None of the {0} logged-in accounts can access this post. Telegram only shows private "
            "channel posts to members ({1}). Join the channel with that account, then retry.".format(
                tried, errors[-1][1] if errors else "private content"
            )
        )
    raise TMediaError(errors[-1][1] if errors else "This post could not be accessed.")


async def process_link(source, link: TelegramLink, opts: Options, reporter) -> str:
    """Error boundary for one link. One bad URL can never abort a batch."""
    attempt = 0
    while True:
        attempt += 1
        try:
            if isinstance(source, AccountPool):
                return await download_with_accounts(source, link, opts, reporter)
            return await download_once(source, link, opts, reporter)
        except TMediaError as exc:
            reporter.say("[!] Error: {0}".format(exc), "bold red")
            return "failed"
        except Exception as exc:
            seconds = flood_seconds(exc)
            if seconds is not None and seconds <= 90 and attempt == 1:
                reporter.say("[!] Telegram rate limit: waiting {0}s before retrying…".format(seconds), "yellow")
                await asyncio.sleep(seconds + 1)
                continue
            reporter.say("[!] Error: {0}".format(humanize_error(exc)), "bold red")
            return "failed"


# ---------------------------------------------------------------------------
# 7. Terminal UI
# ---------------------------------------------------------------------------


class AdaptiveSizeColumn(ProgressColumn):
    """Overall row -> '3/10 links'; file rows -> '12.4/50.0 MB'."""

    def render(self, task) -> Text:
        if task.fields.get("overall"):
            return Text(
                "{0}/{1} links".format(int(task.completed), int(task.total or 0)),
                style="progress.download",
            )
        return DownloadColumn().render(task)


class AdaptiveSpeedColumn(ProgressColumn):
    """Hide transfer speed on the overall row (it counts links, not bytes)."""

    def render(self, task) -> Text:
        if task.fields.get("overall"):
            return Text("", style="progress.data.speed")
        return TransferSpeedColumn().render(task)


class AdaptiveEtaColumn(ProgressColumn):
    """Hide ETA on the overall row (per-link durations vary too much)."""

    def render(self, task) -> Text:
        if task.fields.get("overall"):
            return Text("", style="progress.remaining")
        return TimeRemainingColumn().render(task)


class Reporter:
    """One Rich Progress display shared by the per-file and overall bars."""

    def __init__(self, console_: Console, workers: int):
        self.console = console_
        self.workers = workers
        self.progress = Progress(
            SpinnerColumn(),
            TextColumn("[progress.description]{task.description}"),
            BarColumn(bar_width=30),
            TaskProgressColumn(),
            AdaptiveSizeColumn(),       # bytes for files, "n/m links" for overall
            AdaptiveSpeedColumn(),      # live speed (files only)
            AdaptiveEtaColumn(),        # ETA (files only)
            console=console_,
            refresh_per_second=8,
        )
        self._overall = None

    def __enter__(self) -> "Reporter":
        self.progress.start()
        return self

    def __exit__(self, *args) -> bool:
        self.progress.stop()
        return False

    def say(self, text: str, style: str = "white") -> None:
        self.progress.console.print(Text(text, style=style))

    def info(self, renderable) -> None:
        self.progress.console.print(renderable)

    def start_overall(self, total: int) -> None:
        self._overall = self.progress.add_task(
            "[bold blue]Overall", total=total, completed=0, overall=True
        )

    def advance_overall(self) -> None:
        if self._overall is not None:
            self.progress.advance(self._overall, 1)

    def new_file(self, name: str, size: Optional[int]):
        label = escape(shorten(name))
        return self.progress.add_task(
            "[cyan]{0}".format(label),
            total=size if size and size > 0 else None,
            completed=0,
        )

    def update(self, task, completed: int) -> None:
        self.progress.update(task, completed=completed)

    def reset(self, task) -> None:
        self.progress.update(task, completed=0)

    def finish_file(self, task) -> None:
        self.progress.remove_task(task)


def pick_txt_file() -> Optional[Path]:
    """Native zenity picker, with a guaranteed terminal fallback."""
    gui = bool(os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"))
    zenity = shutil.which("zenity")
    if zenity and gui:
        try:
            completed = subprocess.run(
                [
                    zenity,
                    "--file-selection",
                    "--title=Select URLs Text File",
                    "--file-filter=*.txt",
                ],
                capture_output=True,
                text=True,
                timeout=120,
                check=False,
            )
            if completed.returncode == 0 and completed.stdout.strip():
                return Path(completed.stdout.strip()).expanduser()
            console.print(Text("[i] File dialog cancelled - falling back to terminal input.", style="yellow"))
        except (OSError, subprocess.SubprocessError):
            console.print(Text("[i] GUI file picker unavailable - falling back to terminal input.", style="yellow"))
    else:
        console.print(Text("[i] No graphical session detected - using terminal path input.", style="yellow"))

    while True:
        raw = Prompt.ask("[bold]Path to the .txt file[/] (or 'q' to go back)").strip().strip("\"'")
        if not raw or raw.lower() in {"q", "quit", "exit"}:
            return None
        path = Path(raw).expanduser()
        if path.is_file():
            return path
        console.print(Text("[!] Not a readable file. Please try again.", style="bold red"))


def read_links(path: Path):
    """Parse a batch file: ignore blanks/comments, report bad lines, dedupe."""
    try:
        content = path.read_text(encoding="utf-8-sig", errors="replace")
    except OSError as exc:
        raise TMediaError("Cannot read '{0}': {1}".format(path, humanize_error(exc)))

    links = []
    problems = []
    seen = set()
    duplicates = 0
    for number, raw in enumerate(content.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        try:
            link = parse_link(line)
        except TMediaError as exc:
            problems.append((number, str(exc)))
            continue
        if link.raw in seen:
            duplicates += 1
            continue
        seen.add(link.raw)
        links.append(link)
    return links, problems, duplicates


# ---------------------------------------------------------------------------
# 8. Workflows
# ---------------------------------------------------------------------------


async def direct_mode(source, opts: Options, url: Optional[str] = None) -> None:
    if url is None:
        url = Prompt.ask("[bold cyan]Paste a Telegram message / media URL[/]").strip()
    try:
        link = parse_link(url)
    except TMediaError as exc:
        console.print(Text("[!] Error: {0}".format(exc), style="bold red"))
        return
    with Reporter(console, opts.workers) as reporter:
        await process_link(source, link, opts, reporter)


async def batch_mode(source, opts: Options, batch_file: Optional[Path] = None) -> None:
    if batch_file is None:
        batch_file = pick_txt_file()
        if batch_file is None:
            return
    batch_file = batch_file.expanduser()
    if not batch_file.is_file():
        console.print(Text("[!] Error: batch file not found: {0}".format(batch_file), style="bold red"))
        return

    try:
        links, problems, duplicates = read_links(batch_file)
    except TMediaError as exc:
        console.print(Text("[!] Error: {0}".format(exc), style="bold red"))
        return

    with Reporter(console, opts.workers) as reporter:
        for number, reason in problems:
            reporter.say("[!] Skipped: line {0} - {1}".format(number, reason), "yellow")
        reporter.say(
            "[i] Loaded {0} valid link(s) from {1}{2}".format(
                len(links), batch_file, " ({0} duplicate(s) ignored)".format(duplicates) if duplicates else ""
            ),
            "cyan",
        )
        if not links:
            return

        reporter.start_overall(len(links))
        totals = {"downloaded": 0, "skipped": 0, "failed": 0}

        if opts.jobs > 1:
            semaphore = asyncio.Semaphore(opts.jobs)

            async def run_one(link: TelegramLink) -> None:
                async with semaphore:
                    try:
                        totals[await process_link(source, link, opts, reporter)] += 1
                    finally:
                        reporter.advance_overall()

            await asyncio.gather(*(run_one(item) for item in links))
        else:
            # Sequential, exactly as specified: one clean bar per file.
            for item in links:
                totals[await process_link(source, item, opts, reporter)] += 1
                reporter.advance_overall()

        summary = Text()
        summary.append("  Downloaded: ", style="white")
        summary.append(str(totals["downloaded"]), style="bold green")
        summary.append("    Skipped: ", style="white")
        summary.append(str(totals["skipped"]), style="bold yellow")
        summary.append("    Failed: ", style="white")
        summary.append(str(totals["failed"]), style="bold red")
        reporter.info(Panel(summary, title="Batch summary", border_style="cyan", title_align="left"))


async def menu_loop(source, opts: Options) -> None:
    while True:
        menu = Text()
        menu.append("  [1] ", style="bold cyan")
        menu.append("Download Media via Direct Link\n", style="white")
        menu.append("  [2] ", style="bold cyan")
        menu.append("Download Media from a Text File (Batch Mode)\n", style="white")
        menu.append("  [0] ", style="dim cyan")
        menu.append("Exit\n", style="dim")
        console.print(Panel(menu, title="Main Menu", border_style="cyan", title_align="left"))

        choice = Prompt.ask("[bold]Select an option[/]", choices=["0", "1", "2"], default="1")
        if choice == "0":
            console.print(Text("[+] Bye!", style="bold cyan"))
            return
        try:
            if choice == "1":
                await direct_mode(source, opts)
            else:
                await batch_mode(source, opts)
        except KeyboardInterrupt:
            console.print(Text("[i] Returning to the main menu.", style="yellow"))


# ---------------------------------------------------------------------------
# 9. CLI entry point
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="tmedia",
        description="Download Telegram media from message links, keeping the exact original file.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  tmedia                                   interactive menu\n"
            "  tmedia -l https://t.me/c/1234567890/42  one private-channel post\n"
            "  tmedia -b ~/links.txt                   batch (no GUI picker)\n"
            "  tmedia -o ~/Videos -j 3                 3 concurrent batch links\n"
            "  tmedia --doctor                         offline credential/session check\n"
            "  tmedia --export-profile                 copy this login to another PC\n"
            "  tmedia --import-profile ~/p.tar.gz      zero-login setup on that PC\n"
            "  tmedia --api-id 12345 --api-hash HASH   set credentials non-interactively\n"
            "  tmedia --list-accounts                  every logged-in account\n"
            "  tmedia --add-account work --session S   register another account (zero login)\n"
            "  tmedia --account work -l URL            pin that account for a private post\n"
            "  tmedia --single-account -l URL          never try other accounts\n"
            "  tmedia --logout                         remove saved session\n"
        ),
    )
    parser.add_argument("-V", "--version", action="version", version="tmedia {0}".format(__version__))
    source = parser.add_mutually_exclusive_group()
    source.add_argument("-l", "--link", metavar="URL", help="download a single Telegram message link")
    source.add_argument("-b", "--batch", metavar="FILE", help="download all links from a .txt file")
    parser.add_argument("-o", "--output", metavar="DIR", default=None, help="destination directory (default: $TMEDIA_DOWNLOAD_DIR or ~/Downloads)")
    parser.add_argument("-j", "--jobs", type=int, default=1, metavar="N", help="concurrent links in batch mode (default: 1 = sequential)")
    parser.add_argument("-w", "--workers", type=int, default=DEFAULT_WORKERS, metavar="N", help="parallel connections per large file (default: 4)")
    parser.add_argument("--no-parallel", action="store_true", help="always use Telethon's single-stream downloader")
    collision = parser.add_mutually_exclusive_group()
    collision.add_argument("--overwrite", action="store_true", help="always overwrite an existing file")
    collision.add_argument("--skip-existing", action="store_true", help="always keep an existing file")

    # --- zero-login / credential recovery ---------------------------------
    recovery = parser.add_argument_group("credential & session recovery")
    recovery.add_argument("--api-id", metavar="ID", help="set/save API ID (overrides auto-discovery)")
    recovery.add_argument("--api-hash", metavar="HASH", help="set/save API HASH (32 hex chars)")
    recovery.add_argument("--phone", metavar="NUMBER", help="set/save phone (only needed for a new login code)")
    recovery.add_argument("--export-profile", nargs="?", const="@auto", metavar="FILE", help="bundle config + session for another PC (default: ./tmedia-profile-<date>.tar.gz)")
    recovery.add_argument("--import-profile", metavar="FILE", help="restore a profile: ZERO new login")
    recovery.add_argument("--doctor", action="store_true", help="offline check of credentials, session and Telegram Desktop")

    accounts = parser.add_argument_group("accounts (v1.2: one API pair, every login)")
    accounts.add_argument("--account", metavar="NAME", help="pin a registered account (see --list-accounts)")
    accounts.add_argument("--session", metavar="PATH", help="use/pin a specific Telethon .session for this run")
    accounts.add_argument("--add-account", metavar="NAME", help="register an authorised session as a named account")
    accounts.add_argument("--list-accounts", action="store_true", help="offline list of usable accounts")
    accounts.add_argument("--single-account", action="store_true", help="do not fall back to other accounts")

    parser.add_argument("--logout", action="store_true", help="delete the local session and credentials")
    parser.add_argument("--no-banner", action="store_true", help="suppress the ASCII banner")
    return parser


def build_options(args) -> Options:
    # -o > TMEDIA_DOWNLOAD_DIR > ~/Downloads  (Termux / Windows friendly)
    chosen = args.output or os.environ.get("TMEDIA_DOWNLOAD_DIR") or str(DEFAULT_DOWNLOAD_DIR)
    output = Path(chosen).expanduser()
    try:
        output.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise TMediaError("Cannot create download folder '{0}': {1}".format(output, humanize_error(exc)))
    if not os.access(output, os.W_OK):
        raise TMediaError("Download folder is not writable: {0}".format(output))
    jobs = max(1, min(args.jobs, 16))
    workers = max(1, min(args.workers, 16))
    return Options(
        output=output.resolve(),
        workers=workers,
        parallel=not args.no_parallel,
        jobs=jobs,
        overwrite=bool(args.overwrite),
        skip_existing=bool(args.skip_existing),
        interactive=not (args.link or args.batch),
    )


async def run(args) -> int:
    opts = build_options(args)
    if not args.no_banner:
        print_banner()

    creds = load_credentials(args)
    session_note = auto_import_session()
    if session_note:
        console.print(Text("[*] Session: {0}".format(session_note), style="dim green"))

    added = auto_register_sessions()
    if added:
        console.print(Text(
            "[*] Registered {0} other logged-in account(s) - no login code needed.".format(added),
            style="dim green"))

    accounts = resolve_account_choice(args)
    single = bool(args.single_account or os.environ.get("TMEDIA_SINGLE_ACCOUNT"))
    if single:
        accounts = accounts[:1]
    if not accounts:
        raise TMediaError("No authorised Telegram session found. Run 'tmedia' once, or import a profile.")
    accounts[0] = Account(accounts[0].label, accounts[0].path, True)

    try_all = len(accounts) > 1
    pool = AccountPool(creds, accounts, try_all=try_all)
    console.print(Text("[*] Connecting to Telegram…", style="dim"))
    client = await pool.primary()
    try:
        me = await client.get_me()
        who = "@" + me.username if getattr(me, "username", None) else (getattr(me, "first_name", None) or str(me.id))
        status = Text()
        status.append("  ●  Connected as ", style="green")
        status.append(who, style="bold white")
        status.append("  (account: ", style="dim")
        status.append(accounts[0].label, style="bold white")
        status.append(")\n  Session:   ", style="dim")
        status.append(str(accounts[0].path), style="dim")
        status.append("\n  Accounts:  ", style="dim")
        status.append(
            "{0} available{1}".format(
                len(accounts), " - private posts auto-fallback" if try_all else " (single-account mode)"
            ),
            style="dim",
        )
        status.append("\n  Downloads: ", style="dim")
        status.append(str(opts.output), style="dim")
        console.print(Panel(status, title="Session", border_style="green", title_align="left"))

        if args.link:
            await direct_mode(pool, opts, url=args.link)
        elif args.batch:
            await batch_mode(pool, opts, batch_file=Path(args.batch))
        else:
            await menu_loop(pool, opts)
    finally:
        await pool.aclose()
    return 0


def main() -> int:
    try:
        args = build_parser().parse_args()
        # Offline maintenance commands never touch the network or the session.
        if args.import_profile:
            return import_profile(Path(args.import_profile))
        if args.export_profile is not None:
            return export_profile(None if args.export_profile == "@auto" else Path(args.export_profile))
        if args.list_accounts:
            return list_accounts()
        if args.add_account:
            return add_account(args.add_account, Path(args.session) if args.session else None)
        if args.doctor:
            return doctor()
        if args.logout:
            return do_logout()
        return asyncio.run(run(args))
    except KeyboardInterrupt:
        console.print(Text("\n[i] Cancelled by user. Bye!", style="yellow"))
        return 130
    except TMediaError as exc:
        console.print(Text("[!] Error: {0}".format(exc), style="bold red"))
        return 1
    except Exception as exc:
        # Deliberately never print a traceback, even for unexpected failures.
        console.print(Text("[!] Error: {0}".format(humanize_error(exc)), style="bold red"))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
__TMEDIA_PY_SOURCE_9F3C21__
chmod 0644 "$TM_PY"

if ! env PYTHONDONTWRITEBYTECODE=1 "$TM_VENV/bin/python" -c \
        'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$TM_PY"; then
    fail "Embedded source failed syntax validation."
fi
"$TM_VENV/bin/python" "$TM_PY" --version >/dev/null 2>&1 \
    || fail "Upgraded source did not start correctly."

# --- 3. make sure the global launcher still exists --------------------------
if [[ ! -f "$TM_BIN" ]]; then
    step "Recreating global 'tmedia' command..."
    mkdir -p -- "$(dirname -- "$TM_BIN")"
    cat > "$TM_BIN" <<'__TMEDIA_WRAPPER_9F3C21__'
#!/usr/bin/env bash
set -euo pipefail
VENV="/opt/tmedia/venv"
APP="/opt/tmedia/tmedia.py"
if [[ ! -x "$VENV/bin/python" || ! -f "$APP" ]]; then
    printf '[!] Error: tmedia installation is incomplete. Re-run install_tmedia.sh.\n' >&2
    exit 1
fi
# shellcheck disable=SC1091
source "$VENV/bin/activate" 2>/dev/null || true
exec "$VENV/bin/python" "$APP" "$@"
__TMEDIA_WRAPPER_9F3C21__
    chmod 0755 "$TM_BIN"
fi

# --- 4. never touch the user's profile --------------------------------------
CONFIG_DIR="$REAL_HOME/.config/tmedia"
if [[ -d "$CONFIG_DIR" ]]; then
    printf '    preserved: %s (config.json + session.session untouched)\n' "$CONFIG_DIR"
fi

printf '\n[+] tmedia upgraded to v%s successfully.\n' "$TM_VERSION"
printf '[+] NO new login is required: your API credentials and session were kept.\n'
printf '[+] Verify with:  tmedia --doctor\n'
printf '[+] Then just:    tmedia\n'
printf '\n    Moving this login to another PC (zero login there too):\n'
printf '      tmedia --export-profile\n'
printf '      tmedia --import-profile <file>   # on the other PC\n'
