import CoreImage

/// The single implementation of per-clip colour adjustments + filter presets, shared by the
/// compositor and UI thumbnails (STUB — engine module).
public enum FilterRenderer {
    /// Applies `color` adjustments, then `filter` mixed with the unfiltered result by `intensity`
    /// (0...1). The output is cropped to the input's extent. Thread-safe.
    public static func apply(color: ColorAdjustments, filter: FilterPreset, intensity: Double, to image: CIImage) -> CIImage {
        image
    }
}
