import copy
import datetime
import hashlib
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('entitlements', Path(__file__).with_name('macos-keychain-entitlements.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ProfileTest(unittest.TestCase):
    def test_profile_authorization(self):
        cert = b'test certificate'
        identity = hashlib.sha1(cert).hexdigest().upper()
        profile = {
            'ExpirationDate': datetime.datetime(2040, 1, 1),
            'Platform': ['OSX'],
            'ProvisionsAllDevices': True,
            'DeveloperCertificates': [cert],
            'Entitlements': {
                'com.apple.application-identifier': 'TEAM.com.example.app',
                'com.apple.developer.team-identifier': 'TEAM',
                'keychain-access-groups': ['TEAM.*'],
            },
        }
        base = {'com.apple.security.app-sandbox': False}
        def prepare(value, signing_identity=identity):
            return module.release_entitlements(value, base, 'com.example.app', signing_identity, f'1) {identity} "Developer ID"')
        result = prepare(profile)
        self.assertEqual(result['keychain-access-groups'], ['TEAM.com.example.app'])
        self.assertFalse(result['com.apple.security.app-sandbox'])
        for key, value in [('ExpirationDate', datetime.datetime(2000, 1, 1)), ('Platform', ['iOS']), ('ProvisionsAllDevices', False), ('DeveloperCertificates', [])]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                prepare({**profile, key: value})
        for key, value in [('com.apple.application-identifier', 'TEAM.com.other.app'), ('keychain-access-groups', ['OTHER.*']), ('get-task-allow', True)]:
            bad = copy.deepcopy(profile)
            bad['Entitlements'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                prepare(bad)
        with self.assertRaises(ValueError):
            prepare(profile, 'Unrelated identity')


if __name__ == '__main__':
    unittest.main()
