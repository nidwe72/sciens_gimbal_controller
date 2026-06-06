"""Project test for the stitch + numba-free crop on the bundled Hugin dataset.

Runs the two live-mode projections (planar/rectilinear and spherical), each
followed by the app's `crop_util.crop_to_content`, and fails if a large black
region remains (fill_ratio < 0.99). Exercises the *shipped* crop module
(android/app/src/main/python/crop_util.py) against the fixtures in
android/app/src/androidTest/assets/hugin/.

Runs on the dev machine via a venv with numpy + opencv-python + stitching (see
requirements.txt). The same fixtures live under androidTest/ so this can later
be promoted to an on-device instrumented test (postponed).
"""

from __future__ import annotations

import glob
import os
import sys

import cv2
import numpy as np
import pytest

_HERE = os.path.dirname(os.path.abspath(__file__))
_APP_PY = os.path.normpath(
    os.path.join(_HERE, "..", "android", "app", "src", "main", "python"))
_HUGIN = os.path.normpath(
    os.path.join(_HERE, "..", "android", "app", "src", "androidTest",
                 "assets", "hugin"))

sys.path.insert(0, _APP_PY)
from crop_util import crop_to_content  # noqa: E402  (the shipped module)

# Passing fill threshold — "no large black portion left" after the crop.
MIN_FILL = 0.99


def _fill_ratio(img) -> float:
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    return float(np.count_nonzero(gray > 1) / gray.size)


def _tile_paths():
    return sorted(glob.glob(os.path.join(_HUGIN, "*.jpg")))


@pytest.mark.skipif(len(_tile_paths()) < 2,
                    reason=f"hugin fixtures not found at {_HUGIN}")
@pytest.mark.parametrize("projection", ["plane", "spherical"])
def test_hugin_stitch_crops_black_free(projection):
    from stitching import Stitcher

    paths = _tile_paths()
    assert len(paths) == 8, f"expected 8 Hugin tiles, found {len(paths)}"

    stitcher = Stitcher(detector="sift", warper_type=projection, crop=False)
    pano = stitcher.stitch(paths)

    cropped, rect = crop_to_content(pano)
    fill = _fill_ratio(cropped)

    assert fill >= MIN_FILL, (
        f"{projection}: large black region remains after crop "
        f"(fill={fill:.3f} < {MIN_FILL}); rect={rect}")
    # Sanity: the crop must not collapse the panorama to a sliver.
    area_frac = (cropped.shape[0] * cropped.shape[1]) / (pano.shape[0] * pano.shape[1])
    assert area_frac > 0.25, f"{projection}: crop collapsed (area_frac={area_frac:.2f})"
