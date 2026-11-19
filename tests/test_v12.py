#!/usr/bin/env python3
"""
Offline test suite for tmedia. No Telegram account or network is needed:
Telethon clients are replaced with tiny fakes, and the SQLite sessions are
created locally. Run with:  python3 tests/test_v12.py
"""
from __future__ import annotations

import asyncio
import importlib.util
import json
import os
import sqlite3
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src" / "tmedia.py"
WORK = Path(tempfile.mkdtemp(prefix="tmedia-test-"))
CONFIG = WORK / "config"
DOWNLOADS = WORK / "downloads"
CONFIG.mkdir(parents=True)
DOWNLOADS.mkdir(parents=True)
os.environ["TMEDIA_CONFIG_DIR"] = str(CONFIG)
os.environ["TMEDIA_DOWNLOAD_DIR"] = str(DOWNLOADS)

spec = importlib.util.spec_from_file_location("tmedia", str(SOURCE))
m = importlib.util.module_from_spec(spec)
sys.modules["tmedia"] = m
spec.loader.exec_module(m)


def ok(condition, label):
    if not condition:
        raise AssertionError(label)
    print("  ok:", label)


def make_session(path: Path, key: bytes = b"k" * 256) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE IF NOT EXISTS sessions (dc_id INTEGER PRIMARY KEY, server_address TEXT, port INTEGER, auth_key BLOB)")
    con.execute("INSERT OR REPLACE INTO sessions VALUES (2, '149.154.167.51', 443, ?)", (key,))
    con.commit()
    con.close()


def run(coro):
    return asyncio.run(coro)


class Reporter:
    def __init__(self):
        self.lines = []

    def say(self, text, style=None):
        self.lines.append(text)

    def info(self, panel):
        pass

    def new_file(self, name, size):
        return object()

    def reset(self, task):
        pass

    def update(self, task, value):
        pass

    def finish_file(self, task):
        pass


def opts(**overrides):
    base = dict(output=DOWNLOADS, workers=1, parallel=False, jobs=1,
                overwrite=True, skip_existing=False, interactive=False)
    base.update(overrides)
    return m.Options(**base)


# ---------------------------------------------------------------------------
print("A) version, links, error classification")
ok(m.__version__ == "1.2.0", "version is 1.2.0")
cases = [
    ("https://t.me/durov/123", "durov", 123, None, None),
    ("https://t.me/c/1234567890/42", -1001234567890, 42, None, None),
    ("https://t.me/c/1234567890/12/987", -1001234567890, 987, 12, None),
    ("https://t.me/durov/123?comment=45", "durov", 123, None, 45),
]
for raw, entity, msg, topic, comment in cases:
    link = m.parse_link(raw)
    ok(link.entity == entity and link.message_id == msg and link.topic_id == topic
       and link.comment_id == comment, "parse " + raw)
ok(m.is_access_error(m.AccountAccessError("not visible")), "AccountAccessError is retryable")
ok(m.is_access_error(SimpleNamespace()) is False, "generic object is NOT retryable")


class FakeChannelPrivate(Exception):
    pass


FakeChannelPrivate.__name__ = "ChannelPrivateError"
ok(m.is_access_error(FakeChannelPrivate()), "ChannelPrivateError is retryable")
ok(m.is_access_error(ValueError("Could not find the input entity")), "unresolved entity is retryable")
ok(m.is_access_error(m.TMediaError("Incomplete download")) is False, "download error is NOT retryable")

# ---------------------------------------------------------------------------
print("B) multi-account registry (one API pair, zero new login)")
main_session = CONFIG / "session.session"
other = WORK / "elsewhere" / "work.session"
make_session(main_session, b"a" * 256)
make_session(other, b"b" * 256)
ok(m.is_telethon_session(main_session) and m.is_telethon_session(other), "SQLite sessions validate")
added = m.auto_register_sessions()
ok(added >= 1, "other account auto-registered (found {0})".format(added))
accounts = m.registered_accounts()
ok(len(accounts) >= 2 and accounts[0].primary, "primary + fallback accounts present")
ok(len({a.label for a in accounts}) == len(accounts), "labels are unique")
ok(len({m.session_signature(a.path) for a in accounts}) == len(accounts), "no duplicate login registered")
ok(0o600 == (m.ACCOUNTS_DIR.stat().st_mode & 0o700) or (m.ACCOUNTS_DIR.stat().st_mode & 0o777) == 0o700,
   "accounts dir is 0700")
for p in m.ACCOUNTS_DIR.glob("*.session"):
    ok((p.stat().st_mode & 0o777) == 0o600, "registered session is 0600: " + p.name)

m.write_active_account("work")
ok(m.read_active_account() == "work", "active account pinned")
args = SimpleNamespace(account=None, session=None)
chosen = m.resolve_account_choice(args)
ok(chosen[0].label == "work" and chosen[0].primary, "pinned account becomes primary")
args2 = SimpleNamespace(account="main", session=None)
ok(m.resolve_account_choice(args2)[0].label == "main", "--account overrides the pin")
m.write_active_account("main")

# ---------------------------------------------------------------------------
print("C) private-chat resolution recovers a fresh session + comment links")


class FakeChannel:
    def __init__(self, cid):
        self.id = cid


