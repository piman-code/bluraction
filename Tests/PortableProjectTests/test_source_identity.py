"""Pure authored stat-domain regressions; no native imports or media reads.

Windows objects model the independently inspected CPython 3.14.7 fields. These
tests do not claim actual Windows filesystem behavior; CI records that separately.
"""
from dataclasses import FrozenInstanceError, replace
import stat
from types import SimpleNamespace
import unittest

from shared.source_identity import (SourceIdentityError, StatSnapshot, metadata,
                                    stat_snapshot, same_domain, path_matches_descriptor,
                                    same_path_binding)


def windows_info(*, domain='path', **changes):
    values = dict(st_dev=0x123456789abcdef, st_ino=(1 << 112) + 0x123456789abcdef,
                  st_mode=stat.S_IFREG | 0o666, st_size=4096,
                  st_mtime_ns=1720000000000000001,
                  st_ctime_ns=1710000000000000001 if domain == 'path' else 1710000000000000123,
                  st_birthtime_ns=1710000000000000001,
                  st_file_attributes=0x20, st_reparse_tag=0)
    values.update(changes)
    return SimpleNamespace(**values)


def win_snapshot(*, domain='path', **changes):
    return stat_snapshot(windows_info(domain=domain, **changes), domain=domain, platform='windows')


def posix_snapshot(*, domain='path', **changes):
    values = dict(st_dev=7, st_ino=55, st_mode=stat.S_IFREG | 0o640, st_size=4096,
                  st_mtime_ns=1720000000000000001, st_ctime_ns=1720000000000000003)
    values.update(changes)
    return stat_snapshot(SimpleNamespace(**values), domain=domain, platform='posix')


