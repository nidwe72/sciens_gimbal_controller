package at.sciens.panostitch;

import org.reactivestreams.FlowAdapters;
import org.reactivestreams.Publisher;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CancellationException;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.SubmissionPublisher;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Ties together the tile-upload buffer, the single-flight stitch worker, and
 * the per-stitch event channel for the {@code stitchEvents} subscription.
 * Adapted from petzvalStudio's RenderService — the publisher / single-flight /
 * cancel machinery is identical; only the work (a {@link StitchEngine} call
 * instead of a module pipeline) differs.
 */
public final class StitchService {

    private static final Logger LOG = LoggerFactory.getLogger(StitchService.class);

    /** Outcome of a stitch run, mirrored into both GET /result and the terminal event. */
    enum Status { OK, CANCELLED, FAILED }

    static final class Result {
        final Status status;
        final byte[] png;
        final int width, height;
        final String error;

        private Result(Status status, byte[] png, int width, int height, String error) {
            this.status = status; this.png = png;
            this.width = width; this.height = height; this.error = error;
        }
        static Result ok(byte[] png, int w, int h) { return new Result(Status.OK, png, w, h, null); }
        static Result cancelled() { return new Result(Status.CANCELLED, null, 0, 0, null); }
        static Result failed(String msg) { return new Result(Status.FAILED, null, 0, 0, msg); }
    }

    private final StitchEngine engine;

    /** Pending tile uploads, keyed by upload id, value = raw PNG bytes. */
    private final Map<String, byte[]> uploads = new ConcurrentHashMap<>();
    private final Map<String, CompletableFuture<Result>> results = new ConcurrentHashMap<>();
    private final Map<String, AtomicBoolean> cancels = new ConcurrentHashMap<>();
    private final Map<String, SubmissionPublisher<Object>> eventPubs = new ConcurrentHashMap<>();

    private volatile String inFlight;

