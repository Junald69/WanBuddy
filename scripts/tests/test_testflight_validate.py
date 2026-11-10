"""Adversarial fixtures for credentials/environment mistakes; no Apple access."""
import copy
import datetime as dt
import hashlib
import importlib.util
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('validate', ROOT / 'scripts/testflight_validate.py')
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)
TEAM = 'ABCDE12345'
CERT = b'synthetic certificate for validation fixtures only'
FP = hashlib.sha1(CERT).hexdigest().upper()
IDENTITIES = '  1) ' + FP + ' "Apple Distribution: Fixture (ABCDE12345)"'
NOW = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)


def profile():
    return {'UUID': '12345678-1234-1234-1234-123456789ABC',
            'ApplicationIdentifierPrefix': ['PREFIX1234'],
            'TeamIdentifier': [TEAM], 'ExpirationDate': dt.datetime(2027, 1, 1),
            'DeveloperCertificates': [CERT],
            'Entitlements': {'application-identifier': 'PREFIX1234.' + v.BUNDLE,
                             'com.apple.developer.team-identifier': TEAM,
                             'get-task-allow': False, 'beta-reports-active': True}}


class ProfileTests(unittest.TestCase):
    def test_app_store_profile_with_distinct_prefix_is_valid(self):
        self.assertEqual(v.profile_check(profile(), TEAM, IDENTITIES, NOW), FP)

    def test_wrong_team_bundle_expired_or_missing_certificate_is_rejected(self):
        bad = []
        for key, value in [('TeamIdentifier', ['OTHER12345']), ('ExpirationDate', dt.datetime(2025, 1, 1)),
                           ('DeveloperCertificates', [b'different cert']), ('UUID', '../../profile'),
                           ('ProvisionedDevices', []), ('ProvisionsAllDevices', True)]:
            p = profile(); p[key] = value; bad.append(p)
        for key, value in [('application-identifier', 'PREFIX1234.com.junald69.wanbuddy'),
                           ('get-task-allow', True), ('beta-reports-active', False),
                           ('com.apple.developer.team-identifier', 'OTHER12345')]:
            p = profile(); p['Entitlements'][key] = value; bad.append(p)
        for index, p in enumerate(bad):
            with self.subTest(case=index), self.assertRaises(ValueError):
                v.profile_check(p, TEAM, IDENTITIES, NOW)

    def test_cli_exports_only_the_validated_beta_profile(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            p = profile()
            # Keep this fixture valid independently of today's date.
            p['ExpirationDate'] = dt.datetime.now(dt.timezone.utc).replace(tzinfo=None) + dt.timedelta(days=30)
            (root / 'profile.plist').write_bytes(plistlib.dumps(p))
            (root / 'identities.txt').write_text(IDENTITIES)
            args = [sys.executable, str(ROOT / 'scripts/testflight_validate.py'), 'profile',
                    '--profile', str(root / 'profile.plist'), '--identities', str(root / 'identities.txt'),
                    '--team', TEAM, '--build', '12', '--export-options', str(root / 'export.plist')]
            result = subprocess.run(args, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            export = plistlib.loads((root / 'export.plist').read_bytes())
            self.assertEqual(export['provisioningProfiles'], {v.BUNDLE: p['UUID']})
            self.assertEqual(export['method'], 'app-store-connect')
            self.assertFalse(export['manageAppVersionAndBuildNumber'])
            for bad in ['0', '10000', '12;echo BAD', '1.2.3']:
                invalid = args.copy(); invalid[invalid.index('--build') + 1] = bad
                self.assertNotEqual(subprocess.run(invalid, capture_output=True).returncode, 0)

    def test_non_distribution_identity_is_rejected(self):
        with self.assertRaises(ValueError):
            v.profile_check(profile(), TEAM, IDENTITIES.replace('Apple Distribution:', 'Apple Development:'), NOW)

    def test_signed_entitlements_do_not_allow_debugging_or_wrong_app(self):
        p = profile()
        v.signed_entitlements_check(p['Entitlements'], p)
        for key, value in [('get-task-allow', True), ('application-identifier', 'PREFIX1234.other'),
                           ('keychain-access-groups', ['OTHER12345.app'])]:
            ent = copy.deepcopy(p['Entitlements']); ent[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                v.signed_entitlements_check(ent, p)


class EnvironmentTests(unittest.TestCase):
    def setUp(self):
        ref, key = v.development()
        self.info = {'CFBundleIdentifier': v.BUNDLE, 'CFBundleShortVersionString': '0.2.0',
                     'CFBundleVersion': '12', 'WANBUDDY_CONFIGURATION': 'beta',
                     'WANBUDDY_BUNDLE_ID_BASE': v.BASE, 'SUPABASE_PROJECT_REF': ref,
                     'SUPABASE_URL': 'https://' + ref + '.supabase.co',
                     'SUPABASE_PUBLISHABLE_KEY': key, 'CFBundleSupportedPlatforms': ['iPhoneOS'],
                     'CFBundleIcons': {'CFBundlePrimaryIcon': {'CFBundleIconName': 'AppIcon'}}}

    def test_beta_info_passes(self):
        v.info_check(self.info, '12')

    def test_production_simulator_wrong_build_and_client_key_are_rejected(self):
        for key, value in [('CFBundleIdentifier', v.BASE), ('WANBUDDY_CONFIGURATION', 'release'),
                           ('SUPABASE_PROJECT_REF', 'abcdefghijklmnopqrst'),
                           ('SUPABASE_URL', 'https://abcdefghijklmnopqrst.supabase.co'),
                           ('SUPABASE_PUBLISHABLE_KEY', 'sb_publishable_wrong'),
                           ('CFBundleVersion', '1'), ('CFBundleSupportedPlatforms', ['iPhoneSimulator']),
                           ('CFBundleIcons', {})]:
            info = copy.deepcopy(self.info); info[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                v.info_check(info, '12')

    def test_release_or_unsigned_build_settings_are_rejected(self):
        ref, key = v.development()
        s = {'CONFIGURATION': 'Beta', 'PRODUCT_BUNDLE_IDENTIFIER': v.BUNDLE,
             'WANBUDDY_CONFIGURATION': 'beta', 'SUPABASE_PROJECT_REF': ref,
             'SUPABASE_URL': 'https://' + ref + '.supabase.co', 'SUPABASE_PUBLISHABLE_KEY': key,
             'CURRENT_PROJECT_VERSION': '12', 'DEVELOPMENT_TEAM': TEAM,
             'CODE_SIGNING_ALLOWED': 'YES', 'CODE_SIGNING_REQUIRED': 'YES', 'CODE_SIGN_STYLE': 'Manual',
             'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'BETA DEV_LOGIN'}
        v.settings_check([{'target': 'WanBuddy', 'buildSettings': s}], '12', TEAM)
        for field, value in [('CONFIGURATION', 'Release'), ('CODE_SIGNING_ALLOWED', 'NO'),
                             ('SWIFT_ACTIVE_COMPILATION_CONDITIONS', 'BETA DEV_LOGIN DEBUG')]:
            bad = dict(s); bad[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                v.settings_check([{'target': 'WanBuddy', 'buildSettings': bad}], '12', TEAM)


class WorkflowTests(unittest.TestCase):
    def test_workflow_cannot_upload_on_pr_or_without_explicit_operation(self):
        source = (ROOT / '.github/workflows/testflight-beta.yml').read_text()
        self.assertNotIn('pull_request:', source)
        self.assertNotIn('push:', source)
        self.assertNotIn('environment:', source)
        for text in ['workflow_dispatch:', 'default: validate', "github.ref == 'refs/heads/main'",
                     "github.event_name == 'workflow_dispatch'", "github.repository == 'Junald69/WanBuddy'",
                     'github.actor == github.repository_owner', 'github.triggering_actor == github.repository_owner',
                     'inputs.approved_commit == github.sha', 'ref: ${{ github.sha }}', 'bash scripts/testflight_request.sh', "if: inputs.operation == 'upload'", 'if: always()',
                     'contents: read', 'persist-credentials: false']:
            self.assertIn(text, source)
        self.assertLess(source.index('python3 scripts/check_static.py'), source.index('run: xcodegen generate'))
        build = (ROOT / 'scripts/testflight_build.sh').read_text()
        self.assertIn('-configuration Beta', build)
        self.assertNotIn('-configuration Release', build)
        self.assertLess(build.index('testflight_validate.py ipa'), build.index('build.json'))

    def test_run_guard_rejects_other_actors_refs_events_and_commits(self):
        sha = 'a' * 40
        env = {'PATH': '/usr/bin:/bin', 'GITHUB_EVENT_NAME': 'workflow_dispatch',
               'GITHUB_REPOSITORY': 'Junald69/WanBuddy', 'GITHUB_REF': 'refs/heads/main',
               'GITHUB_REPOSITORY_OWNER': 'Junald69', 'GITHUB_ACTOR': 'Junald69',
               'GITHUB_TRIGGERING_ACTOR': 'Junald69', 'GITHUB_SHA': sha,
               'APPROVED_COMMIT': sha, 'OPERATION': 'validate'}
        script = str(ROOT / 'scripts/testflight_request.sh')
        def run(settings):
            return subprocess.run(['bash', script], env=settings, capture_output=True).returncode
        self.assertEqual(run(env), 0)
        self.assertEqual(run(dict(env, OPERATION='upload')), 0)
        for key, value in [('GITHUB_EVENT_NAME', 'pull_request'), ('GITHUB_EVENT_NAME', 'push'),
                           ('GITHUB_EVENT_NAME', 'pull_request_target'), ('GITHUB_EVENT_NAME', 'workflow_run'),
                           ('GITHUB_REPOSITORY', 'someone/WanBuddy'), ('GITHUB_REF', 'refs/heads/feature'),
                           ('GITHUB_REF', 'refs/tags/main'), ('GITHUB_ACTOR', 'collaborator'),
                           ('GITHUB_TRIGGERING_ACTOR', 'collaborator'), ('GITHUB_REPOSITORY_OWNER', 'someone'),
                           ('APPROVED_COMMIT', ''), ('APPROVED_COMMIT', 'b' * 40),
                           ('APPROVED_COMMIT', 'a' * 7), ('APPROVED_COMMIT', '$(echo bad)'),
                           ('GITHUB_SHA', ''), ('OPERATION', 'production')]:
            bad = dict(env); bad[key] = value
            with self.subTest(key=key, value=value):
                self.assertNotEqual(run(bad), 0)

    def test_normal_builds_stay_unsigned(self):
        for path in ['ios/project.yml', 'ios/Config/Common.xcconfig']:
            text = (ROOT / path).read_text()
            self.assertIn('CODE_SIGNING_ALLOWED', text)
            self.assertNotIn('CODE_SIGNING_ALLOWED = YES', text)
            self.assertNotIn('CODE_SIGNING_ALLOWED: "YES"', text)


if __name__ == '__main__':
    unittest.main()
