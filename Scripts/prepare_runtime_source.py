#!/usr/bin/env python3
"""Point SwiftPM at the same verified upstream source used to build the kit."""
import os
from pathlib import Path
import uuid
from upstream_source import ROOT, prepare


def main():
    source = prepare()
    link = ROOT / '.build/runtime-source'
    link.parent.mkdir(parents=True, exist_ok=True)
    if link.is_symlink() and link.resolve() == source:
        return
    if link.exists() and not link.is_symlink():
        raise RuntimeError('Unexpected runtime source directory; existing files were preserved')
    temporary = link.with_name('.runtime-source-' + uuid.uuid4().hex)
    try:
        temporary.symlink_to(source, target_is_directory=True)
        os.replace(temporary, link)
    finally:
        temporary.unlink(missing_ok=True)


if __name__ == '__main__':
    main()
