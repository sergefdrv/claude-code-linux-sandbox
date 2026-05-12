#!/bin/bash
# claude-sandbox-managed
#
# Claude Code sandboxed launcher (bubblewrap).
#
# Runs the real Claude Code binary inside a bubblewrap sandbox that limits
# filesystem access to the workspace directory, ~/.claude, and a small set
# of read-only tool installs and shell rc files.
#
# Installed at ~/.local/bin/claude by claude-sandbox-setup.sh -- this is the
# ONLY `claude` on the user's PATH. The real binary lives at
# $INSTALL_HOME/.local/bin/claude (off PATH on the host) and is reachable
# only via the bwrap overlay that maps it onto $HOME/.local/bin/claude
# inside the sandbox.
#
# The "# claude-sandbox-managed" marker on line 2 lets setup detect
# previously-installed wrappers when re-running.

set -e

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
if [ -f "$SCRIPT_DIR/claude-sandbox-common.sh" ]; then
    source "$SCRIPT_DIR/claude-sandbox-common.sh"
else
    source "$HOME/.local/opt/claude-sandbox/claude-sandbox-common.sh"
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Config not found at: $CONFIG_FILE" >&2
    echo "Run claude-sandbox-setup.sh first." >&2
    exit 1
fi
source "$CONFIG_FILE"

# ── Sanity checks ────────────────────────────────────────────────────
if [[ ! -x "$INSTALL_CLAUDE" && ! -L "$INSTALL_CLAUDE" ]]; then
    echo "Error: real claude binary missing at $INSTALL_CLAUDE" >&2
    echo "Re-run claude-sandbox-setup.sh to (re)install." >&2
    exit 1
fi
if [[ ! -f "$SECCOMP_BPF" ]]; then
    echo "Error: seccomp BPF blob missing at $SECCOMP_BPF" >&2
    echo "Re-run claude-sandbox-setup.sh to regenerate it." >&2
    exit 1
fi
if ! command -v bwrap &>/dev/null; then
    echo "Error: bubblewrap (bwrap) is not installed." >&2
    exit 1
fi

# ── Effective workspace (writable root) ──────────────────────────────
# The configured WORKSPACE_DIR is the broadest the sandbox will ever allow.
# Two mechanisms can narrow it further (never widen):
#   1. CLAUDE_SANDBOX_WORKSPACE=...  explicit override; must be inside WORKSPACE_DIR
#   2. --dangerously-skip-permissions in argv  auto-narrow to PWD (the running
#      project), and also drop the container-socket passthrough (escape hatch).
override_set=false
[[ -n "${CLAUDE_SANDBOX_WORKSPACE:-}" ]] && override_set=true
auto_narrow=false
if ! "$override_set"; then
    for arg in "$@"; do
        if [[ "$arg" == "--dangerously-skip-permissions" ]]; then
            auto_narrow=true
            break
        fi
    done
fi

effective_workspace="$WORKSPACE_DIR"
if "$override_set"; then
    override="$(readlink -f "$CLAUDE_SANDBOX_WORKSPACE")"
    if [[ "$override" == "$WORKSPACE_DIR" || "$override/" == "$WORKSPACE_DIR/"* ]]; then
        effective_workspace="$override"
    else
        echo "Error: CLAUDE_SANDBOX_WORKSPACE ($override) is not inside WORKSPACE_DIR ($WORKSPACE_DIR)." >&2
        echo "       The sandbox can only narrow, never widen, the configured workspace." >&2
        exit 1
    fi
elif "$auto_narrow"; then
    if [[ "$PWD" != "$WORKSPACE_DIR" && "$PWD/" == "$WORKSPACE_DIR/"* ]]; then
        effective_workspace="$PWD"
        echo "Notice: --dangerously-skip-permissions detected; narrowing writable workspace" >&2
        echo "        from $WORKSPACE_DIR to $effective_workspace, and dropping container socket." >&2
        echo "        Override with CLAUDE_SANDBOX_WORKSPACE=... if you want a different scope." >&2
    else
        echo "Warning: --dangerously-skip-permissions but PWD=$PWD is not a sub-directory of" >&2
        echo "         WORKSPACE_DIR=$WORKSPACE_DIR -- cannot auto-narrow. Running with the full" >&2
        echo "         workspace writable. Consider setting CLAUDE_SANDBOX_WORKSPACE=... explicitly." >&2
    fi
fi

# ── Working directory inside the sandbox ─────────────────────────────
# If PWD is inside the effective workspace, preserve it; otherwise fall back
# to the workspace root (the host PWD won't exist inside the sandbox).
sandbox_cwd="$effective_workspace"
if [[ "$PWD/" == "$effective_workspace/"* ]]; then
    sandbox_cwd="$PWD"
