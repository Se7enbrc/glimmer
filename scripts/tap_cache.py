"""Validate the dedicated Homebrew tap checkout before any destructive update."""

import argparse
from pathlib import Path
import subprocess


def paths_alias_or_overlap(directory: Path, first: str, second: str) -> bool:
    for existing, candidate in ((directory / first, directory / second),
                                (directory / second, directory / first)):
        if not existing.exists():
            continue
        for ancestor in (candidate, *candidate.parents):
            if ancestor == directory:
                break
            if ancestor.exists() and existing.samefile(ancestor):
                return True
    return False


def validate_cache(directory: Path, repo: str, remote_tip: str | None = None) -> None:
    if not directory.exists():
        return
    if not directory.is_dir():
        raise ValueError("tap cache path is not a directory")
    if not (directory / ".git").exists():
        if any(directory.iterdir()):
            raise ValueError("tap cache contains files but is not a Git checkout; choose an empty directory")
        return

    def git(*args: str) -> str:
        return subprocess.run(["git", "-C", str(directory), *args], check=True,
                              capture_output=True, text=True).stdout.rstrip("\n")

    if Path(git("rev-parse", "--show-toplevel")).resolve() != directory.resolve():
        raise ValueError("tap cache path is not the checkout root")
    if git("rev-parse", "--abbrev-ref", "HEAD") != "main":
        raise ValueError("tap cache must be on main; preserve other branches before updating")
    allowed = {f"git@github.com:{repo}.git", f"https://github.com/{repo}.git",
               f"https://github.com/{repo}", f"ssh://git@github.com/{repo}.git"}
    for options in (("--all",), ("--push", "--all")):
        if any(url not in allowed for url in git("remote", "get-url", *options, "origin").splitlines()):
            raise ValueError(f"tap cache origin does not match {repo}; choose the dedicated tap checkout")
    if git("status", "--porcelain", "--untracked-files=all"):
        raise ValueError("tap cache has local changes; commit or move them before updating")
    if remote_tip:
        ancestry = subprocess.run(["git", "-C", str(directory), "merge-base", "--is-ancestor", "HEAD", remote_tip],
                                  capture_output=True)
        if ancestry.returncode != 0:
            raise ValueError("updating the tap cache would discard local commits; preserve them first")
        ignored = git("ls-files", "--others", "--ignored", "--exclude-standard", "-z").split("\0")[:-1]
        incoming = git("ls-tree", "-r", "--name-only", "-z", remote_tip).split("\0")[:-1]
        for local in ignored:
            if any(local == path or local.startswith(path + "/") or path.startswith(local + "/")
                   or paths_alias_or_overlap(directory, local, path)
                   for path in incoming):
                raise ValueError("updating the tap cache would overwrite ignored files; move them first")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("repo")
    parser.add_argument("--remote-tip")
    args = parser.parse_args()
    try:
        validate_cache(args.directory, args.repo, args.remote_tip)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"ERR: {error}\n")


if __name__ == "__main__":
    main()
