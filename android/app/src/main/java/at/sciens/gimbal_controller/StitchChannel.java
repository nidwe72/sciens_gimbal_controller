package at.sciens.gimbal_controller;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;

import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * Platform-channel bridge for the Phase 6 on-device stitch preview.
 *
 * Dart writes each captured tile to a temp file (under
 * {@code cacheDir/pano_stitch/}) and sends the list of paths plus an
 * output path; this side runs the native stitch and returns the result
 * path. File-path transport keeps us clear of the ~1 MB Binder limit.
 *
 * The actual stitch is the vendored OpenPano engine reached through a
 * thin C++/JNI shim ({@code cpp/stitch.cpp}, native lib
 * {@code panostitch}). This class just marshals paths in/out and the
 * status back to the main thread, as {@link NsdChannel} /
 * {@link WifiNetworkChannel} do.
 *
 * See SPEC-flutter-app.md "Phase 6 — On-device stitch preview".
 */
public class StitchChannel implements MethodChannel.MethodCallHandler {

    private static final String CHANNEL_NAME =
            "at.sciens.gimbal_controller/stitch";

    static {
        // The shim compiles the vendored OpenPano sources in, so it's
        // self-contained — no separate stitch .so to load.
        System.loadLibrary("panostitch");
    }

    /** C++ shim: read(paths) → OpenPano stitch → write(outPath). [nCols]
     *  is the grid width (row-major order) used to restrict feature
     *  matching to neighbouring tiles. 0 = OK; positive = stitch failure;
     *  negative = I/O error. */
    private static native int nativeStitch(String[] paths, String outPath, int nCols);

    private final Handler mainHandler;
    private final ExecutorService executor;

    public StitchChannel(@NonNull Context context) {
        this.mainHandler = new Handler(Looper.getMainLooper());
        this.executor = Executors.newSingleThreadExecutor();
    }

    /** Register this handler against the Flutter engine. */
    public void register(@NonNull FlutterEngine engine) {
        new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), CHANNEL_NAME)
                .setMethodCallHandler(this);
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        if (!"stitch".equals(call.method)) {
            result.notImplemented();
            return;
        }
        final List<String> paths = call.argument("paths");
        final String outPath = call.argument("outPath");
        final Integer nCols = call.argument("nCols");
        if (paths == null || paths.size() < 2 || outPath == null) {
            result.error("bad_args", "Need >= 2 tile paths and an outPath.", null);
            return;
        }
        final String[] pathArray = paths.toArray(new String[0]);
        final int cols = nCols != null ? nCols : 0;
        executor.execute(() -> runStitch(pathArray, outPath, cols, result));
    }

    private void runStitch(String[] paths, String outPath, int nCols,
                           MethodChannel.Result result) {
        final int status;
        try {
            status = nativeStitch(paths, outPath, nCols);
        } catch (Throwable t) {
            reply(() -> result.error("stitch_error", String.valueOf(t.getMessage()), null));
            return;
        }
        if (status == 0) {
            reply(() -> result.success(outPath));
        } else if (status > 0) {
            reply(() -> result.error("stitch_failed", "Stitcher status " + status, status));
        } else {
            reply(() -> result.error("stitch_io", "Stitch I/O error " + status, status));
        }
    }

    private void reply(@NonNull Runnable r) {
        mainHandler.post(r);
    }
}
