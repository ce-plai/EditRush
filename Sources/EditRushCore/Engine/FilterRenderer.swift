import CoreImage

/// The single implementation of per-clip colour adjustments + filter presets, shared by the
/// compositor and UI thumbnails.
public enum FilterRenderer {
    /// Kelvin shift applied by `ColorAdjustments.temperature` = ±1.
    static let temperatureRangeKelvin = 3000.0

    /// Applies `color` adjustments, then `filter` mixed with the unfiltered result by `intensity`
    /// (0...1). The output is cropped to the input's extent. Thread-safe.
    public static func apply(color: ColorAdjustments, filter: FilterPreset, intensity: Double, to image: CIImage) -> CIImage {
        let mix = max(0, min(1, intensity))
        let hasFilter = filter != .none && mix > 0
        guard !color.isIdentity || hasFilter else { return image }
        let extent = image.extent

        var base = adjust(image, color: color)
        if hasFilter {
            let filtered = preset(filter, on: base, extent: extent)
            if mix >= 0.999 {
                base = filtered
            } else {
                base = base.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: filtered,
                    kCIInputTimeKey: mix,
                ])
            }
        }
        return extent.isInfinite ? base : base.cropped(to: extent)
    }

    // MARK: - Colour adjustments

    private static func adjust(_ input: CIImage, color c: ColorAdjustments) -> CIImage {
        var img = input
        if c.exposure != 0 {
            img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: c.exposure])
        }
        if c.brightness != 0 || c.contrast != 1 || c.saturation != 1 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: c.brightness,
                kCIInputContrastKey: c.contrast,
                kCIInputSaturationKey: c.saturation,
            ])
        }
        if c.temperature != 0 {
            img = temperature(img, amount: c.temperature)
        }
        if c.vignette > 0 {
            img = vignette(img, strength: c.vignette, extent: input.extent)
        }
        return img
    }

    /// +amount = warmer (more red/orange), −amount = cooler (more blue).
    private static func temperature(_ img: CIImage, amount: Double) -> CIImage {
        // CITemperatureAndTint maps `neutral` to `targetNeutral`; a target cooler than the
        // source illuminant renders the image warmer.
        let neutral = 6500.0
        let target = neutral - amount * temperatureRangeKelvin
        return img.applyingFilter("CITemperatureAndTint", parameters: [
            "inputNeutral": CIVector(x: neutral, y: 0),
            "inputTargetNeutral": CIVector(x: target, y: 0),
        ])
    }

    private static func vignette(_ img: CIImage, strength: Double, extent: CGRect) -> CIImage {
        guard !extent.isInfinite, extent.width > 0, extent.height > 0 else { return img }
        let halfDiagonal = hypot(extent.width, extent.height) / 2
        return img.applyingFilter("CIVignetteEffect", parameters: [
            kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
            kCIInputRadiusKey: halfDiagonal * 0.9,
            kCIInputIntensityKey: min(1, strength),
            "inputFalloff": 0.65,
        ])
    }

    // MARK: - Presets

    private static func preset(_ filter: FilterPreset, on img: CIImage, extent: CGRect) -> CIImage {
        switch filter {
        case .none:
            return img
        case .vivid:
            return img
                .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.6])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.15, kCIInputContrastKey: 1.08])
        case .warm:
            return temperature(img, amount: 0.45)
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.08])
        case .cool:
            return temperature(img, amount: -0.45)
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.95])
        case .mono: return img.applyingFilter("CIPhotoEffectMono")
        case .noir: return img.applyingFilter("CIPhotoEffectNoir")
        case .chrome: return img.applyingFilter("CIPhotoEffectChrome")
        case .fade: return img.applyingFilter("CIPhotoEffectFade")
        case .instant: return img.applyingFilter("CIPhotoEffectInstant")
        case .process: return img.applyingFilter("CIPhotoEffectProcess")
        case .tonal: return img.applyingFilter("CIPhotoEffectTonal")
        case .transfer: return img.applyingFilter("CIPhotoEffectTransfer")
        case .sepia:
            return img.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.9])
        case .blur:
            guard !extent.isInfinite else { return img }
            let radius = max(1, min(extent.width, extent.height) * 0.012)
            return img.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: extent)
        case .sharpen:
            let radius = extent.isInfinite ? 1.69 : max(1, min(extent.width, extent.height) / 600)
            return img.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.6, kCIInputRadiusKey: radius])
        case .comic:
            return img.applyingFilter("CIComicEffect")
        }
    }
}
