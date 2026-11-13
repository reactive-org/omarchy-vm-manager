#!/usr/bin/env python3
"""Remove optional applications without replacing Omarchy's package/update policy."""

import argparse
import os
import platform
import re
import shutil
import subprocess
from pathlib import Path


PACKAGE_LIST = Path(__file__).with_name("lean-developer.packages")
# Include optional integration/desktop components: pacman only guards hard deps.
PROTECTED = set("""
base base-devel bash pacman pacman-contrib systemd polkit sudo openssh
networkmanager ufw ufw-docker btrfs-progs snapper limine
limine-mkinitcpio-hook limine-snapper-sync mkinitcpio
hyprland quickshell uwsm sddm mesa libdrm libglvnd
xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-hyprland
pipewire pipewire-audio pipewire-pulse wireplumber rtkit
gnome-keyring libsecret upower dkms v4l2loopback-dkms
fcitx5 fcitx5-chewing fcitx5-hangul fcitx5-mozc noto-fonts-cjk
foot chromium neovim git tmux mise-bin docker docker-buildx docker-compose
qemu-user-static qemu-user-static-binfmt mariadb-libs postgresql-libs
ruby libyaml libvips lua51 luarocks
wl-clipboard wf-recorder grim slurp ffmpeg jq gum python python-gobject
""".split())
PROTECTED_PREFIXES = ("omarchy-", "try-omarchy", "linux-", "ttf-jetbrains-mono")


def run(argv, *, check=True):
    return subprocess.run(
        argv, text=True, capture_output=True, check=check,
        env=dict(os.environ, LC_ALL="C"),
    )


def package_names(output):
    names = output.splitlines()
    if any(not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9@._+\-]*", name) for name in names):
        raise RuntimeError("Unexpected package names; refusing removal")
    return set(names)


def candidates():
    return [
        name for line in PACKAGE_LIST.read_text().splitlines()
        if (name := line.split("#", 1)[0].strip())
    ]


def apply(keep):
    if platform.machine() != "aarch64" or not shutil.which("omarchy"):
        raise RuntimeError("Run this inside the managed Omarchy aarch64 guest")
    if not shutil.which("omarchy-pkg-drop"):
        raise RuntimeError("Omarchy's native package removal command is required")
    installed = package_names(run(["pacman", "-Qq"]).stdout)
    if "try-omarchy" not in installed:
        raise RuntimeError("The required Try Omarchy integration package is missing")
    selected = candidates()
    package_names("\n".join(selected))  # Validate the tracked allowlist too.
    # Names explicitly requested by the operator always win over the profile.
    protected = PROTECTED | set(keep)
    pending = [name for name in selected if name in installed and name not in keep]
    print("Lean developer candidates: " + (", ".join(pending) or "none"), flush=True)
    retained = {}
    # Retrying lets us handle dependencies between candidates without cascading
    # into other installed software (e.g. a printing UI before its server).
    while pending:
        removed = []
        for name in pending:
            if name in removed:
                continue
            plan = run(
                # --nosave changes config-file handling, not dependency closure,
                # and pacman rejects combining it with --print.
                ["pacman", "-Rs", "--print", "--print-format", "%n", name],
                check=False,
            )
            if plan.returncode:
                if "could not satisfy dependencies" not in plan.stderr:
                    raise RuntimeError("Unable to preview removal: " + plan.stderr.strip())
                retained[name] = plan.stderr.strip()
                continue
            transaction = package_names(plan.stdout)
            if not transaction or name not in transaction:
                raise RuntimeError("Empty or inconsistent removal proposal; refusing removal")
            blocked = sorted(
                pkg for pkg in transaction
                if pkg in protected or pkg == "omarchy" or (
                    pkg.startswith(PROTECTED_PREFIXES)
                    and pkg != "omarchy-power-profiles-daemon"
                )
            )
            if blocked:
                retained[name] = "transaction would remove protected packages: " + ", ".join(blocked)
                continue
            print("Removing through Omarchy: " + ", ".join(sorted(transaction)), flush=True)
            # Omarchy owns the actual -Rns transaction, including its sudo prompt.
            result = run(["omarchy-pkg-drop", name])
            print(result.stdout, end="", flush=True)
            print(result.stderr, end="", flush=True)
            removed.extend(pkg for pkg in pending if pkg in transaction)
        if not removed:
            break
        pending = [name for name in pending if name not in removed]
    for name in pending:
        print(f"Retained {name}: {retained[name]}", flush=True)
    print("Lean developer profile applied; required or explicitly selected software was retained.", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--keep", action="append", default=[], metavar="PACKAGE")
    args = parser.parse_args()
    try:
        apply(args.keep)
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stderr or error.stdout, end="", flush=True)
        parser.exit(1, f"Lean developer profile failed: {error}\n")


if __name__ == "__main__":
    main()
