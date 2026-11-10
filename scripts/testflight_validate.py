#!/usr/bin/env python3
"""Fail closed on Beta settings, App Store profiles, and exported IPA metadata."""
import argparse
import datetime as dt
import hashlib
import json
import plistlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'com.junald69.wanbuddy.beta'
BASE = 'com.junald69.wanbuddy'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def development():
    known = (ROOT / 'Packages/WanBuddyCore/Sources/WanBuddyCore/Environment/WanBuddyKnownEnvironment.swift').read_text()
    match = re.search(r'developmentProjectRef = "([a-z0-9]{20})"', known)
    require(match is not None, 'Development reference is missing')
    config = (ROOT / 'ios/Config/Beta.xcconfig').read_text()
    key = re.search(r'^SUPABASE_PUBLISHABLE_KEY\s*=\s*(sb_publishable_\S+)\s*$', config, re.M)
    require(key is not None, 'Beta client key is missing')
    return match.group(1), key.group(1)


def profile_check(profile, team, identities, now=None):
    ent = profile.get('Entitlements', {})
    prefixes = profile.get('ApplicationIdentifierPrefix', [])
    require(len(prefixes) == 1 and prefixes[0], 'Profile must have one App ID prefix')
    require(profile.get('TeamIdentifier') == [team], 'Profile Team mismatch')
    require(ent.get('com.apple.developer.team-identifier') == team, 'Profile entitlement Team mismatch')
    require(ent.get('application-identifier') == prefixes[0] + '.' + BUNDLE, 'Profile Bundle ID mismatch')
    require(ent.get('get-task-allow') is False, 'Development profile is forbidden')
    require(ent.get('beta-reports-active') is True, 'Profile is not enabled for TestFlight')
    require('ProvisionedDevices' not in profile, 'Device-bound profile is forbidden')
    require(not profile.get('ProvisionsAllDevices'), 'Enterprise profile is forbidden')
    expiry = profile.get('ExpirationDate')
    require(isinstance(expiry, dt.datetime), 'Profile expiry is missing')
    require(expiry.replace(tzinfo=dt.timezone.utc) > (now or dt.datetime.now(dt.timezone.utc)), 'Profile expired')
    require(re.fullmatch(r'[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}', profile.get('UUID', '')), 'Invalid Profile UUID')
    fingerprints = [hashlib.sha1(c).hexdigest().upper() for c in profile.get('DeveloperCertificates', [])]
    matches = [fp for fp in fingerprints if re.search(r'\b' + fp + r'\b.*"Apple Distribution:', identities)]
    require(bool(matches), 'No valid Apple Distribution identity matches the profile')
    return matches[0]


def info_check(info, build):
    ref, key = development()
    expected = {
        'CFBundleIdentifier': BUNDLE,
        'CFBundleShortVersionString': '0.2.0',
        'CFBundleVersion': build,
        'WANBUDDY_CONFIGURATION': 'beta',
        'WANBUDDY_BUNDLE_ID_BASE': BASE,
        'SUPABASE_PROJECT_REF': ref,
        'SUPABASE_URL': 'https://' + ref + '.supabase.co',
        'SUPABASE_PUBLISHABLE_KEY': key,
        'CFBundleSupportedPlatforms': ['iPhoneOS'],
    }
    for name, value in expected.items():
        require(info.get(name) == value, 'Unexpected IPA field: ' + name)
    require(info.get('CFBundleIcons', {}).get('CFBundlePrimaryIcon', {}).get('CFBundleIconName') == 'AppIcon', 'AppIcon metadata is missing')


def settings_check(settings, build, team):
    ref, key = development()
    app = [s['buildSettings'] for s in settings if s.get('target') == 'WanBuddy']
    require(len(app) == 1, 'Expected one WanBuddy target')
    s = app[0]
    expected = {'CONFIGURATION': 'Beta', 'PRODUCT_BUNDLE_IDENTIFIER': BUNDLE,
                'WANBUDDY_CONFIGURATION': 'beta', 'SUPABASE_PROJECT_REF': ref,
                'SUPABASE_URL': 'https://' + ref + '.supabase.co',
                'SUPABASE_PUBLISHABLE_KEY': key, 'CURRENT_PROJECT_VERSION': build,
                'DEVELOPMENT_TEAM': team, 'CODE_SIGNING_ALLOWED': 'YES',
                'CODE_SIGNING_REQUIRED': 'YES', 'CODE_SIGN_STYLE': 'Manual',
                'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon'}
    for name, value in expected.items():
        require(s.get(name) == value, 'Unexpected build setting: ' + name)
    flags = set(s.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', '').split())
    require({'BETA', 'DEV_LOGIN'} <= flags and not flags.intersection({'DEBUG', 'RELEASE'}), 'Invalid Beta compile conditions')


def signed_entitlements_check(ent, profile):
    allowed = profile['Entitlements']
    for name in ('application-identifier', 'com.apple.developer.team-identifier', 'beta-reports-active'):
        require(ent.get(name) == allowed.get(name), 'Signed entitlement mismatch: ' + name)
    require(ent.get('get-task-allow', False) is False, 'Debugging entitlement is forbidden')
    prefix = profile['ApplicationIdentifierPrefix'][0] + '.'
    for group in ent.get('keychain-access-groups', []):
        require(group.startswith(prefix), 'Unexpected keychain access prefix')


def load(path):
    with Path(path).open('rb') as f:
        return plistlib.load(f)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('kind', choices=['profile', 'settings', 'ipa'])
    parser.add_argument('--profile', required=True)
    parser.add_argument('--identities', required=True)
    parser.add_argument('--team', required=True)
    parser.add_argument('--build', required=True)
    parser.add_argument('--settings')
    parser.add_argument('--app')
    parser.add_argument('--entitlements')
    parser.add_argument('--certificate')
    parser.add_argument('--export-options')
    args = parser.parse_args()
    try:
        require(re.fullmatch(r'[1-9][0-9]{0,3}', args.build), 'Build must be 1..9999')
        require(re.fullmatch(r'[A-Z0-9]{10}', args.team), 'Invalid Team ID')
        profile = load(args.profile)
        identity = profile_check(profile, args.team, Path(args.identities).read_text())
        if args.kind == 'profile':
            # These contain identifiers only; no passwords or private keys.
            print(profile['UUID'])
            print(identity)
            if args.export_options:
                with Path(args.export_options).open('wb') as f:
                    plistlib.dump({'method': 'app-store-connect', 'destination': 'export',
                                   'signingStyle': 'manual', 'teamID': args.team,
                                   'signingCertificate': identity,
                                   'manageAppVersionAndBuildNumber': False,
                                   'provisioningProfiles': {BUNDLE: profile['UUID']}}, f)
        elif args.kind == 'settings':
            settings_check(json.loads(Path(args.settings).read_text()), args.build, args.team)
            print('Beta build settings validated')
        else:
            app = Path(args.app)
            info_check(load(app / 'Info.plist'), args.build)
            require((app / '_CodeSignature/CodeResources').is_file(), 'Signature resources missing')
            require((app / 'PrivacyInfo.xcprivacy').is_file(), 'Privacy manifest missing')
            fingerprint = hashlib.sha1(Path(args.certificate).read_bytes()).hexdigest().upper()
            require(fingerprint == identity, 'Exported signing certificate mismatch')
            embedded = load(args.profile)
            signed_entitlements_check(load(args.entitlements), embedded)
            print('Signed Beta IPA validated for Development')
    except (ValueError, KeyError, TypeError, OSError, plistlib.InvalidFileException) as error:
        parser.exit(1, 'TestFlight validation failed: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
