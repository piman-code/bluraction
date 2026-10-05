"""Canonical output schedules, actual authored MOV EOF and PCM readback.

The family runner owns native deadlines. MPEG4 is explicitly selected only in
the direct provider test, never a production fallback. Production bridge tests
use the registered native H264 encoder. No user media/device/desktop input.
"""
from copy import deepcopy
from fractions import Fraction as F
import hashlib
import json
from pathlib import Path
import tempfile
import struct
import unittest
from unittest.mock import patch

from platforms.windows.bluraction import video, canonical_export as export
from platforms.windows.bluraction.canonical_audio import OwnedCanonicalAudioProvider
from platforms.windows.bluraction.canonical_video import DecoderAccess, OwnedCanonicalVideoProvider
from platforms.windows.bluraction.frame_inventory import FrameInventory
from platforms.windows.bluraction.local_decoder import open_local_decoder
from platforms.windows.bluraction.media import Cancelled
from Tests.WindowsAppTests import test_canonical_video as controlled
from Tests.WindowsAppTests import test_canonical_video_fixtures as fixtures
from Tests.WindowsAppTests import test_canonical_transport_fixtures as transport_fixtures
from shared.video_timeline import rational


ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / 'shared/fixtures/video-timelines'
UNIQUE = ROOT / 'shared/fixtures/video-timelines-unique-pcm'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def providers(path):
    sha = digest(path)
    picture = OwnedCanonicalVideoProvider.build(path, expected_sha256=sha, generation=1,
        decoder_access=DecoderAccess(FrameInventory.build, open_local_decoder))
    try:
        sound = OwnedCanonicalAudioProvider.build(path, expected_sha256=sha, generation=1,
            decoder_clock_mode='ffmpeg-editlist-applied', expected_timeline=picture.timeline)
    except BaseException:
        picture.close()
        raise
    return picture, sound


