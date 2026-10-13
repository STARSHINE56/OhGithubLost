#!/usr/bin/env python3
"""Restrict Gradle native plugin packaging to ARM64, or verify an APK."""
import sys
from pathlib import Path
import zipfile

if len(sys.argv) > 1:
    with zipfile.ZipFile(sys.argv[1]) as archive:
        abis = {n.split('/')[1] for n in archive.namelist()
                if n.startswith('lib/') and n.endswith('.so')}
    if abis != {'arm64-v8a'}:
        raise SystemExit('Unexpected native ABIs: ' + ', '.join(sorted(abis)))
    print('Verified ARM64-only APK')
else:
    path = Path('android/app/build.gradle.kts')
    text = path.read_text()
    marker = '// OGL_ARM64_ONLY'
    if marker not in text:
        anchor = 'defaultConfig {'
        if text.count(anchor) != 1:
            raise SystemExit('Unexpected Gradle defaultConfig template')
        text = text.replace(anchor, anchor + '\n        ndk {\n'
                            '            abiFilters.clear()\n'
                            '            abiFilters.add("arm64-v8a")\n'
                            '        } ' + marker, 1)
        path.write_text(text)
    print('Gradle ARM64 native packaging filter ready')
