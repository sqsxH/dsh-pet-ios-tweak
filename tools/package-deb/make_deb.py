#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Assemble a rootless iOS .deb with Python stdlib only (no dpkg-deb needed).

IMPORTANT — read this before using the output:
  A *functional* dsh-pet tweak needs dshpet.dylib, built by Theos + Xcode
  clang on macOS (arm64 + arm64e new ABI). That dylib CANNOT be produced on
  this Windows host. Running this script WITHOUT --dylib yields a
  structurally valid .deb (dpkg can parse/install it) that contains the
  control metadata, the Substrate filter plist and asset placeholders —
  but NO injected binary, so the pet will not appear on the home screen.

  Once the cloud build (GitHub Actions macos-14) produces dshpet.dylib,
  re-run with:
      python make_deb.py --dylib <path/to/dshpet.dylib> --out <output.deb>
  to get the complete, installable package.

Layout (rootless, /var/jb):
  ./var/jb/Library/MobileSubstrate/DynamicLibraries/dshpet.plist
  ./var/jb/Library/MobileSubstrate/DynamicLibraries/dshpet.dylib   (only with --dylib)
  ./var/jb/Library/Application Support/dsh-pet/README.txt
  ./var/jb/Library/Application Support/dsh-pet/BUILD-NEEDED.txt
"""
import argparse, io, os, tarfile, time

PKG_ID = "com.yourid.dshpet"
VERSION = "0.0.1"
ARCH = "iphoneos-arm64"
ROOTLESS = "./var/jb"

CONTROL = ("Package: " + PKG_ID + "\n"
    "Name: dsh-pet\n"
    "Version: " + VERSION + "\n"
    "Section: Tweaks\nPriority: optional\n"
    "Architecture: " + ARCH + "\n"
    "Depends: firmware (>= 15.0), mobilesubstrate (>= 0.9.7100) | ellekit\n"
    "Maintainer: YourID <you@example.com>\nAuthor: YourID\n"
    "Description: Floating desktop pet for SpringBoard (rootless)\n"
    " dsh-pet renders an animated, draggable, tappable floating pet on the\n"
    " iOS home screen inside SpringBoard. First release includes a transparent\n"
    " passthrough overlay, WebP sequence-frame animation, drag with spring-back\n"
    " and screen clamping, and 5-way tap response animations.\n"
    " Rootless (/var/jb) build.\n")

POSTINST = ("#!/bin/sh\n"
    "echo \"dsh-pet installed to /var/jb.\"\n"
    "echo \"Activate with: killall -9 SpringBoard (run as root)\"\n"
    "exit 0\n")

FILTER_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Filter</key>
  <dict>
    <key>Bundles</key>
    <array><string>com.apple.springboard</string></array>
  </dict>
</dict>
</plist>"""

ASSET_README = """dsh-pet animation assets (rootless)
====================================
Each animation folder contains anim.json and frames/frame_00001.webp ...
Generate from the 8 WebM sources with:
  SRC_DIR=<dsh-pet>/assets/webm OUT_ROOT=<this-dir> bash transcode.sh <names...>
The GitHub Actions workflow performs this automatically. See tweak/README.md."""

BUILD_NEEDED = """*** INCOMPLETE PACKAGE - READ ME ***
This .deb was assembled locally on Windows. It contains NO dshpet.dylib:
an arm64e (A14 / iPhone 12) tweak binary cannot be compiled on Linux/Windows
because ld64/ldid are Apple-only.

To make it functional:
  1. Push this repo to GitHub and let .github/workflows/build-tweak.yml
     (macos-14 + Theos, THEOS_PACKAGE_SCHEME=rootless) produce dshpet.dylib.
  2. Re-run make_deb.py with --dylib <built dshpet.dylib>.
  3. Install on the jailbroken iPhone 12:
       dpkg -i com.yourid.dshpet_0.0.1_iphoneos-arm64.deb
       killall -9 SpringBoard
Without steps 1-2 the package installs cleanly but the pet will not appear."""


def tar_gz(entries):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz", format=tarfile.GNU_FORMAT) as tf:
        now = int(time.time())
        for name, payload, mode in entries:
            info = tarfile.TarInfo(name)
            info.mtime = now; info.uid = 0; info.gid = 0
            info.uname = "root"; info.gname = "wheel"
            if name.endswith("/"):
                info.type = tarfile.DIRTYPE; info.mode = 0o755
                tf.addfile(info); continue
            info.type = tarfile.REGTYPE; info.mode = mode
            data = payload.encode("utf-8") if isinstance(payload, str) else payload
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))
    return buf.getvalue()


def ar_header(name, size, mode=0o644):
    n = name.encode("ascii")
    if len(n) > 16:
        raise ValueError("ar member name too long: " + name)
    h = n.ljust(16, b" ")
    h += b"0".ljust(12, b" ")
    h += b"0".ljust(6, b" ")
    h += b"0".ljust(6, b" ")
    h += oct(mode).encode().ljust(8, b" ")
    h += str(size).encode().ljust(10, b" ")
    h += bytes([0x60, 0x0A])   # ar magic: backtick + LF
    assert len(h) == 60, "bad ar header length"
    return h


def build(dylib_path, out_path):
    control_entries = [("./", b"", 0o755), ("./control", CONTROL, 0o644), ("./postinst", POSTINST, 0o755)]
    control_tar = tar_gz(control_entries)

    dl = ROOTLESS + "/Library/MobileSubstrate/DynamicLibraries"
    assets = ROOTLESS + "/Library/Application Support/dsh-pet"
    data_entries = [
        ("./", b"", 0o755), (ROOTLESS + "/", b"", 0o755),
        (ROOTLESS + "/Library/", b"", 0o755),
        (ROOTLESS + "/Library/MobileSubstrate/", b"", 0o755),
        (dl + "/", b"", 0o755), (assets + "/", b"", 0o755),
        (dl + "/dshpet.plist", FILTER_PLIST, 0o644),
        (assets + "/README.txt", ASSET_README, 0o644),
        (assets + "/BUILD-NEEDED.txt", BUILD_NEEDED, 0o644),
    ]
    if dylib_path:
        if not os.path.isfile(dylib_path):
            raise SystemExit("dylib not found: " + dylib_path)
        with open(dylib_path, "rb") as f:
            dylib_data = f.read()
        data_entries.append((dl + "/dshpet.dylib", dylib_data, 0o755))
        print("[i] embedding dylib: %s (%d bytes)" % (dylib_path, len(dylib_data)))
    else:
        print("[!] NO dylib supplied — building STRUCTURAL skeleton package.")
    data_tar = tar_gz(data_entries)

    out = bytearray(b"!<arch>\n")
    for name, data in (("debian-binary", b"2.0\n"), ("control.tar.gz", control_tar), ("data.tar.gz", data_tar)):
        out += ar_header(name, len(data))
        out += data
        if len(data) % 2:
            out += b"\n"
    parent = os.path.dirname(os.path.abspath(out_path))
    if parent and not os.path.isdir(parent):
        os.makedirs(parent)
    with open(out_path, "wb") as f:
        f.write(out)
    print("[+] wrote %s (%d bytes)" % (out_path, len(out)))
    return out_path


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--dylib", help="path to Theos-built dshpet.dylib (optional)")
    ap.add_argument("--out", required=True, help="output .deb path")
    a = ap.parse_args()
    build(a.dylib, a.out)