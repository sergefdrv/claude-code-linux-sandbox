#!/bin/bash
#
# Claude Code Sandbox Setup (run once, or re-run to update).
#
# Checks prerequisites, generates the seccomp BPF blob, runs Anthropic's
# install.sh inside a tight sandbox (or migrates a prior non-sandboxed
# install), and installs the wrapper at ~/.local/bin/claude.
#

set -e

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
source "$SCRIPT_DIR/claude-sandbox-common.sh"

interactive() { [[ -t 0 && -t 1 ]]; }

# ── Parse args ───────────────────────────────────────────────────────
NO_INSTALL=false
FORCE_REINSTALL=false
UNINSTALL=false
PURGE=false
ASSUME_YES=false
for arg in "$@"; do
    case "$arg" in
        --no-install)      NO_INSTALL=true ;;
        --force-reinstall) FORCE_REINSTALL=true ;;
        --uninstall)       UNINSTALL=true ;;
        --purge)           PURGE=true ;;
        --yes|-y)          ASSUME_YES=true ;;
        --help|-h)
            cat <<EOF
Usage: $0 [--no-install | --force-reinstall | --uninstall [--purge]] [--yes]

  --no-install        Skip running Anthropic's installer even if the
                      install home is empty (expects a manual install
                      under \$INSTALL_HOME).
  --force-reinstall   Re-run the sandboxed installer even if the install
                      home already contains a claude binary.
  --uninstall         Remove the sandbox: \$INSTALL_DIR and the wrapper
                      at \$WRAPPER_PATH (only if it is ours). Preserves
                      ~/.claude/ and ~/.claude.json (your Claude Code
                      state, sessions, and OAuth credentials).
  --purge             With --uninstall, also remove ~/.claude/ and
                      ~/.claude.json* (logs you out, forgets MCP setup).
  --yes, -y           Skip the interactive "are you sure?" prompt.

