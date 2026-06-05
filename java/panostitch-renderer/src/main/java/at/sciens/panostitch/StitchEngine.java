package at.sciens.panostitch;

import java.util.List;

/**
 * The actual stitch, injected by the host. The renderer jar is pure Java with
 * no image stack of its own; on Android the app supplies a Chaquopy/Python
 * implementation that runs the validated `AffineStitcher(sift, crop=False)`.
 * (This is the same dependency-injection seam petzvalStudio uses for its
 * WorkspaceService.)
 */
public interface StitchEngine {

    /**
     * Stitch tiles into a single panorama.
     *
     * @param tilePaths absolute paths to tile PNGs, in stitch order
     * @param nCols     grid column count (hint; {@code <= 0} if unknown)
     * @param progress  called with monotonic [0,1] fractions as the pipeline
     *                  advances. The implementation should call it between
     *                  pipeline steps; if it throws (e.g. on cancel) the engine
     *                  must let the exception propagate.
     * @return the stitched panorama as PNG bytes + dimensions
     * @throws Exception on any stitch failure (surfaced to the client as FAILED)
     */
    StitchOutcome stitch(List<String> tilePaths, int nCols, ProgressReporter progress)
            throws Exception;
}
