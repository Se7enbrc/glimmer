"""Commit one release metadata file through GitHub's verified-commit API."""

import argparse
import base64
import json
from pathlib import Path, PurePosixPath
import re
import subprocess

MUTATION = """mutation($input: CreateCommitOnBranchInput!) {
  createCommitOnBranch(input: $input) {
    commit { oid signature { isValid wasSignedByGitHub } }
  }
}"""


def commit_file(repository: str, expected_head: str, path: str, file: Path, message: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Invalid repository for release metadata commit.")
    if not re.fullmatch(r"[0-9a-f]{40}", expected_head):
        raise ValueError("Release metadata commit needs a full expected head SHA.")
    relative = PurePosixPath(path)
    if not path or relative.is_absolute() or ".." in relative.parts or str(relative) != path:
        raise ValueError("Release metadata path must be relative to the repository.")
    if not message or "\n" in message or "\r" in message:
        raise ValueError("Release metadata commit needs a single-line message.")
    request = {
        "query": MUTATION,
        "variables": {"input": {
            "branch": {"repositoryNameWithOwner": repository, "branchName": "main"},
            "expectedHeadOid": expected_head,
            "message": {"headline": message},
            "fileChanges": {"additions": [{"path": path, "contents": base64.b64encode(file.read_bytes()).decode("ascii")}]},
        }},
    }
    try:
        result = subprocess.run(["gh", "api", "graphql", "--input", "-"], input=json.dumps(request),
                                text=True, capture_output=True, timeout=60, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ValueError("GitHub commit request failed. Check the remote branch before retrying; it may have changed.") from error
    if result.returncode:
        raise ValueError("GitHub commit request failed. The remote may already have changed; inspect it before retrying.")
    try:
        response = json.loads(result.stdout)
        if response.get("errors"):
            raise ValueError("GraphQL errors")
        commit = response["data"]["createCommitOnBranch"]["commit"]
        signature = commit["signature"]
        if signature["isValid"] is not True or signature["wasSignedByGitHub"] is not True:
            raise ValueError("Unverified signature")
        oid = commit["oid"]
        if not isinstance(oid, str) or not re.fullmatch(r"[0-9a-f]{40}", oid):
            raise ValueError("Invalid commit ID")
    except (ValueError, TypeError, KeyError, AttributeError) as error:
        raise ValueError("GitHub did not confirm a verified commit. The remote may already have changed; inspect it before retrying.") from error
    return oid


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository")
    parser.add_argument("expected_head")
    parser.add_argument("path")
    parser.add_argument("file", type=Path)
    parser.add_argument("message")
    args = parser.parse_args()
    try:
        oid = commit_file(args.repository, args.expected_head, args.path, args.file, args.message)
    except OSError:
        parser.exit(1, "ERR: Couldn't read the release metadata file.\n")
    except ValueError as error:
        parser.exit(1, f"ERR: {error}\n")
    print(oid)


if __name__ == "__main__":
    main()
