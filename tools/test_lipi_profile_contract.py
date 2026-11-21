"""Pure in-memory profile recreation regression tests, no app or preferences access."""
import copy
import itertools
import unittest
from lipi_profile_contract import profile_for_launch


class ProfileContractTests(unittest.TestCase):
    def setUp(self):
        self.source = {'Name': 'Lipi Terminal Test', 'Guid': 'known',
                       'Mouse Reporting': True, 'Mouse Reporting allow mouse wheel': True,
                       'Scrollback in Alternate Screen': True, 'Allow Alternate Mouse Scroll': True,
                       'Automatically Enable Alternate Mouse Scroll': False,
                       'Future Setting': {'nested': ['preserve']}}

    def test_clone_preserves_every_setting_and_changes_only_identity(self):
        before = copy.deepcopy(self.source)
        clone = profile_for_launch([self.source], 'Lipi Lab')
        self.assertEqual({k: v for k, v in clone.items() if k not in ('Name', 'Guid')},
                         {k: v for k, v in self.source.items() if k not in ('Name', 'Guid')})
        self.assertEqual(clone['Name'], 'Lipi Lab')
        self.assertNotEqual(clone['Guid'], self.source['Guid'])
        clone['Future Setting']['nested'].append('local')
        self.assertEqual(self.source, before)

    def test_existing_profile_is_reused_over_every_short_launch_sequence(self):
        for names in itertools.product(('Lipi Driver', 'Lipi Lab'), repeat=3):
            profiles = [copy.deepcopy(self.source)]
            ids = {}
            for name in names:
                result = profile_for_launch(profiles, name)
                if name not in ids:
                    ids[name] = result['Guid']
                    profiles.append(result)
                self.assertEqual(result['Guid'], ids[name])
            self.assertEqual(len(set(ids.values())), len(ids))

    def test_reuse_preserves_all_alternate_choices_without_replacing_saved_profile(self):
        from lipi_profile_contract import SCROLL_KEYS
        for values in itertools.product((False, True), repeat=3):
            saved = dict(self.source, Name='Lipi Driver', Guid='saved')
            saved.update(zip(SCROLL_KEYS[2:], values))
            result = profile_for_launch([self.source, self.source, saved], 'Lipi Driver')
            self.assertEqual(result, saved)
            self.assertIsNot(result, saved)

    def test_refuses_missing_or_disabled_contract_and_ambiguous_identity(self):
        for key in [k for k in self.source if k not in ('Name', 'Guid', 'Future Setting')]:
            for missing in ((False, True) if key in ('Mouse Reporting', 'Mouse Reporting allow mouse wheel') else (True,)):
                bad = copy.deepcopy(self.source)
                if missing:
                    del bad[key]
                else:
                    bad[key] = not bad[key]
                with self.assertRaises(ValueError):
                    profile_for_launch([bad], 'Lipi Lab')
        for profiles in ([], [self.source, self.source]):
            with self.assertRaises(ValueError):
                profile_for_launch(profiles, 'Lipi Lab')
        with self.assertRaises(ValueError):
            profile_for_launch([{'Name': 'Lipi Driver', 'Guid': 'bad'}], 'Lipi Driver')


if __name__ == '__main__':
    unittest.main()