    /** One stitch at a time (single-flight). Daemon so it never blocks JVM exit. */
    private final ExecutorService exec = Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "panostitch-worker");
        t.setDaemon(true);
        return t;
    });

    public StitchService(StitchEngine engine) {
        this.engine = engine;
    }

    public String registerUpload(byte[] bytes) {
        String id = UUID.randomUUID().toString();
        uploads.put(id, bytes);
        return id;
    }

    /**
     * Materialise the uploaded tiles to a temp dir and submit the stitch.
     * Returns a stitchId immediately; the work runs on the single-flight worker.
     */
    public String stitch(List<String> uploadIds, int nCols) {
        String id = UUID.randomUUID().toString();
        AtomicBoolean cancel = new AtomicBoolean(false);
        cancels.put(id, cancel);
        CompletableFuture<Result> fut = new CompletableFuture<>();
        results.put(id, fut);
        SubmissionPublisher<Object> events = new SubmissionPublisher<>();
        eventPubs.put(id, events);

        // Single-flight: supersede any stitch currently in flight.
        String prev = inFlight;
        if (prev != null) {
            AtomicBoolean prevCancel = cancels.get(prev);
            if (prevCancel != null) prevCancel.set(true);
        }
        inFlight = id;

        // Drain the uploads onto disk now (on the request thread) so a slow
        // worker can't race a follow-up upload reusing the buffer.
        final List<Path> tilePaths;
        final Path tileDir;
        try {
            tileDir = Files.createTempDirectory("panostitch-" + id.substring(0, 8) + "-");
            tilePaths = new ArrayList<>(uploadIds.size());
            int i = 0;
            for (String uid : uploadIds) {
                byte[] bytes = uploads.remove(uid);
                if (bytes == null) {
                    throw new IllegalArgumentException("unknown uploadId: " + uid);
                }
                Path p = tileDir.resolve(String.format("tile_%02d.png", i++));
                Files.write(p, bytes);
                tilePaths.add(p);
            }
        } catch (Exception e) {
            Result r = Result.failed("tile staging failed: " + e.getMessage());
            fut.complete(r);
            events.submit(terminalEvent(id, r));
            events.close();
            eventPubs.remove(id);
            cancels.remove(id);
            return id;
        }

        exec.submit(() -> {
            Result r;
            try {
                // Progress is lossy-OK: offer non-blocking. The cancel check
                // turns a flipped flag into a CancellationException at the next
                // reported step boundary.
                ProgressReporter overall = frac -> {
                    if (cancel.get()) throw new CancellationException();
                    events.offer(progressEvent(id, frac), 0L, TimeUnit.MILLISECONDS, null);
                };
                List<String> paths = tilePaths.stream().map(Path::toString).toList();
                StitchOutcome out = engine.stitch(paths, nCols, overall);
                r = Result.ok(out.png, out.width, out.height);
            } catch (CancellationException ce) {
                r = Result.cancelled();
            } catch (Throwable t) {
                // The engine runs Python via Chaquopy, which wraps a thrown
                // CancellationException into its own exception type — so a
                // flipped cancel flag is the reliable signal, not the class.
                if (cancel.get()) {
                    r = Result.cancelled();
                } else {
                    LOG.warn("stitch {} failed", id, t);
                    r = Result.failed(t.getClass().getSimpleName() + ": " + t.getMessage());
                }
            } finally {
                cancels.remove(id);
                deleteQuietly(tileDir, tilePaths);
            }
            fut.complete(r);
            try {
                events.submit(terminalEvent(id, r));
            } catch (RuntimeException ignored) {
                // submit can be interrupted during shutdown; GET /result still works.
            } finally {
                events.close();
                eventPubs.remove(id);
            }
        });
        return id;
    }

    /** Reactive-streams view of a stitch's event channel for the subscription
     *  resolver. Unknown / finished stitches get an immediately-complete stream. */
    public Publisher<Object> eventPublisher(String stitchId) {
        SubmissionPublisher<Object> pub = eventPubs.get(stitchId);
        if (pub != null) {
            return FlowAdapters.toPublisher(pub);
        }
        SubmissionPublisher<Object> empty = new SubmissionPublisher<>();
        Publisher<Object> p = FlowAdapters.toPublisher(empty);
        empty.close();
        return p;
    }

    public boolean cancel(String stitchId) {
        AtomicBoolean flag = cancels.get(stitchId);
        if (flag != null) {
            flag.set(true);
            return true;
        }
        return false;
    }

    /** Blocks until the stitch completes, returns and discards its result.
     *  Null only for an unknown stitchId. */
    public Result fetchResult(String stitchId) {
        CompletableFuture<Result> fut = results.get(stitchId);
        if (fut == null) return null;
        try {
            return fut.get();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return Result.failed("interrupted while awaiting stitch");
        } catch (ExecutionException e) {
            Throwable cause = e.getCause() != null ? e.getCause() : e;
            return Result.failed(cause.toString());
        } finally {
            results.remove(stitchId);
        }
    }

    private static Map<String, Object> progressEvent(String id, double frac) {
        double f = frac < 0 ? 0 : (frac > 1 ? 1 : frac);
        Map<String, Object> m = new HashMap<>();
        m.put("stitchId", id);
        m.put("phase", "stitch");
        m.put("done", f);
        m.put("status", "PROGRESS");
        return m;
    }

    private static Map<String, Object> terminalEvent(String id, Result r) {
        Map<String, Object> m = new HashMap<>();
        m.put("stitchId", id);
        m.put("phase", "done");
        switch (r.status) {
            case OK -> {
                m.put("done", 1.0);
                m.put("status", "COMPLETED");
                Map<String, Object> res = new HashMap<>();
                res.put("width", r.width);
                res.put("height", r.height);
                res.put("bytes", r.png != null ? r.png.length : 0);
                m.put("result", res);
            }
            case CANCELLED -> m.put("status", "CANCELLED");
            case FAILED -> {
                m.put("status", "FAILED");
                m.put("error", r.error);
            }
        }
        return m;
    }

    private static void deleteQuietly(Path dir, List<Path> files) {
        for (Path f : files) {
            try { Files.deleteIfExists(f); } catch (IOException ignored) { /* best effort */ }
        }
        try { Files.deleteIfExists(dir); } catch (IOException ignored) { /* best effort */ }
    }
}
