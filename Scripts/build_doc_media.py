#!/usr/bin/env python3
"""Optimize real app captures and assemble a small, silent screenshot tour."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
SCREENS = [
    ("01-library", "library", "Your virtual machines", "Browse guest states, configured resources and total allocated memory."),
    ("02-new-vm", "new-vm", "Create a guest", "Choose a name, resources, owner setup and SSH. This example was cancelled."),
    ("03-guest-home", "guest-home", "Guest Home", "Select a guest to inspect its state, resources, clipboard and storage."),
    ("12-running", "running", "A running guest", "The current guest shows Shut Down controls. Configuration is locked until it stops."),
    ("05-configure", "configure", "Configure a stopped guest", "Save CPU, memory and display changes for the next start. This form was cancelled."),
    ("06-network", "network", "Networking", "Each SSH-enabled guest has a distinct localhost port. Networking uses NAT."),
    ("07-startup", "startup", "Startup and display", "Choose windowed or immersive mode. Opening the manager does not start guests."),
    ("08-ssh", "ssh", "SSH from this Mac", "A stopped guest is available on next launch. Copy SSH Command appears after verification."),
    ("09-spaces", "spaces", "Mission Control Spaces", "Use the running guest's Dock icon: Options, Assign To, This Desktop."),
    ("10-permissions", "permissions", "Super shortcuts", "Enable the manager in Accessibility yourself before starting guests."),
    ("11-runtime", "runtime", "Runtime and troubleshooting", "Check host readiness and the known graphics startup limitation."),
]


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True, stdout=subprocess.DEVNULL)


def timestamp(seconds):
    return f"{seconds // 3600:02}:{seconds // 60 % 60:02}:{seconds % 60:02}.000"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("captures", type=Path, help="Directory of original PNG screenshots captured through Computer Use")
    args = parser.parse_args()
    for tool in ("magick", "ffmpeg", "ffprobe"):
        if not shutil.which(tool): parser.error(f"{tool} is required")
    output = ROOT / "docs/media"
    stage = ROOT / ".build/user-doc-media"
    output.mkdir(parents=True, exist_ok=True)
    stage.mkdir(parents=True, exist_ok=True)
    font = Path("/System/Library/Fonts/Supplemental/Arial.ttf")
    if not font.is_file(): parser.error("The macOS Arial font is required for tour captions")
    manifest = {"appVersion": "0.5.1 (8)", "captureDate": "2026-10-31", "timezone": "Australia/Melbourne", "source": "real manager window captured through Computer Use", "tourKind": "captioned still-screen walkthrough, not a continuous recording", "screens": []}
    concat = ["ffconcat version 1.0"]
    subtitles = ["WEBVTT", ""]
    for index, (raw, name, title, caption) in enumerate(SCREENS):
        source = args.captures / (raw + ".png")
        if not source.is_file(): parser.error(f"Missing capture: {source}")
        image = output / (name + ".webp")
        run("magick", source, "-colorspace", "sRGB", "-resize", "1280x>", "-strip", "-quality", "90", "-define", "webp:method=6", image)
        frame = stage / f"frame-{index:02}.png"
        run("magick", "-size", "1280x960", "xc:#17191d", "(", image, "-resize", "1160x800>", ")", "-gravity", "center", "-geometry", "+0+20", "-composite",
            "-font", font, "-fill", "#f5f6f8", "-gravity", "northwest", "-pointsize", "28", "-annotate", "+52+18", f"{index + 1:02} / {len(SCREENS):02}   {title}",
            "-fill", "#b7bdc8", "-pointsize", "16", "-annotate", "+52+57", caption,
            "-gravity", "southwest", "-pointsize", "14", "-annotate", "+52+22", "Omarchy VM Manager 0.5.1  |  Captured screens  |  No guest lifecycle actions performed", "-strip", frame)
        concat.extend([f"file '{frame.name}'", "duration 4"])
        subtitles.extend([str(index + 1), f"{timestamp(index * 4)} --> {timestamp((index + 1) * 4)}", title + ". " + caption, ""])
        size = subprocess.check_output(["magick", "identify", "-format", "%wx%h", str(image)], text=True)
        manifest["screens"].append({"file": image.name, "title": title, "dimensions": size, "bytes": image.stat().st_size, "sha256": hashlib.sha256(image.read_bytes()).hexdigest(), "sourceSHA256": hashlib.sha256(source.read_bytes()).hexdigest()})
    concat.append(f"file 'frame-{len(SCREENS) - 1:02}.png'")
    playlist = stage / "tour.ffconcat"
    playlist.write_text("\n".join(concat) + "\n")
    video = output / "quick-tour.mp4"
    run("ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", playlist, "-vf", "fps=5", "-t", len(SCREENS) * 4,
        "-c:v", "libx264", "-preset", "slow", "-crf", "24", "-pix_fmt", "yuv420p", "-movflags", "+faststart", "-map_metadata", "-1", "-an", video)
    (output / "quick-tour.vtt").write_text("\n".join(subtitles))
    probe = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", str(video)], text=True))
    stream = probe["streams"][0]
    if stream["codec_name"] != "h264" or len(probe["streams"]) != 1 or float(probe["format"]["duration"]) != len(SCREENS) * 4:
        raise RuntimeError("Unexpected tour encoding")
    manifest["video"] = {"file": video.name, "bytes": video.stat().st_size, "durationSeconds": len(SCREENS) * 4, "dimensions": f"{stream['width']}x{stream['height']}", "codec": "H.264", "audio": False, "sha256": hashlib.sha256(video.read_bytes()).hexdigest()}
    total = sum(item["bytes"] for item in manifest["screens"]) + video.stat().st_size
    if total >= 2_000_000: raise RuntimeError("Documentation media exceeds the 2 MB budget")
    manifest["screenshotsAndVideoBytes"] = total
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"screenshots": len(SCREENS), "videoBytes": video.stat().st_size, "totalMediaBytes": total, "seconds": len(SCREENS) * 4}))


if __name__ == "__main__":
    main()
