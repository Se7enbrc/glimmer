#!/usr/bin/env python3
"""Promote an attested candidate without rebuilding or changing its assets."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from release_validation import validate_feed

REPO = "Se7enbrc/glimmer"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
WORKFLOW = f"{REPO}/.github/workflows/release.yml"


def command(args, message):
    result = subprocess.run(args, capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise ValueError(message)
    return result.stdout


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def directory():
    root = Path(os.environ["RUNNER_TEMP"])
    run, attempt = os.environ["GITHUB_RUN_ID"], os.environ["GITHUB_RUN_ATTEMPT"]
    if not root.is_absolute() or not root.is_dir() or not run.isdigit() or not attempt.isdigit():
        raise ValueError("invalid promotion run")
    return root / f"glimmer-promotion-{run}-{attempt}"


def source(tag, sha):
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("candidate SHA must be a full lowercase commit SHA")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+-rc\.[1-9][0-9]*", tag):
        raise ValueError("invalid candidate tag")
    command(["git", "fetch", "--quiet", "origin", "main", f"refs/tags/{tag}"], "cannot fetch candidate source")
    actual = command(["gh", "api", f"repos/{REPO}/commits/{tag}", "--jq", ".sha"], "cannot resolve candidate tag").strip()
    if actual != sha:
        raise ValueError("candidate tag does not identify the reviewed source")
    expected = os.environ["EXPECTED_SHA"]
    main = command(["git", "rev-parse", "origin/main"], "cannot resolve main").strip()
    if main != expected or command(["git", "rev-parse", "HEAD"], "cannot resolve checkout").strip() != expected:
        raise ValueError("main moved; review and dispatch its new SHA")
    command(["git", "diff", "--quiet", sha, expected, "--", ".", ":(exclude)appcast.xml"],
            "candidate source differs from reviewed main; build and test a new candidate")
    config = command(["git", "show", f"{sha}:Glimmer/Version.xcconfig"], "cannot read candidate version")
    values = dict(re.findall(r"^(MARKETING_VERSION|CURRENT_PROJECT_VERSION)\s*=\s*(\S+)\s*$", config, re.M))
    short, build = values["MARKETING_VERSION"], values["CURRENT_PROJECT_VERSION"]
    if tag.rsplit("-rc.", 1)[0] != short or not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("candidate version does not match its tag")
    return short, build, main


def release(tag, short):
    data = json.loads(command(["gh", "api", f"repos/{REPO}/releases/tags/{tag}"], "cannot read candidate release"))
    if data.get("draft") or data.get("tag_name") != tag:
        raise ValueError("candidate release is not published")
    names = {f"Glimmer-{short}.{suffix}" for suffix in ("dmg", "zip")}
    assets = [asset for asset in data.get("assets", []) if asset.get("name") in names]
    if len(assets) != 2 or {asset["name"] for asset in assets} != names:
        raise ValueError("candidate must contain exactly one DMG and one ZIP")
    if any(not asset.get("size") or asset.get("state") != "uploaded" for asset in assets):
        raise ValueError("candidate assets are incomplete")
    return data


def feed_item(short, build, tag):
    text = command(["git", "show", "origin/main:appcast.xml"], "cannot read current appcast")
    root = ET.fromstring(text)
    channel = root.find("channel")
    if channel is None:
        raise ValueError("appcast has no channel")
    item = validate_feed(channel, short, build, promote=True)
    if item is None:
        raise ValueError("candidate update is missing in the appcast")
    if item.findtext(f"{{{SPARKLE}}}channel", "") not in {"rc", ""}:
        raise ValueError("candidate belongs to a different update channel")
    enclosure = item.find("enclosure")
    url = f"https://github.com/{REPO}/releases/download/{tag}/Glimmer-{short}.zip"
    if enclosure is None or enclosure.get("url") != url:
        raise ValueError("candidate update points at different assets")
    return text, enclosure.attrib


def prepare(tag, sha):
    short, build, _ = source(tag, sha)
    data = release(tag, short)
    _, enclosure = feed_item(short, build, tag)
    root = directory()
    root.mkdir(mode=0o700)
    command(["gh", "release", "download", tag, "-R", REPO, "-p", f"Glimmer-{short}.dmg",
             "-p", f"Glimmer-{short}.zip", "-D", str(root)], "candidate download failed")
    hashes = {}
    for suffix in ("dmg", "zip"):
        path = root / f"Glimmer-{short}.{suffix}"
        if not path.is_file() or not path.stat().st_size:
            raise ValueError("candidate download is empty")
        command(["gh", "attestation", "verify", str(path), "--repo", REPO,
                 "--signer-workflow", WORKFLOW, "--source-ref", "refs/heads/release-candidate",
                 "--source-digest", sha], "candidate provenance verification failed")
        hashes[path.name] = digest(path)
    zip_path = root / f"Glimmer-{short}.zip"
    if enclosure.get("length") != str(zip_path.stat().st_size):
        raise ValueError("candidate ZIP differs from its signed update length")
    proof = {"tag": tag, "sha": sha, "short": short, "build": build,
             "release_id": data["id"], "hashes": hashes, "enclosure": enclosure}
    (root / "verified.json").write_text(json.dumps(proof))


def validate(tag, sha):
    short, build, main = source(tag, sha)
    data = release(tag, short)
    _, enclosure = feed_item(short, build, tag)
    root = directory()
    proof = json.loads((root / "verified.json").read_text())
    expected = {"tag": tag, "sha": sha, "short": short, "build": build,
                "release_id": data["id"], "enclosure": enclosure}
    if any(proof.get(key) != value for key, value in expected.items()):
        raise ValueError("candidate changed after provenance verification")
    names = {f"Glimmer-{short}.{suffix}" for suffix in ("dmg", "zip")}
    if set(proof.get("hashes", {})) != names:
        raise ValueError("candidate digest proof is incomplete")
    for name in names:
        if digest(root / name) != proof["hashes"][name]:
            raise ValueError("candidate bytes changed after provenance verification")
        asset = next(asset for asset in data["assets"] if asset["name"] == name)
        if asset.get("digest") != f"sha256:{proof['hashes'][name]}":
            raise ValueError("published candidate asset changed after verification")
    return proof, main


def publish(tag, sha):
    proof, main = validate(tag, sha)
    text, enclosure = feed_item(proof["short"], proof["build"], tag)
    appcast = directory() / "appcast.xml"
    appcast.write_text(text)
    command([sys.executable, "scripts/update-appcast.py", str(appcast), "--promote",
             "--short-version", proof["short"], "--version", proof["build"],
             "--url", enclosure["url"], "--ed-signature", enclosure[f"{{{SPARKLE}}}edSignature"],
             "--length", enclosure["length"]], "candidate appcast promotion rejected")
    command(["gh", "release", "edit", tag, "-R", REPO, "--prerelease=false", "--latest",
             "--title", f"Glimmer {proof['short']}"], "GitHub candidate promotion failed")
    if appcast.read_text() != text:
        command([sys.executable, "scripts/github_signed_commit.py", REPO, main, "appcast.xml", str(appcast),
                 f"appcast: promote Glimmer {proof['short']}"], "appcast changed; retry promotion from current main")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("prepare", "validate", "publish"))
    parser.add_argument("tag")
    parser.add_argument("sha")
    args = parser.parse_args()
    try:
        {"prepare": prepare, "validate": validate, "publish": publish}[args.phase](args.tag, args.sha)
    except (ValueError, KeyError, StopIteration, OSError, ET.ParseError,
            subprocess.TimeoutExpired) as error:
        parser.exit(1, f"ERR: {error}\n")
    print(f"Candidate {args.phase} succeeded without changing release assets.")


if __name__ == "__main__":
    main()
