#!/usr/bin/env python3
"""Validate a decoded Developer ID profile and prepare release entitlements."""

import datetime
import hashlib
import plistlib
import subprocess
import sys


def release_entitlements(profile, base, bundle_id, identity, identities):
    if profile.get('ExpirationDate', datetime.datetime.min) <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
        raise ValueError('Developer ID provisioning profile has expired')
    if 'OSX' not in profile.get('Platform', []) or not profile.get('ProvisionsAllDevices'):
        raise ValueError('A Developer ID profile for all Macs is required')
    allowed = profile.get('Entitlements', {})
    team = allowed.get('com.apple.developer.team-identifier')
    app_id = allowed.get('com.apple.application-identifier', '')
    if not team or app_id != f'{team}.{bundle_id}' or allowed.get('get-task-allow'):
        raise ValueError('Profile does not authorize this release app')
    groups = allowed.get('keychain-access-groups', [])
    if app_id not in groups and f'{team}.*' not in groups:
        raise ValueError('Profile does not authorize the app keychain group')
    fingerprints = [hashlib.sha1(cert).hexdigest().upper() for cert in profile.get('DeveloperCertificates', [])]
    if not any(
        fingerprint in line and (identity.upper() == fingerprint or f'"{identity}"' in line)
        for fingerprint in fingerprints for line in identities.splitlines()
    ):
        raise ValueError('Signing identity is not authorized by the profile')
    return {
        **base,
        'com.apple.application-identifier': app_id,
        'com.apple.developer.team-identifier': team,
        'keychain-access-groups': [app_id],
    }


if __name__ == '__main__':
    profile_path, base_path, bundle_id, identity, output_path = sys.argv[1:]
    with open(profile_path, 'rb') as source:
        profile = plistlib.load(source)
    with open(base_path, 'rb') as source:
        base = plistlib.load(source)
    identities = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
    try:
        result = release_entitlements(profile, base, bundle_id, identity, identities)
    except ValueError as error:
        sys.exit(str(error))
    with open(output_path, 'wb') as destination:
        plistlib.dump(result, destination)
