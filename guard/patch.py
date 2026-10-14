#!/usr/bin/env python3
"""Keep headless Chrome's helper processes out of the Dock.

T3 Code and Playwright launch chrome-headless-shell, which has no app
bundle. macOS files it and its helpers under the launching app and the
Dock inserts a tile for each launch. This wraps every chrome-headless-shell
so its child processes skip the Launch Services check-in (see chsguard.c).

Re-run after a browser download. A login item does that automatically.
The Claude and Codex functions below are kept for --restore and --check
only; those binaries are no longer modified.
"""

import os
import plistlib
import shutil
import struct
import subprocess
import sys
from pathlib import Path

HOME = Path.home()
SOURCE = Path(__file__).resolve().parent / "dockguard.m"
DYLIB = HOME / ".local" / "lib" / "dg.dylib"
CHS_LIB = HOME / ".local" / "lib" / "libchsguard.dylib"
CHS_SRC = Path(__file__).resolve().parent / "chsguard.c"
WRAP_SRC = Path(__file__).resolve().parent / "chs-wrap.c"
WRAP_BIN = HOME / ".local" / "lib" / "chs-wrap"
BACKUP_ROOT = HOME / "Library" / "Application Support" / "DockGuard" / "backups"
LOG = HOME / "Library" / "Logs" / "dockguard.log"
AGENT = HOME / "Library" / "LaunchAgents" / "local.dockguard.plist"

LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0x0C
MH_MAGIC_64 = 0xFEEDFACF
MH_MAGIC_FAT = 0xBEBAFECA


def log(message):
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open("a") as handle:
        handle.write(message.rstrip() + "\n")
    print(message)


def build_dylib():
    DYLIB.parent.mkdir(parents=True, exist_ok=True)
    if DYLIB.exists() and DYLIB.stat().st_mtime >= SOURCE.stat().st_mtime:
        return
    subprocess.check_call(
        [
            "clang",
            "-dynamiclib",
            "-framework",
            "AppKit",
            "-framework",
            "Foundation",
            "-install_name",
            str(DYLIB),
            "-o",
            str(DYLIB),
            str(SOURCE),
        ]
    )
    subprocess.check_call(["codesign", "--force", "--sign", "-", "--timestamp=none", str(DYLIB)])
    log("built %s" % DYLIB)


def build_chrome_guard():
    CHS_LIB.parent.mkdir(parents=True, exist_ok=True)
    if not CHS_LIB.exists() or CHS_LIB.stat().st_mtime < CHS_SRC.stat().st_mtime:
        subprocess.check_call(
            [
                "clang",
                "-dynamiclib",
                "-framework",
                "CoreFoundation",
                "-framework",
                "ApplicationServices",
                "-o",
                str(CHS_LIB),
                str(CHS_SRC),
            ]
        )
        subprocess.check_call(["codesign", "--force", "--sign", "-", "--timestamp=none", str(CHS_LIB)])
        log("built %s" % CHS_LIB)
    if not WRAP_BIN.exists() or WRAP_BIN.stat().st_mtime < WRAP_SRC.stat().st_mtime:
        subprocess.check_call(
            [
                "clang",
                "-O2",
                "-DCHS_GUARD_LIB=\"%s\"" % CHS_LIB,
                "-o",
                str(WRAP_BIN),
                str(WRAP_SRC),
            ]
        )
        subprocess.check_call(["codesign", "--force", "--sign", "-", "--timestamp=none", str(WRAP_BIN)])
        log("built %s" % WRAP_BIN)


def chrome_binaries():
    roots = [
        HOME / ".t3" / "tools" / "chrome-headless-shell",
        HOME / "Library" / "Caches" / "ms-playwright",
    ]
    found = []
    for root in roots:
        if not root.exists():
            continue
        for path in root.rglob("chrome-headless-shell"):
            if path.is_file() and not path.name.endswith(".real"):
                found.append(path)
    return found


def wrap_chrome(path):
    real = Path(str(path) + ".real")
    # A re-download drops a full browser binary back on the original path.
    if path.stat().st_size < 1000000 and real.exists():
        return
    if path.stat().st_size < 1000000:
        log("skip (unexpected small binary) %s" % path)
        return
    temporary = Path(str(path) + ".wrapnew")
    shutil.copy2(str(WRAP_BIN), str(temporary))
    os.chmod(temporary, 0o755)
    os.replace(str(path), str(real))
    try:
        os.replace(str(temporary), str(path))
    except Exception:
        os.replace(str(real), str(path))
        raise
    log("wrapped %s" % path)