class SourceIdentityTests(unittest.TestCase):
    def test_windows_immutable_file_crosses_domains_without_equating_creation_and_change(self):
        path, descriptor = win_snapshot(), win_snapshot(domain='descriptor')
        self.assertNotEqual(path.metadata[5], descriptor.metadata[5])
        self.assertEqual(path.birthtime_ns, descriptor.birthtime_ns)
        self.assertTrue(path_matches_descriptor(path, descriptor))
        self.assertTrue(same_domain(path, win_snapshot()))
        self.assertTrue(same_domain(descriptor, win_snapshot(domain='descriptor')))
        self.assertEqual(path.metadata, metadata(windows_info()))
        self.assertEqual(path.metadata[3], 4096, 'Existing SourceIdentity size index must remain 3')

    def test_descriptor_change_time_is_retained_in_its_full_baseline(self):
        path, before = win_snapshot(), win_snapshot(domain='descriptor')
        after = win_snapshot(domain='descriptor', st_ctime_ns=before.metadata[5] + 1)
        # Common identity cannot detect a metadata-only change: the independent
        # fd/fd baseline is mandatory, rather than replacing ctime with birthtime.
        self.assertTrue(path_matches_descriptor(path, after))
        self.assertFalse(same_domain(before, after))
        self.assertEqual(after.metadata[5] - before.metadata[5], 1)

    def test_path_change_time_is_retained_even_when_common_fields_are_unchanged(self):
        before, descriptor = win_snapshot(), win_snapshot(domain='descriptor')
        after = win_snapshot(st_ctime_ns=before.metadata[5] + 1)
        self.assertTrue(path_matches_descriptor(after, descriptor))
        self.assertFalse(same_domain(before, after))
        self.assertFalse(same_path_binding(before, after, 'C:/approved/source.pdf', 'C:/approved/source.pdf'))

    def test_integer_nanosecond_write_time_is_not_rounded_to_float_seconds(self):
        path, descriptor = win_snapshot(), win_snapshot(domain='descriptor')
        one_ns = win_snapshot(domain='descriptor', st_mtime_ns=descriptor.metadata[4] + 1)
        self.assertEqual(float(one_ns.metadata[4] / 1e9), float(descriptor.metadata[4] / 1e9))
        self.assertFalse(path_matches_descriptor(path, one_ns))
        self.assertFalse(same_domain(descriptor, one_ns))
        posix = posix_snapshot()
        self.assertFalse(path_matches_descriptor(posix, posix_snapshot(domain='descriptor', st_mtime_ns=posix.metadata[4] + 1)))

    def test_entire_128_bit_inode_volume_size_and_birthtime_are_cross_compared(self):
        path, descriptor = win_snapshot(), win_snapshot(domain='descriptor')
        for changes in (dict(st_ino=descriptor.metadata[1] + (1 << 96)),
                        dict(st_dev=descriptor.metadata[0] + 1),
                        dict(st_size=descriptor.metadata[3] + 1),
                        dict(st_birthtime_ns=descriptor.birthtime_ns + 1)):
            with self.subTest(changes=changes):
                changed = win_snapshot(domain='descriptor', **changes)
                self.assertFalse(path_matches_descriptor(path, changed))
                self.assertFalse(same_domain(descriptor, changed))
        rival = win_snapshot(domain='descriptor', st_ino=descriptor.metadata[1] ^ (1 << 112))
        self.assertEqual(rival.metadata[1] & ((1 << 64) - 1), descriptor.metadata[1] & ((1 << 64) - 1))
        self.assertFalse(path_matches_descriptor(path, rival), 'Do not truncate file IDs to low 64 bits')

    def test_windows_filename_execute_bits_differ_but_raw_same_domain_modes_remain_guarded(self):
        executable_path = win_snapshot(st_mode=stat.S_IFREG | 0o777)
        descriptor = win_snapshot(domain='descriptor')
        self.assertTrue(path_matches_descriptor(executable_path, descriptor))
        self.assertFalse(same_domain(executable_path, win_snapshot()))
        self.assertFalse(same_domain(descriptor, win_snapshot(domain='descriptor', st_mode=stat.S_IFREG | 0o444)))
        readonly = win_snapshot(domain='descriptor', st_file_attributes=0x21)
        self.assertFalse(path_matches_descriptor(executable_path, readonly))
        self.assertFalse(same_domain(descriptor, readonly))
        # Same-domain checks also retain non-readonly attributes, not just the
        # cross-view readonly bit used to tolerate filename-derived permissions.
        archive_changed = win_snapshot(domain='descriptor', st_file_attributes=0x80)
        self.assertFalse(same_domain(descriptor, archive_changed))

    def test_missing_birthtime_attributes_or_zero_ids_fail_closed_on_windows(self):
        for absent in ('st_birthtime_ns', 'st_file_attributes', 'st_reparse_tag'):
            info = windows_info(); delattr(info, absent)
            with self.subTest(absent=absent), self.assertRaises(SourceIdentityError):
                stat_snapshot(info, domain='path', platform='windows')
        for changes in (dict(st_dev=0), dict(st_ino=0), dict(st_birthtime_ns=True),
                        dict(st_birthtime_ns=1.0), dict(st_file_attributes=-1),
                        dict(st_reparse_tag=1 << 32)):
            with self.subTest(changes=changes), self.assertRaises(SourceIdentityError):
                win_snapshot(**changes)

    def test_regular_file_type_and_name_surrogate_reparse_policy_are_not_bypassed(self):
        for mode in (stat.S_IFDIR | 0o777, stat.S_IFLNK | 0o777, stat.S_IFIFO | 0o666):
            for platform in ('windows', 'posix'):
                with self.subTest(mode=mode, platform=platform), self.assertRaises(SourceIdentityError):
                    stat_snapshot(windows_info(st_mode=mode), domain='path', platform=platform)
        with self.assertRaisesRegex(SourceIdentityError, 'reparse'):
            win_snapshot(st_file_attributes=0x420, st_reparse_tag=0xa000000c)

    def test_posix_cross_domain_preserves_all_six_fields_including_mode_and_ctime(self):
        path, descriptor = posix_snapshot(), posix_snapshot(domain='descriptor')
        self.assertTrue(path_matches_descriptor(path, descriptor))
        for changes in (dict(st_dev=8), dict(st_ino=56), dict(st_mode=stat.S_IFREG | 0o600),
                        dict(st_size=4097), dict(st_mtime_ns=path.metadata[4] + 1),
                        dict(st_ctime_ns=path.metadata[5] + 1)):
            with self.subTest(changes=changes):
                current = posix_snapshot(domain='descriptor', **changes)
                self.assertFalse(path_matches_descriptor(path, current))
                self.assertFalse(same_domain(descriptor, current))

    def test_same_metadata_canonical_retarget_is_rejected_without_touching_either_source(self):
        baseline, current = win_snapshot(), win_snapshot()
        left, right = 'C:/approved/left/source.pdf', 'C:/approved/right/source.pdf'
        self.assertTrue(same_domain(baseline, current))
        self.assertTrue(same_path_binding(baseline, current, left, left))
        self.assertFalse(same_path_binding(baseline, current, left, right))
        with self.assertRaises(SourceIdentityError):
            same_path_binding(baseline, current, left, None)

    def test_domain_or_platform_confusion_never_silently_weakens_a_comparison(self):
        path, descriptor = win_snapshot(), win_snapshot(domain='descriptor')
        for call in (lambda: same_domain(path, descriptor),
                     lambda: path_matches_descriptor(descriptor, path),
                     lambda: path_matches_descriptor(path, path),
                     lambda: path_matches_descriptor(path, posix_snapshot(domain='descriptor')),
                     lambda: same_path_binding(descriptor, descriptor, 'x', 'x'),
                     lambda: same_domain(path, None),
                     lambda: same_path_binding(None, path, 'x', 'x')):
            with self.assertRaises(SourceIdentityError):
                call()

    def test_invalid_or_mutable_metadata_cannot_form_a_baseline(self):
        snapshot = win_snapshot()
        with self.assertRaises(FrozenInstanceError):
            snapshot.birthtime_ns = 0
        for field, value in (('st_dev', True), ('st_ino', 1.5), ('st_mode', False),
                             ('st_size', -1), ('st_mtime_ns', 1.0), ('st_ctime_ns', True)):
            with self.subTest(field=field), self.assertRaises(SourceIdentityError):
                win_snapshot(**{field: value})
        for changes in (dict(metadata=list(snapshot.metadata)), dict(domain='unknown'),
                        dict(platform='unknown'), dict(metadata=snapshot.metadata[:5])):
            with self.subTest(changes=changes), self.assertRaises(SourceIdentityError):
                replace(snapshot, **changes)
        with self.assertRaises(SourceIdentityError):
            metadata(SimpleNamespace(st_dev=1))
        with self.assertRaises(SourceIdentityError):
            StatSnapshot('posix', 'path', snapshot.metadata, birthtime_ns=1)


if __name__ == '__main__':
    unittest.main()
