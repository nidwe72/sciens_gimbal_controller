# python_test

Dev-machine tests for the app's bundled Python (Chaquopy) stitch code — runs on
the host, not the phone. Currently guards the **stitch + numba-free crop** on
the Hugin dataset.

- **`test_stitch_crop.py`** — stitches the 8 Hugin frames with the two live-mode
  projections (`plane` / `spherical`), applies the shipped
  `crop_util.crop_to_content`, and **fails if a large black region remains**
  (`fill_ratio < 0.99`).
- Fixtures live in `android/app/src/androidTest/assets/hugin/` — the **test**
  APK only (not shipped to users), so this can later become an on-device
  instrumented test (postponed).
- The crop module under test is `android/app/src/main/python/crop_util.py` (the
  real shipped code).

## Run

```bash
python -m venv .venv && . .venv/bin/activate
pip install -r python_test/requirements.txt
pytest python_test -q
```
