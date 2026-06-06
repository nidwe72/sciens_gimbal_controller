package at.sciens.gimbal_controller;

import at.sciens.panostitch.ProgressReporter;
import at.sciens.panostitch.StitchEngine;
import at.sciens.panostitch.StitchOutcome;

import com.chaquo.python.PyObject;
import com.chaquo.python.Python;

import java.io.File;
import java.nio.file.Files;
import java.util.List;

/**
 * {@link StitchEngine} backed by the on-device Python {@code stitch_worker}
 * (Chaquopy). This is the app-side seam: the pure-Java panostitch-renderer jar
 * has no image stack, so it delegates the actual stitch here, where Chaquopy's
 * in-process CPython runs the validated {@code AffineStitcher(sift,
 * crop=False)} recipe.
 *
 * <p>The injected {@link ProgressReporter} is handed straight to Python — the
 * worker calls {@code progress.report(float)} between pipeline steps, and those
 * fractions flow back out onto the {@code stitchEvents} subscription.
 */
public final class ChaquopyStitchEngine implements StitchEngine {

    private final File cacheDir;

    public ChaquopyStitchEngine(File cacheDir) {
        this.cacheDir = cacheDir;
    }

    /**
     * Public adapter so Python sees a public class with a public {@code
     * report(double)} method. Passing the bare {@link ProgressReporter} lambda
     * risks the same "inaccessible class" reflection failure Chaquopy hits on
     * package-private types.
     */
    public static final class PyProgress {
        private final ProgressReporter delegate;
        PyProgress(ProgressReporter delegate) { this.delegate = delegate; }
        public void report(double fraction) { delegate.report(fraction); }
    }

    @Override
    public StitchOutcome stitch(List<String> tilePaths, int nCols,
                                String projection, ProgressReporter progress)
            throws Exception {
        Python py = Python.getInstance();
        PyObject worker = py.getModule("stitch_worker");
        // GraphQL enum name (AFFINE/RECTILINEAR/SPHERICAL) -> worker's
        // lowercase projection key.
        String proj = (projection == null ? "affine" : projection).toLowerCase();

        // Pass a Java String[] — Chaquopy maps Java *arrays* to a `jarray` that
        // supports Python's full sequence protocol (iteration, len, indexing),
        // so the worker can iterate it directly. Java *collections* (List/
        // ArrayList) are NOT mapped this way — they stay opaque jclass objects
        // and aren't iterable from Python — which is why passing the List
        // failed. (Per Chaquopy's data-types docs.)
        String[] paths = tilePaths.toArray(new String[0]);

        File out = File.createTempFile("pano_", ".png", cacheDir);
        try {
            // stitch_worker.stitch(tile_paths, out_path, n_cols, progress) ->
            // [width, height]. `progress` is this Java object; Python invokes
            // its report(double) directly via Chaquopy.
            PyObject dims = worker.callAttr(
                    "stitch", paths, out.getAbsolutePath(), nCols,
                    new PyProgress(progress), proj);
            List<PyObject> wh = dims.asList();
            int width = wh.get(0).toInt();
            int height = wh.get(1).toInt();
            byte[] png = Files.readAllBytes(out.toPath());
            return new StitchOutcome(png, width, height);
        } finally {
            //noinspection ResultOfMethodCallIgnored
            out.delete();
        }
    }
}
