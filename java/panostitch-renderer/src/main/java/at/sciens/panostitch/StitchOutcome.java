package at.sciens.panostitch;

/** The product of a successful stitch: PNG bytes + pixel dimensions. */
public final class StitchOutcome {
    public final byte[] png;
    public final int width;
    public final int height;

    public StitchOutcome(byte[] png, int width, int height) {
        this.png = png;
        this.width = width;
        this.height = height;
    }
}
