"""Static contracts only; native compilation and installation are separate evidence."""
from pathlib import Path
import contextlib
import hashlib
import io
import json
import sys
import tempfile
import unittest
from unittest.mock import patch
from shared import windows_package_receipt as files

ROOT = Path(__file__).resolve().parents[2]

class PersonalInstallerTests(unittest.TestCase):
    def test_validator_python_compiles(self):
        ps = (ROOT/'platforms/windows/installer/build_personal_installer.ps1').read_text(encoding='utf-8')
        validator = ps.split("$Validator = @'\n",1)[1].split("\n'@",1)[0]
        compile(validator, '<personal installer validator>', 'exec')
        for gate in ('actual != recorded', "mode='prepare'", "'frozen-smoke-pass'", "'executableSHA256'", "'bundleUnchanged'", 'f.tree_files(bundle)', 'f.plain(p)'):
            self.assertIn(gate, validator)
        self.assertIn('$After -cne $Before', ps)
        self.assertIn("licenseReview='pending'", ps)
        self.assertNotIn("mode='finalize'", ps)

    def run_authored_validator(self, mutation=None, output_kind='sibling'):
        """Authored file validation; runtime/receipt observers mocked, never Windows proof."""
        ps = (ROOT/'platforms/windows/installer/build_personal_installer.ps1').read_text(encoding='utf-8')
        validator = ps.split("$Validator = @'\n",1)[1].split("\n'@",1)[0]
        with tempfile.TemporaryDirectory() as td:
            root = Path(td).resolve()/'repo'; root.mkdir()
            build = root/'.build'; build.mkdir()
            bundle = build/'candidate'; bundle.mkdir()
            (bundle/'licenses').mkdir()
            for name in ('BlurAction.exe','LICENSE.txt','licenses/NOTICE.txt','licenses/dependencies.json'):
                (bundle/name).write_text('authored fixture')
            actual = {name:files.sha(path) for name,path in files.tree_files(bundle).values()}
            manifest = build/'manifest.json'
            manifest.write_text(json.dumps([{'path':'BlurAction/'+n,'sha256':h} for n,h in actual.items()]))
            artifacts=build/'artifacts'; artifacts.mkdir()
            receipt=build/'receipt.json'; receipt.write_text(json.dumps({'app_source':{'sha256':'a'*64}}))
            frozen_dir=build/'frozen'; frozen_dir.mkdir(); (frozen_dir/'smoke').mkdir()
            smoke=frozen_dir/'smoke/report.json'; smoke.write_text('{}')
            log=frozen_dir/'execution.log'; log.write_text('authored fixture')
            report={'status':'frozen-smoke-pass','actualWindows':True,'bundleUnchanged':True,
                'exit':0,'timedOut':False,'executableSHA256':actual['BlurAction.exe'],
                'bundleSHA256':hashlib.sha256(json.dumps(actual,sort_keys=True,separators=(',',':')).encode()).hexdigest(),
                'OSInput':False,'installerVerified':False,'userAcceptanceVerified':False,'redistributionApproved':False,
                'smokeReportSHA256':files.sha(smoke),'logSHA256':files.sha(log)}
            frozen=frozen_dir/'execution.json'; frozen.write_text(json.dumps(report))
            compiler=build/'compiler.exe'; compiler.write_text('authored compiler')
            recipe=root/'recipe.iss'; recipe.write_text('authored recipe')
            out=build/'personal-installer' if output_kind=='sibling' else bundle/'installer'
            if mutation=='bundle': (bundle/'LICENSE.txt').write_text('changed')
            if mutation=='extra': (bundle/'extra.dll').write_text('unexpected')
            if mutation=='smoke': smoke.write_text('{"changed":true}')
            if mutation=='frozen-census':
                report['bundleSHA256']='b'*64; frozen.write_text(json.dumps(report))
            argv=['validator',*map(str,(root,bundle,manifest,receipt,artifacts,frozen,compiler,recipe,out))]
            with patch.object(sys,'argv',argv), patch.object(sys,'platform','win32'), \
                    patch.object(files,'require_amd64'), \
                    patch.object(files,'validate_receipt',return_value={'ok':True,'host':'win32'}) as receipt_check, \
                    contextlib.redirect_stdout(io.StringIO()) as output:
                exec(compile(validator,'<authored validator>','exec'), {})
            self.assertEqual(receipt_check.call_args.kwargs['mode'],'prepare')
            return json.loads(output.getvalue())

    def test_authored_repo_build_sibling_is_allowed(self):
        self.assertEqual(self.run_authored_validator()['source'], 'a'*64)

    def test_authored_inputs_reject_changed_or_unbound_bytes(self):
        for mutation in ('bundle','extra','smoke','frozen-census'):
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                self.run_authored_validator(mutation=mutation)

    def test_authored_output_must_not_overlap_bundle(self):
        with self.assertRaises(ValueError):
            self.run_authored_validator(output_kind='bundle')

    def test_personal_installer_is_isolated_and_never_launches(self):
        iss = (ROOT/'platforms/windows/installer/BlurAction-personal.iss').read_text(encoding='utf-8')
        for requirement in ('PrivilegesRequired=lowest', 'BlurAction.Windows.PersonalTest.',
                'Programs\\BlurAction-PrivateTest\\', 'DirExists', 'CloseApplications=no',
                'RestartApplications=no', 'personal-test-status.json'):
            self.assertIn(requirement, iss)
        for prohibited in ('[Run]', '[Registry]', '[UninstallDelete]', 'reviewed-bundle.json'):
            self.assertNotIn(prohibited, iss)

    def test_final_installer_still_requires_review(self):
        ps = (ROOT/'platforms/windows/installer/build_installer.ps1').read_text(encoding='utf-8')
        self.assertIn('$Review.status -ne "reviewed"', ps)
        self.assertIn('"--mode", "finalize"', ps)
        self.assertNotIn('Personal', ps)

if __name__ == '__main__':
    unittest.main()