Environment:
  WORKSPACE_DIR        Workspace directory bound rw inside the sandbox.
                       Prompted if unset.
  CLAUDE_INSTALL_URL   Override the install URL
                       (default: https://claude.ai/install.sh).
EOF
            exit 0
            ;;
    esac
done

# ── Uninstall path ───────────────────────────────────────────────────
if "$UNINSTALL"; then
    # Safety: refuse to operate on suspicious values.
    if [[ -z "$INSTALL_DIR" || "$INSTALL_DIR" != "$HOME"/* ]]; then
        echo "Error: refusing to act on INSTALL_DIR='$INSTALL_DIR' (expected under \$HOME)." >&2
        exit 1
    fi

    plan=()
    [[ -d "$INSTALL_DIR" ]] && plan+=("$INSTALL_DIR/")
    if [[ -e "$WRAPPER_PATH" || -L "$WRAPPER_PATH" ]]; then
        if claude_is_our_wrapper "$WRAPPER_PATH"; then
            plan+=("$WRAPPER_PATH (sandbox wrapper)")
        else
            echo "Note: $WRAPPER_PATH exists but does NOT carry our marker;" >&2
            echo "      leaving it alone (looks like a foreign claude install)." >&2
            echo "" >&2
        fi
    fi
    if "$PURGE"; then
        [[ -e "$HOME/.claude" || -L "$HOME/.claude" ]] && plan+=("$HOME/.claude/ (sessions, OAuth credentials, MCP config)")
        shopt -s nullglob
        for f in "$HOME"/.claude.json "$HOME"/.claude.json.backup*; do
            plan+=("$f")
        done
        shopt -u nullglob
    fi

    if (( ${#plan[@]} == 0 )); then
        echo "Nothing to uninstall."
        exit 0
    fi

    echo "Will remove:"
    for p in "${plan[@]}"; do
        echo "  - $p"
    done
    echo ""
    if ! "$PURGE"; then
        echo "  ~/.claude/ and ~/.claude.json* are preserved."
        echo "  Pass --purge to also wipe them (logs you out, forgets MCP setup)."
        echo ""
    fi

    if ! "$ASSUME_YES"; then
        if interactive; then
            read -rp "Proceed? [y/N] " answer
            [[ "$answer" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }
        else
            echo "Error: refusing to uninstall non-interactively without --yes." >&2
            exit 1
        fi
    fi

    # Best-effort removal: each step is independent; we report failures at the
    # end rather than aborting on the first error (otherwise a single rm fail
    # leaves the user in an inconsistent half-uninstalled state).
    failures=()
    _try_rm() {
        local err
        if ! err="$(rm -rf "$1" 2>&1)"; then
            failures+=("$1: $err")
        fi
    }
    [[ -d "$INSTALL_DIR" ]] && _try_rm "$INSTALL_DIR"
    if [[ -e "$WRAPPER_PATH" || -L "$WRAPPER_PATH" ]] && claude_is_our_wrapper "$WRAPPER_PATH"; then
        _try_rm "$WRAPPER_PATH"
    fi
    if "$PURGE"; then
        [[ -e "$HOME/.claude" || -L "$HOME/.claude" ]] && _try_rm "$HOME/.claude"
        shopt -s nullglob
        for f in "$HOME"/.claude.json "$HOME"/.claude.json.backup*; do
            _try_rm "$f"
        done
        shopt -u nullglob
    fi

    if (( ${#failures[@]} == 0 )); then
        echo "Uninstall complete."
        exit 0
    fi
    echo "" >&2
    echo "Uninstall finished with errors:" >&2
    for f in "${failures[@]}"; do
        echo "  $f" >&2
    done
    exit 1
fi

# ── Prereqs ──────────────────────────────────────────────────────────
missing=()
for cmd in bwrap curl xdg-dbus-proxy gdbus python3; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
done
if (( ${#missing[@]} > 0 )); then
    echo "Error: missing required commands: ${missing[*]}" >&2
    echo "" >&2
    echo "Install on Debian/Ubuntu:" >&2
    echo "  sudo apt install bubblewrap curl xdg-dbus-proxy libglib2.0-bin python3 python3-seccomp" >&2
    echo "Install on Fedora:" >&2
    echo "  sudo dnf install bubblewrap curl xdg-dbus-proxy glib2 python3 python3-libseccomp" >&2
    echo "Install on Arch:" >&2
    echo "  sudo pacman -S bubblewrap curl xdg-desktop-portal glib2 python python-libseccomp" >&2
    exit 1
fi

if ! check_libseccomp_python; then
    echo "" >&2
    echo "Install on Debian/Ubuntu: sudo apt install python3-seccomp" >&2
    echo "Install on Fedora:        sudo dnf install python3-libseccomp" >&2
    echo "Install on Arch:          sudo pacman -S python-libseccomp" >&2
    exit 1
fi

# bwrap must be able to create unprivileged user namespaces -- this is the
# single biggest source of "it doesn't work on Ubuntu 24.04" reports, so
# preflight it here rather than letting the install step fail opaquely.
echo "Checking that bwrap can create user namespaces..."
if ! check_bwrap_userns; then
    print_userns_remediation
    exit 1
fi
echo "  OK."
echo ""

# ── Workspace ────────────────────────────────────────────────────────
if [[ -z "$WORKSPACE_DIR" ]]; then
    if interactive; then
        read -rp "Enter workspace directory [$HOME/proj]: " WORKSPACE_DIR
        WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/proj}"
    else
        WORKSPACE_DIR="$HOME/proj"
    fi
fi
mkdir -p "$WORKSPACE_DIR"
WORKSPACE_DIR="$(readlink -f "$WORKSPACE_DIR")"

# ── Required directories ─────────────────────────────────────────────
mkdir -p "$INSTALL_DIR" \
         "$INSTALL_DIR/bin" \
         "$INSTALL_HOME" \
         "$HOME/.local/bin" \
         "$HOME/.claude"
# ~/.claude.json is bound as a file in both the install and runtime sandboxes;
# the file must exist on the host beforehand or the bind fails. Seed with an
# empty JSON object rather than touching to zero bytes -- the installer reads
# this file at startup and a 0-byte file makes its JSON parser hang.
if [[ ! -s "$HOME/.claude.json" ]]; then
    echo '{}' > "$HOME/.claude.json"
fi

# ── Copy support files into $INSTALL_DIR (so re-runs work standalone) ─
cp "$SCRIPT_DIR/claude-sandbox-common.sh"    "$INSTALL_DIR/"
cp "$SCRIPT_DIR/claude-install-in-sandbox.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/gen-seccomp-bpf.py"          "$INSTALL_DIR/"
cp "$SCRIPT_DIR/claude.seccomp.deny.list"    "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/claude-install-in-sandbox.sh" \
         "$INSTALL_DIR/gen-seccomp-bpf.py"

# ── Handle pre-existing ~/.local/bin/claude ──────────────────────────
existing="$(find_foreign_claude || true)"
if [[ -n "$existing" ]]; then
    echo "Found a non-sandboxed claude install at:"
    echo "  $existing"
    echo "It will be migrated into the install home:"
    echo "  $INSTALL_HOME/.local/bin/claude"
    echo "  $INSTALL_HOME/.local/share/claude/"
    echo ""
    if interactive; then
        read -rp "Proceed with migration? [Y/n] " answer
        if [[ -n "$answer" && ! "$answer" =~ ^[Yy] ]]; then
            echo "Aborted by user. No changes made."
            exit 1
        fi
    else
        echo "Error: non-interactive run found a foreign claude install." >&2
        echo "Re-run setup interactively, or remove the prior install first." >&2
        exit 1
    fi

    mkdir -p "$INSTALL_HOME/.local/bin" "$INSTALL_HOME/.local/share"
    # Move the entry point. $existing may be a symlink or a regular file.
    if [[ -e "$HOME/.local/bin/claude" || -L "$HOME/.local/bin/claude" ]]; then
        mv "$HOME/.local/bin/claude" "$INSTALL_HOME/.local/bin/claude"
        echo "Moved $HOME/.local/bin/claude -> $INSTALL_HOME/.local/bin/claude"
    fi
    # Move the versioned tree if present at the conventional location.
    if [[ -d "$HOME/.local/share/claude" ]]; then
        mv "$HOME/.local/share/claude" "$INSTALL_HOME/.local/share/claude"
        echo "Moved $HOME/.local/share/claude -> $INSTALL_HOME/.local/share/claude"
    fi
    echo ""
fi

# ── Run the sandboxed installer if no claude in the install home ─────
need_install=true
[[ -e "$INSTALL_CLAUDE" || -L "$INSTALL_CLAUDE" ]] && need_install=false
[[ "$FORCE_REINSTALL" == "true" ]] && need_install=true

if "$need_install"; then
    if "$NO_INSTALL"; then
        echo "Error: --no-install passed but no claude binary in $INSTALL_HOME." >&2
        exit 1
    fi
    echo "No claude binary in install home. Running sandboxed installer..."
    echo ""
    "$INSTALL_DIR/claude-install-in-sandbox.sh"
    echo ""
fi

if [[ ! -e "$INSTALL_CLAUDE" && ! -L "$INSTALL_CLAUDE" ]]; then
    echo "Error: expected $INSTALL_CLAUDE after install/migrate, but it is missing." >&2
    exit 1
fi

# ── Generate seccomp BPF ─────────────────────────────────────────────
echo "Generating seccomp BPF..."
python3 "$INSTALL_DIR/gen-seccomp-bpf.py" \
    "$INSTALL_DIR/claude.seccomp.deny.list" \
    "$SECCOMP_BPF"
echo ""

# ── xdg-open shim (portal OpenURI for OAuth browser open) ────────────
# Electron-style code in some MCP servers or the binary itself calls
# xdg-open; routing that through the portal opens links on the host.
cat > "$INSTALL_DIR/bin/xdg-open" <<'WRAPPEREOF'
#!/bin/bash
for _u in "$@"; do
    gdbus call --session \
        --dest org.freedesktop.portal.Desktop \
        --object-path /org/freedesktop/portal/desktop \
        --method org.freedesktop.portal.OpenURI.OpenURI \
        "" "$_u" "{}" >/dev/null 2>&1 || true
done
WRAPPEREOF
chmod +x "$INSTALL_DIR/bin/xdg-open"

# ── Write config ─────────────────────────────────────────────────────
write_claude_sandbox_config

# ── Install wrapper at ~/.local/bin/claude ───────────────────────────
# If something is already there and isn't our wrapper, refuse (we should
# have migrated above).  Loop-detect just in case.
if [[ -e "$WRAPPER_PATH" || -L "$WRAPPER_PATH" ]]; then
    if ! claude_is_our_wrapper "$WRAPPER_PATH"; then
        echo "Error: $WRAPPER_PATH exists and is not our wrapper (no marker)." >&2
        echo "This should not happen after migration; bailing out to avoid clobbering." >&2
        exit 1
    fi
fi
cp "$SCRIPT_DIR/claude-sandbox.sh" "$WRAPPER_PATH"
chmod +x "$WRAPPER_PATH"

# ── Done ─────────────────────────────────────────────────────────────
echo "Setup complete."
echo "  Workspace:    $WORKSPACE_DIR"
echo "  Install home: $INSTALL_HOME"
# readlink (no -f) gives the literal symlink target; the target is only
# resolvable inside the runtime sandbox, where the share tree is overlaid.
_claude_target="$(readlink "$INSTALL_CLAUDE" 2>/dev/null || echo "[regular file]")"
echo "  Real claude:  $INSTALL_CLAUDE -> $_claude_target"
echo "  Seccomp BPF:  $SECCOMP_BPF ($(stat -c%s "$SECCOMP_BPF") bytes)"
echo "  Wrapper:      $WRAPPER_PATH"
echo "  Config:       $CONFIG_FILE"
echo ""
echo "Run 'claude' from a workspace directory to launch."
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    echo ""
    echo "Note: $HOME/.local/bin is not in your PATH."
    echo "      Add it to your shell rc (e.g. echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc)."
fi
