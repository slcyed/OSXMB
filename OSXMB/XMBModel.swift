import Foundation
import SwiftUI
import simd

struct RGBColor: Hashable {
    var r: Float
    var g: Float
    var b: Float

    init(_ r: Float, _ g: Float, _ b: Float) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(r255: Float, g255: Float, b255: Float) {
        self.init(r255 / 255, g255 / 255, b255 / 255)
    }

    var simd: SIMD3<Float> { SIMD3<Float>(r, g, b) }
    var color: Color { Color(.sRGB, red: Double(r), green: Double(g), blue: Double(b), opacity: 1) }

    func clamped() -> RGBColor {
        RGBColor(min(max(r, 0), 1), min(max(g, 0), 1), min(max(b, 0), 1))
    }

    static func + (lhs: RGBColor, rhs: RGBColor) -> RGBColor {
        RGBColor(lhs.r + rhs.r, lhs.g + rhs.g, lhs.b + rhs.b)
    }

    static func * (lhs: RGBColor, rhs: Float) -> RGBColor {
        RGBColor(lhs.r * rhs, lhs.g * rhs, lhs.b * rhs)
    }

    static func mix(_ a: RGBColor, _ b: RGBColor, _ t: Float) -> RGBColor {
        RGBColor(
            a.r + (b.r - a.r) * t,
            a.g + (b.g - a.g) * t,
            a.b + (b.b - a.b) * t
        )
    }

    var luminance: Float { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    func saturation(_ amount: Float) -> RGBColor {
        let l = luminance
        return RGBColor(l + (r - l) * amount, l + (g - l) * amount, l + (b - l) * amount)
    }
}

struct XMBGradient: Hashable {
    var angleDeg: Float
    var start: RGBColor
    var end: RGBColor

    var direction: SIMD2<Float> {
        let rad = angleDeg * .pi / 180
        return SIMD2<Float>(cosf(rad), sinf(rad))
    }

    var tRange: (min: Float, span: Float) {
        let d = direction
        let t00 = d.x * 0 + d.y * 0
        let t10 = d.x * 1 + d.y * 0
        let t01 = d.x * 0 + d.y * 1
        let t11 = d.x * 1 + d.y * 1
        let lo = min(min(t00, t10), min(t01, t11))
        let hi = max(max(t00, t10), max(t01, t11))
        return (lo, max(1e-6, hi - lo))
    }

    static func original(r: Float, g: Float, b: Float, topMul: Float, botMul: Float) -> XMBGradient {
        let top = RGBColor(r255: r, g255: g, b255: b)
        let bottom = RGBColor(r255: r, g255: g, b255: b)
        return XMBGradient(
            angleDeg: 90,
            start: RGBColor(top.r * topMul, top.g * topMul, top.b * topMul * 1.2),
            end: RGBColor(bottom.r * botMul, bottom.g * botMul, bottom.b * botMul)
        )
    }
}

struct XMBParameters: Hashable {
    var colorR: Float = 37
    var colorG: Float = 89
    var colorB: Float = 179
    var gradientTopMul: Float = 0.09
    var gradientBotMul: Float = 0.62

    var flowSpeed: Float = 0.18
    var tension: Float = 0.12
    var damping: Float = 0.0001
    var length: Float = 0.306001
    var spacing: Float = 407.658
    var timeStep: Float = 1.0

    var bandAmplitude: Float = 0.200
    var bandSecondaryFreq: Float = 7.0
    var bandSecondaryAmp: Float = 0.025

    var travelSpeed1: Float = 0.25
    var travelAmp1: Float = 0.014
    var travelSpeed2: Float = 0.15
    var travelAmp2: Float = 0.008

    var perturbation: Float = 0.0998587
    var perturbationScale: Float = 0.07
    var waveCosAmp: Float = 0.09
    var waveBias: Float = -0.1
    var waveHeightScale: Float = 0.5
    var waveSoftClip: Float = 0.22

    var rePipelineBlend: Float = 0.45
    var reDescriptorStrength: Float = 0.7
    var reSyntheticDescriptorSeed: Int = 1337
    var reSyntheticDescriptorMotion: Float = 0.65
    var reKernelGain: Float = 0.04
    var reNormalizeGain: Float = 0.08
    var reKernelPhaseStep: Float = 0.45
    var reIndexJitter: Float = 0.006
    var reTemporalSmooth: Float = 0.84

