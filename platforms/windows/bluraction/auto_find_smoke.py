"""CLI-only offline feature diagnostics; all authored files are retained."""
from copy import deepcopy
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import sys
import time


class SyntheticVideo:
    """In-memory, textured moving targets with explicit presentation intervals."""
    duration = 2.

    def __init__(self):
        import numpy as np
        from PySide6.QtGui import QImage
        from .video import TimedImage
        random = np.random.default_rng(1701)
        textures = [random.integers(0, 256, (36,36,3), dtype=np.uint8) for _ in range(2)]
        self.frames = []
        for index in range(24):
            pixels = np.full((160,240,3), 235, dtype=np.uint8)
            for target,(y,x) in enumerate(((30,30+index*2),(95,150-index))):
                pixels[y:y+36,x:x+36] = textures[target]
            image = QImage(pixels.data,240,160,720,QImage.Format.Format_RGB888).copy()
            self.frames.append(TimedImage(Fraction(index,12),image,'content',Fraction(index+1,12),index,Fraction(index,12)))
        self.validations = 0

    def validate(self, cancel=None):
        from .media import check_cancel
        check_cancel(cancel)
        self.validations += 1

    def frame_at_timed(self, stamp, cancel=None):
        self.validate(cancel)
        return self.frames[min(23,max(0,int(float(stamp)*12)))]

    def iter_frames(self, start, end, cancel=None):
        for frame in self.frames:
            self.validate(cancel)
            if start <= float(frame.time) <= end:
                yield frame

    def targets(self, index=12):
        targets = []
        for target,(y,x) in enumerate(((30,30+index*2),(95,150-index))):
            targets.append(({'shape':{'rectangle':{'id':f'synthetic-{target}',
                'origin':[x/240,1-(y+36)/160],'size':[36/240,36/160]}},
                'effect':{'enabled':True,'locked':False,'timeRange':[0,0],'keyframes':[]}},True))
        return targets


def text_fixture():
    from PySide6.QtGui import QImage, QPainter, QColor, QFont, QFontDatabase
    QFontDatabase.addApplicationFont('C:/Windows/Fonts/malgun.ttf')
    image = QImage(900,400,QImage.Format.Format_RGB32)
    image.fill(0xffffffff)
    painter = QPainter(image)
    painter.setPen(QColor('black'))
    painter.setFont(QFont('맑은 고딕',38))
    painter.drawText(50,100,'자동 글자 찾기 시험')
    painter.drawText(50,210,'TEST PLATE 1234')
    painter.end()
    return image


