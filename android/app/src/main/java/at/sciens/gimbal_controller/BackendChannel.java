package at.sciens.gimbal_controller;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import androidx.annotation.NonNull;

import at.sciens.panostitch.Main;

import com.chaquo.python.Python;
import com.chaquo.python.android.AndroidPlatform;

import java.io.File;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.javalin.Javalin;

/**
 * Boots the in-process panostitch-renderer (Javalin + GraphQL) and exposes its
 * bound port to Dart — the panoramique analogue of petzvalStudio's MainActivity
 * backend boot, packaged as a platform-channel handler to match this app's
 * {@link StitchChannel} / {@link NsdChannel} style.
 *
 * <p>Started eagerly at app launch (per the "boot at app start" decision):
 * Chaquopy's CPython is initialised and the server bound on 127.0.0.1:0 on a
 * background thread. Dart calls {@code getBackendPort} (which blocks until the
 * server is up) to learn the URL for the affine StitchMode.
 */
public class BackendChannel implements MethodChannel.MethodCallHandler {

    private static final String TAG = "panostitch-backend";
    private static final String CHANNEL_NAME = "at.sciens.gimbal_controller/backend";

    private final Context appContext;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final CountDownLatch ready = new CountDownLatch(1);
    private final AtomicInteger boundPort = new AtomicInteger(-1);
    private final AtomicReference<Throwable> startError = new AtomicReference<>(null);
    private final ExecutorService bootExec = Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "panostitch-backend");
        t.setDaemon(true);
        return t;
    });
    private Javalin server;

    public BackendChannel(@NonNull Context context) {
        this.appContext = context.getApplicationContext();
        bootExec.submit(this::boot);
    }

    private void boot() {
        try {
            if (!Python.isStarted()) {
                Python.start(new AndroidPlatform(appContext));
            }
            File cacheDir = appContext.getCacheDir();
            server = Main.start(0, new ChaquopyStitchEngine(cacheDir));
            boundPort.set(server.port());
            Log.i(TAG, "panostitch-renderer ready on 127.0.0.1:" + server.port());
        } catch (Throwable t) {
            Log.e(TAG, "backend failed to start", t);
            startError.set(t);
        } finally {
            ready.countDown();
        }
    }

    public void register(@NonNull FlutterEngine engine) {
        new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), CHANNEL_NAME)
                .setMethodCallHandler(this);
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        if (!"getBackendPort".equals(call.method)) {
            result.notImplemented();
            return;
        }
        // Await the boot off the platform thread, then post the answer back.
        new Thread(() -> {
            try {
                if (!ready.await(30, TimeUnit.SECONDS)) {
                    postError(result, "BACKEND_TIMEOUT", "backend did not start in 30s");
                    return;
                }
                Throwable err = startError.get();
                if (err != null) {
                    postError(result, "BACKEND_FAILED",
                            err.getMessage() != null ? err.getMessage() : err.toString());
                    return;
                }
                int p = boundPort.get();
                mainHandler.post(() -> result.success(p));
            } catch (InterruptedException e) {
                postError(result, "BACKEND_INTERRUPTED", e.getMessage());
            }
        }, "panostitch-port-wait").start();
    }

    private void postError(MethodChannel.Result result, String code, String msg) {
        mainHandler.post(() -> result.error(code, msg, null));
    }
}
