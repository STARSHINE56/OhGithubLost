#!/usr/bin/env python3
"""Verify APK signatures with the Android SDK, never by scanning raw bytes.

Certificate SHA-256 is supplied via OGL_ANDROID_CERT_SHA256.
"""
import argparse
from pathlib import Path
import android_signing

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apk', required=True)
    args = parser.parse_args()
    apk = Path(args.apk).resolve()
    try:
        android_signing.verify(str(apk.relative_to(android_signing.ROOT)))
    except (ValueError, OSError) as exc:
        raise SystemExit(str(exc))
