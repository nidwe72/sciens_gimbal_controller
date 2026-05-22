package at.sciens.gimbal_controller;

import android.content.Context;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * Platform-channel bridge that advertises the in-app diagnostics HTTP
 * server over mDNS / DNS-SD, so the dev machine can discover it
 * (e.g. {@code avahi-browse -rt _http._tcp}) without being told the
 * phone's DHCP IP.
 *
 * Wraps {@link NsdManager#registerService} / {@link
 * NsdManager#unregisterService}. Registration callbacks arrive on a
 * background thread; replies are marshalled to the main thread, as
 * {@link WifiNetworkChannel} does.
 *
 * See SPEC-flutter-app.md Phase 2, "Pre-PR 5 — In-app diagnostics
 * wizard".
 */
public class NsdChannel implements MethodChannel.MethodCallHandler {

    private static final String CHANNEL_NAME =
            "at.sciens.gimbal_controller/nsd";

    private final Context appContext;
    private final Handler mainHandler;

    @Nullable
    private NsdManager nsdManager;
    @Nullable
    private NsdManager.RegistrationListener registrationListener;

    public NsdChannel(@NonNull Context context) {
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
            case "register":
                registerService(
                        call.argument("name"),
                        call.argument("type"),
                        call.argument("port"),
                        result);
                break;
            case "unregister":
                unregisterService(result);
                break;
            default:
                result.notImplemented();
        }
    }

    private void registerService(@Nullable String name, @Nullable String type,
                                 @Nullable Integer port,
                                 @NonNull MethodChannel.Result rawResult) {
        final MainThreadResult result = new MainThreadResult(rawResult, mainHandler);

        if (name == null || type == null || port == null) {
            result.error("bad_args", "name, type and port are required", null);
            return;
        }

        if (nsdManager == null) {
            nsdManager = (NsdManager) appContext.getSystemService(Context.NSD_SERVICE);
        }
        if (nsdManager == null) {
            result.error("no_nsd_service", "NsdManager unavailable", null);
            return;
        }

        // Drop a stale registration first — one RegistrationListener
        // instance can back only a single service at a time.
        if (registrationListener != null) {
            try {
                nsdManager.unregisterService(registrationListener);
            } catch (Exception ignored) {}
            registrationListener = null;
        }

        NsdServiceInfo info = new NsdServiceInfo();
        info.setServiceName(name);
        info.setServiceType(type);
        info.setPort(port);

        registrationListener = new NsdManager.RegistrationListener() {
            private boolean replied = false;

            @Override
            public void onServiceRegistered(NsdServiceInfo serviceInfo) {
                if (replied) return;
                replied = true;
                // Android may auto-rename on a name collision; report
                // back whatever name actually went on the wire.
                result.success(serviceInfo.getServiceName());
            }

            @Override
            public void onRegistrationFailed(NsdServiceInfo serviceInfo, int errorCode) {
                if (replied) return;
                replied = true;
                registrationListener = null;
                result.error("registration_failed",
                        "NSD registration failed: " + errorCode, null);
            }

            @Override
            public void onServiceUnregistered(NsdServiceInfo serviceInfo) {}

            @Override
            public void onUnregistrationFailed(NsdServiceInfo serviceInfo, int errorCode) {}
        };

        try {
            nsdManager.registerService(info, NsdManager.PROTOCOL_DNS_SD, registrationListener);
        } catch (Exception e) {
            registrationListener = null;
            result.error("registration_threw", e.getMessage(), null);
        }
    }

    private void unregisterService(@NonNull MethodChannel.Result rawResult) {
        final MainThreadResult result = new MainThreadResult(rawResult, mainHandler);
        if (nsdManager != null && registrationListener != null) {
            try {
                nsdManager.unregisterService(registrationListener);
            } catch (Exception ignored) {}
        }
        registrationListener = null;
        // Best-effort: reply immediately rather than awaiting the
        // onServiceUnregistered callback — teardown is fire-and-forget.
        result.success(null);
    }

    /**
     * Wraps {@link MethodChannel.Result} so success/error are
     * dispatched on the main thread (NSD callbacks fire on a binder
     * thread).
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
