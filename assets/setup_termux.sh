#!/usr/bin/env bash
# =============================================================================
#  setup_termux.sh -- install tmedia inside Termux (Android, no root needed)
#
#  Installs into $HOME/.tmedia/{venv,tmedia.py} and registers $PREFIX/bin/tmedia
#  (already on PATH in Termux). Downloads go to ~/storage/downloads after
#  `termux-setup-storage`, otherwise ~/Downloads.
#
#  Termux has no zenity: tmedia automatically uses the terminal path prompt.
# =============================================================================
set -Eeuo pipefail

readonly TM_VERSION="1.1.0"
APP_DIR="$HOME/.tmedia"
VENV_DIR="$APP_DIR/venv"
APP_PY="$APP_DIR/tmedia.py"
WRAPPER="${PREFIX:-/data/data/com.termux/files/usr}/bin/tmedia"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_PY="$(cd -- "$SCRIPT_DIR/.." && pwd)/src/tmedia.py"

step() { printf '\n[+] %s\n' "$1"; }
fail() { printf '\n[!] %s\n' "$1" >&2; exit 1; }

[[ -f "$SOURCE_PY" ]] || fail "Cannot find src/tmedia.py next to this script ($SOURCE_PY)."

# ---------------------------------------------------------------- python
step "Checking Termux packages ..."
PYTHON="$(command -v python3 || command -v python || true)"
if [[ -z "$PYTHON" ]]; then
    command -v pkg >/dev/null 2>&1 || fail "Termux 'pkg' not found. Are you inside Termux?"
    printf '    installing python ...\n'
    pkg install -y python >/dev/null || fail "pkg install python failed."
    PYTHON="$(command -v python3 || command -v python || true)"
fi
[[ -n "$PYTHON" ]] || fail "Python is still unavailable."
"$PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3,8) else 1)' \
    || fail "Python 3.8+ is required."

# ---------------------------------------------------------------- venv
step "Configuring virtual environment at $VENV_DIR ..."
mkdir -p -- "$APP_DIR"
if [[ -x "$VENV_DIR/bin/python" ]]; then
    printf '    existing venv reused (idempotent)\n'
else
    "$PYTHON" -m venv "$VENV_DIR" >/dev/null 2>&1 \
        || fail "python -m venv failed. Try: pkg install python && pip install virtualenv"
fi
PY="$VENV_DIR/bin/python"

# ---------------------------------------------------------------- deps
step "Installing Python dependencies (Telethon, rich, cryptg) ..."
if ! env PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1 \
        "$PY" -m pip install --quiet --no-input --disable-pip-version-check \
        "Telethon>=1.36,<2" "rich>=13,<15"; then
    fail "Could not install Telethon / rich (check your network)."
fi
if ! env PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1 \
        "$PY" -m pip install --quiet --no-input --disable-pip-version-check "cryptg>=0.4"; then
    printf '    [i] cryptg unavailable on this device (optional accelerator) - continuing\n'
fi

# ---------------------------------------------------------------- source
step "Installing tmedia source ..."
cp -- "$SOURCE_PY" "$APP_PY"
chmod 0644 "$APP_PY"
env PYTHONDONTWRITEBYTECODE=1 "$PY" -c \
    'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$APP_PY" \
    || fail "Source failed syntax validation."

# ---------------------------------------------------------------- launcher
step "Registering 'tmedia' command ..."
mkdir -p -- "$(dirname -- "$WRAPPER")"
cat > "$WRAPPER" <<EOF
#!/usr/bin/env bash
# tmedia launcher for Termux
set -euo pipefail
APP="$APP_DIR"
VENV="$VENV_DIR"
if [[ ! -x "\$VENV/bin/python" || ! -f "\$APP/tmedia.py" ]]; then
    printf '[!] Error: tmedia installation is incomplete. Re-run assets/setup_termux.sh.\\n' >&2
    exit 1
fi
DL="\$HOME/storage/downloads"
if [[ ! -d "\$DL" ]]; then DL="\$HOME/Downloads"; fi
mkdir -p -- "\$DL"
export TMEDIA_DOWNLOAD_DIR="\$DL"
exec "\$VENV/bin/python" "\$APP/tmedia.py" "\$@"
EOF
chmod 0755 "$WRAPPER"

"$PY" "$APP_PY" --version >/dev/null 2>&1 || fail "Verification failed."

printf '\n[+] tmedia v%s installed successfully.\n' "$TM_VERSION"
printf '[+] Grant shared storage once:  termux-setup-storage\n'
printf '[+] Then type:  tmedia        (check with:  tmedia --doctor)\n'
printf '[+] No new login needed if you import a profile:\n'
printf '      tmedia --import-profile <file>\n'
