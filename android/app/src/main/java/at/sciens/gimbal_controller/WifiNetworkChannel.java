package at.sciens.gimbal_controller;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.net.wifi.WifiManager;
import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * Platform-channel bridge that lets the Dart camera code route HTTP /
 * UDP traffic over the camera's WiFi access point instead of cellular.
 *
 * On Android 10+, if the phone has cellular AND a camera-AP attached,
 * the OS will prefer cellular for "192.168.54.1" — failing immediately
 * or, worse, burning paid data on Panasonic-shaped XML that goes
 * nowhere. SSDP multicast replies also won't reach a non-locked
 * process. {@link #bind()} fixes both:
 *   1. Acquires a {@link WifiManager.MulticastLock} so SSDP M-SEARCH
 *      replies are delivered to our app.
 *   2. Issues a {@link NetworkRequest} for WiFi, awaits the {@link
 *      Network} callback, then calls
 *      {@link ConnectivityManager#bindProcessToNetwork(Network)} so
 *      every subsequent socket in our process routes over WiFi.
 *
 * {@link #unbind()} is the exact inverse and is idempotent.
 *
 * Both methods reply on the main thread (MethodChannel convention).
 *
 * See SPEC-flutter-app.md Phase 2, "WifiNetworkChannel.java".
 */
public class WifiNetworkChannel implements MethodChannel.MethodCallHandler {

    private static final String CHANNEL_NAME =
            "at.sciens.gimbal_controller/wifi_network";

    private final Context appContext;
    private final Handler mainHandler;

    @Nullable
    private WifiManager.MulticastLock multicastLock;
    @Nullable
    private ConnectivityManager.NetworkCallback networkCallback;

    public WifiNetworkChannel(@NonNull Context context) {
        this.appContext = context.getApplicationContext();
        this.mainHandler = new Handler(Looper.getMainLooper());
    }

    /** Register this handler against the Flutter engine. */
    public void register(@NonNull FlutterEngine engine) {
        new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), CHANNEL_NAME)
                .setMethodCallHandler(this);
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case "bind":
                bind(result);
                break;
            case "unbind":
                unbind(result);
                break;
            default:
                result.notImplemented();
        }
    }

    private void bind(@NonNull MethodChannel.Result rawResult) {
        // Wrap so the result fires on the main thread regardless of
        // which thread NetworkCallback delivers on.
        final MainThreadResult result = new MainThreadResult(rawResult, mainHandler);

        // Step 1: multicast lock so SSDP replies make it into our process.
        WifiManager wifi = (WifiManager) appContext.getSystemService(Context.WIFI_SERVICE);
        if (wifi == null) {
            result.error("no_wifi_service", "WifiManager unavailable", null);
            return;
        }
        if (multicastLock == null) {
            multicastLock = wifi.createMulticastLock("sciens-ssdp");
            multicastLock.setReferenceCounted(false);
        }
        if (!multicastLock.isHeld()) {
            multicastLock.acquire();
        }

        // Step 2: request a WiFi network, bind the process to it once
        // the OS hands one over.
        final ConnectivityManager cm =
                (ConnectivityManager) appContext.getSystemService(Context.CONNECTIVITY_SERVICE);
        if (cm == null) {
            releaseMulticast();
            result.error("no_connectivity_service", "ConnectivityManager unavailable", null);
            return;
        }

        NetworkRequest request = new NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .build();

        // If a previous bind() left a callback registered (shouldn't
        // happen with paired unbind(), but defensive), drop it first.
        if (networkCallback != null) {
            try { cm.unregisterNetworkCallback(networkCallback); } catch (Exception ignored) {}
            networkCallback = null;
        }

        networkCallback = new ConnectivityManager.NetworkCallback() {
            private boolean replied = false;

            @Override
            public void onAvailable(@NonNull Network network) {
                if (replied) return;
                replied = true;
                boolean bound = cm.bindProcessToNetwork(network);
                if (bound) {
                    result.success(null);
                } else {
                    result.error("bind_failed",
                            "bindProcessToNetwork returned false", null);
                }
            }

            @Override
            public void onUnavailable() {
                if (replied) return;
                replied = true;
                result.error("unavailable",
                        "No WiFi network available", null);
            }
        };

        cm.requestNetwork(request, networkCallback);
    }

    private void unbind(@NonNull MethodChannel.Result rawResult) {
        final MainThreadResult result = new MainThreadResult(rawResult, mainHandler);

        ConnectivityManager cm =
                (ConnectivityManager) appContext.getSystemService(Context.CONNECTIVITY_SERVICE);

        if (cm != null) {
            // Step 1: restore default OS routing.
            try { cm.bindProcessToNetwork(null); } catch (Exception ignored) {}

            // Step 2: release the WiFi network-request callback.
            if (networkCallback != null) {
                try { cm.unregisterNetworkCallback(networkCallback); } catch (Exception ignored) {}
                networkCallback = null;
            }
        }

        // Step 3: release the multicast lock.
        releaseMulticast();

        result.success(null);
    }

    private void releaseMulticast() {
        if (multicastLock != null) {
            try {
                if (multicastLock.isHeld()) multicastLock.release();
            } catch (Exception ignored) {}
            multicastLock = null;
        }
    }

    /**
     * Wraps {@link MethodChannel.Result} so success/error are dispatched
     * on the main thread. Flutter's MethodChannel is technically
     * thread-safe, but the convention is main-thread reply.
     */
    private static final class MainThreadResult {
        private final MethodChannel.Result delegate;
        private final Handler handler;

        MainThreadResult(@NonNull MethodChannel.Result delegate, @NonNull Handler handler) {
            this.delegate = delegate;
            this.handler = handler;
        }

        void success(@Nullable Object value) {
            handler.post(() -> delegate.success(value));
        }

        void error(@NonNull String code, @Nullable String message, @Nullable Object details) {
            handler.post(() -> delegate.error(code, message, details));
        }
    }
}