class SequentialCanonicalTests(unittest.TestCase):
    def harness(self, **options):
        harness = controlled.CanonicalVideoTests('test_exact_pixels_asset_duration_presence_boundaries_and_explicit_options')
        harness.setUp(); self.addCleanup(harness.doCleanups)
        if options.pop('preroll', False):
            harness.rows.insert(0, controlled.frame(-100, duration=100))
        provider = harness.build(**options)
        return harness, provider

    def test_one_sequential_decoder_matches_index_without_seeks_and_exact_eof(self):
        harness, provider = self.harness(preroll=True)
        rows = list(provider.iter_content())
        self.assertEqual([(r.asset_pts, r.interval_end, r.source_index) for r in rows],
                         [(F(1,2), F(3,4), 1), (F(3,4), F(1), 2)])
        self.assertEqual(len(harness.containers), 1)
        self.assertEqual(harness.containers[0].seek_calls, [])
        self.assertTrue(harness.containers[0].closed)
        self.assertTrue(harness.containers[0].iterator_closed)
        self.assertEqual(harness.source.read_bytes(), harness.original)
        self.assertEqual(rows[0].image.pixelColor(0,0).getRgb(), (20,180,40,255))

    def test_changed_middle_and_missing_tail_never_publish_partial_eof(self):
        for rows in ([controlled.frame(500), controlled.frame(750,duration=249)],
                     [controlled.frame(500)]):
            with self.subTest(count=len(rows)):
                harness, provider = self.harness()
                provider._access = harness.access(pixel_rows=rows)
                with self.assertRaisesRegex(ValueError, 'differs|before complete'):
                    list(provider.iter_content())
                self.assertFalse(harness.inventories[-1].complete)
                self.assertEqual(harness.source.read_bytes(), harness.original)

    def test_early_consumer_close_releases_cursor_without_closing_provider(self):
        harness, provider = self.harness()
        cursor = provider.iter_content(); first = next(cursor); cursor.close()
        self.assertEqual(first.asset_pts, F(1,2))
        self.assertTrue(harness.containers[0].closed)
        self.assertTrue(harness.inventories[-1].complete)
        self.assertEqual(provider.frame_at(F(3,4)).asset_pts, F(3,4))

    def test_explicit_empty_and_suffix_are_scenes_not_foreign_content(self):
        harness, provider = self.harness()
        rows = list(export.iter_scenes(provider, {'regions': [], 'drawings': []}, (96,64)))
        self.assertEqual(rows[0].time, 0); self.assertEqual(rows[-1].end, F(3,2))
        self.assertEqual([r.time for r in rows if r.presence == 'content'], [F(1,2),F(3,4)])
        self.assertEqual([r.presence for r in rows if r.source_index is not None], ['content','content'])
        for before, after in zip(rows, rows[1:]): self.assertEqual(before.end, after.time)
        for row in rows:
            if row.presence != 'content':
                self.assertEqual(row.image.pixelColor(0,0).getRgb(), (0,0,0,255))

    def test_content_period_and_from_now_eraser_are_evaluated_at_preview_pts(self):
        harness,provider=self.harness()
        region={'shape': {'rectangle': {'id':'D12CD58A-14BE-48B2-823E-E1B1806274BA',
            'origin':[.1,.1], 'size':[.6,.6]}}, 'effect':{'enabled':True,'blurRadius':0,
            'featherRadius':0,'style':'solid','color':{'red':0,'green':0,'blue':0,'alpha':1},
            'timeRange':[.5,.5],'keyframes':[], 'erasures':[{'points':[[.3,.3]],'width':.2,'from':.75}]}}
        scenes=list(export.iter_scenes(provider,{'regions':[region],'drawings':[]},(96,64)))
        content=[s for s in scenes if s.presence=='content']
        self.assertEqual(content[0].time,F(1,2)); self.assertEqual(content[1].time,F(3,4))
        self.assertEqual(content[0].image.pixelColor(29,44).getRgb(),(0,0,0,255))
        self.assertEqual(content[1].image.pixelColor(29,44).getRgb(),(20,180,40,255))
        region['effect']['timeRange']=[0,0]
        scenes=list(export.iter_scenes(provider,{'regions':[region],'drawings':[]},(96,64)))
        content=[s for s in scenes if s.presence=='content']
        self.assertEqual(content[0].image.pixelColor(29,44).getRgb(),(0,0,0,255))
        self.assertEqual(content[1].image.pixelColor(29,44).getRgb(),(20,180,40,255))

    def test_content_gap_is_not_synthetic_black_and_clock_overflow_is_not_rounded(self):
        harness, provider = self.harness()
        # Completed observations still leave an actual hole inside declared content.
        provider.close()
        harness.rows = [controlled.frame(500,duration=100), controlled.frame(750)]
        provider = harness.build()
        with self.assertRaisesRegex(export.CanonicalExportError, 'unobserved content'):
            list(export.iter_scenes(provider, {'regions': [], 'drawings': []}, (96,64)))
        for time, base in ((F(1,3),F(1,2)), (F(1<<63),F(1))):
            with self.assertRaises(export.CanonicalExportError): export.exact_ticks(time,base)

    def test_cancel_between_frames_discards_only_the_owned_candidate(self):
        harness, provider = self.harness()
        cursor = provider.iter_content(); next(cursor); harness.event.set()
        with self.assertRaises(ValueError): next(cursor)
        self.assertFalse(harness.inventories[-1].complete)
        self.assertEqual(harness.source.read_bytes(), harness.original)

    def test_actual_pyav_rational_getter_uses_exact_adapter_and_rejects_guesses(self):
        av=video._av()
        frame=av.AudioFrame(format='s16',layout='mono',samples=1)
        frame.time_base=F(1,8000)
        self.assertEqual(export.exact_ticks(F(3,8000),frame.time_base),3)
        self.assertNotEqual(type(frame.time_base),F,'Pinned19 native getter boundary is exercised')
        for clock in (1/8000,True,0,object()):
            with self.subTest(clock=type(clock).__name__):
                with self.assertRaises(ValueError): export.exact_ticks(F(1,8000),clock)
        with self.assertRaises(export.CanonicalExportError): export.exact_ticks(F(1,3),frame.time_base)

    def test_drained_cancel_during_cursor_open_still_closes_owned_child_cursor(self):
        from threading import RLock
        from platforms.windows.bluraction.canonical_transport import CanonicalSession
        session=object.__new__(CanonicalSession)
        session._lock=RLock(); session._closed=False; session.duration=F(1)
        calls=[]
        def rpc(operation,args=(),cancel=None):
            calls.append(operation)
            if operation=='cursor_open': raise Cancelled('cancel after drained ready')
            return {'kind':'cursor_closed'},()
        session._rpc=rpc
        with self.assertRaises(Cancelled): next(session.iter_frames())
        self.assertEqual(calls,['cursor_open','cursor_close'])
        self.assertFalse(session._closed)


class ActualCanonicalExportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)

    def check_case(self, kind, *, unique=False):
        directory = UNIQUE if unique else FIXTURES
        manifest = json.loads((directory/'manifest.json').read_bytes())
        case = next(c for c in manifest['cases'] if c['kind'] == kind)
        path = directory/case['file']; original = path.read_bytes()
        self.assertEqual(hashlib.sha256(original).hexdigest(), case['sourceSHA256'])
        picture, sound = providers(path)
        self.addCleanup(picture.close); self.addCleanup(sound.close)
        expected_pts = []
        for row in case.get('frames', []):
            stamp = rational(row['pts'])
            if fixtures.expected_at(stamp,case)[0] == 'content': expected_pts.append(stamp)
        rows = list(picture.iter_content())
        if not unique:
            self.assertEqual([r.asset_pts for r in rows], expected_pts)
            for row in rows:
                expected = fixtures.expected_at(row.asset_pts,case)[1]
                self.assertEqual(fixtures.classify(fixtures.image_bytes(row.image)),expected['markerCode'])
        for row in rows:
            expected = picture.frame_at(row.asset_pts)
            self.assertEqual(bytes(row.image.constBits()), bytes(expected.image.constBits()))
            self.assertEqual((row.source_index,row.interval_end),(expected.source_index,expected.interval_end))
        output = self.folder/(kind+'.mov')
        report = export.encode_from_providers(picture,sound,{'regions': [], 'drawings': []},output,
            {'averageRate': F(12), 'bitRate': 500000}, 'high', 'mpeg4')
        self.assertTrue(report['outputVerified'])
        self.assertEqual(rational(report['assetDuration']), rational(case['timeline']['assetDuration']))
        self.assertEqual(report['contentFrames'], len(rows))
        self.assertEqual(report['verifiedAudioTracks'], len(sound.tracks))
        self.assertEqual(report['outputSHA256'], digest(output))
        # Exact original PCM byte/sample and source SHA checks are mandatory in
        # verify_output; final lossy MPEG4 RGB is not a whole-byte parity oracle.
        for stats in report['audioTracks']:
            track = next(t for t in case['timeline']['tracks'] if t['id'] == stats['sourceTrackID'])
            content = sum(rational(s['assetDuration'])*stats['sampleRate'] for s in track['segments'] if s['mediaStart'] is not None)
            empty = sum(rational(s['assetDuration'])*stats['sampleRate'] for s in track['segments'] if s['mediaStart'] is None)
            self.assertEqual((stats['contentSamples'],stats['emptySamples']),(content,empty))
            if unique:
                authored_pcm = bytearray()
                for segment in track['segments']:
                    count = rational(segment['assetDuration'])*8000
                    self.assertEqual(count.denominator,1)
                    if segment['mediaStart'] is None:
                        authored_pcm.extend(bytes(count.numerator*2))
                    else:
                        source_index = rational(segment['mediaStart'])*8000
                        self.assertEqual(source_index.denominator,1)
                        authored_pcm.extend(transport_fixtures.authored(source_index.numerator,count.numerator,True))
                self.assertEqual(stats['inputPCM_SHA256'],hashlib.sha256(authored_pcm).hexdigest())
        self.assertEqual(path.read_bytes(),original)

    def test_actual_mov8_content_and_scene_eof_pcm_export(self):
        for kind in fixtures.KINDS:
            with self.subTest(kind=kind): self.check_case(kind)

    def test_actual_unique_pcm2_preserves_each_trimmed_sample_in_mov(self):
        for kind in transport_fixtures.UNIQUE:
            with self.subTest(kind=kind): self.check_case(kind,unique=True)

    def test_actual_two_pcm_tracks_keep_stereo_layout_and_independent_bytes(self):
        av=video._av(); path=self.folder/'two-tracks.mov'
        from av.stream import Disposition
        from PIL import Image
        patterns=[]
        with av.open(str(path),'w') as out:
            v=out.add_stream('mpeg4',rate=10); v.width,v.height=96,64
            v.pix_fmt='yuv420p'; v.time_base=v.codec_context.time_base=F(1,1000)
            v.codec_context.max_b_frames=0
            sounds=[]
            for layout in ('mono','stereo'):
                a=out.add_stream('pcm_s16le',rate=8000); a.layout=layout
                a.disposition=Disposition.default; sounds.append(a)
            from platforms.windows.bluraction.frame_inventory import _exact_fraction
            def mux_video(packets):
                for packet in packets:
                    packet.duration=export.exact_ticks(F(1,10),_exact_fraction(packet.time_base,'authored packet time base'))
                    out.mux(packet)
            for t in range(10):
                frame=av.VideoFrame.from_image(Image.new('RGB',(96,64),(20,180,40)))
                frame.pts,frame.time_base,frame.duration=t*100,F(1,1000),100
                mux_video(v.encode(frame))
            mux_video(v.encode(None))
            for index,a in enumerate(sounds):
                channels=index+1
                meaningful=struct.pack('<'+'h'*(8000*channels),
                    *[((i*31+c*73)%2000)-1000 for i in range(8000) for c in range(channels)])
                patterns.append(hashlib.sha256(meaningful).hexdigest())
                frame=av.AudioFrame(format='s16',layout='mono' if index==0 else 'stereo',samples=8000)
                frame.pts,frame.time_base,frame.sample_rate=0,F(1,8000),8000
                frame.planes[0].update(meaningful+b'\0'*(frame.planes[0].buffer_size-len(meaningful)))
                for packet in a.encode(frame): out.mux(packet)
                for packet in a.encode(None): out.mux(packet)
        from platforms.windows.bluraction.asset_timeline import inspect_asset_timeline
        descriptor=inspect_asset_timeline(path)
        self.assertEqual(len(descriptor.tracks),3)
        self.assertTrue(all(t.enabled for t in descriptor.tracks),'Authored positive fixture enables every actual audio track')
        picture,sound=providers(path)
        self.addCleanup(picture.close); self.addCleanup(sound.close)
        result=export.encode_from_providers(picture,sound,{'regions':[],'drawings':[]},
            self.folder/'two-tracks-output.mov',{'averageRate':F(10)},'high','mpeg4')
        self.assertEqual(result['verifiedAudioTracks'],2)
        output_descriptor=inspect_asset_timeline(self.folder/'two-tracks-output.mov')
        self.assertTrue(all(t.enabled for t in output_descriptor.tracks),'Output preserves all active audio tracks')
        self.assertEqual([r['samples'] for r in result['audioTracks']],[8000,8000])
        self.assertEqual([r['channels'] for r in result['audioTracks']],[['FC'],['FL','FR']])
        self.assertEqual([r['inputPCM_SHA256'] for r in result['audioTracks']],patterns)

    def test_actual_production_export_reaps_new_attempt_and_preserves_live_owner(self):
        original_path = FIXTURES/'gap0-vfr.mov'
        source = video.VideoSource(original_path,require_asset_presentation=True)
        self.addCleanup(source.close_asset_transport)
        owner = source.asset_session
        before = source.frame_at_timed(source.first_frame_time)
        target = self.folder/'native-export.mov'
        video.export_video(source,{'regions': [], 'drawings': []},target)
        self.assertTrue(target.exists())
        self.assertIs(source.asset_session,owner); self.assertFalse(owner._closed)
        after = source.frame_at_timed(source.first_frame_time)
        self.assertEqual(after.time,before.time)
        self.assertEqual(bytes(after.image.constBits()),bytes(before.image.constBits()))

    def test_actual_mid_export_cancel_has_no_public_output_and_keeps_live_session(self):
        source = video.VideoSource(FIXTURES/'nonzero-origin.mov',require_asset_presentation=True)
        self.addCleanup(source.close_asset_transport)
        owner = source.asset_session; cancelled = [False]
        def progress(value): cancelled[0] = value > 0
        target = self.folder/'cancelled.mov'
        with self.assertRaises(Cancelled):
            video.export_video(source,{'regions': [], 'drawings': []},target,
                cancel=lambda:cancelled[0],progress=progress)
        self.assertFalse(target.exists()); self.assertFalse(list(self.folder.glob('.bluraction-video-*')))
        self.assertIs(source.asset_session,owner); self.assertFalse(owner._closed)
        self.assertEqual(source.frame_at_timed(source.first_frame_time).presence,'content')

    def test_actual_mp4_aac_all_audio_tracks_have_exact_sample_coverage(self):
        # AAC is lossy. The gate compares decoded time/sample coverage and
        # channel/rate, not impossible compressed/decoded PCM byte equality.
        for kind in ('audio-earlier-gap','audio-later-gap'):
            with self.subTest(kind=kind):
                case=next(c for c in json.loads((FIXTURES/'manifest.json').read_bytes())['cases'] if c['kind']==kind)
                picture,sound=providers(FIXTURES/case['file'])
                try:
                    result=export.encode_from_providers(picture,sound,{'regions': [], 'drawings': []},
                        self.folder/(kind+'.mp4'),{'averageRate':F(12)},'high','mpeg4')
                    self.assertTrue(result['outputVerified'])
                    self.assertEqual(result['verifiedAudioTracks'],len(sound.tracks))
                finally:
                    sound.close(); picture.close()

    def test_actual_output_readback_rejects_wrong_pts_record(self):
        path = FIXTURES/'gap0-vfr.mov'; picture,sound = providers(path)
        self.addCleanup(picture.close); self.addCleanup(sound.close)
        output = self.folder/'tamper.mov'
        report = export.encode_from_providers(picture,sound,{'regions': [], 'drawings': []},output,
            {'averageRate':F(12)},'high','mpeg4')
        records = output.with_suffix('.mov.video-records.jsonl')
        lines = records.read_bytes().splitlines(); row = json.loads(lines[0])
        row['pts']={'numerator':'1','denominator':'3'}
        lines[0]=json.dumps(row).encode(); records.write_bytes(b'\n'.join(lines)+b'\n')
        with self.assertRaisesRegex(export.CanonicalExportError,'PTS/duration'):
            export.verify_output(output,records,report)


if __name__ == '__main__':
    unittest.main()
