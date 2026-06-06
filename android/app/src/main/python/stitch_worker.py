"""On-device stitch worker, driven from Java via Chaquopy.

`stitch()` builds one of three stitcher configs from the `projection` arg —
  * "affine"      → AffineStitcher (demo mode: flat crops)
  * "rectilinear" → Stitcher(warper_type="plane")   (live, looks like one lens)
  * "spherical"   → Stitcher(warper_type="spherical")(live, wide >90° FOV)
all with detector="sift", crop=False — then walks the library's own pipeline
step-by-step (the exact sequence from stitching.Stitcher.stitch, shared by all
three) so it can report a monotonic [0,1] progress fraction between phases.
After the blend it applies the app's numba-free `crop_util.crop_to_content`
to trim the rotational warp's black wedges. Progress fractions are forwarded
to the injected Java `ProgressReporter`, which pushes them onto the GraphQL
`stitchEvents` subscription.

Pinned to stitching==0.6.1 (vendored under this python dir), so the step
sequence is fixed. If `progress.report` raises (the Java side throws on
cancel), the exception propagates and aborts the stitch.
"""

import cv2

from stitching import AffineStitcher, Stitcher
from stitching.images import Images

from crop_util import crop_to_content

# Phase weights (cumulative). Mirror OpenPano's progress.txt feel:
# features ~35, matching ~10, geometry ~15, warp ~20, blend ~20.
_AFTER_FEATURES = 0.35
_AFTER_MATCHING = 0.45
_AFTER_GEOMETRY = 0.60
_AFTER_SEAMS = 0.70
_AFTER_WARP = 0.85
_AFTER_BLEND = 0.98


def _make_stitcher(projection):
    proj = (projection or "affine").lower()
    if proj == "affine":
        return AffineStitcher(detector="sift", crop=False)
    if proj == "rectilinear":
        return Stitcher(detector="sift", warper_type="plane", crop=False)
    if proj == "spherical":
        return Stitcher(detector="sift", warper_type="spherical", crop=False)
    raise ValueError(f"unknown projection: {projection!r}")


def stitch(tile_paths, out_path, n_cols=0, progress=None, projection="affine"):
    """Stitch tile PNGs into a panorama written to out_path.

    Returns [width, height]. `tile_paths` is an iterable of paths: a Chaquopy
    `jarray` (Java String[], which supports Python's sequence protocol) on
    Android, or a plain Python list in local tests. `progress` is a Java
    ProgressReporter-like object with `report(float)`, or None. `projection`
    selects the stitcher (affine / rectilinear / spherical).
    """
    paths = [str(p) for p in tile_paths]

    def report(frac):
        if progress is not None:
            progress.report(float(frac))

    s = _make_stitcher(projection)

    # --- mirror stitching.Stitcher.stitch(), reporting between phases ---
    s.images = Images.of(
        paths, s.medium_megapix, s.low_megapix, s.final_megapix
    )

    imgs = s.resize_medium_resolution()
    features = s.find_features(imgs)
    report(_AFTER_FEATURES)

    matches = s.match_features(features)
    report(_AFTER_MATCHING)

    imgs, features, matches = s.subset(imgs, features, matches)
    cameras = s.estimate_camera_parameters(features, matches)
    cameras = s.refine_camera_parameters(features, matches, cameras)
    cameras = s.perform_wave_correction(cameras)
    s.estimate_scale(cameras)
    report(_AFTER_GEOMETRY)

    imgs = s.resize_low_resolution(imgs)
    imgs, masks, corners, sizes = s.warp_low_resolution(imgs, cameras)
    s.prepare_cropper(imgs, masks, corners, sizes)
    imgs, masks, corners, sizes = s.crop_low_resolution(imgs, masks, corners, sizes)
    s.estimate_exposure_errors(corners, imgs, masks)
    seam_masks = s.find_seam_masks(imgs, corners, masks)
    report(_AFTER_SEAMS)

    imgs = s.resize_final_resolution()
    imgs, masks, corners, sizes = s.warp_final_resolution(imgs, cameras)
    imgs, masks, corners, sizes = s.crop_final_resolution(imgs, masks, corners, sizes)
    s.set_masks(masks)
    imgs = s.compensate_exposure_errors(corners, imgs)
    seam_masks = s.resize_seam_masks(seam_masks)
    report(_AFTER_WARP)

    s.initialize_composition(corners, sizes)
    s.blend_images(imgs, seam_masks, corners)
    pano = s.create_final_panorama()
    report(_AFTER_BLEND)

    # Numba-free crop to trim the warp's black wedges (near-noop for affine,
    # which already fills the frame).
    pano, _ = crop_to_content(pano)

    cv2.imwrite(out_path, pano)
    report(1.0)

    h, w = pano.shape[:2]
    return [int(w), int(h)]


def versions():
    import numpy
    import stitching
    return (
        f"numpy {numpy.__version__} | cv2 {cv2.__version__} | "
        f"stitching {stitching.__version__}"
    )