def wrap_chromes():
    build_chrome_guard()
    for path in chrome_binaries():
        try:
            wrap_chrome(path)
        except Exception as error:
            log("chrome wrap failed %s: %s" % (path, error))


def agent_binaries():
    found = []
    versions = HOME / ".local" / "share" / "claude" / "versions"
    if versions.is_dir():
        for path in versions.iterdir():
            if path.is_file() and not path.name.endswith(".dockguard-new"):
                found.append(path)
    desktop = HOME / "Library" / "Application Support" / "Claude" / "claude-code"
    if desktop.is_dir():
        for path in desktop.glob("*/*/claude.app/Contents/MacOS/claude"):
            found.append(path)
    codex = HOME / ".codex" / "packages" / "standalone" / "releases"
    if codex.is_dir():
        for path in codex.glob("*/bin/codex"):
            found.append(path)
    unique = []
    seen = set()
    for path in found:
        try:
            resolved = path.resolve()
        except OSError:
            continue
        if resolved in seen or not resolved.is_file():
            continue
        seen.add(resolved)
        unique.append(resolved)
    return unique


def read_header(path):
    with path.open("rb") as handle:
        header = handle.read(4096)
    if len(header) < 32:
        return None
    magic = struct.unpack_from("<I", header, 0)[0]
    if magic != MH_MAGIC_64:
        return None
    ncmds, sizeofcmds = struct.unpack_from("<II", header, 16)
    need = 32 + sizeofcmds
    if len(header) < need:
        with path.open("rb") as handle:
            header = handle.read(need)
    return header, ncmds, sizeofcmds


def load_commands(header, ncmds):
    commands = []
    offset = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", header, offset)
        commands.append((cmd, cmdsize, offset))
        offset += cmdsize
    return commands


def first_section_offset(header, commands):
    earliest = None
    for cmd, cmdsize, offset in commands:
        if cmd != LC_SEGMENT_64:
            continue
        nsects = struct.unpack_from("<I", header, offset + 64)[0]
        section = offset + 72
        for _ in range(nsects):
            file_off = struct.unpack_from("<I", header, section + 48)[0]
            if file_off and (earliest is None or file_off < earliest):
                earliest = file_off
            section += 80
    return earliest


def already_patched(header, ncmds):
    del ncmds
    return str(DYLIB).encode() in header


def command_size(path_text):
    raw = 24 + len(path_text.encode()) + 1
    return (raw + 7) & ~7


def patch_file(path):
    parsed = read_header(path)
    if parsed is None:
        raise RuntimeError("not a thin arm64 Mach-O: %s" % path)
    header, ncmds, sizeofcmds = parsed
    if already_patched(header, ncmds):
        return False
    commands = load_commands(header, ncmds)
    section_off = first_section_offset(header, commands)
    header_end = 32 + sizeofcmds
    if section_off is None:
        raise RuntimeError("no section offset in %s" % path)
    size = command_size(str(DYLIB))
    slack = section_off - header_end
    if size > slack:
        raise RuntimeError("only %s bytes of header slack in %s, need %s" % (slack, path, size))
    command = bytearray(size)
    struct.pack_into("<IIIIII", command, 0, LC_LOAD_DYLIB, size, 24, 0, 0x10000, 0x10000)
    encoded = str(DYLIB).encode()
    command[24 : 24 + len(encoded)] = encoded
    with path.open("r+b") as handle:
        handle.seek(header_end)
        handle.write(command)
        handle.seek(16)
        handle.write(struct.pack("<II", ncmds + 1, sizeofcmds + size))
    return True


def identifier_of(path):
    result = subprocess.run(
        ["codesign", "-d", "-v", str(path)],
        capture_output=True,
        text=True,
    )
    text = result.stderr + result.stdout
    for line in text.splitlines():
        if line.startswith("Identifier="):
            return line.split("=", 1)[1].strip()
    return path.name


def entitlements_of(path, dest):
    result = subprocess.run(
        ["codesign", "-d", "--entitlements", ":-", str(path)],
        capture_output=True,
    )
    raw = result.stdout.strip()
    if raw:
        ent = plistlib.loads(raw)
    else:
        ent = {}
    ent["com.apple.security.cs.disable-library-validation"] = True
    dest.write_bytes(plistlib.dumps(ent, fmt=plistlib.FMT_XML))


def resign(path, ident, ent_path):
    subprocess.check_call(
        [
            "codesign",
            "--force",
            "--sign",
            "-",
            "--timestamp=none",
            "--options",
            "runtime",
            "--identifier",
            ident,
            "--entitlements",
            str(ent_path),
            str(path),
        ]
    )


