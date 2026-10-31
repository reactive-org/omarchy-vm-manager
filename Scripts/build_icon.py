#!/usr/bin/env python3
"""Render editable manager artwork and package the full macOS icon family."""
from pathlib import Path
import hashlib
import json
import xml.etree.ElementTree as ET
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "App/Assets"
BUILD = ROOT / ".build/manager-icon"


def run(*arguments):
    subprocess.run([str(value) for value in arguments], check=True)


def main():
    source = (ASSETS / "OmarchyGuest-source.svg").read_bytes()
    metadata = json.loads((ASSETS / "OmarchyGuest-source.json").read_bytes())
    assert hashlib.sha256(source).hexdigest() == metadata["sourceSHA256"], "official guest logo source changed"
    source_paths = ET.fromstring(source).findall(".//{http://www.w3.org/2000/svg}path")
    rendered_paths = ET.parse(ASSETS / "OmarchyGuest.svg").findall(".//{http://www.w3.org/2000/svg}path")
    assert len(source_paths) == len(rendered_paths) == 1
    assert source_paths[0].attrib["d"] == rendered_paths[0].attrib["d"], "guest icon must preserve the official Omarchy mark"
    BUILD.mkdir(parents=True, exist_ok=True)
    for stem in ("OmarchyVMManager", "OmarchyGuest"):
        iconset = BUILD / (stem + ".iconset")
        iconset.mkdir(exist_ok=True)
        master = ASSETS / (stem + ".png")
        run("swift", ROOT / "Vendor/try-omarchy/macos/render-app-icon.swift", ASSETS / (stem + ".svg"), master)
        for points in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                pixels = points * scale
                name = f"icon_{points}x{points}" + ("@2x" if scale == 2 else "") + ".png"
                run("sips", "-z", pixels, pixels, master, "--out", iconset / name)
        run(sys.executable, ROOT / "Vendor/try-omarchy/macos/pack-app-icon.py", iconset, ASSETS / (stem + ".icns"))
        shutil.copy2(iconset / "icon_256x256.png", ASSETS / (stem + "-preview.png"))
    print("Manager and guest artwork: SVG, 1024px PNG and ten ICNS representations each")


if __name__ == "__main__":
    main()