    var fresnelPower: Float = 4.0
    var fresnelScale: Float = 0.5
    var opacity: Float = 0.7
    var brightness: Float = 0.98
    var zDetailScale: Float = 0.08

    var ffdScale1X: Float = 5.67726
    var ffdScale1Y: Float = 1.00077
    var ffdScale1Z: Float = 1.0
    var ffdScale2X: Float = 2.82755
    var ffdScale2Y: Float = 1.27579
    var ffdScale2Z: Float = 2.88782
    var ffdOffsetX: Float = 0.0
    var ffdOffsetY: Float = -0.469999
    var ffdOffsetZ: Float = 0.0
    var ffdYAmp: Float = 0.05
    var ffdZAmp: Float = 0.06

    var particleCount: Int = 2000
    var particleOpacity: Float = 0.75
    var particleSizeBase: Float = 2.6
    var particleSizeVar: Float = 1.5
    var particleFlowSpeed: Float = 0.18
}

struct XMBVariant: Identifiable, Hashable {
    let id: String
    let name: String
    let family: String
    let month: Int?
    let lighting: String?
    let gradient: XMBGradient
    let parameters: XMBParameters
    let detail: String?

    init(id: String, name: String, family: String, month: Int?, lighting: String?,
         gradient: XMBGradient, parameters: XMBParameters, detail: String? = nil) {
        self.id = id
        self.name = name
        self.family = family
        self.month = month
        self.lighting = lighting
        self.gradient = gradient
        self.parameters = parameters
        self.detail = detail
    }

    var subtitle: String {
        if let detail { return detail }
        if let month {
            let monthName = XMBCatalog.monthNames[month - 1]
            return "\(monthName) \(lighting ?? "") · \(family)"
        }
        return family
    }
}

final class XMBCatalog {
    static let shared = XMBCatalog()

    static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    static let styleFamilies = [
        "Classic", "Soft", "Deep", "Bright", "Vivid",
        "Pastel", "Neon", "Mono", "Retro", "Crystal",
        "Midnight", "Dawn", "Dusk", "Aqua", "Glass",
    ]

    let variants: [XMBVariant]
    let families: [String]

    private init() {
        var result: [XMBVariant] = []

        let originals: [(String, String, Float, Float, Float)] = [
            ("original-midnight-blue", "Original · Midnight Blue", 37, 89, 179),
            ("original-ocean", "Original · Ocean", 19, 118, 168),
            ("original-violet", "Original · Violet", 93, 61, 181),
        ]
        for (id, name, r, g, b) in originals {
            var p = XMBParameters()
            p.colorR = r
            p.colorG = g
            p.colorB = b
            var gradient = XMBGradient.original(r: r, g: g, b: b,
                                                topMul: p.gradientTopMul,
                                                botMul: p.gradientBotMul)
            gradient.angleDeg = 90
            result.append(XMBVariant(id: id, name: name, family: "Original",
                                     month: nil, lighting: nil,
                                     gradient: gradient, parameters: p))
        }

        result.append(SeasonalTheme.makeVariant())

        for month in 1...12 {
            for lighting in ["Day", "Night"] {
                let base = lighting == "Day" ? XMBCatalog.day[month - 1] : XMBCatalog.night[month - 1]
                for (index, family) in XMBCatalog.styleFamilies.enumerated() {
                    var p = XMBParameters()
                    var gradient = XMBGradient(angleDeg: base.angle, start: base.start, end: base.end)
                    XMBCatalog.apply(family: family, params: &p, gradient: &gradient)
                    p.reSyntheticDescriptorSeed = 1200 + month * 73 + index * 29
                    let id = String(format: "%02d-%@-%@", month,
                                    lighting.lowercased(), family.lowercased())
                    let name = "\(XMBCatalog.monthNames[month - 1]) \(lighting) · \(family)"
                    result.append(XMBVariant(id: id, name: name, family: family,
                                             month: month, lighting: lighting,
                                             gradient: gradient, parameters: p))
                }
            }
        }

        variants = result
        families = ["All"] + ["Original", "Live"] + XMBCatalog.styleFamilies
    }

    func variant(id: String) -> XMBVariant? {
        if id == SeasonalTheme.variantID {
            return SeasonalTheme.makeVariant()
        }
        return variants.first { $0.id == id }
    }

