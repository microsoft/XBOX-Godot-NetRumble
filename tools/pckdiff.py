"""Inspect or diff Godot .pck packages.

Written to diagnose silently-truncated exports. The failure that motivated it:
exporting with --headless skips Godot's D3D12 shader baking step, so the .pck
ships without any .d3d12xs.cache blobs and the title is killed at startup on
console. Nothing in the export log says so — the only signal is in the package.

    python tools/pckdiff.py <pck>                 summarise one package
    python tools/pckdiff.py <old_pck> <new_pck>   diff two packages

Supports pack format versions 1-3 (Godot 4.x). Version 3 moved the file table
to a trailing directory referenced by an offset in the header.
"""

import collections
import struct
import sys


def read_pck(path):
    with open(path, "rb") as handle:
        data = handle.read()

    if data[:4] != b"GDPC":
        raise SystemExit(f"{path}: not a Godot .pck (bad magic {data[:4]!r})")

    version = struct.unpack_from("<I", data, 4)[0]
    major, minor, patch = struct.unpack_from("<III", data, 8)

    cursor = 20
    if version >= 2:
        cursor += 4  # pack flags
        cursor += 8  # file base
    if version >= 3:
        directory = struct.unpack_from("<Q", data, cursor)[0]
        cursor = directory
    else:
        cursor += 16 * 4  # reserved

    count = struct.unpack_from("<I", data, cursor)[0]
    cursor += 4

    files = {}
    for _ in range(count):
        length = struct.unpack_from("<I", data, cursor)[0]
        cursor += 4
        name = data[cursor:cursor + length].rstrip(b"\0").decode("utf-8", "replace")
        cursor += length
        _offset, size = struct.unpack_from("<QQ", data, cursor)
        cursor += 16 + 16  # offset/size already read, then the md5
        if version >= 2:
            cursor += 4  # entry flags
        files[name] = size

    return {"engine": f"{major}.{minor}.{patch}", "version": version, "files": files}


def by_extension(files):
    totals = collections.Counter()
    counts = collections.Counter()
    for name, size in files.items():
        ext = name.rsplit(".", 1)[-1] if "." in name else "(none)"
        totals[ext] += size
        counts[ext] += 1
    return totals, counts


def summarise(path, pck):
    files = pck["files"]
    print(f"{path}")
    print(f"  engine {pck['engine']}  pack format {pck['version']}")
    print(f"  {len(files)} files, {sum(files.values()):,} bytes")

    shaders = [n for n in files if n.endswith(".d3d12xs.cache")]
    shader_bytes = sum(files[n] for n in shaders)
    if shaders:
        print(f"  d3d12 shader cache: {len(shaders)} blobs, {shader_bytes:,} bytes")
    else:
        print("  d3d12 shader cache: none")
        print("     Expected for the 'XBOX on PC' preset (shader_baker/enabled=false;")
        print("     desktop D3D12 compiles at runtime). For a console package this")
        print("     means the title will be terminated at startup (0x87E50006) --")
        print("     re-export without --headless.")

    totals, counts = by_extension(files)
    print("  largest types:")
    for ext, size in totals.most_common(8):
        print(f"    .{ext:<16} {counts[ext]:>4} files  {size:>12,} bytes")


def diff(old_path, old, new_path, new):
    summarise(old_path, old)
    print()
    summarise(new_path, new)

    a, b = old["files"], new["files"]
    removed = {k: v for k, v in a.items() if k not in b}
    added = {k: v for k, v in b.items() if k not in a}

    print()
    print(f"== Only in {new_path}: {len(added)} files, {sum(added.values()):,} bytes ==")
    for name, size in sorted(added.items(), key=lambda kv: -kv[1])[:15]:
        print(f"   {size:>10,}  {name}")

    print()
    print(f"== Only in {old_path}: {len(removed)} files, {sum(removed.values()):,} bytes ==")
    for name, size in sorted(removed.items(), key=lambda kv: -kv[1])[:15]:
        print(f"   {size:>10,}  {name}")


def main(argv):
    if len(argv) == 2:
        summarise(argv[1], read_pck(argv[1]))
    elif len(argv) == 3:
        diff(argv[1], read_pck(argv[1]), argv[2], read_pck(argv[2]))
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
