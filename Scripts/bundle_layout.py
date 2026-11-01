"""Recognize the two macOS resource-bundle layouts emitted by SwiftPM."""


def core_resource_directory(bundle):
    candidates = [folder for folder in (bundle / "Contents/Resources", bundle)
                  if (folder / "OwnerSetupContract.json").is_file()]
    if len(candidates) != 1:
        raise ValueError("Expected exactly one embedded SwiftPM resource layout")
    return candidates[0]
