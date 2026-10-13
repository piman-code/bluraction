"""Native Windows video compatibility diagnostic; retain every fixture/output.

The real VideoSource, spawned decoder, handshake, preview, cursor and private
export run unchanged. Only diagnostic temporary-file factories retain files
instead of automatically deleting them. This seam is never used by normal UI.
"""
from fractions import Fraction
from pathlib import Path
from types import SimpleNamespace
from contextlib import contextmanager
import hashlib,json,sys,time,traceback,uuid


def retain_files(root):
    from . import frame_inventory, canonical_audio, canonical_transport
    root=Path(root)
    root.mkdir(parents=True,exist_ok=True)
    class RetainedDirectory:
        def __init__(self,*args,prefix='',**kwargs):
            path=root/(prefix+uuid.uuid4().hex)
            path.mkdir(exist_ok=False)
            self.name=str(path)
        def cleanup(self):
            pass
        def __enter__(self): return self.name
        def __exit__(self,*args): return False
    def retained_file(mode='w+b',dir=None,buffering=-1,**kwargs):
        return (Path(dir)/('inventory-'+uuid.uuid4().hex+'.bin')).open('x+b',buffering=buffering)
    factories=SimpleNamespace(TemporaryDirectory=RetainedDirectory,TemporaryFile=retained_file,tempdir=str(root))
    for module in (frame_inventory,canonical_audio,canonical_transport):
        module.tempfile=factories


def retained_decoder_process(connection,path,sha,work):
    retain_files(work)
    from .canonical_transport import _decoder_process
    _decoder_process(connection,path,sha,work)


def run(directory,fixtures):
    from PySide6.QtWidgets import QApplication
    from . import canonical_transport
    from .video import VideoSource
    directory=Path(directory)
    directory.mkdir(parents=True,exist_ok=False)
    retain_files(directory/'retained')
    app=QApplication.instance() or QApplication(['BlurAction-video-compat-smoke'])
    cases=json.loads(Path(fixtures).read_text(encoding='utf8'))
    report={'status':'running','actualWindows':sys.platform=='win32','frozen':bool(getattr(sys,'frozen',False)),
            'filesRetained':True,'cases':[]}
    real_session=canonical_transport.CanonicalSession
    def session(*args,**kwargs):
        return real_session(*args,**kwargs,_decoder_target=retained_decoder_process)
    @contextmanager
    def diagnostic_sessions():
        canonical_transport.CanonicalSession=session
        try:
            yield
        finally:
            canonical_transport.CanonicalSession=real_session
    try:
        with diagnostic_sessions():
            for case in cases:
                started=time.perf_counter()
                path=Path(case['path'])
                before=hashlib.sha256(path.read_bytes()).hexdigest()
                source=None
                try:
                    source=VideoSource(path,require_asset_presentation=case.get('owned',True))
                    times=(Fraction(0),Fraction(str(source.duration))/2,Fraction(str(source.duration))-Fraction(1,30))
                    for i,stamp in enumerate(times):
                        pixels=source.frame_at(stamp)
                        assert not pixels.isNull()
                        assert [pixels.width(),pixels.height()]==case['size'],case
                        assert pixels.save(str(directory/(case['name']+f'-{i}.png')))
                    row={'name':case['name'],'size':case['size'],'sar':str(source.sample_aspect_ratio),
                         'duration':source.duration,'spawnedOwnedDecoder':getattr(source,'asset_session',None) is not None}
                    if case.get('check_vfr'):
                        observed=[f.time for f in source.iter_frames()]
                        deltas={b-a for a,b in zip(observed,observed[1:])}
                        assert len(deltas)>1
                        row['actualPTSIntervals']=[str(v) for v in sorted(deltas)]
                    if case.get('check_audio'):
                        assert source.audio_codecs
                        assert source.asset_session.metadata['audioTracks']
                        row['audioCodecs']=list(source.audio_codecs)
                    if case.get('check_export'):
                        # Native exporter creates a fresh private artifact; retain it and the work tree.
                        from .auto_find import Detection
                        from .find_actions import prepared_regions
                        state={'regions':[],'drawings':[]}
                        state['regions']=prepared_regions([Detection((.1,.1,.3,.3),'text',1.)],state,
                            0.,source.duration,style='solid',radius=0.,feather=0.,
                            color={'red':0.,'green':0.,'blue':0.,'alpha':1.})
                        artifact,export_report=source.asset_session.export_private(state,'high','.mp4')
                        assert export_report['outputVerified']
                        import av
                        with av.open(str(artifact)) as container:
                            frame=next(container.decode(video=0))
                            array=frame.to_ndarray(format='rgb24')
                            px=array[int(array.shape[0]*.75),int(array.shape[1]*.25)]
                            assert int(px.max())<=8, ('mask',px.tolist())
                        row['privateExportVerified']=True
                        row['maskPixelsVerified']=True
                        row['exportArtifact']=str(artifact)
                    assert hashlib.sha256(path.read_bytes()).hexdigest()==before
                    row.update(passed=True,sourceUnchanged=True,seconds=round(time.perf_counter()-started,3))
                    report['cases'].append(row)
                    print(case['name']+' PASS',flush=True)
                except BaseException:
                    report['cases'].append({'name':case['name'],'passed':False,'error':traceback.format_exc()})
                    print(case['name']+' FAIL',flush=True)
                finally:
                    if source is not None and getattr(source,'asset_session',None) is not None:
                        source.asset_session.close()
                        source.asset_session=None
        report['status']='pass' if all(case.get('passed') for case in report['cases']) else 'fail'
    except BaseException:
        report['status']='fail'
        report['error']=traceback.format_exc()
    with (directory/'report.json').open('x',encoding='utf8') as file:
        json.dump(report,file,ensure_ascii=False,indent=2)
    print(json.dumps(report,ensure_ascii=True),flush=True)
    return 0 if report['status']=='pass' else 1
