"""Numba-free 'crop to content' for stitched panoramas.

A rotational stitch's warped hull is non-rectangular, so `crop=False` output
has black wedges. The `stitching` library's `crop=True` trims them via
`largestinteriorrectangle` (numba — no Android wheel) and is also buggy on
multi-row layouts ("Rectangles do not overlap"). This is a pure-numpy
replacement: find the largest all-valid axis-aligned rectangle (the classic
"largest rectangle of 1s in a binary matrix", O(H*W)) and crop to it. Run on a
downscaled mask for speed, then scale the rectangle back.

`largest_interior_rectangle` is the unit-testable core (binary mask in,
rectangle out); `crop_to_content` is the image-level wrapper.
"""

from __future__ import annotations

import cv2
import numpy as np


def _max_rect_in_histogram(heights) -> tuple[int, int, int]:
    """Largest-area rectangle under a histogram. Returns (left_x, width,
    height). Standard monotonic-stack sweep, O(W)."""
    stack: list[tuple[int, int]] = []
    best = (0, 0, 0)
    best_area = 0
    n = len(heights)
    for i in range(n + 1):
        cur = int(heights[i]) if i < n else 0
        start = i
        while stack and stack[-1][1] > cur:
            s_i, s_h = stack.pop()
            area = s_h * (i - s_i)
            if area > best_area:
                best_area = area
                best = (s_i, i - s_i, s_h)
            start = s_i
        stack.append((start, cur))
    return best


def largest_interior_rectangle(mask) -> tuple[int, int, int, int]:
    """Largest all-True axis-aligned rectangle in a 2D mask.

    Returns (x, y, w, h). (0,0,0,0) if the mask is empty. Pure numpy — this is
    the function the synthetic unit tests pin.
    """
    m = (np.asarray(mask) > 0).astype(np.int32)
    if m.ndim != 2:
        raise ValueError("mask must be 2D")
    h, w = m.shape
    if h == 0 or w == 0:
        return (0, 0, 0, 0)
    heights = np.zeros(w, dtype=np.int32)
    best = (0, 0, 0, 0)
    best_area = 0
    for y in range(h):
        heights = np.where(m[y] > 0, heights + 1, 0)
        x, rw, rh = _max_rect_in_histogram(heights)
        if rw * rh > best_area:
            best_area = rw * rh
            best = (x, y - rh + 1, rw, rh)
    return best


def content_mask(image, thresh: int = 1):
    """Boolean mask of non-black pixels (the stitched content)."""
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY) if image.ndim == 3 else image
    return gray > thresh


def crop_to_content(image, downscale_to: int = 1000, clean_px: int = 5):
    """Crop `image` to the largest rectangle containing only content (no black
    wedges). LIR is computed on a mask downscaled so its long edge is
    `downscale_to`, then the rectangle is scaled back and inset to absorb the
    downscale's coarseness (guarantees no residual black fringe).

    Before the LIR, a morphological close with a `clean_px`-wide kernel fills
    thin black artifacts (1–few px warp slivers at tile seams) so they don't
    force the rectangle to dodge a near-full frame. Large warp wedges (the
    rotational case) are far wider than the kernel and survive — they still get
    cropped. `clean_px=0` disables it.

    Returns (cropped_image, (x, y, w, h) in full-res coords).
    """
    mask = content_mask(image)
    h, w = mask.shape
    scale = 1.0
    small = mask
    if max(h, w) > downscale_to:
        scale = downscale_to / max(h, w)
        small = cv2.resize(
            mask.astype(np.uint8),
            (max(1, int(w * scale)), max(1, int(h * scale))),
            interpolation=cv2.INTER_NEAREST,
        ) > 0

    if clean_px and clean_px > 0:
        k = cv2.getStructuringElement(cv2.MORPH_RECT, (clean_px, clean_px))
        small = cv2.morphologyEx(
            small.astype(np.uint8), cv2.MORPH_CLOSE, k).astype(bool)

    x, y, rw, rh = largest_interior_rectangle(small)
    if rw == 0 or rh == 0:
        return image, (0, 0, 0, 0)

    # Scale back to full res, then inset by the downscale's pixel-uncertainty
    # (one small-pixel = 1/scale full pixels) so no black edge sneaks in.
    inset = int(np.ceil(1.0 / scale)) if scale < 1.0 else 0
    X = int(round(x / scale)) + inset
    Y = int(round(y / scale)) + inset
    W = int(round(rw / scale)) - 2 * inset
    H = int(round(rh / scale)) - 2 * inset
    X = max(0, min(X, w - 1))
    Y = max(0, min(Y, h - 1))
    W = max(1, min(W, w - X))
    H = max(1, min(H, h - Y))
    return image[Y:Y + H, X:X + W], (X, Y, W, H)
