#!/bin/bash
# Shared paths, constants, and helpers.
# Source this file; do not run directly.
# shellcheck disable=SC2034  # variables consumed by sourcing scripts

INSTALL_DIR="$HOME/.local/opt/claude-sandbox"
INSTALL_HOME="$INSTALL_DIR/install-home"
CONFIG_FILE="$INSTALL_DIR/.claude-sandbox.env"
SECCOMP_BPF="$INSTALL_DIR/claude.seccomp.bpf"
WRAPPER_PATH="$HOME/.local/bin/claude"
WRAPPER_MARKER='# claude-sandbox-managed'

INSTALL_CLAUDE="$INSTALL_HOME/.local/bin/claude"
INSTALL_CLAUDE_SHARE="$INSTALL_HOME/.local/share/claude"

# True if $1 is a regular file/symlink containing our wrapper marker.
claude_is_our_wrapper() {
    local p="$1"
    [[ -f "$p" ]] && grep -qF "$WRAPPER_MARKER" "$p" 2>/dev/null
}

# Find an existing claude binary on the host that is NOT our wrapper.
# Searches: $CLAUDE_BIN, then $HOME/.local/bin/claude, then PATH.
# Echoes the resolved path or nothing.
find_foreign_claude() {
    local candidates=()
    [[ -n "$CLAUDE_BIN" ]] && candidates+=("$CLAUDE_BIN")
    candidates+=("$HOME/.local/bin/claude")
    local from_path
    from_path="$(command -v claude 2>/dev/null)" && candidates+=("$from_path")

    for c in "${candidates[@]}"; do
        [[ -e "$c" ]] || continue
        if claude_is_our_wrapper "$c"; then
            continue
        fi
        readlink -f "$c"
        return 0
    done
    return 1
}

write_claude_sandbox_config() {
    mkdir -p "$INSTALL_DIR"
    {
        echo '# Automatically generated -- re-run claude-sandbox-setup.sh to regenerate'
        printf 'INSTALL_DIR=%q\n'   "$INSTALL_DIR"
        printf 'INSTALL_HOME=%q\n'  "$INSTALL_HOME"
        printf 'WORKSPACE_DIR=%q\n' "$WORKSPACE_DIR"
        printf 'SECCOMP_BPF=%q\n'   "$SECCOMP_BPF"
    } > "$CONFIG_FILE"
}

# Check that bwrap can create unprivileged user namespaces on this kernel.
# Returns 0 on success; on failure echoes the bwrap stderr to caller's stderr
# and returns the bwrap exit code.
check_bwrap_userns() {
    command -v bwrap &>/dev/null || { echo "bwrap not installed" >&2; return 127; }
    local output rc
    # Same minimal bind set as the install profile (in particular /lib*, so the
    # dynamic linker of /usr/bin/true is reachable on non-merged-usr systems).
    output=$(bwrap \
        --unshare-user \
        --ro-bind /usr /usr \
        --ro-bind-try /lib /lib \
        --ro-bind-try /lib64 /lib64 \
        --proc /proc --dev /dev \
        /usr/bin/true 2>&1)
    rc=$?
    if (( rc != 0 )); then
        echo "$output" >&2
    fi
    return "$rc"
}

# Print actionable remediation for the Ubuntu 24.04 AppArmor userns restriction.
print_userns_remediation() {
    cat >&2 <<'EOF'

bwrap cannot create user namespaces on this system.  The most common cause on
Ubuntu 23.10+ (and Debian 12+ with apparmor hardening) is the kernel sysctl
'kernel.apparmor_restrict_unprivileged_userns=1' combined with no AppArmor
profile that grants 'userns,' to /usr/bin/bwrap.

Apply ONE of the following on the host, then re-run this setup:

  # Option 1 -- Per-binary AppArmor profile (cleanest, only relaxes bwrap):
  sudo tee /etc/apparmor.d/bwrap >/dev/null <<'PROFILE'
  abi <abi/4.0>,
  include <tunables/global>

  profile bwrap /usr/bin/bwrap flags=(unconfined) {
    userns,
    include if exists <local/bwrap>
  }
  PROFILE
  sudo systemctl reload apparmor

  # Option 2 -- Disable the sysctl, persistent (relaxes globally):
  echo "kernel.apparmor_restrict_unprivileged_userns = 0" \
      | sudo tee /etc/sysctl.d/60-userns.conf
  sudo sysctl --system

  # Option 3 -- Disable just for this session (lost on reboot):
  sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0

EOF
}

# Check whether python3 + libseccomp Python bindings are usable.
# Returns 0 if OK, non-zero with a stderr message otherwise.
check_libseccomp_python() {
    if ! command -v python3 &>/dev/null; then
        echo "python3 not found" >&2
        return 1
    fi
    if ! python3 -c 'import seccomp' &>/dev/null; then
        echo "python3 'seccomp' module not found (install python3-seccomp on Debian/Ubuntu, python3-libseccomp on Fedora, python-libseccomp on Arch)" >&2
        return 1
    fi
    return 0
}