def verify(path):
    try:
        result = subprocess.run(
            [str(path), "--version"],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except subprocess.TimeoutExpired:
        return False, "timed out"
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "exit %s" % result.returncode).strip()
        return False, detail.splitlines()[-1][:200]
    line = (result.stdout or result.stderr).strip().splitlines()
    return True, line[0] if line else "ok"


def backup_for(path):
    relative = Path(*path.parts[1:])
    return BACKUP_ROOT / relative


def protect(path):
    parsed = read_header(path)
    if parsed is None:
        log("skip (not thin arm64) %s" % path)
        return
    header, ncmds, _sizeof = parsed
    if already_patched(header, ncmds):
        return
    if not os.access(str(path), os.W_OK):
        log("skip (not writable) %s" % path)
        return
    temp = path.with_name(path.name + ".dockguard-new")
    ent = path.with_name(path.name + ".dockguard-ent.plist")
    try:
        shutil.copy2(str(path), str(temp))
        ident = identifier_of(path)
        entitlements_of(path, ent)
        changed = patch_file(temp)
        if not changed:
            return
        resign(temp, ident, ent)
        ok, detail = verify(temp)
        if not ok:
            log("reject %s: %s" % (path, detail))
            return
        destination = backup_for(path)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(str(path), str(destination))
        os.replace(str(temp), str(path))
        log("protected %s (%s)" % (path, detail))
    finally:
        if temp.exists():
            temp.unlink()
        if ent.exists():
            ent.unlink()


def restore():
    if not BACKUP_ROOT.exists():
        log("nothing to restore")
        return
    for backup in BACKUP_ROOT.rglob("*"):
        if not backup.is_file():
            continue
        relative = backup.relative_to(BACKUP_ROOT)
        dest = Path("/") / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        # Write to a new inode. Overwriting a signed binary in place leaves
        # the kernel with a stale code signature and SIGKILLs the next run.
        temp = dest.with_name(dest.name + ".restore-new")
        shutil.copy2(str(backup), str(temp))
        os.replace(str(temp), str(dest))
        log("restored %s" % dest)


def install_agent():
    watches = []
    for candidate in (
        HOME / ".local" / "share" / "claude" / "versions",
        HOME / "Library" / "Application Support" / "Claude" / "claude-code",
        HOME / ".codex" / "packages" / "standalone" / "releases",
        HOME / ".t3" / "tools" / "chrome-headless-shell",
        HOME / "Library" / "Caches" / "ms-playwright",
    ):
        if candidate.exists():
            watches.append(str(candidate))
    plist = {
        "Label": "local.dockguard",
        "ProgramArguments": ["/usr/bin/python3", str(Path(__file__).resolve())],
        "RunAtLoad": True,
        "WatchPaths": watches,
        "StartInterval": 300,
        "ThrottleInterval": 10,
    }
    AGENT.parent.mkdir(parents=True, exist_ok=True)
    AGENT.write_bytes(plistlib.dumps(plist, fmt=plistlib.FMT_XML))
    domain = "gui/%s" % os.getuid()
    subprocess.run(["launchctl", "bootout", domain, str(AGENT)], capture_output=True)
    subprocess.check_call(["launchctl", "bootstrap", domain, str(AGENT)])
    log("login item installed")


def check_copy():
    build_dylib()
    source = HOME / ".local" / "share" / "claude" / "versions"
    current = None
    link = HOME / ".local" / "bin" / "claude"
    if link.exists():
        current = link.resolve()
    elif source.is_dir():
        files = sorted(source.iterdir())
        current = files[-1] if files else None
    if current is None:
        raise SystemExit("no claude binary found")
    temp = Path("/tmp/dockguard-test-claude")
    if temp.exists():
        temp.unlink()
    shutil.copy2(str(current), str(temp))
    ident = identifier_of(temp)
    ent = Path("/tmp/dockguard-test-claude.ent.plist")
    entitlements_of(current, ent)
    patch_file(temp)
    resign(temp, ident, ent)
    ok, detail = verify(temp)
    listed = subprocess.run(["otool", "-L", str(temp)], capture_output=True, text=True)
    print(detail)
    print(listed.stdout)
    if not ok or str(DYLIB) not in listed.stdout:
        raise SystemExit("check failed")
    print("check ok", temp)


def main(argv):
    if "--restore" in argv:
        restore()
        return
    if "--check" in argv:
        check_copy()
        return
    # Do not inject into Claude or Codex. Loading that library crashes
    # Bun before main. The Dock tiles come from chrome-headless-shell.
    wrap_chromes()
    if "--install" in argv:
        install_agent()


if __name__ == "__main__":
    main(sys.argv[1:])