    var defaultVariant: XMBVariant { variants[0] }

    private static func apply(family: String, params p: inout XMBParameters, gradient g: inout XMBGradient) {
        func recolor(sat: Float = 1, bright: Float = 1, white: Float = 0, tint: RGBColor = RGBColor(0, 0, 0), angle: Float = 0) {
            var s = g.start.saturation(sat) * bright
            var e = g.end.saturation(sat) * bright
            s = RGBColor.mix(s, RGBColor(1, 1, 1), white) + tint
            e = RGBColor.mix(e, RGBColor(1, 1, 1), white) + tint
            g.start = s.clamped()
            g.end = e.clamped()
            g.angleDeg += angle
        }

        switch family {
        case "Classic":
            break
        case "Soft":
            recolor(sat: 0.82, bright: 0.94, white: 0.04)
            p.opacity = 0.55
            p.brightness = 0.9
            p.fresnelScale = 0.36
            p.waveHeightScale = 0.44
            p.particleOpacity = 0.48
            p.particleCount = 1400
        case "Deep":
            recolor(sat: 1.08, bright: 0.86)
            p.opacity = 0.8
            p.brightness = 0.88
            p.waveHeightScale = 0.66
            p.zDetailScale = 0.12
            p.damping = 0.0002
            p.particleOpacity = 0.65
        case "Bright":
            recolor(sat: 1.1, bright: 1.16)
            p.opacity = 0.84
            p.brightness = 1.22
            p.fresnelScale = 0.64
            p.particleOpacity = 0.85
        case "Vivid":
            recolor(sat: 1.4, bright: 1.08)
            p.opacity = 0.78
            p.brightness = 1.08
            p.flowSpeed = 0.24
            p.particleFlowSpeed = 0.24
            p.particleOpacity = 0.9
        case "Pastel":
            recolor(sat: 0.68, bright: 1.08, white: 0.28)
            p.opacity = 0.56
            p.brightness = 1.02
            p.fresnelScale = 0.4
            p.waveHeightScale = 0.4
            p.particleOpacity = 0.55
        case "Neon":
            recolor(sat: 1.65, bright: 1.2)
            p.opacity = 0.9
            p.brightness = 1.3
            p.fresnelScale = 0.82
            p.fresnelPower = 3.2
            p.particleOpacity = 1.0
        case "Mono":
            recolor(sat: 0.0, bright: 1.0)
            p.brightness = 0.98
        case "Retro":
            recolor(sat: 0.82, bright: 0.92, tint: RGBColor(0.04, 0.018, -0.012))
            p.opacity = 0.72
            p.brightness = 0.94
            p.waveHeightScale = 0.54
        case "Crystal":
            recolor(sat: 1.12, bright: 1.14)
            p.opacity = 0.52
            p.brightness = 1.18
            p.fresnelPower = 6.2
            p.fresnelScale = 0.78
            p.zDetailScale = 0.13
        case "Midnight":
            recolor(sat: 0.9, bright: 0.58)
            p.opacity = 0.74
            p.brightness = 0.82
            p.particleOpacity = 0.9
            p.particleCount = 2400
        case "Dawn":
            recolor(sat: 0.92, bright: 1.06, white: 0.14, tint: RGBColor(0.035, 0.012, -0.004))
            p.opacity = 0.62
            p.brightness = 1.08
            p.waveHeightScale = 0.46
            p.particleOpacity = 0.58
        case "Dusk":
            recolor(sat: 1.14, bright: 0.78, tint: RGBColor(0.025, -0.01, 0.03))
            p.opacity = 0.8
            p.brightness = 0.92
            p.fresnelScale = 0.58
        case "Aqua":
            recolor(sat: 1.18, bright: 1.02, tint: RGBColor(-0.02, 0.035, 0.05))
            p.opacity = 0.72
            p.brightness = 1.04
            p.flowSpeed = 0.21
            p.particleFlowSpeed = 0.21
        case "Glass":
            recolor(sat: 1.05, bright: 1.1)
            p.opacity = 0.6
            p.brightness = 1.12
            p.fresnelPower = 2.5
            p.fresnelScale = 0.72
            p.zDetailScale = 0.15
            p.waveSoftClip = 0.28
        default:
            break
        }
    }

    private struct MonthPreset {
        var angle: Float
        var start: RGBColor
        var end: RGBColor
    }

