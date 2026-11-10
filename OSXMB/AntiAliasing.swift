import Foundation

enum AntiAliasingMode: Int, CaseIterable {
    case off = 1
    case msaa2x = 2
    case msaa4x = 4

    static let defaultsKey = "antiAliasingMode"

    var sampleCount: Int { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .msaa2x: return "2× MSAA"
        case .msaa4x: return "4× MSAA"
        }
    }

    var isSupported: Bool {
        sampleCount == 1 || MetalShared.shared.device.supportsTextureSampleCount(sampleCount)
    }

    static var current: AntiAliasingMode {
        let defaults = UserDefaults.standard
        let raw = defaults.object(forKey: defaultsKey) as? Int ?? AntiAliasingMode.msaa4x.rawValue
        return supported(AntiAliasingMode(rawValue: raw) ?? .msaa4x)
    }

    static func supported(_ mode: AntiAliasingMode) -> AntiAliasingMode {
        mode.isSupported ? mode : .off
    }

    static func save(_ mode: AntiAliasingMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: defaultsKey)
    }
}
