#!/usr/bin/env python3
"""Build the reviewed Windows packages from local files (Python 3.8+).

No network access, game modifications, or overwriting of existing build outputs.
The verification reports are historical records copied without modification;
this script verifies packaging integrity, not game behavior.
"""

import argparse
import hashlib
import json
import re
import shutil
import sys
import zipfile
from pathlib import Path, PurePosixPath


REPO = Path(__file__).resolve().parent.parent
PACKAGE_NAMES = {
    "online": "BeingADIK_CN_0.8.3_S1-S2_20261003",
    "offline": "BeingADIK_CN_0.8.3_S1-S2_20261003_OFFLINE",
}
ARCHIVE_PATH = "cache/BAD_CN_0.09.rar"
CHUNK_SIZE = 1024 * 1024


class BuildError(Exception):
    pass


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(CHUNK_SIZE), b""):
            digest.update(block)
    return digest.hexdigest()


def relative_path(value):
    if not isinstance(value, str) or not value or "\\" in value or ":" in value:
        raise BuildError("Invalid package path: {!r}".format(value))
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts or path.as_posix() != value:
        raise BuildError("Unsafe or non-canonical package path: {!r}".format(value))
    return path


def checked_file(path, expected, label):
    if not path.is_file():
        raise BuildError("Missing {}: {}".format(label, path))
    size = expected.get("bytes")
    digest = expected.get("sha256", "")
    if not isinstance(size, int) or isinstance(size, bool) or size < 0:
        raise BuildError("Invalid byte count for {}".format(label))
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise BuildError("Invalid SHA-256 for {}".format(label))
    if path.stat().st_size != size:
        raise BuildError("Size mismatch for {}: {}".format(label, path))
    if sha256(path) != digest:
        raise BuildError("SHA-256 mismatch for {}: {}".format(label, path))


def files_below(directory):
    if not directory.is_dir():
        raise BuildError("Missing source directory: {}".format(directory))
    found = []
    for path in directory.rglob("*"):
        if path.is_symlink():
            raise BuildError("Source symlinks are not supported: {}".format(path))
        if path.is_file():
            path.resolve().relative_to(REPO)
            found.append(path)
    return sorted(found, key=lambda p: p.relative_to(directory).as_posix())


def prepare(mode, base_archive):
    source = REPO / "packaging" / mode
    manifest_path = source / "package.json"
    with manifest_path.open("r", encoding="utf-8-sig") as handle:
        manifest = json.load(handle)
    if manifest.get("format") != 1:
        raise BuildError("Unsupported package manifest format")
    if bool(manifest.get("offline_only", False)) != (mode == "offline"):
        raise BuildError("Package offline_only setting does not match build mode")

    inputs = {}

    def add(relative, path):
        relative_path(relative)
        if relative.casefold() in {name.casefold() for name in inputs}:
            raise BuildError("Duplicate package destination: {}".format(relative))
        inputs[relative] = path

    for path in files_below(source):
        relative = path.relative_to(source).as_posix()
        if relative == "SHA256SUMS.txt" or relative.startswith(("cache/", "payload/")):
            raise BuildError("Unexpected generated file in packaging source: {}".format(relative))
        add(relative, path)

    payload_source = REPO / "payload"
    payload_entries = manifest.get("payload_files", [])
    declared_payload = set()
    for entry in payload_entries:
        relative = relative_path(entry["path"]).as_posix()
        path = payload_source / relative
        checked_file(path, entry, "payload")
        add("payload/" + relative, path)
        declared_payload.add(relative)
    actual_payload = {p.relative_to(payload_source).as_posix() for p in files_below(payload_source)}
    if not declared_payload or declared_payload != actual_payload:
        raise BuildError("Payload file list differs from package.json")

    for path in files_below(REPO / "tools" / "unrar"):
        add("tools/" + path.name, path)
    for entry in manifest.get("tool_files", []):
        relative = relative_path(entry["path"]).as_posix()
        if relative not in inputs:
            raise BuildError("Declared tool is missing: {}".format(relative))
        checked_file(inputs[relative], entry, "tool")
    if "tools/UnRAR.exe" not in inputs or "tools/UnRAR-license.txt" not in inputs:
        raise BuildError("UnRAR executable and its license must both be present")

    if mode == "offline":
        if base_archive is None:
            raise BuildError("Offline builds require --base-archive pointing to the original RAR")
        checked_file(base_archive, manifest["upstream"], "upstream archive")
        add(ARCHIVE_PATH, base_archive)
    return inputs


