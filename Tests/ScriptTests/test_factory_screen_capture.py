"""PNG dimensions must match logical component bounds at 1x or 2x scale."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Scripts'))
from test_factory_screens import validate_dimensions


class FactoryCaptureTests(unittest.TestCase):
    def test_native_components_accept_both_display_scales(self):
        for name, width, height in [('factory-library-dark.png', 1200, 960), ('factory-build-sheet-light.png', 570, 549), ('factory-missing-docker-dark.png', 570, 486)]:
            for scale in [1, 2]:
                validate_dimensions(name, width * scale, height * scale, {'widthPoints': width, 'heightPoints': height})

    def test_cropped_or_distorted_pixels_cannot_pass(self):
        frame = {'widthPoints': 570, 'heightPoints': 549}
        for width, height in [(570, 200), (1140, 549), (600, 549), (1, 1)]:
            with self.assertRaises(AssertionError):
                validate_dimensions('factory-build-sheet-dark.png', width, height, frame)

    def test_inadequate_logical_viewport_is_refused_even_at_retina_scale(self):
        for name, width, height in [('factory-library-light.png', 500, 800), ('factory-build-sheet-dark.png', 570, 200)]:
            with self.assertRaises(AssertionError):
                validate_dimensions(name, width * 2, height * 2, {'widthPoints': width, 'heightPoints': height})