elif [[ "$PWD" != "$effective_workspace" ]]; then
    echo "Notice: current directory $PWD is outside the (effective) workspace; starting in $effective_workspace." >&2
fi

# ── xdg-dbus-proxy (filtered session bus for the portal OAuth flow) ──
USER_ID="$(id -u)"
XDG_DIR="${XDG_RUNTIME_DIR:-/run/user/$USER_ID}"
PROXY_DIR=
proxy_pid=
if command -v xdg-dbus-proxy &>/dev/null && [[ -n "$DBUS_SESSION_BUS_ADDRESS" ]]; then
    PROXY_DIR="$XDG_DIR/claude-sandbox.$$"
    mkdir -p "$PROXY_DIR"
    chmod 700 "$PROXY_DIR"
    xdg-dbus-proxy "$DBUS_SESSION_BUS_ADDRESS" "$PROXY_DIR/bus" \
        --filter \
        --talk=org.freedesktop.portal.Desktop \
        --talk=org.freedesktop.portal.OpenURI \
        --talk=org.freedesktop.Notifications \
        &
    proxy_pid=$!
    cleanup() {
        if [[ -n "$proxy_pid" ]]; then
            kill "$proxy_pid" 2>/dev/null || true
        fi
        if [[ -n "$PROXY_DIR" ]]; then
            rm -rf "$PROXY_DIR" || true
        fi
    }
    trap cleanup EXIT INT TERM
    # Wait briefly for the proxy socket to appear (up to ~2s).
    for _ in $(seq 1 20); do
        [[ -S "$PROXY_DIR/bus" ]] && break
        sleep 0.1
    done
    if [[ ! -S "$PROXY_DIR/bus" ]]; then
        echo "Warning: xdg-dbus-proxy did not produce a socket; portal calls will fail." >&2
        PROXY_DIR=
    fi
else
    echo "Notice: xdg-dbus-proxy not available; sandbox will run without a session bus." >&2
fi

# ── Build bwrap argument list ────────────────────────────────────────
ARGS=(
    # Base read-only system layout
    --ro-bind /usr /usr
    --ro-bind-try /bin /bin
    --ro-bind-try /sbin /sbin
    --ro-bind-try /lib /lib
    --ro-bind-try /lib32 /lib32
    --ro-bind-try /lib64 /lib64
    --ro-bind /etc /etc
    --proc /proc
    --dev /dev
    --tmpfs /tmp
    --tmpfs /run

    # Re-expose resolver state so /etc/resolv.conf's symlink chain resolves
    # (Ubuntu/systemd-resolved, NetworkManager, openresolv).
    --ro-bind-try /run/systemd/resolve /run/systemd/resolve
    --ro-bind-try /run/NetworkManager  /run/NetworkManager
    --ro-bind-try /run/resolvconf       /run/resolvconf

    # Blanket-tmpfs $HOME, then re-expose only what's needed
    --tmpfs "$HOME"

    # Writable: workspace (possibly narrowed) + Claude's own state
    --bind "$effective_workspace" "$effective_workspace"
    --bind "$HOME/.claude" "$HOME/.claude"
    --bind "$HOME/.claude.json" "$HOME/.claude.json"

    # Read-only tool installs (managed outside the sandbox)
    --ro-bind-try "$HOME/.local/bin"        "$HOME/.local/bin"
    --ro-bind-try "$HOME/.local/share/pnpm" "$HOME/.local/share/pnpm"
    --ro-bind-try "$HOME/.cargo"  "$HOME/.cargo"
    --ro-bind-try "$HOME/.rustup" "$HOME/.rustup"
    --ro-bind-try "$HOME/.nvm"    "$HOME/.nvm"
    --ro-bind-try "$HOME/.pyenv"  "$HOME/.pyenv"
    --ro-bind-try "$HOME/go"      "$HOME/go"

    # Read-only shell rc + git config (so Claude's spawned shells feel familiar)
    --ro-bind-try "$HOME/.gitconfig"    "$HOME/.gitconfig"
    --ro-bind-try "$HOME/.bashrc"       "$HOME/.bashrc"
    --ro-bind-try "$HOME/.profile"      "$HOME/.profile"
    --ro-bind-try "$HOME/.bash_profile" "$HOME/.bash_profile"
    --ro-bind-try "$HOME/.zshrc"        "$HOME/.zshrc"
    --ro-bind-try "$HOME/.zshenv"       "$HOME/.zshenv"
    --ro-bind-try "$HOME/.inputrc"      "$HOME/.inputrc"

    # Real claude overlays.  Order matters: these come AFTER the broader
    # $HOME/.local/bin bind above, so they win for these two paths.
    --ro-bind "$INSTALL_CLAUDE_SHARE" "$HOME/.local/share/claude"
)

