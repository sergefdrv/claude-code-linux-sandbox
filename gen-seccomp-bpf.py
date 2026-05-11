#!/usr/bin/env python3
"""Generate a seccomp BPF blob from a deny-list file.

Usage: gen-seccomp-bpf.py <deny-list-path> <output-bpf-path>

The deny-list is a plain text file with one syscall name per line.
'#' starts a comment, blank lines are ignored. Syscalls that don't
exist on the current architecture are skipped with a warning.

Default action is ALLOW; each listed syscall is rejected with EPERM.
We use EPERM instead of KILL_PROCESS so that benign callers that
probe for syscall availability (e.g. glibc fallback paths) survive
gracefully -- the goal is exploit mitigation, not behavioural strictness.
"""

import errno
import os
import sys

try:
    import seccomp
except ImportError:
    sys.stderr.write(
        "error: python3 'seccomp' module not found.\n"
        "  Debian/Ubuntu: sudo apt install python3-seccomp\n"
        "  Fedora:        sudo dnf install python3-libseccomp\n"
        "  Arch:          sudo pacman -S python-libseccomp\n"
    )
    sys.exit(2)


def main() -> int:
    if len(sys.argv) != 3:
        sys.stderr.write(f"usage: {sys.argv[0]} <deny-list> <output-bpf>\n")
        return 2

    deny_list_path, output_path = sys.argv[1], sys.argv[2]

    syscalls: list[str] = []
    with open(deny_list_path, encoding="utf-8") as f:
        for raw in f:
            line = raw.split("#", 1)[0].strip()
            if line:
                syscalls.append(line)

    f = seccomp.SyscallFilter(defaction=seccomp.ALLOW)

    added, skipped = 0, []
    for name in syscalls:
        try:
            f.add_rule(seccomp.ERRNO(errno.EPERM), name)
            added += 1
        except (RuntimeError, ValueError) as e:
            # Most commonly: syscall not defined on this architecture
            skipped.append((name, str(e)))

    # Write to a tmp path then rename, so we never leave a half-written BPF.
    tmp = output_path + ".tmp"
    with open(tmp, "wb") as out:
        f.export_bpf(out)
    os.replace(tmp, output_path)

    sys.stderr.write(f"seccomp: {added} rules added, {len(skipped)} skipped\n")
    for name, reason in skipped:
        sys.stderr.write(f"  skipped {name}: {reason}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
