"""Offline parser/acquisition-contract tests; no package or signer is executed.

The 24 public name/version/file/SHA rows came from the retained CI11 repository
snapshot. Test DBs are authored tar images with synthetic signature framing,
NOT cryptographic PGP proof or a bundled MSYS database.
"""
import base64
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('owned_recipe_signatures_support',
    REPO / 'build-recipes/windows-owned-ffmpeg/recipe_support.py')
support = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(support)

# Explicit public package metadata only; no author/runner/private paths.
OBSERVED_CLOSURE = [['mingw-w64-x86_64-libwinpthread', '14.0.0.r426.g4564ee4b5-1', 'mingw-w64-x86_64-libwinpthread-14.0.0.r426.g4564ee4b5-1-any.pkg.tar.zst', '543017ce2731292b215bf1d36fd70a86d8a8d5ed0afba9d3db9fff89804cda71', 'mingw64.db'], ['mingw-w64-x86_64-libatomic', '16.2.0-4', 'mingw-w64-x86_64-libatomic-16.2.0-4-any.pkg.tar.zst', 'c71710695b1a49a089e82c4fc4e2247003bfb7ac8ef3327291880eaa59dcebdc', 'mingw64.db'], ['mingw-w64-x86_64-libgcc', '16.2.0-4', 'mingw-w64-x86_64-libgcc-16.2.0-4-any.pkg.tar.zst', 'd615f6a8536ca16b1f049daea1fa440a3b7a405449ec0e93ad6106db43682d54', 'mingw64.db'], ['mingw-w64-x86_64-tzdata', '2026e-1', 'mingw-w64-x86_64-tzdata-2026e-1-any.pkg.tar.zst', '6d28805f8fb6517011cc309aa452111565afa1bc9188ad784cb5f62df98f0988', 'mingw64.db'], ['mingw-w64-x86_64-libstdc++', '16.2.0-4', 'mingw-w64-x86_64-libstdc++-16.2.0-4-any.pkg.tar.zst', '3d4c3faf4c2c5c7a851ff12214ddcbf8c0d6df0964fc1d3ebd8c38f227183034', 'mingw64.db'], ['mingw-w64-x86_64-libquadmath', '16.2.0-4', 'mingw-w64-x86_64-libquadmath-16.2.0-4-any.pkg.tar.zst', '70317ed08299f8e40af8354e124db33fcf47840ec8cefbea5d7134c6d136d13e', 'mingw64.db'], ['mingw-w64-x86_64-cc-libs', '16.2.0-4', 'mingw-w64-x86_64-cc-libs-16.2.0-4-any.pkg.tar.zst', '691c243e8df80ab075cabf79236b9e2281907fb1f3ac7206fe3a2d71269e4fa2', 'mingw64.db'], ['mingw-w64-x86_64-libiconv', '1.19-1', 'mingw-w64-x86_64-libiconv-1.19-1-any.pkg.tar.zst', '21e334d0911f25de75d3e18e0697648bcecfa9658256d600cad0827d719c2f35', 'mingw64.db'], ['mingw-w64-x86_64-gettext-runtime', '1.0-1', 'mingw-w64-x86_64-gettext-runtime-1.0-1-any.pkg.tar.zst', 'be68d7f260633284b910c588c6d82ee304a81c8817a686d2cd9df83f872c27af', 'mingw64.db'], ['mingw-w64-x86_64-zlib', '1.3.2-2', 'mingw-w64-x86_64-zlib-1.3.2-2-any.pkg.tar.zst', '9e75842a070ba648e986e12424e1c92c9d7d77200e85f6a34eeb600819f2e694', 'mingw64.db'], ['mingw-w64-x86_64-zstd', '1.5.7-2', 'mingw-w64-x86_64-zstd-1.5.7-2-any.pkg.tar.zst', '1add6705b344664f6aca108c85f79ab5bdd9e1162662bb06a4cf40a34f6e0907', 'mingw64.db'], ['mingw-w64-x86_64-binutils', '2.47-3', 'mingw-w64-x86_64-binutils-2.47-3-any.pkg.tar.zst', '827363748ce3320683319d860ee4fcfcdbb36baf66aac6dab0ec3822be2d4ff7', 'mingw64.db'], ['mingw-w64-x86_64-headers', '14.0.0.r426.g4564ee4b5-1', 'mingw-w64-x86_64-headers-14.0.0.r426.g4564ee4b5-1-any.pkg.tar.zst', 'b6f06085e8f3858cb59ed72d581203c75000592bdaa55af2710be3b1a752a7bb', 'mingw64.db'], ['mingw-w64-x86_64-crt', '14.0.0.r426.g4564ee4b5-1', 'mingw-w64-x86_64-crt-14.0.0.r426.g4564ee4b5-1-any.pkg.tar.zst', '5513117e204c933ed3b3e17b1bb809667653b72b3ca932d0c048ffc8f01f3801', 'mingw64.db'], ['mingw-w64-x86_64-gmp', '6.3.0-2', 'mingw-w64-x86_64-gmp-6.3.0-2-any.pkg.tar.zst', '8924433974c4add46cb46ea4f6ef283b5c5139d3f552375115b5580f855015cc', 'mingw64.db'], ['mingw-w64-x86_64-isl', '0.28-1', 'mingw-w64-x86_64-isl-0.28-1-any.pkg.tar.zst', '03ed191718a89edc46e783deed46b8fd20ec47a09fcdefb37c6c4169b6188b08', 'mingw64.db'], ['mingw-w64-x86_64-mpfr', '4.2.2-3', 'mingw-w64-x86_64-mpfr-4.2.2-3-any.pkg.tar.zst', '9ecbc05f1f855bc656a8f111d367f61fbd90dbbfcf469ba74d6d5dd1ec07a542', 'mingw64.db'], ['mingw-w64-x86_64-mpc', '1.4.1-1', 'mingw-w64-x86_64-mpc-1.4.1-1-any.pkg.tar.zst', 'ce024a90d59c8a591d2c88ef94a386c6367750bf9edc6a944e80815ec5d93344', 'mingw64.db'], ['mingw-w64-x86_64-windows-default-manifest', '20260815-1', 'mingw-w64-x86_64-windows-default-manifest-20260815-1-any.pkg.tar.zst', 'd2dd9a4f3a3362bc85ca273dff2b0f9868cfba7ba60151499b5935a049f00d74', 'mingw64.db'], ['mingw-w64-x86_64-winpthreads', '14.0.0.r426.g4564ee4b5-1', 'mingw-w64-x86_64-winpthreads-14.0.0.r426.g4564ee4b5-1-any.pkg.tar.zst', 'f8e8cea030192fedc17a41167a868c4de909ebf01ea9730d8d1133641b208785', 'mingw64.db'], ['mingw-w64-x86_64-gcc', '16.2.0-4', 'mingw-w64-x86_64-gcc-16.2.0-4-any.pkg.tar.zst', '7928a168fe0827e6ba41ea672a9957a5bfa47f732f6922e86cf0f24dd61e5d0c', 'mingw64.db'], ['mingw-w64-x86_64-nasm', '3.02-1', 'mingw-w64-x86_64-nasm-3.02-1-any.pkg.tar.zst', '63493c3f1ee2ea71727acfc338c53a6f5a18d1c2c21cdb5d39dea227756e2fe4', 'mingw64.db'], ['mingw-w64-x86_64-pkgconf', '1~3.0.7-1', 'mingw-w64-x86_64-pkgconf-1~3.0.7-1-any.pkg.tar.zst', '37b97f372409fa7cf54d709bab892f34e9c62d2658230a09f783a89a55ae590e', 'mingw64.db'], ['make', '4.4.1-3', 'make-4.4.1-3-x86_64.pkg.tar.zst', 'af0bdba17f06fe037f0194069adaa31a8fe45f1a11381501896aea1fae37bd5d', 'msys.db']]


