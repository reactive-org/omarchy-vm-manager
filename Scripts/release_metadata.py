"""Release identity embedded before app signing; local builds have no release tag."""
import re

RELEASE_TAG_KEY = "OmarchyReleaseTag"


def validate_tag(tag, version):
    if not re.fullmatch(re.escape("v" + version) + r"-dev\.[1-9][0-9]*", tag):
        raise ValueError(f"Use v{version}-dev.N (N >= 1); only development prereleases are supported")
    return tag


def release_info(info, tag):
    info = dict(info)
    info.pop(RELEASE_TAG_KEY, None)
    if tag:
        info[RELEASE_TAG_KEY] = validate_tag(tag, info["CFBundleShortVersionString"])
    return info


def verify_release_info(info, tag, version):
    validate_tag(tag, version)
    if info.get(RELEASE_TAG_KEY) != tag or info.get("CFBundleShortVersionString") != version:
        raise ValueError("Packaged app release identity does not match RELEASE_TAG and app version")
