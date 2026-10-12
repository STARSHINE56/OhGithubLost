#!/usr/bin/env python3
"""Fixed Android signing setup and APK verification; never generates a key."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
REQUIRED = ('OGL_ANDROID_KEYSTORE', 'OGL_ANDROID_STORE_PASSWORD',
            'OGL_ANDROID_KEY_PASSWORD', 'OGL_ANDROID_KEY_ALIAS',
            'OGL_ANDROID_CERT_SHA256')


def required(name):
    value = os.environ.get(name, '')
    if not value:
        raise ValueError('Missing Actions Secret: ' + name)
    return value


def fingerprint(value):
    value = value.replace(':', '').lower()
    if not re.fullmatch(r'[0-9a-f]{64}', value):
        raise ValueError('Invalid certificate SHA-256')
    return value


def private_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, 'wb') as handle:
        handle.write(data)


def prepare():
    values = {name: required(name) for name in REQUIRED}
    expected = fingerprint(values['OGL_ANDROID_CERT_SHA256'])
    keystore = Path(required('RUNNER_TEMP')) / 'ogl-android-release.jks'
    try:
        data = base64.b64decode(''.join(values['OGL_ANDROID_KEYSTORE'].split()), validate=True)
    except ValueError:
        raise ValueError('Invalid OGL_ANDROID_KEYSTORE Base64') from None
    if not data:
        raise ValueError('Empty Android keystore')
    private_write(keystore, data)
    proc = subprocess.run([
        'keytool', '-exportcert', '-keystore', str(keystore),
        '-storepass:env', 'OGL_ANDROID_STORE_PASSWORD',
        '-alias', values['OGL_ANDROID_KEY_ALIAS']], capture_output=True)
    if proc.returncode:
        raise ValueError('Cannot read Android keystore; check the signing Secrets')
    if hashlib.sha256(proc.stdout).hexdigest() != expected:
        raise ValueError('Keystore certificate does not match OGL_ANDROID_CERT_SHA256')
    # Escape Java Properties without interpolating any secret into Gradle source.
    def escape(value):
        return ''.join(('\\u%04x' % ord(c)) if c in '\\:=#! \r\n\t' or ord(c) > 126
                       else c for c in value)
    props = {'storeFile': str(keystore),
             'storePassword': values['OGL_ANDROID_STORE_PASSWORD'],
             'keyPassword': values['OGL_ANDROID_KEY_PASSWORD'],
             'keyAlias': values['OGL_ANDROID_KEY_ALIAS']}
    private_write(ROOT / 'android/key.properties',
                  ''.join(k + '=' + escape(v) + '\n' for k, v in props.items()).encode())
    print('Fixed Android signing prepared; certificate SHA-256: ' + expected)


def build_number():
    # Seconds since 2020: shared ordering across workflows, under Android's limit.
    requested = os.environ.get('OGL_REQUESTED_VERSION_CODE', '')
    if requested and not re.fullmatch(r'[1-9][0-9]*', requested):
        raise ValueError('version_number must be a positive integer')
    match = re.search(r'^version:\s*[^\n+]+\+(\d+)',
                      (ROOT / 'pubspec.yaml').read_text(), re.M)
    code = max(int(time.time()) - 1577836800, int(requested or 0),
               int(match.group(1)) if match else 1)
    if not 0 < code <= 2100000000:
        raise ValueError('Android versionCode exceeds the supported range')
    with open(required('GITHUB_OUTPUT'), 'a') as handle:
        handle.write('version_code=%d\n' % code)
    print('Android versionCode: %d (manual input is a lower bound)' % code)


def sdk_tool(name):
    sdk = Path(os.environ.get('ANDROID_HOME') or required('ANDROID_SDK_ROOT'))
    candidates = [p for p in (sdk / 'build-tools').glob('*/' + name) if p.is_file()]
    if not candidates:
        raise ValueError('Android SDK tool missing: ' + name)
    return str(max(candidates, key=lambda p: tuple(int(v) for v in re.findall(r'\d+', p.parent.name))))


def verify(pattern, expected_code=None):
    expected = fingerprint(required('OGL_ANDROID_CERT_SHA256'))
    apks = sorted(ROOT.glob(pattern))
    if not apks:
        raise ValueError('No APK files found for verification')
    reports = []
    for apk in apks:
        proc = subprocess.run([sdk_tool('apksigner'), 'verify', '--verbose',
                               '--print-certs', str(apk)], capture_output=True, text=True)
        if proc.returncode:
            raise ValueError('apksigner verification failed: ' + apk.name)
        # With --verbose, current apksigner prints v3/v3.1 signers by SDK range
        # instead of "Signer #1". Check every range, including rotation entries.
        found = re.findall(
            r'^Signer (?:#\d+|\(minSdkVersion=.*\)) certificate SHA-256 digest:\s*(\S+)',
            proc.stdout, re.M)
        signer_count = re.search(r'^Number of signers:\s*(\d+)\s*$', proc.stdout, re.M)
        numbered_signers = set(re.findall(r'^Signer #(\d+) certificate SHA-256 digest:', proc.stdout, re.M))
        if (not found or any(fingerprint(value) != expected for value in found)
                or (signer_count and int(signer_count[1]) != 1)
                or len(numbered_signers) > 1):
            # Fingerprints are public, but do not dump the complete tool output.
            raise ValueError('Unexpected APK signing certificate: ' + apk.name
                             + ' (observed SHA-256: ' + ', '.join(found) + ')')
        badging = subprocess.run([sdk_tool('aapt'), 'dump', 'badging', str(apk)],
                                 capture_output=True, text=True, check=True).stdout
        match = re.search(r"package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", badging)
        if not match or match[1] != 'com.yingo.ohgithublost':
            raise ValueError('Android applicationId changed: ' + apk.name)
        if expected_code and int(match[2]) != int(expected_code):
            raise ValueError('Unexpected APK versionCode: ' + apk.name)
        report = {'apk': apk.name, 'applicationId': match[1], 'versionCode': int(match[2]),
                  'versionName': match[3], 'certificate_sha256': expected,
                  'apksigner_verified': True, 'run_id': os.environ.get('GITHUB_RUN_ID'),
                  'run_attempt': os.environ.get('GITHUB_RUN_ATTEMPT')}
        reports.append(report)
        print(json.dumps(report))
    output = ROOT / 'build/android-signing-report.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(reports, indent=2) + '\n')
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
            summary.write('### Android signing verified\n\nCertificate SHA-256: `' + expected + '`\n\n')
            for report in reports:
                summary.write('- `%s`: `%s`, versionCode `%s`\n' %
                              (report['apk'], report['applicationId'], report['versionCode']))


def cleanup():
    (ROOT / 'android/key.properties').unlink(missing_ok=True)
    if os.environ.get('RUNNER_TEMP'):
        (Path(os.environ['RUNNER_TEMP']) / 'ogl-android-release.jks').unlink(missing_ok=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('prepare', 'version', 'verify', 'cleanup'))
    parser.add_argument('--apks', default='build/app/outputs/flutter-apk/*.apk')
    parser.add_argument('--version-code')
    args = parser.parse_args()
    try:
        if args.command == 'verify':
            verify(args.apks, args.version_code)
        else:
            {'prepare': prepare, 'version': build_number, 'cleanup': cleanup}[args.command]()
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        # Error messages only name configuration fields; never print secret values.
        raise SystemExit(str(exc))
