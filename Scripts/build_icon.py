#!/usr/bin/env python3
"""Render editable manager artwork and package the full macOS icon family."""
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "App/Assets"
BUILD = ROOT / ".build/manager-icon"


def run(*arguments):
    subprocess.run([str(value) for value in arguments], check=True)


def main():
    BUILD.mkdir(parents=True, exist_ok=True)
    iconset = BUILD / "OmarchyVMManager.iconset"
    iconset.mkdir(exist_ok=True)
    master = ASSETS / "OmarchyVMManager.png"
    run("swift", ROOT / "Vendor/try-omarchy/macos/render-app-icon.swift", ASSETS / "OmarchyVMManager.svg", master)
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = points * scale
            name = f"icon_{points}x{points}" + ("@2x" if scale == 2 else "") + ".png"
            run("sips", "-z", pixels, pixels, master, "--out", iconset / name)
    run(sys.executable, ROOT / "Vendor/try-omarchy/macos/pack-app-icon.py", iconset, ASSETS / "OmarchyVMManager.icns")
    shutil.copy2(iconset / "icon_256x256.png", ASSETS / "OmarchyVMManager-preview.png")
    print("Manager artwork: SVG, 1024px PNG and ten ICNS representations")


if __name__ == "__main__":
    main()
