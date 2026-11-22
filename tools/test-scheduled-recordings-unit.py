#!/usr/bin/env python3
"""Local checks for the live audit's content-matching confidence logic."""
import importlib.util
from pathlib import Path
import random
import unittest

spec = importlib.util.spec_from_file_location("scheduled_audit", Path(__file__).with_name("test-scheduled-recordings.py"))
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class MatchingTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
