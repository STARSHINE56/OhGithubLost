#!/usr/bin/env python3
"""Report actual APK bytes and ZIP contents, without extracting or changing it."""
import argparse
import json
from pathlib import Path
import zipfile


def category(name):
    if name.startswith('lib/'):
        parts = name.split('/')
        return 'native/' + (parts[1] if len(parts) > 2 else 'unknown')
    if name.startswith('assets/flutter_assets/'):
        return 'flutter_assets'
    if name.endswith('.dex'):
        return 'dex'
    if name.startswith('res/') or name == 'resources.arsc':
        return 'android_resources'
    if name.startswith('META-INF/'):
        return 'metadata'
    return 'other'


def analyze(path):
    path = Path(path)
    groups = {}
    entries = []
    with zipfile.ZipFile(path) as archive:
        for item in archive.infolist():
            if item.is_dir():
                continue
            group = groups.setdefault(category(item.filename), {
                'files': 0, 'compressed_bytes': 0, 'uncompressed_bytes': 0,
            })
            group['files'] += 1
            group['compressed_bytes'] += item.compress_size
            group['uncompressed_bytes'] += item.file_size
            entries.append({
                'name': item.filename,
                'compressed_bytes': item.compress_size,
                'uncompressed_bytes': item.file_size,
            })
    actual = path.stat().st_size
    compressed = sum(e['compressed_bytes'] for e in entries)
    return {
        'apk': path.name,
        'actual_bytes': actual,
        'actual_mib': round(actual / (1024 ** 2), 3),
        'entries': len(entries),
        'compressed_content_bytes': compressed,
        # Includes ZIP headers, APK signing blocks and alignment padding.
        'container_overhead_bytes': actual - compressed,
        'uncompressed_content_bytes': sum(e['uncompressed_bytes'] for e in entries),
        'categories': dict(sorted(groups.items())),
        'largest_entries': sorted(entries, key=lambda e: e['compressed_bytes'],
                                  reverse=True)[:30],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=Path)
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    report = analyze(args.apk)
    output = json.dumps(report, ensure_ascii=False, indent=2) + '\n'
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(output, encoding='utf-8')
    print(output, end='')


if __name__ == '__main__':
    main()
