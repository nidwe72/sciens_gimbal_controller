package at.sciens.panostitch;

/**
 * Callback for streaming a stitch's completion fraction. Implementations push
 * the value onto the {@code stitchEvents} subscription. Forked verbatim from
 * petzvalStudio's render.ProgressReporter.
 */
@FunctionalInterface
public interface ProgressReporter {
    /** Report completion fraction, clamped to [0,1] by the consumer. */
    void report(double fraction);

    /** A reporter that discards progress — for callers that don't stream it. */
    ProgressReporter NOOP = fraction -> { };
}
