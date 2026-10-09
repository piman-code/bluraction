"""Retained native playback diagnostic for source and packaged CLI runs."""
from pathlib import Path
from fractions import Fraction
import sys,time,json,hashlib,statistics,traceback


def run(directory,fixture):
    from PySide6.QtWidgets import QApplication
    from .video_compat_smoke import retain_files,retained_decoder_process
    from . import canonical_transport,renderer
    from .video import VideoSource
    from .auto_find import Detection
    from .find_actions import prepared_regions
    directory=Path(directory); directory.mkdir(exist_ok=False)
    retain_files(directory/'retained')
    app=QApplication.instance() or QApplication([])
    report={'status':'fail','frozen':bool(getattr(sys,'frozen',False)),
            'actualWindows':sys.platform=='win32','filesRetained':True}
    session=canonical_transport.CanonicalSession
    canonical_transport.CanonicalSession=lambda *a,**k:session(*a,**k,_decoder_target=retained_decoder_process)
    source=window=None
    try:
        path=Path(fixture); before=hashlib.sha256(path.read_bytes()).hexdigest()
        start=time.perf_counter(); source=VideoSource(path,require_asset_presentation=True)
        report['open_seconds']=time.perf_counter()-start
        state={'regions':[],'drawings':[]}
        boxes=[(.08,.43,.11,.25),(.35,.45,.12,.30),(.58,.44,.10,.25),(.78,.45,.12,.30)]
        state['regions']=prepared_regions([Detection(r,'faces',1.) for r in boxes],state,0.,source.duration,
            style='blur',radius=25.,feather=12.,color={'red':0.,'green':0.,'blue':0.,'alpha':1.})
        report['benchmarks']=[]
        for offset in [0,5]:
            frames=[]
            for index in range(30):
                stamp=Fraction(offset)+Fraction(index,30)
                start=time.perf_counter(); pixels=source.frame_at_timed(stamp,preview=True)
                decode=time.perf_counter()-start
                assert pixels.time==stamp
                assert (pixels.image.width(),pixels.image.height())==(640,360)
                then=time.perf_counter()
                shown=renderer.render_preview(pixels.image,state,float(stamp),(1920,1080))
                frames.append({'decode_seconds':decode,'render_seconds':time.perf_counter()-then})
                if index==0: shown.save(str(directory/('preview-'+str(offset)+'.png')))
            steady=frames[1:]
            row={'offset':offset,'frames':len(frames),'first_frame_seconds':sum(frames[0].values()),
                 'steady_mean_seconds':statistics.mean(sum(f.values()) for f in steady),'timings':frames}
            row['throughput_fps']=1/row['steady_mean_seconds']
            report['benchmarks'].append(row)
            if sys.stdout is not None:
                try: print(json.dumps({k:v for k,v in row.items() if k!='timings'}),flush=True)
                except OSError: pass  # A windowed frozen EXE may have no console handle.
        # Backward seek, proxy -> full-res restoration, and exact original pixels.
        full=source.frame_at_timed(Fraction(1,2))
        assert (full.image.width(),full.image.height())==(1920,1080)
        original=full.image.copy()
        small=source.frame_at_timed(Fraction(1,2),preview=True)
        again=source.frame_at_timed(Fraction(1,2))
        assert full.time==small.time==again.time
        assert bytes(again.image.constBits())==bytes(original.constBits())
        report['full_resolution_restored']=True
        # Qt widget initialization exercises revised defaults and preview request API.
        from .ui import BlurActionWindow
        window=BlurActionWindow()
        assert not window.find_then_track.isChecked()
        assert 'local4' in window.windowTitle()
        from .canonical_transport import AssetClock
        from copy import deepcopy
        window.workspace._replace([source.page()],'재생 성능 검수',source)
        window.workspace.page.state=deepcopy(state)
        context=(window._video_generation,id(window.workspace.page),window._seek_epoch)
        window.canvas.accept_prepared(source._first_image,state,
            renderer.render(source._first_image,state,0.),0.,context)
        window._asset_clock=AssetClock(source.asset_session.duration)
        displayed=[]
        window.canvas.presented.connect(lambda result: displayed.append((time.perf_counter(),result[1])))
        then=time.perf_counter()
        window._asset_clock.play(); window._asset_timer.start()
        while time.perf_counter()-then<8. and (len(displayed)<10 or time.perf_counter()-then<2.):
            app.processEvents(); time.sleep(.001)
        elapsed=time.perf_counter()-then
        report['qt_playback']={'seconds':elapsed,'presented_frames':len(displayed),
                              'presented_fps':len(displayed)/elapsed,'offscreen':True}
        assert len(displayed)>=1
        assert all(b[1]>=a[1] for a,b in zip(displayed,displayed[1:]))
        window.toggle_playback()  # Pause performs a full-resolution explicit seek.
        deadline=time.perf_counter()+30
        while window.canvas.preview_queue.busy and time.perf_counter()<deadline:
            app.processEvents(); time.sleep(.001)
        assert not window.canvas.preview_queue.busy
        assert window.canvas.image.width()==1920
        report['qt_pause_full_resolution']=True
        window.workspace.video=None  # Diagnostic retains the session for explicit close below.
        window.close(); app.processEvents()
        report['window_and_defaults']=True
        report['source_unchanged']=hashlib.sha256(path.read_bytes()).hexdigest()==before
        assert report['source_unchanged']
        report['status']='pass'
    except BaseException:
        report['error']=traceback.format_exc()
    finally:
        if window is not None:
            window._pause_asset()
            window.canvas.preview_queue.shutdown()
            deadline=time.perf_counter()+30
            while window.canvas.preview_queue.busy and time.perf_counter()<deadline:
                app.processEvents(); time.sleep(.002)
            if not window.canvas.preview_queue.busy:
                window.workspace.video=None
                window.close(); app.processEvents()
        if source is not None and source.asset_session is not None: source.asset_session.close()
        canonical_transport.CanonicalSession=session
        with (directory/'report.json').open('x',encoding='utf8') as file:
            json.dump(report,file,ensure_ascii=False,indent=2)
    return 0 if report['status']=='pass' else 1
