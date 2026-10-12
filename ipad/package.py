"""Packs the iPad app and the backlight tweak into one .deb inside a flat Cydia source, without dpkg.
Usage: python3 -I ipad/package.py <ScreenPad.app> <ScreenPadBacklight.dylib> <source icon.png> <repo dir>
The repo dir is what gets published (GitHub Pages, gh-pages branch): add its URL as a source in Cydia."""
import bz2, gzip, hashlib, io, plistlib, sys, tarfile, time
from pathlib import Path

app, tweak, icon, repo = map(Path, sys.argv[1:5])
VERSION = plistlib.loads((app / "Info.plist").read_bytes())["CFBundleShortVersionString"]
CONTROL = f"""Package: fr.krnd.screenpad
Name: Screen Pad
Version: {VERSION}
Architecture: iphoneos-arm
Depends: mobilesubstrate, uikittools
Section: Utilities
Maintainer: Kitround
Author: Kitround
Homepage: https://github.com/Kitround/screenpad
Description: Use the iPad as an extra display for your Mac, over USB. Needs the Screen Pad Mac app.
"""
RELEASE = """Origin: Screen Pad
Label: Screen Pad
Suite: stable
Version: 1.0
Codename: ios
Architectures: iphoneos-arm
Components: main
Description: Screen Pad, an iPad as an extra display for the Mac
"""
# Registers the app on the home screen; tells Cydia to restart SpringBoard, which loads the tweak.
POSTINST = b"""#!/bin/sh
su mobile -c uicache
[ -n "$CYDIA" ] && eval "echo finish:restart >&${CYDIA%% *}"
exit 0
"""
POSTRM = b"""#!/bin/sh
su mobile -c uicache
exit 0
"""
LIBRARIES = "./Library/MobileSubstrate/DynamicLibraries/"
FILTER = b'{ Filter = { Bundles = ( "com.apple.springboard" ); }; }\n'  # load into SpringBoard only


def tar_gz(files):
    """files: {"./path": (data, mode)}; adds the parent directories, owned by root as dpkg-deb does."""
    entries = {}
    for path in files:
        parts = path.split("/")
        for i in range(1, len(parts)):
            entries.setdefault("/".join(parts[:i]) + "/", None)
        entries[path] = files[path]
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz", format=tarfile.USTAR_FORMAT) as tar:
        for name, content in entries.items():
            info = tarfile.TarInfo(name)
            info.uid = info.gid = 0
            info.uname, info.gname = "root", "wheel"
            info.mtime = int(time.time())
            if content is None:
                info.type, info.mode = tarfile.DIRTYPE, 0o755
                tar.addfile(info)
            else:
                data, info.mode = content
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


def ar(members):
    out = b"!<arch>\n"
    for name, data in members:
        out += f"{name:<16}{int(time.time()):<12}{0:<6}{0:<6}{'100644':<8}{len(data):<10}`\n".encode() + data
        if len(data) % 2:
            out += b"\n"
    return out


def ar_members(deb):
    members, i = {}, 8
    while i < len(deb):
        name, size = deb[i:i + 16].decode().strip(), int(deb[i + 48:i + 58])
        members[name] = deb[i + 60:i + 60 + size]
        i += 60 + size + size % 2
    return members


data = {LIBRARIES + "ScreenPadBacklight.dylib": (tweak.read_bytes(), 0o755),
        LIBRARIES + "ScreenPadBacklight.plist": (FILTER, 0o644)}
for file in sorted(p for p in app.rglob("*") if p.is_file()):
    executable = file.name == "ScreenPad"
    data[f"./Applications/{app.name}/{file.relative_to(app)}"] = (file.read_bytes(), 0o755 if executable else 0o644)
deb = ar([
    ("debian-binary", b"2.0\n"),
    ("control.tar.gz", tar_gz({"./control": (CONTROL.encode(), 0o644), "./postinst": (POSTINST, 0o755),
                               "./postrm": (POSTRM, 0o755)})),
    ("data.tar.gz", tar_gz(data)),
])
# Self-check: the archive reads back with the app and the tweak where iOS and Substrate look for them.
names = tarfile.open(fileobj=io.BytesIO(ar_members(deb)["data.tar.gz"])).getnames()
assert list(ar_members(deb))[0] == "debian-binary", ar_members(deb).keys()
assert {LIBRARIES + "ScreenPadBacklight.dylib", "./Applications/ScreenPad.app/ScreenPad"} <= set(names), names

name = f"debs/screenpad_{VERSION}_iphoneos-arm.deb"
(repo / "debs").mkdir(parents=True, exist_ok=True)
for old in (repo / "debs").glob("*.deb"):
    old.unlink()
(repo / name).write_bytes(deb)
packages = (CONTROL + f"Filename: {name}\nSize: {len(deb)}\nMD5sum: {hashlib.md5(deb).hexdigest()}\n"
            + f"SHA256: {hashlib.sha256(deb).hexdigest()}\n\n").encode()
(repo / "Packages").write_bytes(packages)
(repo / "Packages.gz").write_bytes(gzip.compress(packages))
(repo / "Packages.bz2").write_bytes(bz2.compress(packages))
(repo / "Release").write_text(RELEASE)
(repo / "CydiaIcon.png").write_bytes(icon.read_bytes())
print(f"{repo / name}: {len(deb)} bytes")
