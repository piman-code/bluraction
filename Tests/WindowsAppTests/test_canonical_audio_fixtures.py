"""Owned PCM against eight public authored MOVs; no audio device/P1 proof.

The authored waveform is s16LE mono8000: ((i*31)%1000)-500 for 9600
samples. Independently witnessed asset edit descriptors determine where those
samples belong. No guessed decoder origin or reapplied trim is an expectation.
The family runner supplies the native-call deadline/process-tree ownership.
"""
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import struct
import unittest

from platforms.windows.bluraction.canonical_audio import OwnedCanonicalAudioProvider, AudioLimits
from shared.video_timeline import rational

FIXTURES=Path(__file__).resolve().parents[2]/'shared/fixtures/video-timelines'
KINDS=('gap0-vfr','nonzero-origin','audio-earlier-gap','audio-later-gap',
       'video0-audio-negative-quarter','video-negative-twelfth-audio0',
       'video-negative-twelfth-audio-negative-quarter','video-negative-twelfth-noaudio')


def authored(first,count):
    return struct.pack('<'+'h'*count,*[((i*31)%1000)-500 for i in range(first,first+count)])


class AuthoredAudioFixtures(unittest.TestCase):
    def check_case(self,kind):
        manifest=FIXTURES/'manifest.json';original=manifest.read_bytes()
        case=next(c for c in json.loads(original)['cases'] if c['kind']==kind)
        source=FIXTURES/case['file'];before=source.read_bytes()
        self.assertEqual(hashlib.sha256(before).hexdigest(),case['sourceSHA256'])
        timeline=case['timeline'];tracks=[t for t in timeline['tracks'] if t['kind']=='audio']
        provider=None
        try:
            provider=OwnedCanonicalAudioProvider.build(source,expected_sha256=case['sourceSHA256'],
                generation=3,current_generation=lambda:3,expected_timeline=timeline,
                decoder_clock_mode='ffmpeg-editlist-applied',
                limits=AudioLimits(max_frames=128,max_spool_bytes=1024*1024,max_frame_bytes=256*1024))
            self.assertEqual(provider.timeline,timeline)
            self.assertEqual(provider.asset_duration,rational(timeline['assetDuration']))
            infos={t.track_id:t for t in provider.tracks}
            self.assertEqual(set(infos),{t['id'] for t in tracks})
            for track in tracks:
                info=infos[track['id']]
                self.assertEqual((info.format.name,info.format.sample_rate,info.format.planar),('s16',8000,False))
                self.assertEqual((info.format.bytes_per_sample,len(info.format.channels),info.format.byte_order),(2,1,'little'))
                self.assertGreater(info.raw_frame_count,0)
                scheduled=0
                for segment in track['segments']:
                    start=rational(segment['assetStart']);end=start+rational(segment['assetDuration'])
                    if segment['mediaStart'] is None:
                        for query in (start,(start+end)/2):
                            row=provider.read_samples(track['id'],query)
                            self.assertEqual((row.presence,row.samples,row.planes),('empty',0,()))
                            self.assertEqual((row.interval_start,row.interval_end),(start,end))
                        continue
                    media=rational(segment['mediaStart']);count=(end-start)*8000
                    self.assertEqual(count.denominator,1)
                    sample_origin=media*8000;self.assertEqual(sample_origin.denominator,1)
                    offset=0;query=start;output=bytearray();calls=0
                    while query<end:
                        calls+=1;self.assertLessEqual(calls,128)
                        row=provider.read_samples(track['id'],query,max_samples=4096)
                        self.assertEqual((row.presence,row.requested_time,row.generation),('content',query,3))
                        self.assertEqual(row.source_sha256,case['sourceSHA256'])
                        self.assertEqual(row.descriptor_sha256,provider.descriptor_sha256)
                        self.assertTrue(0<row.samples<=min(4096,count.numerator-offset))
                        self.assertEqual(len(row.planes),1)
                        self.assertEqual(row.planes[0],authored(sample_origin.numerator+offset,row.samples))
                        observation=provider.observation(track['id'],row.source_frame_index)
                        self.assertEqual(row.asset_pts,observation.pts)
                        self.assertEqual(query,observation.pts+Fraction(row.source_sample_offset,8000))
                        self.assertEqual((row.interval_start,row.interval_end),(query,query+Fraction(row.samples,8000)))
                        self.assertLessEqual(row.interval_end,end)
                        output.extend(row.planes[0]);offset+=row.samples;query=row.interval_end
                    self.assertEqual((query,offset),(end,count.numerator))
                    self.assertEqual(bytes(output),authored(sample_origin.numerator,count.numerator))
                    scheduled+=offset
                self.assertEqual(info.scheduled_samples,scheduled)
                eof=provider.read_samples(track['id'],provider.asset_duration)
                self.assertEqual((eof.presence,eof.samples,eof.planes),('EOF',0,()))
                end=rational(track['segments'][-1]['assetStart'])+rational(track['segments'][-1]['assetDuration'])
                if end<provider.asset_duration:
                    suffix=provider.read_samples(track['id'],end)
                    self.assertEqual((suffix.presence,suffix.samples,suffix.planes),('suffix',0,()))
                    self.assertEqual((suffix.interval_start,suffix.interval_end),(end,provider.asset_duration))
            directory=Path(provider._directory.name)
            provider.close();self.assertFalse(directory.exists())
        finally:
            if provider is not None:provider.close()
            self.assertEqual(source.read_bytes(),before)
            self.assertEqual(manifest.read_bytes(),original)


for _kind in KINDS:
    def _test(self,kind=_kind):self.check_case(kind)
    setattr(AuthoredAudioFixtures,'test_'+_kind.replace('-','_'),_test)
