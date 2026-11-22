#!/usr/bin/env python3
"""Local checks for the live audit's content-matching confidence logic."""
import importlib.util
import datetime as dt
from pathlib import Path
import random
import struct
import tempfile
import unittest
import wave

spec = importlib.util.spec_from_file_location("scheduled_audit", Path(__file__).with_name("test-scheduled-recordings.py"))
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class MatchingTests(unittest.TestCase):
    def test_forced_stop_reference_preserves_pcm_and_finalizes_its_header(self):
        for trailing in (b"", b"x"):
            with self.subTest(trailing=trailing), tempfile.TemporaryDirectory() as folder:
                original = Path(folder)/"reference.wav"
                pcm = struct.pack("<8h", -700, 0, 120, 200, 400, -100, 70, 300)
                with wave.open(str(original), "wb") as output:
                    output.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                    output.writeframes(pcm)
                data = bytearray(original.read_bytes()+trailing)
                data[4:8] = b"\xff"*4
                offset = data.index(b"data")+4
                data[offset:offset+4] = b"\xff"*4
                original.write_bytes(data)
                recovered, note = audit.recover_reference_wav(original)
                self.assertEqual(original.read_bytes(), data)
                self.assertEqual(note["discardedTailBytes"], len(trailing))
                self.assertEqual(note["frames"], 8)
                with wave.open(str(recovered), "rb") as output:
                    self.assertEqual(output.getnframes(), 8)
                    self.assertEqual(output.readframes(100), pcm)

    def test_foreground_checks_controller_identity_and_reconnects(self):
        state = {"state":"playing", "station":{"id":"other"}, "playerPid":123, "retry":0, "error":""}
        self.assertEqual(audit.foreground_sample(state, "other", 123)["stationId"], "other")
        for changed in ({"station":{"id":"wrong"}}, {"station":None}, {"playerPid":456},
                        {"state":"paused"}, {"retry":1}, {"error":"connection failed"}):
            with self.subTest(changed=changed), self.assertRaises(RuntimeError):
                audit.foreground_sample(dict(state, **changed), "other", 123)

    def test_duration_and_offset_values_are_bounded_and_match_stations(self):
        self.assertEqual(audit.minute_values("5", 3, 1, 30, "minutes"), [5,5,5])
        self.assertEqual(audit.minute_values("0,1,2", 3, 0, 10, "offsets"), [0,1,2])
        for raw in ("0", "31", "5,6", "bad", "1,2,3,4"):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                audit.minute_values(raw, 3, 1, 30, "minutes")

    def test_staggered_windows_keep_padding_lead_and_cross_midnight(self):
        now = dt.datetime(2026,11,22,23,58,55,tzinfo=dt.timezone.utc)
        windows = audit.schedule_windows(now, [5,6,7], [0,1,2], [(15,30),(30,45),(45,60)])
        self.assertGreaterEqual((windows[0][0]-now).total_seconds(), 60)
        self.assertEqual(windows[0][0], dt.datetime(2026,11,23,0,0,tzinfo=dt.timezone.utc))
        self.assertEqual([(b-a).total_seconds()/60 for a,b in windows], [5,6,7])
        self.assertEqual([(a-windows[0][0]).total_seconds()/60 for a,b in windows], [0,1,2])

    def test_known_offset_and_gain(self):
        rng = random.Random(91)
        reference = [rng.uniform(.1, 2) for _ in range(1800)]
        template = [x*.7+.3 for x in reference[317:717]]
        match = audit.find_match(reference, template)
        self.assertAlmostEqual(match["referenceSecond"], 317/50)
        self.assertGreater(match["correlation"], .999)
        self.assertGreater(match["ambiguityMargin"], .05)

    def test_flat_and_unrelated_audio_do_not_prove_a_match(self):
        self.assertIsNone(audit.find_match([1]*1000, [1]*400))
        rng = random.Random(29)
        match = audit.find_match([rng.random() for _ in range(1800)], [rng.random() for _ in range(400)])
        self.assertLess(match["correlation"], .85)

    def test_repeated_content_is_marked_ambiguous(self):
        rng = random.Random(17)
        clip = [rng.random() for _ in range(400)]
        match = audit.find_match(clip+[0]*200+clip, clip)
        self.assertAlmostEqual(match["ambiguityMargin"], 0)

    def test_delivery_bounds_need_both_sides(self):
        points = [{"wallTime":1,"mediaSecond":4}, {"wallTime":2,"mediaSecond":12}]
        self.assertEqual(audit.delivery_bounds(points, 1.5), [4, 12])
        self.assertIsNone(audit.delivery_bounds(points, .5))
        self.assertIsNone(audit.delivery_bounds(points, 3))

    def test_boundary_content_can_match_without_the_post_roll_tail(self):
        rng = random.Random(42)
        reference = [rng.random() for _ in range(3000)]
        saved = [x*.8 for x in reference[300:2300]]
        saved[-400:] = [rng.random() for _ in range(400)]
        match = audit.match_delivery_boundary(saved, reference, [17.2,17.8])
        self.assertTrue(match["confirmed"])
        self.assertAlmostEqual(match["savedDeliveryBounds"][0], 11.2)
        self.assertAlmostEqual(match["savedDeliveryBounds"][1], 11.8)

    def test_missing_boundary_is_not_accepted(self):
        rng = random.Random(71)
        reference = [rng.random() for _ in range(3000)]
        self.assertFalse(audit.match_delivery_boundary(reference[300:600], reference, [30,30.2])["confirmed"])
        self.assertFalse(audit.match_delivery_boundary(reference, reference, [90,91])["confirmed"])

    def test_different_outer_context_does_not_hide_a_preserved_boundary(self):
        rng = random.Random(132)
        reference = [rng.random() for _ in range(3500)]
        saved = reference[300:2800].copy()
        # Different content 2–4 seconds either side, but the entire boundary
        # interval plus two seconds on each side is preserved.
        for first, last in [(21,23), (27.2,29.2)]:
            lo, hi = round(first*50)-300, round(last*50)-300
            saved[lo:hi] = [rng.random() for _ in range(hi-lo)]
        result = audit.match_delivery_boundary(saved, reference, [25,25.2])
        self.assertTrue(result["confirmed"])
        self.assertEqual(result["contextSeconds"], 2)
        self.assertFalse(result["widerContextMatch"]["confirmed"])
        self.assertAlmostEqual(result["savedDeliveryBounds"][0], 19)
        self.assertAlmostEqual(result["savedDeliveryBounds"][1], 19.2)

    def test_narrower_context_still_rejects_repeated_boundary_content(self):
        rng = random.Random(133)
        reference = [rng.random() for _ in range(3500)]
        core = reference[23*50:round(27.2*50)]
        saved = [rng.random() for _ in range(500)]+core+[rng.random() for _ in range(500)]+core
        result = audit.match_delivery_boundary(saved, reference, [25,25.2])
        self.assertFalse(result["confirmed"])
        self.assertLess(result["match"]["ambiguityMargin"], .05)


if __name__ == "__main__":
    unittest.main()
