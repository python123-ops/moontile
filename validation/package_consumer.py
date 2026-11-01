"""Test a packaged MoonTile archive in a separate temporary MoonBit workspace.

The consumer and MoonTile sources are both taken from the package archive.
Dependencies other than MoonTile are resolved by `moon update` as usual.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", required=True, type=Path)
    args = parser.parse_args()
    archive = args.archive.resolve(strict=True)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    moon = shutil.which("moon")
    if moon is None:
        raise SystemExit("moon executable not found")
    with tempfile.TemporaryDirectory(prefix="moontile-package-consumer-") as temporary:
        root = Path(temporary).resolve()
        module = root / "moontile"
        module.mkdir()
        with zipfile.ZipFile(archive) as packaged:
            for item in packaged.infolist():
                # Extract only inside the new module directory on all platforms.
                name = item.filename
                target = (module / name).resolve()
                if "\\" in name or os.path.commonpath([str(module), str(target)]) != str(module):
                    raise SystemExit("unsafe package archive path: " + name)
                if item.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(packaged.read(item))
        consumer = root / "consumer"
        shutil.copytree(module / "examples" / "consumer", consumer)
        (consumer / "moon.work").write_text('members = [\n  ".",\n  "../moontile",\n]\n', encoding="utf8")
        print("Archive SHA-256:", digest, flush=True)
        print("Running independent consumer with packaged module and registry dependencies.", flush=True)
        subprocess.run([moon, "update"], cwd=consumer, check=True)
        subprocess.run([moon, "test", "--target", "all", "--deny-warn"], cwd=consumer, check=True)
        print("Packaged consumer passed on all four targets.", flush=True)


if __name__ == "__main__":
    main()
