# Claude Code Linux Sandbox

Run [Claude Code](https://claude.com/claude-code) inside a [bubblewrap](https://github.com/containers/bubblewrap) sandbox on Linux. The CLI and everything it executes are confined to an explicit allowlist of paths -- your workspace, `~/.claude`, and a small set of read-only tool installs (cargo, rustup, nvm, pyenv, pnpm, etc.). The rest of your filesystem is invisible.

The installer itself (`curl -fsSL https://claude.ai/install.sh | bash`) also runs inside a sandbox with `$HOME` bound to a dedicated install home, so the install step cannot touch your real `~/.ssh`, `~/.bashrc`, browser data, or anything else outside that directory.

> **Disclaimer:** Personal project, not affiliated with or endorsed by Anthropic or the bubblewrap authors. The sandbox is best-effort -- Linux user-namespace isolation is not a security boundary against a determined attacker, and escape paths exist (in particular through unrestricted network egress and any opt-in container-socket passthrough). Review [`claude-sandbox.sh`](claude-sandbox.sh) and [`claude.seccomp.deny.list`](claude.seccomp.deny.list) before use. Provided as-is, no warranty (see [LICENSE](LICENSE)).

## What the sandbox enforces

- **Filesystem isolation** -- `$HOME` is a tmpfs by default; only explicitly bound paths are visible (workspace rw, `~/.claude` rw, shell rc / git config / tool installs ro). `~/.config`, `~/.cache`, and `~/.local` are sandbox-private overlays backed by `~/.local/share/claude-sandbox/`, so subprocess XDG writes persist on disk without touching the host's real ones.
- **User namespace** -- no SUID binary involved, no root inside the sandbox, `NoNewPrivileges` set.
- **All Linux capabilities dropped.**
- **Seccomp filter** -- generated at setup time from [`claude.seccomp.deny.list`](claude.seccomp.deny.list); blocks ~40 syscalls historically tied to kernel exploits (io_uring, bpf, userfaultfd, kexec, ptrace, mount, etc.).
- **PID, UTS, IPC, cgroup namespaces** unshared -- no view of host processes.
- **Filtered session D-Bus** via `xdg-dbus-proxy` -- only `org.freedesktop.portal.Desktop` and notifications.
- **Ephemeral `/dev`, `/tmp`, `/run`** -- standard bwrap minimal `/dev`, fresh tmpfs for `/tmp` and `/run`.

Claude **can** use the network, your terminal, your git config (ro), and any read-only tool installs you opt in to. It **cannot** see your home directory, other projects, SSH keys, browser data, or host processes.

## Why two sandboxes (install + runtime)?

The official Claude Code install command (`curl -fsSL https://claude.ai/install.sh | bash`) runs as your user with full home access. Without intervention, the installer can write anywhere -- including places the runtime sandbox is designed to hide. So setup wraps the installer in its own bwrap profile with `$HOME` bound to `~/.local/opt/claude-sandbox/install-home/`. The installer thinks it's writing to your home, but every file actually lands in that install home; the real `~/.local/bin/`, `~/.local/share/`, `~/.ssh`, `~/.bashrc`, etc. are never visible to it.

After install, the runtime sandbox **overlays** the binary from the install home onto `$HOME/.local/bin/claude` inside the sandbox only. The host's PATH contains exactly one `claude` -- our wrapper -- and the real binary lives off-PATH at `~/.local/opt/claude-sandbox/install-home/.local/bin/claude`.

## Prerequisites

- Linux with user namespaces enabled (default on all modern distros)
- `bubblewrap` (bwrap)
- `curl` (for the installer)
- `xdg-dbus-proxy` (filtered session bus)
- `gdbus` (from GLib, for the xdg-open portal shim)
- `python3` + libseccomp Python bindings (BPF generation at setup time)

```bash
sudo apt install bubblewrap curl xdg-dbus-proxy libglib2.0-bin python3 python3-seccomp      # Debian/Ubuntu
sudo dnf install bubblewrap curl xdg-dbus-proxy glib2 python3 python3-libseccomp            # Fedora
sudo pacman -S bubblewrap curl xdg-desktop-portal glib2 python python-libseccomp            # Arch
```

## Setup

Run setup once:

```bash
./claude-sandbox-setup.sh
```

This prompts for a workspace directory, runs Anthropic's installer in a sandbox (writes only to `~/.local/opt/claude-sandbox/install-home/`), generates the seccomp BPF blob, installs the xdg-open shim, and writes the wrapper to `~/.local/bin/claude`.

Re-run setup after pulling repo changes (to update the wrapper and regenerate the BPF) or after editing [`claude.seccomp.deny.list`](claude.seccomp.deny.list).

Override defaults:

```bash
WORKSPACE_DIR=$HOME/repos ./claude-sandbox-setup.sh
CLAUDE_INSTALL_URL=https://claude.ai/install.sh ./claude-sandbox-setup.sh
```

Setup flags:

- `--no-install` -- skip the sandboxed installer (expects a manual install under `~/.local/opt/claude-sandbox/install-home/`).
- `--force-reinstall` -- re-run the sandboxed installer even if a claude binary is already present.
- `--uninstall` -- remove `~/.local/opt/claude-sandbox/` and the wrapper at `~/.local/bin/claude` (only if it is ours). Preserves `~/.claude/` and `~/.claude.json` so re-installing keeps you logged in.
- `--uninstall --purge` -- also wipe `~/.claude/` and `~/.claude.json*` (logs you out, forgets MCP setup).

### Migrating an existing native install

If you already have a non-sandboxed claude at `~/.local/bin/claude` (from `curl ... | bash` run directly), setup will offer to migrate it: it moves `~/.local/bin/claude` and `~/.local/share/claude/` into the install home, then installs the wrapper in their place. Your `~/.claude/` (sessions, OAuth credentials, MCP config) is preserved.

## Usage

From any subdirectory of your workspace:

```bash
cd ~/proj/some-repo && claude
claude --print "summarise this repo"
claude mcp list
```

The wrapper at `~/.local/bin/claude` is the only `claude` on your PATH; it always invokes the sandbox. There is no unsandboxed claude reachable through normal PATH lookup.

Claude Code, like git, is per-project: `cd` into the project before running. The sandbox's `WORKSPACE_DIR` (set at setup) is the *outer* bound — by default the parent directory of all your projects. Claude itself still treats the cwd as the project root (`~/.claude/projects/` keys by absolute path, `CLAUDE.md` discovery walks up from cwd).

`$PWD` is also preserved when it sits under `~/.claude` (handy for editing `settings.json`, agents, or MCP config from inside Claude). For any other bound path — e.g. an extra `--bind` added through the local profile — set `CLAUDE_SANDBOX_CWD` explicitly:

```bash
CLAUDE_SANDBOX_CWD=~/some/bound/path claude
```

If `$PWD` is outside both the workspace and `~/.claude`, and `CLAUDE_SANDBOX_CWD` is not set, the launcher prints a notice and starts in the workspace root.

### Narrowing the writable scope per invocation

`WORKSPACE_DIR` can be narrowed (never widened) at invocation time in two ways:

1. **Explicit override** via `CLAUDE_SANDBOX_WORKSPACE` (must be a subdirectory of `WORKSPACE_DIR` or equal to it):

   ```bash
   CLAUDE_SANDBOX_WORKSPACE=~/proj/some-repo claude
   ```

2. **Auto-narrow** when `--dangerously-skip-permissions` is detected anywhere in argv: the launcher narrows the writable workspace to PWD. If PWD is not a sub-directory of `WORKSPACE_DIR`, it warns and proceeds with the full workspace. Set `CLAUDE_SANDBOX_WORKSPACE` to opt out of the auto-narrow. The container-socket opt-in (see Docker / Podman below) is also force-ignored under this flag.

This way `cd ~/proj/some-repo && claude --dangerously-skip-permissions` autonomously edits only that one repo, with no access to siblings under `~/proj` and no container-socket escape.

## Tools

These directories are exposed **read-only** if they exist: `~/.cargo`, `~/.rustup`, `~/.nvm`, `~/.pyenv`, `~/go`, `~/.local/share/pnpm`, `~/.local/bin`. Compilers, interpreters, and CLI tools installed there work inside the sandbox, but installing or updating them (`nvm install`, `rustup update`, `pip install --user`, etc.) must happen outside the sandbox.

Package-manager **caches** are carved out as **read-write** within those trees and shared with the host: `~/.cargo/registry`, `~/.npm/_cacache`, `~/.local/share/pnpm/store`, `~/.cache/pip`, `~/go/pkg/mod`, `~/.cache/go-build`. This lets `cargo build`, `npm install`, `pnpm install`, `pip install`, and `go build` work from within a workspace. Sharing is safe because each tool verifies cache content against a lockfile (cargo SHA-256 vs `Cargo.lock`, npm SRI vs `package-lock.json`, pnpm content-addressed store, pip `--require-hashes`, Go module SHA-256 vs `go.sum`), so a sandboxed process cannot substitute forged cache entries for host or other-project builds.

Shell rc files are exposed read-only too: `~/.bashrc`, `~/.profile`, `~/.bash_profile`, `~/.zshrc`, `~/.zshenv`, `~/.inputrc`. Sub-shells Claude spawns will feel familiar.

### XDG state: `~/.config`, `~/.cache`, `~/.local`

Inside the sandbox, `~/.config`, `~/.cache`, and `~/.local` are bound from `~/.local/share/claude-sandbox/{config,cache,local}` on the host -- the host's real XDG dirs are invisible. Subprocess writes (LSP state, language-tool caches, app data under `~/.local/share`, state under `~/.local/state`, dotfile-style configs from `Bash` tool calls) persist across sessions on disk but never reach the host's real ones. `rm -rf ~/.local/share/claude-sandbox/{config,cache,local}` to reset. The existing read-only binds (`~/.local/bin`, `~/.local/share/pnpm`, `~/.local/share/claude`) layer on top of the overlay unchanged. If a package needs more of the host's XDG tree visible inside, add it via the extension hooks below.

## Docker / Podman

**Off by default.** The host Docker/Podman socket is not exposed inside the sandbox unless you opt in. Anything launched via that socket runs *on the host as your real user, outside the sandbox* — and a process that can talk to the daemon can trivially ask it to run a privileged container with `/` bind-mounted in, which is equivalent to host root (Docker / rootful Podman) or full account access (rootless Podman). Binding the socket therefore defeats the rest of the sandbox.

Opt in only if you accept that trade-off:

```bash
CLAUDE_SANDBOX_BIND_CONTAINER_SOCKET=1 claude
```

Inside the sandbox, talk to the host daemon over its API by adding `--remote`:

```bash
podman --remote ps
docker --remote info
```

The opt-in is **always ignored under `--dangerously-skip-permissions`** — a yolo-mode loop with the host socket would have no effective bound at all. To make the opt-in persistent for normal runs, export the variable in your shell rc.

## Extending the sandbox

MCP servers run as subprocesses inside the sandbox. If a server (or any code Claude runs) needs filesystem paths or sockets beyond the workspace + `~/.claude`, there are two hooks to splice extra bwrap arguments in. Each entry widens the sandbox -- use sparingly.

**Persistent: `~/.local/opt/claude-sandbox/claude-sandbox.local`** — plain text, one bwrap directive per line. `#` starts a comment, blank lines are ignored, and `${HOME}` / `${INSTALL_DIR}` / other env vars are expanded:

```
# Expose an extra tool's install + state dirs.
--ro-bind /opt/foo /opt/foo
--bind    ${HOME}/.config/foo ${HOME}/.config/foo
```

The file lives alongside the installed launcher (outside the sandbox's writable scope), so it can't be tampered with from inside Claude.

**Per-invocation: `$CLAUDE_SANDBOX_EXTRA_ARGS`** — space-separated bwrap args for a single launch:

```bash
CLAUDE_SANDBOX_EXTRA_ARGS="--ro-bind /opt/something /opt/something" claude
```

## The `--dangerously-skip-permissions` story

Under this sandbox, `--dangerously-skip-permissions` (or "yolo mode") means **"bounded autonomous execution"**: Claude runs every tool call without prompting, but its filesystem reach is still limited to the (auto-narrowed) workspace and `~/.claude`. It cannot touch `~/.ssh`, your shell rc, other projects, or system paths. The bound is the sandbox boundary, not the prompt boundary.

When the launcher sees this flag in argv it automatically:

- Narrows the writable workspace from `WORKSPACE_DIR` to `$PWD` (assuming PWD is inside the workspace). Override with `CLAUDE_SANDBOX_WORKSPACE=...`.
- Force-ignores `CLAUDE_SANDBOX_BIND_CONTAINER_SOCKET=1`. The host container socket is off by default for normal runs too (see Docker / Podman); under yolo it can't be turned on at all, since an autonomous loop with the host socket would have no effective bound.

Caveats that still apply with this flag:

- **Network egress is unrestricted.** Workspace contents can be exfiltrated to arbitrary hosts. The sandbox does not protect against data exfiltration. If you need egress filtering, switch to rootless podman with a network policy or use systemd-run with `IPAddressDeny`/`IPAddressAllow`.
- **`~/.claude` is rw**, so a compromised Claude can rotate or exfiltrate its own OAuth credentials. Generally acceptable.
- **The narrowed workspace is rw**, so the project at hand is at Claude's mercy. Treat it as version-controlled / backed up.
- **The narrowing relies on the flag being present in argv as `--dangerously-skip-permissions`**. If Claude grows a new "yolo" alias (`--bypass-permissions`, env var, settings.json entry, etc.), the auto-narrow won't trigger. Set `CLAUDE_SANDBOX_WORKSPACE` explicitly for full assurance.

## Customising the seccomp filter

The deny-list lives in [`claude.seccomp.deny.list`](claude.seccomp.deny.list). Edit it, re-run `./claude-sandbox-setup.sh`, and the new BPF is generated by [`gen-seccomp-bpf.py`](gen-seccomp-bpf.py) at `~/.local/opt/claude-sandbox/claude.seccomp.bpf`. If an MCP server fails with `Operation not permitted` on a denied syscall, either remove that syscall from the list or widen the sandbox to exclude that server.

## Troubleshooting

**`claude` not found** -- ensure `~/.local/bin` is in your PATH. Setup prints a notice if it's not.

**Sandbox refuses to start** -- run `claude` from a terminal. Common causes:
- `bwrap` not installed.
- User namespaces disabled on your kernel. Check `sysctl kernel.unprivileged_userns_clone` -- should be `1`.
- Seccomp BPF file missing or wrong architecture -- re-run setup.

**OAuth login URL doesn't open in browser** -- the xdg-open shim needs `xdg-dbus-proxy` running and `xdg-desktop-portal` on the host. Without these the URL is still printed and can be pasted into a host browser manually; the callback returns a code Claude accepts.

**MCP server fails with permission errors** -- it probably needs paths outside the sandbox. Use `CLAUDE_SANDBOX_EXTRA_ARGS` to add `--ro-bind`/`--bind` entries, or edit [`claude.seccomp.deny.list`](claude.seccomp.deny.list) if a denied syscall is the issue.

## License

MIT -- see [LICENSE](LICENSE).