def signature():
    # Old-format signature tag2 / two-byte body length. Structural fixture only.
    body = bytes([4, 0, 1, 8]) + b'\0' * 558
    return b'\x89' + len(body).to_bytes(2, 'big') + body


def write_db(path, rows, *, changes=None, duplicate=None, unsafe=False):
    changes = changes or {}
    with tarfile.open(path, 'w:gz') as archive:
        for row in rows:
            name, version, filename, digest, database = row
            data = {'NAME':[name], 'VERSION':[version], 'FILENAME':[filename],
                    'SHA256SUM':[digest]}
            if name == 'make': data['PGPSIG'] = [base64.b64encode(signature()).decode()]
            data.update(changes.get(name, {}))
            raw = ''.join('%' + k + '%\n' + '\n'.join(v) + '\n\n' for k,v in data.items()).encode()
            leaf = name + '-' + version + '/desc'
            entry = tarfile.TarInfo('../outside/desc' if unsafe else leaf)
            entry.size = len(raw); archive.addfile(entry, io.BytesIO(raw))
            if duplicate == name:
                second = tarfile.TarInfo('duplicate-' + leaf)
                second.size = len(raw); archive.addfile(second, io.BytesIO(raw))


def setup(root, *, changes=None, duplicate=None, unsafe=False):
    (root/'owned.json').write_text('{}')
    (root/'downloads').mkdir(); (root/'reports').mkdir()
    lines = []
    for name, version, filename, digest, database in OBSERVED_CLOSURE:
        prefix = '/mingw/mingw64/' if database == 'mingw64.db' else '/msys/x86_64/'
        lines.append('|'.join([name,version,filename,digest,'https://repo.msys2.org'+prefix+filename]))
    (root/'pacman-plan.txt').write_text('\n'.join(lines)+'\n')
    for db in ('msys.db','mingw64.db'):
        write_db(root/'reports'/db,[r for r in OBSERVED_CLOSURE if r[4]==db],
                 changes=changes,duplicate=duplicate,unsafe=unsafe)


