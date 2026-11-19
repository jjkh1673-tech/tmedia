#!/usr/bin/env bash
# =============================================================================
#  publish_github.sh -- create a PUBLIC GitHub repo and push this project
#
#  Arena has no GitHub connector in this session, so run this from your own
#  machine. Requires: git + GitHub CLI (https://cli.github.com) and `gh auth login`.
#
#  Usage:
#     bash scripts/publish_github.sh                  # -> <your-login>/tmedia
#     bash scripts/publish_github.sh my-user/tmedia  # explicit name
#
#  Safety: refuses to stage *.session, config.json, .env or profile archives.
# =============================================================================
set -Eeuo pipefail

REPO="${1:-}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$ROOT"

command -v git >/dev/null 2>&1 || { printf '[!] git is required.\n' >&2; exit 1; }
command -v gh  >/dev/null 2>&1 || { printf '[!] GitHub CLI (gh) is required: https://cli.github.com\n' >&2; exit 1; }
if ! gh auth status >/dev/null 2>&1; then
    printf '[!] Not authenticated. Run: gh auth login\n' >&2
    exit 1
fi
if [[ -z "$REPO" ]]; then
    LOGIN="$(gh api user --jq .login 2>/dev/null || true)"
    [[ -n "$LOGIN" ]] || { printf '[!] Could not determine your GitHub login; pass owner/repo explicitly.\n' >&2; exit 1; }
    REPO="$LOGIN/tmedia"
fi

printf '[+] Repository : %s (public)\n' "$REPO"
printf '[+] Source     : %s\n' "$ROOT"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '[+] Initialising git ...\n'
    git init -q
fi

# --- secret guard ------------------------------------------------------------
git add -A
if git diff --cached --name-only | grep -vE '(^|/)\.env\.example$' | grep -Eqi '(^|/)([^/]*\.session(-journal|-wal)?|config\.json|credentials\.json|\.env(\..*)?|tmedia-profile-[^/]*\.tar\.gz|[^/]*\.tar\.gz)$'; then
    printf '[!] Refusing to commit: a session / credential / profile file is staged.\n' >&2
    printf '    Remove it (or check .gitignore) and run again.\n' >&2
    git reset -q
    exit 1
fi

if git diff --cached --quiet; then
    printf '[+] Nothing new to commit.\n'
else
    git commit -q -m "tmedia v1.1.0: zero-login recovery, profiles, cross-platform setup"
    printf '[+] Commit created.\n'
fi

# --- create or reuse remote ---------------------------------------------------
if git remote get-url origin >/dev/null 2>&1; then
    printf '[+] Pushing to existing origin ...\n'
    git push -u origin HEAD
else
    printf '[+] Creating public repository and pushing ...\n'
    gh repo create "$REPO" --public --source=. --remote=origin --push
fi

printf '\n[+] Done: https://github.com/%s\n' "$REPO"
printf '[+] Next: add a description + topics (telegram, telethon, cli, downloader),\n'
printf '          enable Issues/Discussions, and share it for forks and reviews.\n'
