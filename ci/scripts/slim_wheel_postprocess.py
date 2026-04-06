#!/usr/bin/env python3
"""Post-process a query_farm_pyarrow_slim wheel to reduce size.

1. Remove C++ headers (include/ directory)
2. Remove test suite (tests/ directory)
3. Replace duplicate .so copies with symlinks
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


def repack_wheel(wheel_dir: Path, out_dir: Path) -> Path:
    """Repack a wheel directory into a .whl file."""
    # Find the .dist-info directory to get the wheel name
    dist_info = next(wheel_dir.glob("*.dist-info"))
    # Read WHEEL and METADATA to reconstruct the filename
    metadata = (dist_info / "METADATA").read_text()
    wheel_meta = (dist_info / "WHEEL").read_text()

    name = re.search(r"^Name: (.+)$", metadata, re.MULTILINE).group(1)
    version = re.search(r"^Version: (.+)$", metadata, re.MULTILINE).group(1)
    tag = re.search(r"^Tag: (.+)$", wheel_meta, re.MULTILINE).group(1)

    name_normalized = name.replace("-", "_")
    wheel_name = f"{name_normalized}-{version}-{tag}.whl"
    wheel_path = out_dir / wheel_name

    with zipfile.ZipFile(wheel_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for root, dirs, files in os.walk(wheel_dir):
            for f in files:
                fp = Path(root) / f
                arcname = fp.relative_to(wheel_dir)
                zf.write(fp, arcname)

    return wheel_path


def process_wheel(wheel_path: Path, out_dir: Path) -> Path:
    """Process a single wheel file."""
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp) / "wheel"
        work.mkdir()

        # Unpack
        with zipfile.ZipFile(wheel_path) as zf:
            zf.extractall(work)

        pyarrow_dir = work / "pyarrow"

        # 1. Remove C++ headers
        include_dir = pyarrow_dir / "include"
        if include_dir.exists():
            size_before = sum(f.stat().st_size for f in include_dir.rglob("*") if f.is_file())
            shutil.rmtree(include_dir)
            print(f"  Removed include/ ({size_before / 1048576:.1f} MB)")

        # 2. Remove test suite
        tests_dir = pyarrow_dir / "tests"
        if tests_dir.exists():
            size_before = sum(f.stat().st_size for f in tests_dir.rglob("*") if f.is_file())
            shutil.rmtree(tests_dir)
            print(f"  Removed tests/ ({size_before / 1048576:.1f} MB)")

        # 3. Deduplicate .so files — replace copies with symlinks
        # Pattern: libfoo.so, libfoo.so.2400, libfoo.so.2400.0.0
        # Keep the most-versioned file, symlink the rest
        so_files = {}
        for f in pyarrow_dir.glob("*.so*"):
            if f.is_file() and not f.name.startswith("_"):  # skip cpython extensions
                base = f.name.split(".so")[0]
                so_files.setdefault(base, []).append(f)

        for base, files in so_files.items():
            if len(files) <= 1:
                continue

            # Sort by name length — longest is most-versioned (the real file)
            files.sort(key=lambda f: len(f.name), reverse=True)
            real_file = files[0]

            # Check which files have the same content
            real_size = real_file.stat().st_size
            duplicates = [f for f in files[1:] if f.stat().st_size == real_size]

            for dup in duplicates:
                dup.unlink()
                dup.symlink_to(real_file.name)
                print(f"  Symlinked {dup.name} -> {real_file.name} (saved {real_size / 1048576:.1f} MB)")

        # 4. Regenerate RECORD file
        dist_info = next(work.glob("*.dist-info"))
        record_path = dist_info / "RECORD"
        records = []
        for root, dirs, files in os.walk(work):
            for f in files:
                fp = Path(root) / f
                rel = fp.relative_to(work)
                if rel == record_path.relative_to(work):
                    continue
                records.append(f"{rel},,")
        records.append(f"{record_path.relative_to(work)},,")
        record_path.write_text("\n".join(records) + "\n")

        # Repack
        out_dir.mkdir(parents=True, exist_ok=True)
        new_wheel = repack_wheel(work, out_dir)
        print(f"  Repacked: {new_wheel.name}")
        return new_wheel


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <wheel_path> [output_dir]")
        sys.exit(1)

    wheel_path = Path(sys.argv[1])
    out_dir = Path(sys.argv[2]) if len(sys.argv) > 2 else wheel_path.parent

    print(f"Processing {wheel_path.name}...")
    orig_size = wheel_path.stat().st_size

    new_wheel = process_wheel(wheel_path, out_dir)

    new_size = new_wheel.stat().st_size
    print(f"  {orig_size / 1048576:.1f} MB -> {new_size / 1048576:.1f} MB "
          f"({100 - new_size * 100 / orig_size:.0f}% smaller)")


if __name__ == "__main__":
    main()