# Resolve $INSTALL_CLAUDE to a real file on the host so we can --ro-bind it
# onto $HOME/.local/bin/claude inside the sandbox.  The installer typically
# writes a symlink whose target is an absolute path into its sandboxed $HOME
# view (e.g. /home/$USER/.local/share/claude/versions/<v>) -- only resolvable
# inside the runtime sandbox -- so we translate that target back to the host
# by swapping the $HOME prefix for $INSTALL_HOME.
if [[ -L "$INSTALL_CLAUDE" ]]; then
    _target="$(readlink "$INSTALL_CLAUDE")"
    [[ "$_target" == "$HOME"/* ]] && _target="$INSTALL_HOME/${_target#$HOME/}"
    _real_claude_host="$_target"
else
    _real_claude_host="$INSTALL_CLAUDE"
fi
if [[ ! -f "$_real_claude_host" ]]; then
    echo "Error: real claude binary not found at $_real_claude_host" >&2
    echo "       Re-run claude-sandbox-setup.sh --force-reinstall." >&2
    exit 1
fi
ARGS+=(--ro-bind "$_real_claude_host" "$HOME/.local/bin/claude")
ARGS+=(

    # xdg-open shim directory (added to PATH below so Electron-style code
    # that calls xdg-open routes through the host portal).
    --ro-bind "$INSTALL_DIR/bin" "$INSTALL_DIR/bin"

    --setenv HOME "$HOME"
    --setenv USER "${USER:-$(id -un)}"
    --setenv PATH "$INSTALL_DIR/bin:$HOME/.local/bin:$PATH"
    --setenv BROWSER "$INSTALL_DIR/bin/xdg-open"
    --setenv XDG_RUNTIME_DIR "$XDG_DIR"
    --setenv TMPDIR "/tmp"

    --chdir "$sandbox_cwd"

    --unshare-all --share-net
    --die-with-parent
    --new-session
    --cap-drop ALL
)

# Filtered session bus, only if the proxy came up.
if [[ -n "$PROXY_DIR" && -S "$PROXY_DIR/bus" ]]; then
    ARGS+=(
        --bind "$PROXY_DIR/bus" "$XDG_DIR/bus"
        --setenv DBUS_SESSION_BUS_ADDRESS "unix:path=$XDG_DIR/bus"
    )
fi

# Container socket passthrough (host-side daemon access via --remote).
# Skipped under --dangerously-skip-permissions because anything Claude runs
# through the socket executes on the host as the real user, outside the sandbox.
if ! "$auto_narrow"; then
    if [[ -S "$XDG_DIR/podman/podman.sock" ]]; then
        ARGS+=(--bind "$XDG_DIR/podman/podman.sock" "$XDG_DIR/podman/podman.sock")
    elif [[ -S "/var/run/docker.sock" ]]; then
        ARGS+=(--bind "/var/run/docker.sock" "/var/run/docker.sock")
    fi
fi

# Optional site-local extension hook (persistent equivalent of the
# $CLAUDE_SANDBOX_EXTRA_ARGS env var below).  Plain text: one bwrap
# directive per line, `#` starts a comment, blank lines ignored.
# Variables ($HOME, $INSTALL_DIR, ...) are expanded.  Lives in
# $INSTALL_DIR so it's outside the sandbox's writable scope.
# See README ("Extending the sandbox") for examples.
LOCAL_PROFILE="$INSTALL_DIR/claude-sandbox.local"
if [[ -f "$LOCAL_PROFILE" ]]; then
    while IFS= read -r _line || [[ -n "$_line" ]]; do
        _line="${_line%%#*}"
        read -r _line <<<"$_line" || true   # trim leading/trailing whitespace
        [[ -z "$_line" ]] && continue
        # eval: enables ${HOME}-style expansion and quoting; trust model
        # is the same as sourcing -- file lives in $INSTALL_DIR.
        eval "ARGS+=( $_line )"
    done < "$LOCAL_PROFILE"
    unset _line
fi

# Optional per-invocation extension hook: extra bwrap args from
# $CLAUDE_SANDBOX_EXTRA_ARGS.  Space-separated, IFS-split.  Use sparingly --
# each entry widens the sandbox.
if [[ -n "${CLAUDE_SANDBOX_EXTRA_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    EXTRA=( $CLAUDE_SANDBOX_EXTRA_ARGS )
    ARGS+=( "${EXTRA[@]}" )
fi

# ── Seccomp BPF: open as FD, pass to bwrap via --seccomp <fd> ────────
exec {seccomp_fd}<"$SECCOMP_BPF"
ARGS+=(--seccomp "$seccomp_fd")

# ── Exec ─────────────────────────────────────────────────────────────
# `claude` (no path) resolves via in-sandbox PATH to $HOME/.local/bin/claude,
# which the overlay above maps to the real binary.  No recursion: the host's
# wrapper at the same path is hidden by the overlay.
exec bwrap "${ARGS[@]}" claude "$@"
