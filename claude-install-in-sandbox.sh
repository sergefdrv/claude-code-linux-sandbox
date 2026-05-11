#!/bin/bash
#
# Run Anthropic's Claude Code installer inside a tight bubblewrap sandbox.
#
# The installer thinks it is writing to $HOME, but $HOME is bound to
# $INSTALL_HOME ($INSTALL_DIR/install-home). Whatever the installer writes
# outside that bound path hits ro /usr or tmpfs and is discarded when bwrap exits.
#
# Result on the host: $INSTALL_HOME contains a fake-home tree with the
# installer's output -- typically $INSTALL_HOME/.local/bin/claude (a symlink)
# and $INSTALL_HOME/.local/share/claude/versions/<v>/claude (the real binary).
#

set -e

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
if [ -f "$SCRIPT_DIR/claude-sandbox-common.sh" ]; then
    source "$SCRIPT_DIR/claude-sandbox-common.sh"
else
    source "$HOME/.local/opt/claude-sandbox/claude-sandbox-common.sh"
fi

INSTALL_URL="${CLAUDE_INSTALL_URL:-https://claude.ai/install.sh}"

mkdir -p "$INSTALL_HOME/.local/bin" \
         "$INSTALL_HOME/.local/share"

if ! command -v bwrap &>/dev/null; then
    echo "Error: bubblewrap (bwrap) is not installed." >&2
    exit 1
fi
if ! command -v curl &>/dev/null; then
    echo "Error: curl is not installed." >&2
    exit 1
fi

echo "Running Claude Code installer inside bubblewrap sandbox..."
echo "  Install URL:          $INSTALL_URL"
echo "  Sandbox \$HOME:        $INSTALL_HOME"
echo "  Pass-through to host: ~/.claude/, ~/.claude.json"
echo ""

# Notes on the bwrap profile below:
#  --bind $INSTALL_HOME $HOME   : installer sees an empty-ish $HOME under its control
#  --bind ~/.claude{,.json}     : narrow overlays so initial user state lands on
#                                  the host instead of being trapped in the
#                                  install home (these become the same files the
#                                  runtime sandbox exposes back to claude)
#  --tmpfs /tmp                  : scratch space for curl etc., discarded on exit
#  --share-net                   : installer needs to download the tarball
#  --unshare-all                 : new user/pid/uts/ipc/cgroup namespaces; no host process visibility
#  --cap-drop ALL                : no Linux capabilities even within the namespace
#  --die-with-parent             : if this script is killed, the sandbox dies too
#  --new-session                 : new session keyring, no inherited terminal control
bwrap \
    --ro-bind /usr /usr \
    --ro-bind-try /bin /bin \
    --ro-bind-try /sbin /sbin \
    --ro-bind-try /lib /lib \
    --ro-bind-try /lib32 /lib32 \
    --ro-bind-try /lib64 /lib64 \
    --ro-bind /etc /etc \
    --proc /proc \
    --dev /dev \
    --tmpfs /tmp \
    --tmpfs /run \
    --ro-bind-try /run/systemd/resolve /run/systemd/resolve \
    --ro-bind-try /run/NetworkManager /run/NetworkManager \
    --ro-bind-try /run/resolvconf /run/resolvconf \
    --bind "$INSTALL_HOME" "$HOME" \
    --bind "$HOME/.claude"      "$HOME/.claude" \
    --bind "$HOME/.claude.json" "$HOME/.claude.json" \
    --setenv HOME "$HOME" \
    --setenv USER "${USER:-claude}" \
    --setenv PATH "/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin" \
    --setenv TMPDIR "/tmp" \
    --unshare-all \
    --share-net \
    --die-with-parent \
    --new-session \
    --cap-drop ALL \
    bash -c "curl -fsSL '$INSTALL_URL' | bash"

echo ""
echo "Installer finished. Contents written to: $INSTALL_HOME"
echo ""

# Verify expected artifacts landed where we expect.  Use -e || -L because the
# installer typically drops a symlink at $INSTALL_CLAUDE whose target is an
# absolute path inside the sandbox's $HOME view (e.g. /home/$USER/.local/share/
# claude/versions/<v>/claude) -- that target only resolves inside the runtime
# bwrap, not on the host.  A dangling-on-the-host symlink is OK.
if [[ ! -e "$INSTALL_CLAUDE" && ! -L "$INSTALL_CLAUDE" ]]; then
    echo "Warning: $INSTALL_CLAUDE does not exist after install." >&2
    echo "         The installer may have written to an unexpected path." >&2
    echo "         Listing contents of $INSTALL_HOME for debugging:" >&2
    find "$INSTALL_HOME" -maxdepth 4 -type f -o -type l 2>/dev/null | head -50 >&2
    exit 1
fi

# readlink without -f so we show the symlink's *literal* target (which will only
# resolve inside the runtime sandbox, where /home/$USER overlays $INSTALL_HOME).
echo "Claude binary: $INSTALL_CLAUDE -> $(readlink "$INSTALL_CLAUDE" 2>/dev/null || echo "[regular file]")"