class Response(io.BytesIO):
    def __init__(self, data, url, declared=None):
        super().__init__(data); self.url=url
        self.headers={} if declared is None else {'Content-Length':str(declared)}
    def geturl(self): return self.url


class OwnedSignatureTests(unittest.TestCase):
    def test_observed_24_closure_exact_metadata_and_23_detached_routes(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder).resolve(); setup(root)
            rows, hashes=support.resolve_package_plan(root)
            self.assertEqual(len(rows),24)
            self.assertEqual(sum('_embedded_signature' in r for r in rows),1)
            for r in rows:
                self.assertEqual(r['databaseSHA256'],support.sha(root/'reports'/r['database']))
            self.assertEqual(set(hashes),{'msys.db','mingw64.db'})
            self.assertEqual(next(r for r in rows if '_embedded_signature' in r)['name'],'make')

    def test_lock_records_exact_signature_hash_source_type_and_db_binding(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder).resolve(); setup(root); urls=[]; acquired=[]
            def fetch(url): urls.append(url); return signature()
            def download(directory,row):
                acquired.append((row['name'],row['sha256']))
                p=directory/'downloads'/row['filename']; p.write_bytes(b'controlled mock acquisition')
                return p
            with patch.object(support,'fetch_package_signature',side_effect=fetch), \
                    patch.object(support,'download',side_effect=download): support.package_lock(root)
            lock=json.loads((root/'reports/compiler-packages-lock.json').read_text())
            self.assertEqual(len(acquired),24);self.assertEqual(len(urls),23)
            self.assertTrue(all(u.startswith('https://repo.msys2.org/mingw/mingw64/') and u.endswith('.sig') for u in urls))
            self.assertEqual([d for _,d in acquired],[r[3] for r in OBSERVED_CLOSURE])
            for r in lock['packages']:
                sig=(root/'downloads'/r['signature']['filename']).read_bytes()
                self.assertEqual(r['signature']['sha256'],hashlib.sha256(sig).hexdigest())
                self.assertFalse(r['signature']['PGPVerified'])
                self.assertEqual(r['databaseSHA256'],lock['repositoryDatabaseSHA256'][r['database']])
                expected='repository-embedded-PGPSIG' if r['name']=='make' else 'same-official-package-detached-signature'
                self.assertEqual(r['signature']['sourceType'],expected)

    def test_entire_plan_db_version_filename_sha_and_name_must_match(self):
        name=OBSERVED_CLOSURE[0][0]
        for field,value in [('VERSION',['new']),('FILENAME',['other.pkg.tar.zst']),
                            ('SHA256SUM',['0'*64]),('NAME',['renamed'])]:
            with self.subTest(field=field),tempfile.TemporaryDirectory() as folder:
                root=Path(folder).resolve();setup(root,changes={name:{field:value}})
                with patch.object(support,'download') as acquire, \
                        patch.object(support,'fetch_package_signature') as fetch:
                    with self.assertRaises(ValueError): support.package_lock(root)
                    acquire.assert_not_called(); fetch.assert_not_called()

    def test_missing_duplicate_unsafe_and_description_budgets_fail_before_acquisition(self):
        name=OBSERVED_CLOSURE[0][0]
        for options in ({'duplicate':name},{'unsafe':True},{}):
            with self.subTest(options=options),tempfile.TemporaryDirectory() as folder:
                root=Path(folder).resolve();setup(root,**options)
                if not options:
                    write_db(root/'reports/mingw64.db',[])
                with self.assertRaises(ValueError): support.resolve_package_plan(root)
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder).resolve();setup(root)
            with patch.object(support,'MAX_DESC_BYTES',8),self.assertRaises(ValueError):
                support.resolve_package_plan(root)
            with patch.object(support,'MAX_DB_MEMBERS',1),self.assertRaises(ValueError):
                support.resolve_package_plan(root)
            with patch.object(support,'MAX_DB_BYTES',8),self.assertRaises(ValueError):
                support.resolve_package_plan(root)
            with patch.object(support,'MAX_DB_EXPANDED_BYTES',32),self.assertRaises(ValueError):
                support.resolve_package_plan(root)

    def test_fixed_compiler_pin_and_five_fields_remain_mandatory(self):
        for change in ('six','version','url','duplicate'):
            with self.subTest(change=change),tempfile.TemporaryDirectory() as folder:
                root=Path(folder).resolve();setup(root);p=root/'pacman-plan.txt';lines=p.read_text().splitlines()
                if change=='six':lines[0]+='|not-allowed-signature-field'
                elif change=='version':
                    i=next(i for i,l in enumerate(lines) if l.startswith('mingw-w64-x86_64-gcc|'))
                    values=lines[i].split('|');values[1]='16.2.0-5';lines[i]='|'.join(values)
                elif change=='url':lines[0]=lines[0].replace('repo.msys2.org','example.invalid')
                else:lines.append(lines[0])
                p.write_text('\n'.join(lines))
                with self.assertRaises(ValueError):support.resolve_package_plan(root)

    def test_invalid_embedded_signature_never_falls_back_to_https(self):
        for encoded in ('%%%','',base64.b64encode(b'HTML'*50).decode()):
            with self.subTest(encoded=encoded[:8]),tempfile.TemporaryDirectory() as folder:
                root=Path(folder).resolve();setup(root,changes={'make':{'PGPSIG':[encoded]}})
                with patch.object(support,'fetch_package_signature') as fetch:
                    with self.assertRaises(ValueError):support.package_lock(root)
                    fetch.assert_not_called()

    def test_http_signature_failure_and_invalid_bytes_publish_no_lock(self):
        for fault in (OSError('HTTP failed'),b'x'*566,b'',b'x'*65537):
            with self.subTest(fault=str(fault)[:20]),tempfile.TemporaryDirectory() as folder:
                root=Path(folder).resolve();setup(root)
                kwargs={'side_effect':fault} if isinstance(fault,Exception) else {'return_value':fault}
                with patch.object(support,'fetch_package_signature',**kwargs),patch.object(support,'download') as acquire:
                    with self.assertRaises((ValueError,OSError)):support.package_lock(root)
                    self.assertFalse((root/'reports/compiler-packages-lock.json').exists())
                    acquire.assert_not_called()

    def test_detached_fetch_exact_https_route_size_and_packet_no_pgp_claim(self):
        url='https://repo.msys2.org/mingw/mingw64/package.pkg.tar.zst.sig'
        class Opener:
            def open(self,request,timeout):
                self_url=request.full_url
                self.assertion=(self_url,timeout)
                return Response(signature(),url,len(signature()))
        opener=Opener()
        with patch.object(support.urllib.request,'build_opener',return_value=opener):
            self.assertEqual(support.fetch_package_signature(url),signature())
        self.assertEqual(opener.assertion,(url,15))
        for bad in ('http://repo.msys2.org/mingw/mingw64/package.pkg.tar.zst.sig',
                    url+'?query=1',url.replace('repo.msys2.org','other.invalid')):
            with self.assertRaises(ValueError):support.fetch_package_signature(bad)
        for data,declared,final in ((signature(),5,url),(signature(),None,url+'?x'),
                                  (b'x'*65537,None,url),(b'x'*566,None,url)):
            response=Response(data,final,declared)
            with patch.object(support.urllib.request,'build_opener') as build:
                build.return_value.open.return_value=response
                with self.assertRaises(ValueError):support.fetch_package_signature(url)
        redirect=support.PackageSignatureRedirects(url)
        with self.assertRaises(ValueError):
            redirect.redirect_request(None,None,302,'',{},url.replace('repo.msys2.org','github.com'))

    def test_database_change_during_acquisition_leaves_no_install_lock(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder).resolve();setup(root);original=(root/'reports/mingw64.db').read_bytes()
            def acquired(directory,row):
                with (root/'reports/mingw64.db').open('ab') as stream:stream.write(b'changed')
            with patch.object(support,'fetch_package_signature',return_value=signature()), \
                    patch.object(support,'download',side_effect=acquired):
                with self.assertRaisesRegex(ValueError,'changed during acquisition'):support.package_lock(root)
            self.assertFalse((root/'reports/compiler-packages-lock.json').exists())
            self.assertTrue((root/'reports/mingw64.db').read_bytes().startswith(original))

    def test_mock_http_package_acquisition_still_enforces_actual_expected_sha(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder).resolve();(root/'downloads').mkdir()
            url='https://repo.msys2.org/mingw/mingw64/source.pkg.tar.zst'
            row={'filename':'source.pkg.tar.zst','sha256':hashlib.sha256(b'expected').hexdigest(),'url':url}
            with patch.object(support.urllib.request,'build_opener') as build:
                build.return_value.open.return_value=Response(b'changed',url)
                with self.assertRaisesRegex(ValueError,'SHA mismatch'):support.download(root,row)
            self.assertEqual((root/'downloads/source.pkg.tar.zst').read_bytes(),b'changed')
            self.assertFalse((root/'reports/compiler-packages-lock.json').exists())

    def test_plan_change_during_acquisition_leaves_no_install_lock(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder).resolve();setup(root)
            def acquired(directory,row):
                with (root/'pacman-plan.txt').open('ab') as stream:stream.write(b'changed')
            with patch.object(support,'fetch_package_signature',return_value=signature()), \
                    patch.object(support,'download',side_effect=acquired):
                with self.assertRaisesRegex(ValueError,'plan changed during acquisition'):support.package_lock(root)
            self.assertFalse((root/'reports/compiler-packages-lock.json').exists())

    def test_packet_framing_rejects_truncation_html_partial_lengths_and_extra_packets(self):
        self.assertEqual(support._signature_bytes(signature()),signature())
        for data in (signature()[:-1],signature()+b'x',b'<html>'+b'x'*200,
                     b'\xc2\xe0'+b'x'*200,b'\x8b'+b'x'*200):
            with self.subTest(header=data[:2]),self.assertRaises(ValueError):support._signature_bytes(data)


if __name__=='__main__':unittest.main()