class FakeClient:
    def __init__(self, name, visible=None, comment=None, needs_recovery=False):
        self.name = name
        self.visible = visible
        self.comment = comment
        self.needs_recovery = needs_recovery
        self.calls = []

    async def get_messages(self, entity, ids=None, **kwargs):
        self.calls.append(("get_messages", entity, ids, kwargs))
        if self.needs_recovery and not isinstance(entity, FakeChannel):
            return None  # fresh session: bare -100 id / PeerChannel resolve to nothing
        if self.visible is False:
            return None
        if ids is not None and self.comment and ids == self.comment.id:
            return self.comment
        if kwargs.get("reply_to") and self.comment:
            return [self.comment]
        return SimpleNamespace(id=ids, file=None, media=None, date=None)

    async def get_entity(self, entity):
        if self.needs_recovery:
            raise ValueError("no entity cache on a fresh session")
        return FakeChannel(1234567890)

    async def get_input_entity(self, entity):
        raise ValueError("no entity cache")

    async def __call__(self, request):
        self.calls.append(("raw", type(request).__name__))
        return SimpleNamespace(chats=[FakeChannel(1234567890)], messages=[])

    def iter_dialogs(self):
        async def gen():
            if False:
                yield None
        return gen()


link = m.parse_link("https://t.me/c/1234567890/42")
client = FakeClient("fresh", needs_recovery=True)
msg = run(m.resolve_message(client, link))
ok(msg.id == 42, "private post resolved despite empty entity cache")
ok(any(c[0] == "raw" and "GetChannels" in c[1] for c in client.calls),
   "channels.GetChannels used as a recovery path")

clink = m.parse_link("https://t.me/durov/123?comment=45")
replies = SimpleNamespace(id=45, file=None, media=None, date=None)
cclient = FakeClient("comments", comment=replies)
ok(run(m.resolve_message(cclient, clink)).id == 45, "?comment= discussion reply resolved")

# ---------------------------------------------------------------------------
print("D) fallback: first account cannot see the private post, second can")
DATA = b"\x00tmedia-exact-bytes\xff" * 97
STAMP = datetime(2024, 5, 6, 7, 8, 9, tzinfo=timezone.utc)


class DownloadClient:
    """download_media writes the exact bytes Telethon would stream."""
    def __init__(self, name, can_see=True):
        self.name = name
        self.can_see = can_see
        self.disconnected = False

    async def download_media(self, message, file=None, progress_callback=None):
        if not self.can_see:
            raise m.AccountAccessError("This account is not a member of the private channel")
        Path(file).write_bytes(DATA)
        if progress_callback:
            progress_callback(len(DATA), len(DATA))
        return file

    async def disconnect(self):
        self.disconnected = True

    async def get_me(self):
        return SimpleNamespace(id=1, username=self.name, first_name=None)


async def fake_resolve(client, link):
    if not client.can_see:
        raise m.AccountAccessError("This account is not a member of the private channel")
    return SimpleNamespace(id=link.message_id, media=None, date=STAMP)


def fake_inspect(message, link):
    return m.MediaInfo("clip_42.mp4", len(DATA), "video/mp4", STAMP, None)


original_resolve, original_inspect = m.resolve_message, m.inspect_media
m.resolve_message, m.inspect_media = fake_resolve, fake_inspect
try:
    bad, good = DownloadClient("first", False), DownloadClient("second", True)
    pool = m.AccountPool(
        m.Credentials(12345, "a" * 32, ""),
        [m.Account("first", main_session, True), m.Account("second", other, False)],
        try_all=True,
    )
    opened = []

    async def fake_open(creds, session_path=None, allow_login=True):
        client = bad if session_path == main_session else good
        opened.append(str(session_path))
        return client

    m.open_client = fake_open
    reporter = Reporter()
    result = run(m.process_link(pool, link, opts(), reporter))
    ok(result == "downloaded", "fallback account downloaded the private post")
    ok(any("trying account 'second'" in line for line in reporter.lines),
       "user is told which account was tried next")
    ok(len(opened) == 2, "only the two accounts were connected")
    saved = DOWNLOADS / "clip_42.mp4"
    ok(saved.read_bytes() == DATA, "exact original bytes preserved")
    ok(int(saved.stat().st_mtime) == int(STAMP.timestamp()), "message-date mtime preserved")
    ok(not list(DOWNLOADS.glob(".tmedia-*.part")), "no temp .part leftovers")

    # single-account mode must NOT try the working account
    (DOWNLOADS / "clip_42.mp4").unlink()
    single = m.AccountPool(m.Credentials(12345, "a" * 32, ""),
                           [m.Account("first", main_session, True)], try_all=False)
    reporter2 = Reporter()
    ok(run(m.process_link(single, link, opts(), reporter2)) == "failed",
       "--single-account reports failure without switching accounts")
    ok(any("not a member" in line for line in reporter2.lines), "clean membership error shown")

    # a plain (non-pool) client still works: backwards compatibility
    reporter3 = Reporter()
    ok(run(m.process_link(good, link, opts(), reporter3)) == "downloaded",
       "legacy single-client process_link still works")
finally:
    m.resolve_message, m.inspect_media = original_resolve, original_inspect

# ---------------------------------------------------------------------------
print("E) offline CLI dispatch + no secrets")
m.doctor()
m.list_accounts()
third_session = WORK / "third" / "third.session"
make_session(third_session, b"c" * 256)
ok(m.add_account("third", third_session) == 0, "--add-account registers a login offline")
ok(m.read_active_account() == "third", "new account pinned")
ok(m.register_session(other, "alias").label == "work", "duplicate login is not registered twice")
ok(not list(WORK.rglob("*.tar.gz")), "no profile archives created by tests")

parser = m.build_parser()
a = parser.parse_args(["--account", "third", "--single-account", "-l", "https://t.me/c/1/2"])
ok(a.account == "third" and a.single_account and a.link, "CLI flags parsed")

print("\n*** V1.2 TEST SUITE PASSED ***")
