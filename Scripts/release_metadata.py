"""Release identity embedded before app signing; local builds have no release tag."""
import re

RELEASE_TAG_KEY = "OmarchyReleaseTag"
CHANNELS = {
    "stable": ("dev.omarchy.vm-manager", "Omarchy VM Manager", "omarchy-vm", "Omarchy-VM-Manager"),
    "development": ("dev.omarchy.vm-manager.dev", "Omarchy VM Manager Dev", "omarchy-vm-dev", "Omarchy-VM-Manager-Dev"),
}


def channel_spec(channel):
    if channel not in CHANNELS:
        raise ValueError("Unknown release channel")
    return CHANNELS[channel]


def tag_version(tag):
    match = re.fullmatch(r"v((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))(-dev\.[1-9][0-9]*)?", tag)
    if not match:
        raise ValueError("Use vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-dev.N")
    return match[1]


def validate_tag(tag, version, channel=None):
    if tag_version(tag) != version:
        raise ValueError("Release tag and app version differ")
    if channel is not None:
        channel_spec(channel)
        if ("-dev." in tag) != (channel == "development"):
            raise ValueError("Release tag belongs to another app channel")
    return tag


def release_info(info, tag, channel=None, version=None, build=None):
    info = dict(info)
    info.pop(RELEASE_TAG_KEY, None)
    if version is not None or build is not None:
        if not tag or version is None or build is None or not re.fullmatch(r"[1-9][0-9]{0,8}", str(build)):
            raise ValueError("Version/build overrides require a complete release identity")
        info["CFBundleShortVersionString"] = version
        info["CFBundleVersion"] = str(build)
    if tag:
        info[RELEASE_TAG_KEY] = validate_tag(tag, info["CFBundleShortVersionString"], channel)
    return info


def verify_release_info(info, tag, version, channel=None):
    validate_tag(tag, version, channel)
    if info.get(RELEASE_TAG_KEY) != tag or info.get("CFBundleShortVersionString") != version:
        raise ValueError("Packaged app release identity does not match RELEASE_TAG and app version")
    if channel is not None:
        bundle, name, _, _ = channel_spec(channel)
        if info.get("OmarchyAppChannel") != channel or info.get("CFBundleIdentifier") != bundle or info.get("CFBundleDisplayName") != name:
            raise ValueError("Packaged app release identity does not match its channel")
