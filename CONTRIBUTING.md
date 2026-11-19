# Contributing to tmedia

Thanks for wanting to improve tmedia. Issues, forks and reviews are very
welcome — this is a small, readable project and PRs are reviewed quickly.

## Ground rules

1. **Never commit secrets.** No `*.session`, `config.json`, `.env` or
   `tmedia-profile-*.tar.gz`. `.gitignore` blocks them and
   `scripts/publish_github.sh` refuses to stage them. A session file contains a
   live Telegram auth key.
2. **Keep the single-source invariant.** `src/tmedia.py` is canonical.
   `install_tmedia.sh` and `upgrade_tmedia.sh` embed it verbatim between the
   `__TMEDIA_PY_SOURCE_9F3C21__` heredoc markers. After any edit, regenerate
   both (see below) — CI will fail otherwise.
3. **No raw tracebacks.** All failures go through `TMediaError` /
   `humanize_error()` and reach the user as one calm line.
4. **No credential borrowing.** Do not add Telegram Desktop's official
   `api_id`/`api_hash` or attempt to decrypt `tdata`. That violates Telegram's
   ToS. Recovery must use only credentials and sessions the user owns.
5. Respect Telegram's ToS and third-party copyright; only download content the
   account is authorised to access.

## Local setup

```bash
git clone https://github.com/<you>/tmedia
cd tmedia
python3 -m venv .venv && . .venv/bin/activate
pip install "Telethon>=1.36,<2" "rich>=13,<15" cryptg
python3 src/tmedia.py --doctor
python3 src/tmedia.py --help
```

## Regenerate the embedded shell scripts

```bash
python3 - <<'PY'
from pathlib import Path
import re
src = Path('src/tmedia.py').read_text(encoding='utf-8')
pattern = re.compile(
    r"(cat > \"\$TM_PY\" <<'__TMEDIA_PY_SOURCE_9F3C21__'\n)(.*?)"
    r"(\n__TMEDIA_PY_SOURCE_9F3C21__\n)", re.S)
for name in ('install_tmedia.sh', 'upgrade_tmedia.sh'):
    path = Path(name); text = path.read_text(encoding='utf-8')
    assert len(pattern.findall(text)) == 1
    path.write_text(pattern.sub(lambda m: m.group(1) + src.rstrip('\n') + m.group(3), text),
                    encoding='utf-8')
print('embedded sources synced')
PY
bash -n install_tmedia.sh && bash -n upgrade_tmedia.sh
bash -n assets/setup_termux.sh && bash -n scripts/publish_github.sh
python3 -c "import ast; ast.parse(open('src/tmedia.py', encoding='utf-8').read())"
```

## Testing without a Telegram account

The download engine can be exercised with a stub MTProto client: fake
`iter_download()` streams, fake `download_media()`, and a fake `get_messages()`
returning a message with a `file` object. CI runs syntax, embedded-source sync
and CLI smoke checks; please add a unit test for any new behaviour.

## Commit / PR checklist

- [ ] `bash -n` on every shell script
- [ ] `python3 src/tmedia.py --version` and `--help` succeed
- [ ] both installers embed the current `src/tmedia.py`
- [ ] `CHANGELOG.md` updated
- [ ] no secrets in the diff
- [ ] new error paths produce a friendly message, not a traceback
- [ ] Windows / Termux behaviour considered (no `zenity`, no `os.pwrite`)

## Ideas we'd love help with

Album (`grouped_id`) support, `?comment=` discussion replies, resume of
interrupted downloads, translations of the `>` guide, packaging as a `.deb`,
and a non-interactive JSON output mode for scripts.
