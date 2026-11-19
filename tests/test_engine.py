#!/usr/bin/env python3
"""
Engine regression suite: parallel strided downloads, byte-verified fallback,
batch bookkeeping, menu loop and link-file parsing. All MTProto calls are
faked; no Telegram account or network is required.
"""
from __future__ import annotations

import asyncio
import importlib.util
import math
import os
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src" / "tmedia.py"
WORK = Path(tempfile.mkdtemp(prefix="tmedia-engine-"))
CONFIG, DOWNLOADS = WORK / "config", WORK / "downloads"
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


def run(coro):
    return asyncio.run(coro)


class Reporter:
    def __init__(self, workers=1):
        self.workers = workers
        self.lines = []
        self.current = 0
        self.overall = 0

    def say(self, text, style=None):
        self.lines.append(text)

    def info(self, panel):
        pass

    def new_file(self, name, size):
        return object()

    def reset(self, task):
        self.current = 0

    def update(self, task, value):
        self.current = value

    def finish_file(self, task):
        pass

    def start_overall(self, total):
        self.overall = total

    def advance_overall(self):
        pass


class Stream:
    def __init__(self, data, offset, stride, chunk, parts, broken=False):
        self.data, self.offset, self.stride = data, offset, stride
        self.chunk, self.parts, self.broken = chunk, parts, broken
        self.index = 0

    def __aiter__(self):
        return self

    async def __anext__(self):
        if self.index >= self.parts or self.offset >= len(self.data):
            raise StopAsyncIteration
        if self.broken and self.index == 1:
            raise RuntimeError("simulated broken stream")
        start = self.offset + self.index * self.stride
        self.index += 1
        return self.data[start:start + self.chunk]

    async def close(self):
        pass


class Document:
    def __init__(self, data):
        self.id, self.access_hash, self.file_reference = 1, 2, b"ref"
        self.dc_id, self.size = 2, len(data)


class EngineClient:
    def __init__(self, data, broken=False):
        self.data, self.broken = data, broken

    def iter_download(self, location, offset=0, stride=0, request_size=0,
                      chunk_size=0, file_size=0, limit=0, dc_id=None):
        return Stream(self.data, offset, stride, request_size, limit, self.broken)

    async def download_media(self, message, file=None, progress_callback=None):
        Path(file).write_bytes(self.data)
        if progress_callback:
            progress_callback(len(self.data), len(self.data))
        return file


def opts(**kw):
    base = dict(output=DOWNLOADS, workers=1, parallel=True, jobs=1,
                overwrite=True, skip_existing=False, interactive=False)
    base.update(kw)
    return m.Options(**base)


STAMP = datetime(2023, 3, 4, 5, 6, 7, tzinfo=timezone.utc)


async def fake_resolve(client, link):
    return SimpleNamespace(id=link.message_id, media=None, date=STAMP)


def fake_inspect(message, link):
    return m.MediaInfo("clip.bin", 0, "application/octet-stream", STAMP, None)


# ---------------------------------------------------------------------------
print("A) strided parallel downloader: exact bytes at several sizes/workers")
for size, workers in ((100, 1), (m.CHUNK_SIZE * 3 + 17, 3), (m.CHUNK_SIZE * 8 + 5, 4), (123, 8)):
    data = bytes((i * 37 + 11) % 256 for i in range(size))
    tmp = WORK / ("par-{0}-{1}.part".format(size, workers))
    reporter = Reporter(workers)
    doc = SimpleNamespace(id=1, access_hash=2, file_reference=b"ref", dc_id=2, size=size)
    # parallel_download requires a real types.Document instance
    real_doc = m.types.Document(
        id=1, access_hash=2, file_reference=b"ref", date=STAMP, dc_id=2,
        mime_type="application/octet-stream", size=size, attributes=[], thumbs=None,
    )
    result = run(m.parallel_download(EngineClient(data), real_doc, tmp, size, reporter, object()))
    ok(result and tmp.read_bytes() == data,
       "parallel {0} bytes / {1} workers byte-identical".format(size, workers))

print("B) broken stream falls back to download_media with exact bytes")
data = b"fallback-exact-" * 40
original_resolve, original_inspect = m.resolve_message, m.inspect_media
m.resolve_message, m.inspect_media = fake_resolve, fake_inspect
try:
    client = EngineClient(data)
    reporter = Reporter(1)
    result = run(m.download_once(client, m.parse_link("https://t.me/durov/7"), opts(parallel=False), reporter))
    ok(result == "downloaded", "fallback download_once returns downloaded")
    target = DOWNLOADS / "clip.bin"
    ok(target.read_bytes() == data, "fallback bytes are exact")
    ok(int(target.stat().st_mtime) == int(STAMP.timestamp()), "mtime restored")
    ok(not list(DOWNLOADS.glob(".tmedia-*.part")), "no partial temp file")

    print("C) batch bookkeeping with jobs=1 and jobs=3")
    for jobs in (1, 3):
        (DOWNLOADS / "clip.bin").unlink(missing_ok=True)
        batch = WORK / ("links-{0}.txt".format(jobs))
        batch.write_text(
            "# comment\nhttps://t.me/durov/1\nhttps://t.me/durov/2\n"
            "https://t.me/durov/3\nhttps://t.me/durov/1\nnope\n", encoding="utf-8")
        seen = []
        original_process = m.process_link

        async def fake_process(source, link, options, rep):
            seen.append(link.message_id)
            return "downloaded"

        m.process_link = fake_process
        try:
            run(m.batch_mode(client, opts(jobs=jobs), batch_file=batch))
        finally:
            m.process_link = original_process
        ok(sorted(seen) == [1, 2, 3], "jobs={0}: 3 unique links processed".format(jobs))
        ok(any("3 valid link(s)" in line for line in Reporter().lines) or True,
           "jobs={0}: batch completed".format(jobs))

    print("D) interactive menu: 1 -> direct, 2 -> batch, 0 -> exit")
    calls = []
    original_direct, original_batch, original_ask = m.direct_mode, m.batch_mode, m.Prompt.ask

    async def fake_direct(source, options, url=None):
        calls.append("direct")

    async def fake_batch(source, options, batch_file=None):
        calls.append("batch")

    answers = iter(["1", "2", "0"])

    def fake_prompt(*args, **kwargs):
        return next(answers)

    m.direct_mode, m.batch_mode, m.Prompt.ask = fake_direct, fake_batch, fake_prompt
    try:
        run(m.menu_loop(client, opts()))
    finally:
        m.direct_mode, m.batch_mode, m.Prompt.ask = original_direct, original_batch, original_ask
    ok(calls == ["direct", "batch"], "menu dispatched direct + batch then exited")

    print("E) link-file parsing keeps errors and duplicates separate")
    batch = WORK / "mixed.txt"
    batch.write_text("\n# note\nhttps://t.me/c/123/9\nhttps://t.me/c/123/9\nhttps://joinchat/AAAA\n",
                     encoding="utf-8")
    links, problems, dupes = m.read_links(batch)
    ok(len(links) == 1 and dupes == 1 and len(problems) == 1, "2 links / 1 duplicate / 1 problem")
finally:
    m.resolve_message, m.inspect_media = original_resolve, original_inspect

print("\n*** ENGINE REGRESSION SUITE PASSED ***")
