package at.sciens.panostitch;

import io.javalin.Javalin;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Panostitch renderer entry point. On Android this is started in-process from
 * MainActivity via {@link #start(int, StitchEngine)} — bound to 127.0.0.1 on a
 * kernel-assigned port (pass {@code 0}). Forked from petzvalStudio's Main,
 * stripped to the single in-process mode (no Linux-sidecar / Web-server modes,
 * no JavaCV thread tuning, no file-log rotation).
 */
public final class Main {

    private static final Logger LOG = LoggerFactory.getLogger(Main.class);

    /**
     * Start the in-process stitch server.
     *
     * @param requestedPort port to bind ({@code 0} = kernel-assigned)
     * @param engine        the stitch implementation (Chaquopy/Python on Android)
     * @return the started Javalin instance; call {@code .port()} for the bound port
     */
    public static Javalin start(int requestedPort, StitchEngine engine) {
        Javalin app = Javalin.create(cfg -> {
            cfg.showJavalinBanner = false;
            cfg.jetty.defaultHost = "127.0.0.1";
            // Tile bundles can be several MB; lift the 1 MB default ceiling.
            cfg.http.maxRequestSize = 200L * 1024 * 1024;
        });
        app.get("/health", ctx -> ctx.result("ok"));
        new GraphQLEndpoint(engine).register(app);
        app.start(requestedPort);
        LOG.info("panostitch-renderer listening on http://127.0.0.1:{}", app.port());
        return app;
    }

    private Main() {}
}