def preflight_output(output, modes):
    # Never write generated outputs inside the inputs or a source checkout path.
    protected = [REPO / "packaging", REPO / "payload", REPO / "tools"]
    for source in protected:
        if output == source or source in output.parents or output in source.parents:
            raise BuildError("Output overlaps source inputs: {}".format(output))
    for mode in modes:
        name = PACKAGE_NAMES[mode]
        for path in (output / name, output / (name + ".zip"), output / (name + ".zip.sha256")):
            if path.exists() or path.is_symlink():
                raise BuildError("Output already exists; choose a new --output directory: {}".format(path))


def build(mode, inputs, output):
    name = PACKAGE_NAMES[mode]
    stage = output / name
    stage.mkdir(parents=True, exist_ok=False)
    for relative, source in sorted(inputs.items()):
        destination = stage / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        # Exclusive creation also protects against a concurrently created file.
        with source.open("rb") as src, destination.open("xb") as dst:
            shutil.copyfileobj(src, dst, CHUNK_SIZE)
        if sha256(destination) != sha256(source):
            raise BuildError("Copied file failed integrity check: {}".format(relative))

    stage_files = sorted((p for p in stage.rglob("*") if p.is_file()),
                         key=lambda p: p.relative_to(stage).as_posix())
    with (stage / "SHA256SUMS.txt").open("x", encoding="utf-8", newline="\n") as handle:
        for path in stage_files:
            handle.write("{}  {}\n".format(sha256(path), path.relative_to(stage).as_posix()))
    stage_files.append(stage / "SHA256SUMS.txt")

    archive = output / (name + ".zip")
    with zipfile.ZipFile(str(archive), "x", compression=zipfile.ZIP_DEFLATED,
                         compresslevel=9, allowZip64=True) as package:
        for path in sorted(stage_files, key=lambda p: p.relative_to(stage).as_posix()):
            relative = path.relative_to(stage).as_posix()
            # Fixed timestamp and permissions make repeated builds reproducible.
            info = zipfile.ZipInfo(name + "/" + relative, date_time=(2026, 10, 3, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.compress_type = zipfile.ZIP_STORED if relative.endswith(".rar") else zipfile.ZIP_DEFLATED
            with path.open("rb") as src, package.open(info, "w", force_zip64=True) as dst:
                shutil.copyfileobj(src, dst, CHUNK_SIZE)
    # Decompress every ZIP entry and compare it to its staged source.
    with zipfile.ZipFile(str(archive), "r") as package:
        for entry in package.infolist():
            relative = entry.filename[len(name) + 1:]
            digest = hashlib.sha256()
            with package.open(entry) as handle:
                for block in iter(lambda: handle.read(CHUNK_SIZE), b""):
                    digest.update(block)
            if digest.hexdigest() != sha256(stage / relative):
                raise BuildError("ZIP entry integrity check failed: {}".format(relative))
    checksum = sha256(archive)
    with (output / (name + ".zip.sha256")).open("x", encoding="utf-8", newline="\n") as handle:
        handle.write("{}  {}\n".format(checksum, archive.name))
    print("Built {} ({} bytes)".format(archive, archive.stat().st_size))
    print("SHA-256: {}".format(checksum))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("online", "offline", "all"), default="online")
    parser.add_argument("--base-archive", type=Path, help="Original CN_Ver0.09 RAR; required for offline/all")
    parser.add_argument("--output", type=Path, default=REPO / "dist", help="New build directory (default: repo/dist)")
    args = parser.parse_args()
    modes = ("online", "offline") if args.mode == "all" else (args.mode,)
    if "offline" in modes and args.base_archive is None:
        parser.error("--base-archive is required for offline/all; no files are downloaded")
    output = args.output.expanduser().resolve()
    base_archive = args.base_archive.expanduser().resolve() if args.base_archive else None
    try:
        preflight_output(output, modes)
        # Validate every selected package before creating any output.
        plans = {mode: prepare(mode, base_archive) for mode in modes}
        for mode in modes:
            build(mode, plans[mode], output)
    except (BuildError, OSError, ValueError, KeyError, zipfile.BadZipFile) as exc:
        print("Build failed: {}".format(exc), file=sys.stderr)
        print("Existing files were not overwritten or removed. If a partial build was created, choose a new --output directory.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
