#!/usr/bin/env python3
"""Build and install the complete Codex package from the latest stable upstream tag.

Requires Python 3.11+, Git, rustup/Cargo, and native compilation tools.
Codex binaries are built from source; pinned V8, ripgrep, and shell resources
are downloaded by the release's own package builder. No existing checkout is used.
"""

import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile


UPSTREAM = "https://github.com/openai/codex.git"
STABLE_REF = re.compile(
    r"refs/tags/(rust-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))"
)


def latest_stable(refs):
    candidates = []
    for line in refs.splitlines():
        fields = line.split()
        if len(fields) != 2:
            continue
        match = STABLE_REF.fullmatch(fields[1])
        if match:
            candidates.append((tuple(map(int, match.groups()[1:])), match[1], fields[0]))
    if not candidates:
        raise RuntimeError("Upstream returned no exact rust-vMAJOR.MINOR.PATCH tags")
    _, tag, object_id = max(candidates)
    return tag, object_id


def run(args, **kwargs):
    print("+ " + shlex.join(map(str, args)), flush=True)
    return subprocess.run(args, check=True, **kwargs)


def installed_is_current(launcher, version):
    if not launcher.is_file():
        return False
    try:
        result = subprocess.run([launcher, "--version"], text=True, capture_output=True,
                                check=True, timeout=15)
        if result.stdout.strip() not in (f"codex-cli {version}", f"codex {version}"):
            return False
        package = launcher.resolve().parent.parent
        metadata = json.loads((package / "codex-package.json").read_text())
        if metadata.get("version") != version or metadata.get("variant") != "codex":
            return False
        required = [package / "bin/codex", package / "bin/codex-code-mode-host",
                    package / "codex-path/rg"]
        if sys.platform == "linux":
            required.append(package / "codex-resources/bwrap")
        if sys.platform in ("darwin", "linux"):
            required.append(package / "codex-resources/zsh/bin/zsh")
        return all(path.is_file() and os.access(path, os.X_OK) for path in required)
    except (OSError, ValueError, subprocess.SubprocessError):
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="Resolve the upstream tag and print the plan without building or installing")
    parser.add_argument("--bin-dir", type=Path, default=Path.home() / ".cargo/bin", help="Directory for the codex symlink (default: ~/.cargo/bin)")
    parser.add_argument("--rebuild", action="store_true", help="Build even when a complete current installation is present")
    parser.add_argument("--install-dir", type=Path, default=Path.home() / ".local/share/codex-source", help="Keep complete versioned packages here")
    parser.add_argument("--cache-dir", type=Path, default=Path.home() / ".cache/codex-source", help="Keep reusable Cargo build artifacts here")
    args = parser.parse_args()
    if sys.version_info < (3, 11):
        parser.error("Python 3.11 or newer is required")
    if sys.platform not in ("darwin", "linux"):
        parser.error("This installer supports macOS and Linux")
    for command in ["git"]:
        if not shutil.which(command):
            raise RuntimeError(f"Required command is missing: {command}")

    # Query upstream, not local tags. --refs excludes annotated-tag ^{} entries.
    refs = subprocess.check_output(
        ["git", "ls-remote", "--tags", "--refs", UPSTREAM, "rust-v*"], text=True
    )
    tag, object_id = latest_stable(refs)
    bin_dir = args.bin_dir.expanduser().resolve()
    install_dir = args.install_dir.expanduser().resolve()
    cache_dir = args.cache_dir.expanduser().resolve()
    launcher = bin_dir / "codex"
    print(f"Latest stable tag: {tag} ({object_id})", flush=True)
    if not args.rebuild and installed_is_current(launcher, tag.removeprefix("rust-v")):
        print(f"Already up to date: {launcher}; skipping build.")
        return
    print(f"Build: complete release package; packages: {install_dir}; command: {launcher}", flush=True)
    if args.dry_run:
        return
    for command in ["cargo", "rustup"]:
        if not shutil.which(command):
            raise RuntimeError(f"Required command is missing: {command}")

    cache_dir.mkdir(parents=True, exist_ok=True)
    install_dir.mkdir(parents=True, exist_ok=True)
    bin_dir.mkdir(parents=True, exist_ok=True)
    if launcher.is_dir():
        raise RuntimeError(f"Cannot replace directory: {launcher}")
    with (install_dir / ".install.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Another Codex installation is already running") from None
        with tempfile.TemporaryDirectory(prefix="checkout-", dir=cache_dir) as checkout:
            source = Path(checkout)
            run(["git", "init", "--quiet", source])
            run(["git", "-C", source, "fetch", "--depth=1", "--no-tags", UPSTREAM,
                 f"refs/tags/{tag}:refs/tags/{tag}"])
            fetched_id = subprocess.check_output(
                ["git", "-C", source, "rev-parse", f"refs/tags/{tag}"], text=True
            ).strip()
            if fetched_id != object_id:
                raise RuntimeError("Upstream tag moved during fetch; rerun to resolve it again")
            run(["git", "-C", source, "checkout", "--quiet", "--detach", f"refs/tags/{tag}"])
            builder = source / "scripts/build_codex_package.py"
            if not builder.is_file():
                raise RuntimeError(f"{tag} does not provide the complete-package builder")
            # Enter the Rust workspace so rustup selects the release's pinned toolchain.
            workspace = source / "codex-rs"
            run(["rustup", "show", "active-toolchain"], cwd=workspace)
            env = dict(os.environ, CODEX_REPO_ROOT=str(source),
                       CARGO_TARGET_DIR=str(cache_dir / "target"))
            # Stage on the installation filesystem; activate only after validation.
            with tempfile.TemporaryDirectory(prefix=".staging-", dir=install_dir) as staging:
                package = Path(staging) / "package"
                # Use the builder's default Cargo invocation: release tags can
                # need lockfile reconciliation in this disposable checkout.
                run([sys.executable, builder, "--cargo-profile", "release",
                     "--package-version", tag.removeprefix("rust-v"),
                     "--package-dir", package], cwd=workspace, env=env)
                run([package / "bin/codex", "--version"])
                if not installed_is_current(package / "bin/codex", tag.removeprefix("rust-v")):
                    raise RuntimeError("Built package failed its version or companion-file check")
                destination = install_dir / f"{tag}-{Path(staging).name.removeprefix('.staging-')}"
                package.rename(destination)
                # Use a temporary symlink for atomic replacement, preserving the old
                # launcher throughout failed builds. Old package directories stay usable.
                with tempfile.TemporaryDirectory(prefix=".codex-link-", dir=bin_dir) as links:
                    link = Path(links) / "codex"
                    link.symlink_to(destination / "bin/codex")
                    os.replace(link, launcher)

    print(f"Installed {tag}: {launcher}")
    print(f"Package retained at: {destination}")
    active = shutil.which("codex")
    if active is None or Path(active).resolve() != launcher.resolve():
        print(f"To use this installation, put {bin_dir} first on PATH:")
        print(f"  export PATH={shlex.quote(str(bin_dir))}:\"$PATH\"")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(f"error: {error}")
