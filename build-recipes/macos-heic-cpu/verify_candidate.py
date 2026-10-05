"""Disposable source-only HEIC diagnostic; no installed-app or release actions."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import signal
import subprocess
import sys
import uuid
import zipfile
from owned_process import finish_owned_group

HERE = Path(__file__).resolve().parent

def sha(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()

def owned_run(root, stem, argv, timeout):
    with (root/(stem+'.log')).open('xb') as f:
        child = subprocess.Popen(argv, stdout=f, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            return child.wait(timeout=timeout)
        except BaseException:
            try:
                os.killpg(child.pid, signal.SIGTERM)
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
            except ProcessLookupError:
                child.wait()
            raise
        finally:
            finish_owned_group(child)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repository', type=Path, required=True)
    args = parser.parse_args()
    repo = args.repository.resolve()
    HERE.relative_to(repo/'build-recipes/macos-heic-cpu')
    machine = platform.machine()
    if sys.platform != 'darwin' or machine not in ('arm64','x86_64'):
        raise ValueError('Actual supported Mac host required')
    parent = repo/'.build'
    parent.mkdir(exist_ok=True)
    if parent.is_symlink() or parent.resolve()!=parent:
        raise ValueError('Plain owned build parent required')
    root = parent/('mac-heic-cpu-verification-'+str(uuid.uuid4()))
    root.mkdir(mode=0o700)
    baseline = {p.name:sha(p) for p in HERE.iterdir() if p.is_file()}
    report = {'status':'failed-or-incomplete','host':sys.platform,'macOS':platform.mac_ver()[0],
              'architecture':machine,'sourceSHA256':baseline,'OSInput':False,
              'installed':False,'appIntegrated':False,'fullHEICCompatibilityClosed':False,
              'HDRVerified':False,'releaseApproved':False}
    try:
        tools = root/'tools';tools.mkdir(mode=0o700)
        rows = json.loads((HERE/'tool-pins.json').read_text())
        selected = [r for r in rows if r['name']=='cmake' or r['filename'].endswith(machine+'.whl')]
        if len(selected)!=2 or {r['name'] for r in selected}!={'cmake','pkgconf'}:
            raise ValueError('Exact tool selection unavailable')
        for row in selected:
            if not row['url'].startswith('https://files.pythonhosted.org/'):
                raise ValueError('Official tool source required')
            archive = tools/row['filename']
            code = owned_run(root,'download-'+row['name'],['/usr/bin/curl','--disable',
                '--fail','--location','--proto','=https','--proto-redir','=https',
                '--connect-timeout','10','--max-time','90','--max-filesize','104857600',
                '--output',str(archive),row['url']],100)
            if code or archive.stat().st_size!=row['bytes'] or sha(archive)!=row['sha256']:
                raise ValueError('Tool download/hash mismatch')
            destination=tools/row['name'];destination.mkdir(mode=0o700)
            with zipfile.ZipFile(archive) as z:
                members=z.infolist()
                if len(members)>20000 or sum(m.file_size for m in members)>300*1024**2:
                    raise ValueError('Bounded tool archive required')
                names=set()
                for m in members:
                    rel=PurePosixPath(m.filename)
                    if rel.is_absolute() or '..' in rel.parts or not rel.parts or m.filename in names or ((m.external_attr>>16)&0o170000)==0o120000:
                        raise ValueError('Plain tool archive members required')
                    names.add(m.filename)
                z.extractall(destination)
                for m in members:
                    p=destination/m.filename
                    if p.is_file():p.chmod((m.external_attr>>16)&0o777 or 0o600)
        (root/'tool-acquisition.json').write_text(json.dumps(selected,indent=2))
        cmake=tools/'cmake/cmake/data/bin/cmake'
        pkg=tools/'pkgconf/pkgconf/.bin/pkgconf'
        build=root/'source-build'
        code=owned_run(root,'build-driver',[sys.executable,str(HERE/'build_recipe.py'),
            '--root',str(build),'--cmake',str(cmake),'--cmake-sha256',sha(cmake),
            '--pkg-config',str(pkg),'--pkg-config-sha256',sha(pkg)],1500)
        report['buildExit']=code
        if code:raise ValueError('Source build failed; logs preserved')
        reader=root/'native-readback'
        cache=root/'clang-cache';cache.mkdir()
        code=owned_run(root,'compile-native-reader',['/usr/bin/xcrun','swiftc',
            '-parse-as-library','-swift-version','6','-target',machine+'-apple-macosx14.0',
            '-module-cache-path',str(cache),str(HERE/'NativeReadback.swift'),'-o',str(reader)],90)
        if code:raise ValueError('Independent reader compile failed')
        helper=build/'heic_cpu_candidate'
        report.update(helperSHA256=sha(helper),readerSHA256=sha(reader))
        code=owned_run(root,'image-diagnostic',[sys.executable,str(HERE/'run_diagnostic.py'),
            '--helper',str(helper),'--helper-sha256',sha(helper),'--imageio-reader',str(reader),
            '--imageio-reader-sha256',sha(reader),'--parent',str(root)],250)
        report['diagnosticExit']=code
        if code:raise ValueError('Actual encode/readback checks incomplete')
        summaries=list(root.glob('mac-heic-cpu-*/summary.json'))
        if len(summaries)!=1:raise ValueError('One exact case summary required')
        summary=json.loads(summaries[0].read_text())
        if summary['status']!='candidate-checks-complete' or len(summary['cases'])!=6 or not all(all(c['checks'].values()) for c in summary['cases']):
            raise ValueError('Actual six-case checks incomplete')
        report.update(status='source-build-and-six-cases-complete',summarySHA256=sha(summaries[0]),
                      summary=str(summaries[0].relative_to(root)))
    finally:
        report['sourcesPreserved']=baseline=={p.name:sha(p) for p in HERE.iterdir() if p.is_file()}
        if not report['sourcesPreserved']:report['status']='failed-source-changed'
        (root/'execution.json').write_text(json.dumps(report,indent=2))
        print(root/'execution.json',flush=True)
    return 0 if report['status']=='source-build-and-six-cases-complete' else 3

if __name__=='__main__':
    def terminate(_signal,_frame):raise KeyboardInterrupt('Owned verification cancelled')
    signal.signal(signal.SIGTERM,terminate)
    raise SystemExit(main())
