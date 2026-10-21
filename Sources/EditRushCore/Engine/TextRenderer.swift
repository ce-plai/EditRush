import CoreGraphics
import CoreImage

/// Renders `TextStyle` into an image at canvas pixel scale (STUB — engine module).
/// The rendered image size is the text clip's base `content` size for `ClipGeometry.rect`.
public enum TextRenderer {
    /// Size in canvas pixels of the rendered text (including background box padding / shadow margin).
    public static func size(for style: TextStyle, canvas: CGSize) -> CGSize {
        CGSize(width: canvas.width * 0.4, height: canvas.height * style.fontSize * 1.4)
    }
    /// Premultiplied RGBA image of the text, `size(for:canvas:)` pixels. Cached by style+canvas.
    public static func image(for style: TextStyle, canvas: CGSize) -> CGImage? { nil }
}