    private static let day: [MonthPreset] = [
        MonthPreset(angle: 90.25, start: RGBColor(r255: 197, g255: 197, b255: 197), end: RGBColor(r255: 201, g255: 201, b255: 201)),
        MonthPreset(angle: 67, start: RGBColor(r255: 203, g255: 158, b255: 13), end: RGBColor(r255: 219, g255: 214, b255: 41)),
        MonthPreset(angle: 106, start: RGBColor(r255: 142, g255: 190, b255: 40), end: RGBColor(r255: 104, g255: 168, b255: 22)),
        MonthPreset(angle: 136.75, start: RGBColor(r255: 216, g255: 182, b255: 182), end: RGBColor(r255: 231, g255: 66, b255: 117)),
        MonthPreset(angle: 1.5, start: RGBColor(r255: 19, g255: 108, b255: 19), end: RGBColor(r255: 24, g255: 156, b255: 24)),
        MonthPreset(angle: 148.75, start: RGBColor(r255: 198, g255: 120, b255: 238), end: RGBColor(r255: 103, g255: 77, b255: 161)),
        MonthPreset(angle: 26.5, start: RGBColor(r255: 0, g255: 167, b255: 146), end: RGBColor(r255: 10, g255: 240, b255: 239)),
        MonthPreset(angle: 62.5, start: RGBColor(r255: 0, g255: 0, b255: 95), end: RGBColor(r255: 33, g255: 217, b255: 255)),
        MonthPreset(angle: 148.5, start: RGBColor(r255: 146, g255: 44, b255: 155), end: RGBColor(r255: 217, g255: 98, b255: 236)),
        MonthPreset(angle: 128.5, start: RGBColor(r255: 227, g255: 151, b255: 15), end: RGBColor(r255: 224, g255: 187, b255: 2)),
        MonthPreset(angle: 90, start: RGBColor(r255: 115, g255: 68, b255: 20), end: RGBColor(r255: 154, g255: 118, b255: 47)),
        MonthPreset(angle: 170.5, start: RGBColor(r255: 236, g255: 68, b255: 45), end: RGBColor(r255: 214, g255: 63, b255: 43)),
    ]

    private static let night: [MonthPreset] = [
        MonthPreset(angle: 89.75, start: RGBColor(r255: 181, g255: 181, b255: 181), end: RGBColor(r255: 0, g255: 0, b255: 0)),
        MonthPreset(angle: 93.75, start: RGBColor(r255: 198, g255: 188, b255: 128), end: RGBColor(r255: 0, g255: 0, b255: 0)),
        MonthPreset(angle: 90.25, start: RGBColor(r255: 152, g255: 170, b255: 113), end: RGBColor(r255: 0, g255: 0, b255: 0)),
        MonthPreset(angle: 90.25, start: RGBColor(r255: 212, g255: 174, b255: 182), end: RGBColor(r255: 10, g255: 8, b255: 8)),
        MonthPreset(angle: 116, start: RGBColor(r255: 48, g255: 118, b255: 48), end: RGBColor(r255: 11, g255: 3, b255: 11)),
        MonthPreset(angle: 91, start: RGBColor(r255: 209, g255: 163, b255: 225), end: RGBColor(r255: 0, g255: 0, b255: 0)),
        MonthPreset(angle: 109.75, start: RGBColor(r255: 16, g255: 129, b255: 124), end: RGBColor(r255: 17, g255: 0, b255: 0)),
        MonthPreset(angle: 69.5, start: RGBColor(r255: 20, g255: 159, b255: 176), end: RGBColor(r255: 0, g255: 0, b255: 31)),
        MonthPreset(angle: 51, start: RGBColor(r255: 116, g255: 0, b255: 153), end: RGBColor(r255: 12, g255: 0, b255: 11)),
        MonthPreset(angle: 89.75, start: RGBColor(r255: 216, g255: 142, b255: 0), end: RGBColor(r255: 0, g255: 0, b255: 0)),
        MonthPreset(angle: 90, start: RGBColor(r255: 131, g255: 86, b255: 32), end: RGBColor(r255: 18, g255: 20, b255: 17)),
        MonthPreset(angle: 118.25, start: RGBColor(r255: 157, g255: 59, b255: 44), end: RGBColor(r255: 0, g255: 0, b255: 3)),
    ]
}
