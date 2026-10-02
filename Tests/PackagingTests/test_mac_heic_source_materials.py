"""Controlled ownership/archive checks, not actual Mach-O/signing/codec proof.

Native commands are injected text observations only. Root must separately run
the tools on actual pinned source builds and a modified-library app copy.
"""
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import stat
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from scripts import relink_heic_cpu as relink
from scripts import package_mac_heic_sources as materials


class MacHEICSourceMaterialsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mac-heic-material-tests-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def file(self, name, data=b'owned source bytes'):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def zip(self, name, rows):
        path = self.root / name
        with zipfile.ZipFile(path, 'w') as archive:
            for member, data in rows:
                archive.writestr(member, data)
        return path

    def test_fd_copy_keeps_original_bytes_mode_identity_and_independent_output(self):
        original = self.file('input.cpp'); original.chmod(0o600)
        output = self.root / 'copy.cpp'
        before = relink.captured_file(original)
        result = relink.captured_file(original, destination=output)
        self.assertEqual(result, before)
        self.assertEqual(output.read_bytes(), original.read_bytes())
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
        self.assertNotEqual(original.stat().st_ino, output.stat().st_ino)
        self.assertEqual(relink.captured_file(original), before)

    def test_changed_bytes_during_copy_are_rejected_without_overwriting_input(self):
        original = self.file('race.txt', b'original')
        output = self.root / 'owned-partial.txt'
        actual_read = os.read; observed = []
        def read(fd, size):
            block = actual_read(fd, size)
            if block and not observed:
                observed.append(True)
                original.write_bytes(b'changed!')
            return block
        with patch.object(relink.os, 'read', side_effect=read):
            with self.assertRaisesRegex(ValueError, 'changed'):
                relink.captured_file(original, destination=output)
        self.assertTrue(observed)
        self.assertEqual(original.read_bytes(), b'changed!')
        self.assertEqual(output.read_bytes(), b'original')

    def test_existing_output_is_never_truncated(self):
        original = self.file('input.txt')
        output = self.file('keep.txt', b'existing sentinel')
        with self.assertRaises(FileExistsError):
            relink.captured_file(original, destination=output)
        self.assertEqual(output.read_bytes(), b'existing sentinel')

    def test_plain_paths_reject_file_and_directory_aliases(self):
        original = self.file('plain.txt')
        link = self.root / 'alias.txt'
        folder = self.root / 'folder'; folder.mkdir()
        directory_alias = self.root / 'folder-alias'
        actual_resolve = Path.resolve
        def alias_resolution(path, *args, **kwargs):
            if path == link: return original
            if path == directory_alias: return folder
            return actual_resolve(path, *args, **kwargs)
        # Observe a canonical/path disagreement without requiring Windows
        # symbolic-link privileges; actual Mac path checks are a native gate.
        with patch.object(Path, 'resolve', autospec=True, side_effect=alias_resolution):
            with self.assertRaises(ValueError): relink.captured_file(link)
            with self.assertRaises(ValueError): relink.plain_path(directory_alias, directory=True)

    def test_output_scope_rejects_system_installations_and_requires_new_expected_suffix(self):
        for path in (Path('/Applications/Modified.app'), Path('/System/Modified.app'),
                     Path('/usr/local/Modified.app'), Path.home() / 'Applications/Modified.app'):
            with self.subTest(path=path), self.assertRaises(ValueError):
                relink.output_path(path, suffix='.app')
        existing = self.root / 'keep.app'; existing.mkdir()
        with self.assertRaises(ValueError): relink.output_path(existing, suffix='.app')
        with self.assertRaises(ValueError): relink.output_path(self.root / 'wrong.zip', suffix='.app')

    def test_metadata_duplicate_escaped_keys_and_nonfinite_values_are_rejected(self):
        for index, data in enumerate((b'{"name":1,"\\u006eame":2}', b'{"value":NaN}')):
            with self.subTest(index=index), self.assertRaises(ValueError):
                relink.read_json(self.file(f'{index}.json', data))

    def test_source_archives_allow_source_and_authored_application_fixture_data(self):
        source = self.zip('source.zip', [('BlurAction/Package.swift', b'// source'),
            ('BlurAction/LICENSE', b'author license'),
            ('BlurAction/shared/fixtures/authored.png', b'\x89PNG\r\n\x1a\nfixture')])
        report = materials.validate_source_archive(source, application=True)
        self.assertEqual(report['files'], 3)
        self.assertEqual(report['roots'], ['BlurAction'])
        self.assertEqual(report['expandedBytes'], sum(len(row[1]) for row in (
            ('', b'// source'), ('', b'author license'), ('', b'\x89PNG\r\n\x1a\nfixture'))))

    def test_archive_traversal_duplicate_and_generated_private_members_rejected(self):
        rows = ([('../outside.py', b'x')], [('A/../outside.py', b'x')],
                [('A/x.py', b'a'), ('A/x.py', b'b')],
                [('A/.build/cache.py', b'x')], [('A/qa-private/probe.py', b'x')],
                [('A/secret.log', b'/absolute/private/log')], [('A/.env', b'secret')])
        for index, entries in enumerate(rows):
            with self.subTest(index=index), self.assertRaises(ValueError):
                materials.validate_source_archive(self.zip(f'bad-{index}.zip', entries), application=True)

    def test_archive_link_and_native_binary_rejection_keeps_destination_untouched(self):
        linked = self.root / 'link.tar'
        with tarfile.open(linked, 'w') as archive:
            member = tarfile.TarInfo('Source/link'); member.type = tarfile.SYMTYPE; member.linkname = '../../outside'
            archive.addfile(member)
        with self.assertRaises(ValueError): materials.validate_source_archive(linked)
        for index, data in enumerate((b'\x7fELFnative', b'\xcf\xfa\xed\xfenative', b'MZnative',
                                      b'\xbe\xba\xfe\xcanative', b'\xca\xfe\xba\xbfnative')):
            with self.subTest(index=index), self.assertRaises(ValueError):
                materials.validate_source_archive(self.zip(f'executable-{index}.zip', [('Source/no-extension', data)]))
        self.assertFalse((self.root / 'outside').exists())

    def test_archive_resource_ceiling_and_unreduced_path_rejected_without_extraction(self):
        archive = self.zip('bounded.zip', [('Source/a.py', b'12345')])
        with patch.object(materials, 'MAX_EXPANDED', 4):
            with self.assertRaises(ValueError): materials.validate_source_archive(archive)
        for path in ('Source//a.py', './Source/a.py', 'C:/a.py', 'Source\\a.py'):
            with self.subTest(path=path), self.assertRaises(ValueError): materials.safe_member(path)

    def test_application_source_cannot_be_a_readme_only_or_split_root_placeholder(self):
        incomplete = self.zip('readme-only.zip', [('Project/README.md', b'description only')])
        with self.assertRaises(ValueError):
            materials.validate_source_archive(incomplete, application=True, require_full_application=True)
        split = self.zip('split-root.zip', [('One/Package.swift', b'// package')] +
            [('Other/' + member, b'// source') for member in materials.APPLICATION_REQUIRED if member != 'Package.swift'])
        with self.assertRaises(ValueError):
            materials.validate_source_archive(split, application=True, require_full_application=True)
        complete = self.zip('rooted-source.zip', [('Project/' + member, b'// source')
                                                for member in materials.APPLICATION_REQUIRED])
        self.assertTrue(materials.validate_source_archive(complete, application=True,
            require_full_application=True)['essentialApplicationFilesPresent'])

    def command(self, *, bad_dependency=False, bad_rpath=False, architecture='arm64'):
        def run(*args):
            if args[0] == '/usr/bin/lipo': return architecture + '\n'
            if args[0] == '/usr/bin/otool' and args[1] == '-L':
                links = ['@rpath/libheif.1.dylib', '/usr/lib/libSystem.B.dylib']
                if bad_dependency: links.append('/absolute/unowned/libexternal.dylib')
                return str(args[-1]) + ':\n' + ''.join('\t' + value + ' (compatibility version 1.0.0)\n' for value in links)
            if args[0] == '/usr/bin/otool' and args[1] == '-l':
                helper = str(args[-1]).endswith('HEICCPUEncoder')
                value = '/absolute/unowned' if bad_rpath else '@loader_path/../Frameworks/HEIC'
                return 'cmd LC_RPATH\ncmdsize 56\npath ' + value + ' (offset 12)\n' if helper else ''
            if args[0] == '/usr/bin/codesign': return ''
            raise AssertionError('Unexpected native command in controlled metadata test')
        return run

    def test_macho_closure_requires_explicit_architecture_known_links_and_helper_rpath(self):
        helper = self.file('HEICCPUEncoder')
        links = relink.inspect_macho(helper, 'arm64', helper=True, command=self.command())
        self.assertIn('@rpath/libheif.1.dylib', links)
        for command in (self.command(bad_dependency=True), self.command(bad_rpath=True),
                        self.command(architecture='x86_64')):
            with self.assertRaises(ValueError): relink.inspect_macho(helper, 'arm64', helper=True, command=command)
        original_command = self.command()
        def traversal(*args):
            output = original_command(*args)
            return output.replace('/usr/lib/libSystem.B.dylib', '/usr/lib/../../unowned.dylib')
        with self.assertRaises(ValueError):
            relink.inspect_macho(helper, 'arm64', helper=True, command=traversal)

    def app(self):
        app = self.root / 'original.app'
        helper = self.file('original.app/' + relink.HELPER, b'controlled helper; not Mach-O')
        rows = []
        for name in relink.LIBRARIES:
            path = self.file('original.app/' + relink.FRAMEWORK + '/' + name, name.encode())
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            rows.append({'name': name, 'signedSHA256': digest, 'upstreamBuildSHA256': digest})
        info = {'CFBundleIdentifier': 'synthetic.bluraction',
            'BlurActionHEICCPUEncoderSHA256': hashlib.sha256(helper.read_bytes()).hexdigest(),
            'BlurActionHEICCPULibrarySHA256': {row['name']: row['signedSHA256'] for row in rows}}
        self.file('original.app/Contents/Info.plist', plistlib.dumps(info))
        self.file('original.app/Contents/MacOS/BlurAction', b'controlled app; not Mach-O')
        self.file('original.app/' + relink.RESOURCES + '/manifest.json',
                  json.dumps({'architecture': 'arm64', 'libraries': rows, 'sources': [],
                              'helperSignedSHA256': info['BlurActionHEICCPUEncoderSHA256']}).encode())
        replacements = {name: self.file('modified/' + name, b'modified ' + name.encode()) for name in relink.LIBRARIES}
        return app, replacements

    def test_owner_copy_updates_integrity_without_mutating_originals_or_claiming_source_or_encode(self):
        app, replacements = self.app()
        before = relink.tree_inventory(app)
        input_bytes = {name: path.read_bytes() for name, path in replacements.items()}
        output = self.root / 'owner-modified.app'
        report = relink.relink(app, replacements, output, command=self.command())
        self.assertTrue(report['originalsPreserved'])
        self.assertFalse(report['encodeVerified']); self.assertFalse(report['sourceCorrespondenceVerified'])
        self.assertFalse(report['notarized']); self.assertFalse(report['releaseApproved'])
        self.assertEqual(relink.tree_inventory(app), before)
        info = plistlib.loads((output / 'Contents/Info.plist').read_bytes())
        for name, data in input_bytes.items():
            self.assertEqual(replacements[name].read_bytes(), data)
            self.assertEqual((output / relink.FRAMEWORK / name).read_bytes(), data)
            self.assertEqual(info['BlurActionHEICCPULibrarySHA256'][name], hashlib.sha256(data).hexdigest())
        modified = json.loads((output / relink.RESOURCES / 'manifest.json').read_bytes())
        self.assertEqual(modified['libraries'], modified['replacementLibraries'])
        self.assertTrue(modified['sourcesDescribeOriginalBuild'])
        self.assertFalse(modified['sourceCorrespondenceVerified'])
        with self.assertRaises(ValueError): relink.relink(app, replacements, output, command=self.command())

    def test_relink_failure_retains_explicit_failed_copy_and_journal_originals_intact(self):
        app, replacements = self.app(); before = relink.tree_inventory(app)
        output = self.root / 'rejected.app'
        with self.assertRaisesRegex(ValueError, 'link closure'):
            relink.relink(app, replacements, output, command=self.command(bad_dependency=True))
        self.assertEqual(relink.tree_inventory(app), before)
        report = json.loads(output.with_name(output.name + '.relink.json').read_text())
        self.assertEqual(report['status'], 'failed-or-incomplete')
        self.assertTrue(report['originalsPreserved'])
        self.assertTrue(output.is_dir())

    def test_source_material_sha_requires_canonical_exact_digest(self):
        for value in ('0' * 63, 'A' * 64, True, None, '0' * 64 + '\n'):
            with self.subTest(value=value), self.assertRaises(ValueError): materials.pinned_digest(value)
        self.assertEqual(materials.pinned_digest('0' * 64), '0' * 64)

    def prepared_materials(self):
        """Injected observation seam for ZIP ownership, not acquisition proof."""
        original = self.file('corresponding.cpp', b'actual controlled source\n')
        app = self.root / 'readonly-app'; app.mkdir()
        (app / 'source-sentinel').write_bytes(b'preserve app observer')
        rows = {'recipe/helper.cpp': materials.captured_file(original)}
        return original, ({'recipe/helper.cpp': original}, rows,
            {'releaseApproved': False, 'completeLegalCorrespondingSourceCertified': False},
            (app, materials.io_helpers.tree_inventory(app), {}))

    def test_zip_readback_records_exact_sources_preserves_inputs_and_never_overwrites(self):
        original, prepared = self.prepared_materials()
        before = original.read_bytes(); output = self.root / 'materials.zip'
        with patch.object(materials, 'source_materials', return_value=prepared):
            report = materials.package(None, None, None, None, None, None, None, None, None, output)
            with self.assertRaises(ValueError):
                materials.package(None, None, None, None, None, None, None, None, None, output)
        self.assertTrue(report['originalsPreserved']); self.assertFalse(report['releaseApproved'])
        self.assertEqual(original.read_bytes(), before)
        with zipfile.ZipFile(output) as archive:
            self.assertEqual(set(archive.namelist()), {'recipe/helper.cpp', 'build-settings.json', 'manifest.json'})
            self.assertEqual(archive.read('recipe/helper.cpp'), before)
            recorded = json.loads(archive.read('manifest.json'))
            self.assertEqual(recorded['files']['recipe/helper.cpp']['sha256'], hashlib.sha256(before).hexdigest())
            self.assertFalse(json.loads(archive.read('build-settings.json'))['completeLegalCorrespondingSourceCertified'])

    def test_changed_input_keeps_incomplete_zip_without_false_manifest_or_public_unlink(self):
        original, prepared = self.prepared_materials(); before = original.read_bytes()
        output = self.root / 'incomplete.zip'; actual_write = zipfile.ZipFile.write
        def after_snapshot(archive, *args, **kwargs):
            result = actual_write(archive, *args, **kwargs)
            original.write_bytes(b'changed during ZIP creation\n')
            return result
        with patch.object(materials, 'source_materials', return_value=prepared), \
             patch.object(zipfile.ZipFile, 'write', autospec=True, side_effect=after_snapshot):
            with self.assertRaisesRegex(ValueError, 'changed'):
                materials.package(None, None, None, None, None, None, None, None, None, output)
        self.assertTrue(output.exists())
        with zipfile.ZipFile(output) as archive:
            self.assertEqual(archive.read('recipe/helper.cpp'), before)
            self.assertNotIn('manifest.json', archive.namelist())

    def test_owned_cleanup_keeps_primary_and_still_closes_after_failure(self):
        primary = ValueError('controlled input failure')
        cleanup = OSError('controlled owned-close failure')
        class Resource:
            closed = False
            def close(self):
                self.closed = True
                raise cleanup
        resource = Resource()
        with self.assertRaises(ValueError) as observed:
            with materials.managed(resource):
                raise primary
        self.assertIs(observed.exception, primary)
        self.assertTrue(resource.closed)
        self.assertIsNot(primary.__cause__, primary)
        self.assertTrue(any('OSError' in note for note in primary.__notes__))
        with self.assertRaises(OSError) as observed_cleanup:
            with materials.managed(Resource()):
                pass
        self.assertIs(observed_cleanup.exception, cleanup)