def run(output, *, face_fixture=None):
    from PySide6.QtWidgets import QApplication
    from PySide6.QtGui import QColor, QImage, QPainter, QPen
    from .auto_find import detect, model_path
    from .auto_tracking import track_many
    from .find_actions import prepared_regions, commit_find, commit_tracking
    from .editor import Workspace
    from .media import Page, fingerprint
    from .renderer import render
    directory = Path(output).absolute()
    directory.mkdir()  # Fresh output only; no clean-up or existing-file overwrite.
    report = {'status':'fail','actualWindows':sys.platform=='win32',
              'frozen':bool(getattr(sys,'frozen',False)),'checks':{},'filesRetained':True,
              'installerVerified':False,'redistributionApproved':False}
    stage = 'runtime'
    app = QApplication.instance() or QApplication(['BlurAction-auto-find-smoke'])
    try:
        model_path('faces'); model_path('text')
        stage = 'text-detection'
        image = text_fixture()
        source = directory/'합성-한글-영문.png'
        if not image.save(str(source)):
            raise ValueError('fixture save')
        before = hashlib.sha256(source.read_bytes()).hexdigest()
        started = time.monotonic()
        finds = detect(image,'text')
        if len(finds)<2:
            raise ValueError('text positive fixture')
        # Verify both authored lines, rather than accepting random detections.
        for x,y in ((.32,.82),(.40,.55)):
            if not any(d.rect[0]<=x<=d.rect[0]+d.rect[2] and d.rect[1]<=y<=d.rect[1]+d.rect[3] for d in finds):
                raise ValueError('text line missed')
        report['checks'][stage] = {'areas':len(finds),'twoLinesCovered':True,'seconds':round(time.monotonic()-started,3)}
        stage = 'face-detection'
        blank = QImage(400,400,QImage.Format.Format_RGB32)
        blank.fill(0xffffffff)
        if detect(blank,'faces'):
            raise ValueError('blank false positive')
        face_count = None
        if face_fixture:
            faces = detect(QImage(str(face_fixture)),'faces')
            face_count = len(faces)
            if not face_count:
                raise ValueError('face positive fixture')
        report['checks'][stage] = {'blankChecked':True,'positiveFaces':face_count}
        stage = 'single-undo-and-render'
        workspace = Workspace()
        workspace._replace([Page(source,fingerprint(source),image)],'자동 찾기 시험')
        regions = prepared_regions(finds,workspace.page.state,0.,None,
            style='solid',radius=0.,feather=0.,color={'red':0,'green':0,'blue':0,'alpha':1})
        ids = commit_find(workspace,regions)
        if len(ids)!=len(regions):
            raise ValueError('find commit')
        flattened = render(workspace.page.image,workspace.page.state)
        for detection in finds:
            x,y,w,h = detection.rect
            color = flattened.pixelColor(round((x+w/2)*image.width()),round((1-y-h/2)*image.height()))
            if color.getRgb()!=(0,0,0,255):
                raise ValueError('mask pixel')
        flattened.save(str(directory/'합성-자동가림.png'))
        state = deepcopy(workspace.page.state)
        workspace.undo()
        if workspace.page.state['regions']:
            raise ValueError('single undo')
        workspace.redo()
        if workspace.page.state != state or hashlib.sha256(source.read_bytes()).hexdigest()!=before:
            raise ValueError('redo or original')
        report['checks'][stage] = {'oneUndo':True,'redo':True,'maskPixels':True,'originalUnchanged':True}
        stage = 'native-multi-tracking'
        source_video = SyntheticVideo()
        originals = source_video.targets()
        snapshot = deepcopy(originals)
        tracking = track_many(source_video, originals,1.,direction='both',smoothing=False)
        if len(tracking)!=2 or originals!=snapshot:
            raise ValueError('tracking mutation')
        for index,result in enumerate(tracking):
            if result.lost or result.skipped or len(result.keyframes)!=24:
                raise ValueError('tracking coverage')
            times = [f['time'] for f in result.keyframes]
            if times != sorted(set(times)) or times[0]!=0. or times[-1]!=23/12:
                raise ValueError('tracking timestamps')
            first = result.keyframes[0]['rect'][0][0]*240
            last = result.keyframes[-1]['rect'][0][0]*240
            expected_delta = 46 if index==0 else -23
            if abs(last-first-expected_delta)>5:
                raise ValueError('tracking displacement')
        report['checks'][stage] = {'targets':2,'framesPerTarget':24,'forwardAndBackward':True,
                                  'realCSRT':True,'timestampsAndDisplacement':True}
        stage = 'real-video-file'
        import av
        from .video import VideoSource, _bgr
        clip = directory/'가변시각-두대상.mkv'
        # Alternating actual intervals exercise a non-FPS-based file timeline.
        with av.open(str(clip),'w') as container:
            stream=container.add_stream('ffv1',rate=12)
            stream.width,stream.height,stream.pix_fmt=240,160,'bgr0'
            stream.time_base=Fraction(1,60)
            for index,timed in enumerate(source_video.frames):
                frame=av.VideoFrame.from_ndarray(_bgr(timed.image),format='bgr24')
                frame.pts=(index//2)*10+(4 if index%2 else 0)
                frame.time_base=Fraction(1,60)
                frame.duration=6 if index%2 else 4
                for packet in stream.encode(frame):
                    container.mux(packet)
            for packet in stream.encode():
                container.mux(packet)
        clip_sha=hashlib.sha256(clip.read_bytes()).hexdigest()
        actual=VideoSource(clip)
        actual_frames=list(actual.iter_frames())
        actual_times=[float(frame.time) for frame in actual_frames]
        if len(actual_times)!=24 or len({round(b-a,3) for a,b in zip(actual_times,actual_times[1:])})<2:
            raise ValueError('variable timestamp fixture')
        real_paths=track_many(actual,source_video.targets(),actual_times[12],direction='both',smoothing=False)
        if len(real_paths)!=2 or any(r.lost or r.skipped for r in real_paths):
            raise ValueError('real video tracking coverage')
        if any([f['time'] for f in r.keyframes]!=actual_times for r in real_paths):
            raise ValueError('real video timestamps')
        if hashlib.sha256(clip.read_bytes()).hexdigest()!=clip_sha:
            raise ValueError('real video original changed')
        report['checks'][stage]={'targets':2,'decodedFrames':24,'variableTimestamps':True,
            'sourceFileUnchanged':True,'actualPTSUsed':True,'sourceSHA256':clip_sha}
        stage = 'qt-window'
        from .ui import BlurActionWindow
        window = BlurActionWindow()
        if window.find_faces_button.text()!='얼굴 찾기' or window.track_direction.currentData()!='both':
            raise ValueError('window controls')
        window.close()
        report['checks'][stage] = {'constructed':True,'faceAndTextControls':True,'directionControls':True}
        report['status']='pass'
    except Exception as error:
        report['failure']={'stage':stage,'type':type(error).__name__,'message':str(error)[:180]}
    finally:
        app.quit()
        (directory/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf8')
    return 0 if report['status']=='pass' else 1
