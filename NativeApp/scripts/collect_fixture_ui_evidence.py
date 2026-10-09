#!/usr/bin/env python3
"""Export only named, cropped UI fixture screenshots from the simulator test runner."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess

EXPECTED = {
    "header-strip-Light", "header-canvas-Light", "header-strip-Dark", "header-canvas-Dark",
    "connector-directory", "connector-editor", "connector-reopened",
    "font-reference-Light", "font-reference-Dark",
}

def collect(log_path, device, output, test_outcome):
    records = {}
    marker = "MYCHAT_UI_EVIDENCE "
    for line in log_path.read_text().splitlines():
        if marker not in line:
            continue
        record = json.loads(line.split(marker, 1)[1])
        if set(record) != {"name", "bundle", "width", "height"}:
            raise ValueError("Unexpected screenshot metadata fields")
        name = record["name"]
        if name not in EXPECTED:
            raise ValueError("Unexpected screenshot name")
        if record["bundle"] != "com.mychat.ios.MyChatUITests.xctrunner":
            raise ValueError("Screenshot was not produced by the expected isolated test runner")
        if name in records and records[name] != record:
            raise ValueError("Conflicting screenshot metadata")
        records[name] = record
    if not records:
        raise ValueError("No approved fixture screenshot was produced")
    missing = sorted(EXPECTED - set(records))

    container = Path(subprocess.check_output([
        "xcrun", "simctl", "get_app_container", device,
        "com.mychat.ios.MyChatUITests.xctrunner", "data",
    ], text=True).strip()).resolve(strict=True)
    source = container / "Library" / "Caches" / "MyChatFixtureEvidence"
    verified = []
    for name in sorted(records):
        path = source / (name + ".png")
        if path.is_symlink() or not path.resolve(strict=True).is_relative_to(container):
            raise ValueError("Unexpected screenshot path")
        data = path.read_bytes()
        if not 24 < len(data) <= 2_000_000 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
            raise ValueError("Invalid or oversized PNG")
        width, height = struct.unpack(">II", data[16:24])
        if (width, height) != (records[name]["width"], records[name]["height"]):
            raise ValueError("PNG dimensions do not match the captured crop")
        if not 1 <= width <= 2048 or not 1 <= height <= 2400:
            raise ValueError("Screenshot is outside the bounded fixture dimensions")
        if name.startswith("header-canvas-") and (width > 40 or height > 40):
            raise ValueError("Canvas evidence must be only the small color swatch")
        if name.startswith("header-strip-") and height > 240:
            raise ValueError("Header evidence must be only the header control strip")
        verified.append((name + ".png", data, {
            "file": name + ".png", "width": width, "height": height,
            "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
        }))

    # Do not copy the result bundle, log, app container, or other cache contents.
    output.mkdir(parents=True, exist_ok=False)
    for name, data, _ in verified:
        (output / name).write_bytes(data)
    manifest = {"scope": "Cropped synthetic UI fixtures only; not user chat/account screenshots",
                "uiTestOutcome": test_outcome, "complete": not missing,
                "expectedCount": len(EXPECTED), "retainedCount": len(verified),
                "missing": missing, "images": [metadata for _, _, metadata in verified]}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Verified {len(verified)} of {len(EXPECTED)} fixture PNG crops; "
          f"missing: {', '.join(missing) or 'none'}; UI outcome: {test_outcome}. "
          "Only verified PNGs and the manifest will be uploaded.")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--device", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--test-outcome", choices=("success", "failure"), required=True)
    args = parser.parse_args()
    collect(args.log, args.device, args.output, args.test_outcome)

