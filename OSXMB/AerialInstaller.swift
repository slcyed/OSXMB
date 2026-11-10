import AppKit
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum AerialInstallError: LocalizedError {
    case catalogMissing
    case invalidManifest(String)
    case tarPatch(String)
    case thumbnail(String)
    case write(String)

    var errorDescription: String? {
        switch self {
        case .catalogMissing:
            return "The macOS Aerial catalog was not found in ~/Library/Application Support/com.apple.wallpaper/aerials."
        case .invalidManifest(let message):
            return "Could not read the Aerial manifest: \(message)"
        case .tarPatch(let message):
            return "Could not patch manifest.tar: \(message)"
        case .thumbnail(let message):
            return "Could not create a thumbnail: \(message)"
        case .write(let message):
            return "Could not write the catalog: \(message)"
        }
    }
}

final class AerialInstaller {
    static let shared = AerialInstaller()
    private init() {}

    private let landscapesCategoryID = "A33A55D9-EDEA-4596-A850-6C10B54FBBB5"
    private let osxmbCategoryID = "5E1C7A90-6B9F-4E2A-8F42-4C1D8B2A7F31"
    private let osxmbSubcategoryID = "B7C2A5F0-2AF7-4A7E-9A3B-3E6F9C1D8E21"
    private let lockScreenShotID = "OSXMB_LOCKSCREEN"

    private var catalogRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials",
                                    isDirectory: true)
    }
    private var entriesJSON: URL { catalogRoot.appendingPathComponent("manifest/entries.json") }
    private var manifestTar: URL { catalogRoot.appendingPathComponent("manifest.tar") }
    private var videosDirectory: URL { catalogRoot.appendingPathComponent("videos", isDirectory: true) }
    private var thumbnailsDirectory: URL { catalogRoot.appendingPathComponent("thumbnails", isDirectory: true) }

    var isCatalogAvailable: Bool {
        FileManager.default.fileExists(atPath: entriesJSON.path)
            && FileManager.default.fileExists(atPath: manifestTar.path)
    }

    // MARK: - UI entry points

    func presentInstallFlow(for variant: XMBVariant) {
        let panel = NSOpenPanel()
        panel.title = "Install a Movie Into the Aerial Catalog"
        panel.message = "Choose an OSXMB export (or any HEVC .mov) to add to the macOS Aerial catalog. This is experimental and modifies a per-user Apple catalog."
        panel.allowedContentTypes = [.quickTimeMovie, .mpeg4Movie]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "lastExportPath") ?? "")
            .deletingLastPathComponent()

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            _ = try installAndActivate(movieURL: url, variant: variant)

            let alert = NSAlert()
            alert.messageText = "Installed into the Aerial catalog"
            alert.informativeText = """
            \(variant.name) is now available in System Settings → Wallpaper and Screen Saver under Landscapes → OSXMB.

            The catalog can be refreshed by macOS updates. OSXMB installed a small launch agent that re-adds the entry when the manifest changes.
            """
            alert.runModal()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not install the Aerial"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    // MARK: - Installation

    @discardableResult
    func installAndActivate(movieURL: URL, variant: XMBVariant) throws -> String {
        let assetID = try install(movieURL: movieURL, variant: variant)
        installRefreshGuard(assetID: assetID, movieURL: movieURL, variant: variant)
        restartWallpaperProcesses()
        return assetID
    }

    @discardableResult
    func install(movieURL: URL, variant: XMBVariant) throws -> String {
        try install(movieURL: movieURL, variant: variant,
                    shotID: "OSXMB_\(variant.id)", name: variant.name)
    }

    @discardableResult
    func syncLockScreen(movieURL: URL, variant: XMBVariant) throws -> String {
        let assetID = try install(movieURL: movieURL, variant: variant,
                                  shotID: lockScreenShotID,
                                  name: "OSXMB Lock Screen · \(variant.name)")
        installRefreshGuard(assetID: assetID, movieURL: movieURL,
                            variant: variant, shotID: lockScreenShotID)
        restartWallpaperProcesses()
        return assetID
    }

    @discardableResult
    private func install(movieURL: URL, variant: XMBVariant,
                         shotID: String, name: String) throws -> String {
        guard FileManager.default.fileExists(atPath: entriesJSON.path),
              FileManager.default.fileExists(atPath: manifestTar.path) else {
            throw AerialInstallError.catalogMissing
        }

        try FileManager.default.createDirectory(at: videosDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)

        let (root, data) = try loadManifest()
        let assetID = existingAssetID(in: root, shotID: shotID) ?? UUID().uuidString
        let videoURL = videosDirectory.appendingPathComponent("\(assetID).mov")
        let thumbURL = thumbnailsDirectory.appendingPathComponent("\(assetID).png")

        if movieURL.standardizedFileURL != videoURL.standardizedFileURL {
            try replaceFile(at: videoURL, with: movieURL)
        }
        try writeThumbnail(from: movieURL, to: thumbURL)

        let updated = try addingAsset(to: root, assetID: assetID, name: name,
                                      shotID: shotID, videoURL: videoURL,
                                      thumbnailURL: thumbURL)
        try writeManifest(updated, original: data)
        return assetID
    }

    func reinstall(assetID: String, movieURL: URL, variantName: String, variantID: String,
                   shotID: String? = nil) throws {
        guard FileManager.default.fileExists(atPath: entriesJSON.path),
              FileManager.default.fileExists(atPath: manifestTar.path) else {
            throw AerialInstallError.catalogMissing
        }
        let (root, data) = try loadManifest()
        let videoURL = videosDirectory.appendingPathComponent("\(assetID).mov")
        let thumbURL = thumbnailsDirectory.appendingPathComponent("\(assetID).png")
        if !FileManager.default.fileExists(atPath: videoURL.path) {
            try replaceFile(at: videoURL, with: movieURL)
        }
        if !FileManager.default.fileExists(atPath: thumbURL.path) {
            try writeThumbnail(from: movieURL, to: thumbURL)
        }
        let updated = try addingAsset(to: root, assetID: assetID, name: variantName,
                                      shotID: shotID ?? "OSXMB_\(variantID)",
                                      videoURL: videoURL, thumbnailURL: thumbURL)
        try writeManifest(updated, original: data)
    }

    func uninstall(assetID: String) throws {
        let (root, data) = try loadManifest()
        guard var assets = root["assets"] as? [[String: Any]] else {
            throw AerialInstallError.invalidManifest("assets array is missing")
        }
        assets.removeAll { ($0["id"] as? String) == assetID }
        var updated = root
        updated["assets"] = assets
        removeOSXMBSubcategoryIfUnused(from: &updated)
        try writeManifest(updated, original: data)
        try? FileManager.default.removeItem(at: videosDirectory.appendingPathComponent("\(assetID).mov"))
        try? FileManager.default.removeItem(at: thumbnailsDirectory.appendingPathComponent("\(assetID).png"))
        removeRefreshGuard(assetID: assetID)
    }

    // MARK: - Manifest model

    private func removeOSXMBSubcategoryIfUnused(from root: inout [String: Any]) {
        let assets = root["assets"] as? [[String: Any]] ?? []
        let stillUsed = assets.contains { asset in
            let subcategories = asset["subcategories"] as? [String] ?? []
            return subcategories.contains(osxmbSubcategoryID)
        }
        guard !stillUsed else { return }

        var categories = root["categories"] as? [[String: Any]] ?? []
        for index in categories.indices {
            var category = categories[index]
            var subcategories = category["subcategories"] as? [[String: Any]] ?? []
            subcategories.removeAll { ($0["id"] as? String) == osxmbSubcategoryID }
            category["subcategories"] = subcategories
            categories[index] = category
        }
        categories.removeAll { ($0["id"] as? String) == osxmbCategoryID }
        root["categories"] = categories
    }

    private func loadManifest() throws -> ([String: Any], Data) {
        let data = try Data(contentsOf: entriesJSON)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AerialInstallError.invalidManifest("top level is not an object")
        }
        return (root, data)
    }

    private func existingAssetID(in root: [String: Any], shotID: String) -> String? {
        guard let assets = root["assets"] as? [[String: Any]] else { return nil }
        return assets.first { ($0["shotID"] as? String) == shotID }?["id"] as? String
    }

    private func addingAsset(to root: [String: Any], assetID: String, name: String,
                             shotID: String, videoURL: URL, thumbnailURL: URL) throws -> [String: Any] {
        guard var assets = root["assets"] as? [[String: Any]],
              var categories = root["categories"] as? [[String: Any]] else {
            throw AerialInstallError.invalidManifest("assets or categories array is missing")
        }

        let videoString = fileURLString(videoURL)
        let thumbString = fileURLString(thumbnailURL)

        let asset: [String: Any] = [
            "accessibilityLabel": name,
            "categories": [landscapesCategoryID],
            "id": assetID,
            "includeInShuffle": false,
            "localizedNameKey": name,
            "pointsOfInterest": [:],
            "preferredOrder": -1000,
            "previewImage": thumbString,
            "shotID": shotID,
            "showInTopLevel": true,
            "subcategories": [osxmbSubcategoryID],
            "url-4K-SDR-240FPS": videoString,
        ]

        if let index = assets.firstIndex(where: { ($0["id"] as? String) == assetID || ($0["shotID"] as? String) == shotID }) {
            assets[index] = asset
        } else {
            assets.insert(asset, at: 0)
        }

        let subcategory: [String: Any] = [
            "id": osxmbSubcategoryID,
            "localizedDescriptionKey": "OSXMB renderer variants",
            "localizedNameKey": "OSXMB",
            "preferredOrder": -1000,
            "previewImage": thumbString,
            "representativeAssetID": assetID,
        ]

        if let catIndex = categories.firstIndex(where: { ($0["id"] as? String) == landscapesCategoryID }) {
            var category = categories[catIndex]
            var subcategories = category["subcategories"] as? [[String: Any]] ?? []
            if let subIndex = subcategories.firstIndex(where: { ($0["id"] as? String) == osxmbSubcategoryID }) {
                subcategories[subIndex] = subcategory
            } else {
                subcategories.insert(subcategory, at: 0)
            }
            category["subcategories"] = subcategories
            categories[catIndex] = category
        } else {
            categories.append([
                "id": osxmbCategoryID,
                "localizedDescriptionKey": "OSXMB live wallpapers",
                "localizedNameKey": "OSXMB",
                "preferredOrder": -1000,
                "previewImage": thumbString,
                "representativeAssetID": assetID,
                "subcategories": [subcategory],
            ])
            if let assetIndex = assets.firstIndex(where: { ($0["id"] as? String) == assetID }) {
                assets[assetIndex]["categories"] = [osxmbCategoryID]
            }
        }

        var updated = root
        updated["assets"] = assets
        updated["categories"] = categories
        return updated
    }

    private func writeManifest(_ root: [String: Any], original: Data) throws {
        let json = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys])
        try backupCatalog()

        do {
            try json.write(to: entriesJSON, options: .atomic)
        } catch {
            throw AerialInstallError.write(error.localizedDescription)
        }

        try patchTar(newEntries: json)
    }

    private func backupCatalog() throws {
        let backupDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OSXMB/Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let entriesBackup = backupDirectory.appendingPathComponent("entries-\(stamp).json")
        let tarBackup = backupDirectory.appendingPathComponent("manifest-\(stamp).tar")

        if !FileManager.default.fileExists(atPath: entriesBackup.path) {
            try? FileManager.default.copyItem(at: entriesJSON, to: entriesBackup)
        }
        if !FileManager.default.fileExists(atPath: tarBackup.path) {
            try? FileManager.default.copyItem(at: manifestTar, to: tarBackup)
        }
    }

    // MARK: - Tar patching

    private func patchTar(newEntries: Data) throws {
        var tar = try Data(contentsOf: manifestTar)
        guard let member = findTarMember(in: tar, named: "entries.json") else {
            throw AerialInstallError.tarPatch("entries.json member was not found")
        }

        let headerStart = member.headerStart
        let dataStart = headerStart + 512
        let oldPaddedEnd = dataStart + ((member.size + 511) & ~511)

        var header = tar.subdata(in: headerStart..<(headerStart + 512))
        writeOctal(newEntries.count, into: &header, offset: 124, length: 12)
        for i in 148..<156 { header[i] = 0x20 }
        let checksum = header.reduce(0) { $0 + Int($1) }
        writeChecksum(checksum, into: &header)

        var rebuilt = Data()
        rebuilt.append(tar.subdata(in: 0..<headerStart))
        rebuilt.append(header)
        rebuilt.append(newEntries)
        let newPadding = ((newEntries.count + 511) & ~511) - newEntries.count
        if newPadding > 0 {
            rebuilt.append(Data(repeating: 0, count: newPadding))
        }
        if oldPaddedEnd < tar.count {
            rebuilt.append(tar.subdata(in: oldPaddedEnd..<tar.count))
        }
        tar = rebuilt
        try tar.write(to: manifestTar, options: .atomic)
    }

    private struct TarMember {
        let headerStart: Int
        let size: Int
    }

    private func findTarMember(in data: Data, named target: String) -> TarMember? {
        var offset = 0
        while offset + 512 <= data.count {
            let header = data.subdata(in: offset..<(offset + 512))
            if header.allSatisfy({ $0 == 0 }) { break }
            let name = tarString(header, 0, 100)
            let prefix = tarString(header, 345, 155)
            let fullName = prefix.isEmpty ? name : "\(prefix)/\(name)"
            let sizeField = tarString(header, 124, 12).trimmingCharacters(in: .whitespacesAndNewlines)
            let size = Int(sizeField, radix: 8) ?? 0

            if fullName == target || fullName.hasSuffix("/\(target)") {
                return TarMember(headerStart: offset, size: size)
            }
            offset += 512 + ((size + 511) & ~511)
        }
        return nil
    }

    private func tarString(_ data: Data, _ offset: Int, _ length: Int) -> String {
        let end = min(offset + length, data.count)
        var bytes = Array(data[offset..<end])
        if let null = bytes.firstIndex(of: 0) {
            bytes = Array(bytes[0..<null])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func writeOctal(_ value: Int, into data: inout Data, offset: Int, length: Int) {
        let string = String(format: "%0\(length - 1)o", value)
        let bytes = Array(string.utf8.prefix(length - 1))
        for i in 0..<(length - 1) {
            data[offset + i] = i < bytes.count ? bytes[i] : 0x30
        }
        data[offset + length - 1] = 0
    }

    private func writeChecksum(_ value: Int, into data: inout Data) {
        let string = String(format: "%06o", value)
        let bytes = Array(string.utf8)
        for i in 0..<6 {
            data[148 + i] = bytes[i]
        }
        data[154] = 0
        data[155] = 0x20
    }

    // MARK: - Files

    private func replaceFile(at destination: URL, with source: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw AerialInstallError.write(error.localizedDescription)
        }
    }

    private func fileURLString(_ url: URL) -> String {
        url.standardizedFileURL.absoluteString
    }

    private func writeThumbnail(from movieURL: URL, to destination: URL) throws {
        let asset = AVURLAsset(url: movieURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var generated: CGImage?
        for seconds in [1.0, 0.5, 0.1, 0.0] {
            if let image = try? generator.copyCGImage(
                at: CMTime(seconds: seconds, preferredTimescale: 600),
                actualTime: nil
            ) {
                generated = image
                break
            }
        }
        guard let cgImage = generated else {
            throw AerialInstallError.thumbnail("the movie did not yield a decodable frame")
        }

        let width = 214
        let height = 130
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder16Little.rawValue |
                         CGImageAlphaInfo.noneSkipLast.rawValue

        let context: CGContext
        if let sixteenBit = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 16, bytesPerRow: width * 8,
                                      space: colorSpace, bitmapInfo: bitmapInfo) {
            context = sixteenBit
        } else if let eightBit = CGContext(data: nil, width: width, height: height,
                                           bitsPerComponent: 8, bytesPerRow: width * 4,
                                           space: colorSpace,
                                           bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            context = eightBit
        } else {
            throw AerialInstallError.thumbnail("could not create a bitmap context")
        }

        context.interpolationQuality = .high
        let scale = max(CGFloat(width) / CGFloat(cgImage.width),
                        CGFloat(height) / CGFloat(cgImage.height))
        let drawWidth = CGFloat(cgImage.width) * scale
        let drawHeight = CGFloat(cgImage.height) * scale
        context.draw(cgImage, in: CGRect(x: (CGFloat(width) - drawWidth) / 2,
                                         y: (CGFloat(height) - drawHeight) / 2,
                                         width: drawWidth, height: drawHeight))

        guard let scaled = context.makeImage(),
              let destinationWriter = CGImageDestinationCreateWithURL(
                destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw AerialInstallError.thumbnail("could not create a PNG destination")
        }
        CGImageDestinationAddImage(destinationWriter, scaled, nil)
        guard CGImageDestinationFinalize(destinationWriter) else {
            throw AerialInstallError.thumbnail("PNG encoding failed")
        }
    }

    // MARK: - Refresh guard

    private func guardURL(assetID: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("com.osxmb.aerialguard.\(assetID).plist")
    }

    func installRefreshGuard(assetID: String, movieURL: URL, variant: XMBVariant,
                             shotID: String? = nil) {
        let launchAgents = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try? FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let plistURL = guardURL(assetID: assetID)
        let executable = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        let paths = [
            manifestTar.path,
            entriesJSON.path,
        ]
        let displayName = shotID == lockScreenShotID
            ? "OSXMB Lock Screen · \(variant.name)"
            : variant.name

        var arguments = [
            executable,
            "--aerial-reinstall",
            assetID,
            movieURL.path,
            displayName,
            variant.id,
        ]
        if let shotID {
            arguments.append(shotID)
        }

        let plist: [String: Any] = [
            "Label": "com.osxmb.aerialguard.\(assetID)",
            "ProgramArguments": arguments,
            "WatchPaths": paths,
            "RunAtLoad": true,
            "ThrottleInterval": 30,
            "ProcessType": "Background",
        ]
        (plist as NSDictionary).write(to: plistURL, atomically: true)

        let bootout = Process()
        bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootout.arguments = ["bootout", "gui/\(getuid())/com.osxmb.aerialguard.\(assetID)"]
        bootout.standardOutput = FileHandle.nullDevice
        bootout.standardError = FileHandle.nullDevice
        try? bootout.run()
        bootout.waitUntilExit()

        let bootstrap = Process()
        bootstrap.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootstrap.arguments = ["bootstrap", "gui/\(getuid())", plistURL.path]
        bootstrap.standardOutput = FileHandle.nullDevice
        bootstrap.standardError = FileHandle.nullDevice
        try? bootstrap.run()
        bootstrap.waitUntilExit()
    }

    func removeRefreshGuard(assetID: String) {
        let plistURL = guardURL(assetID: assetID)
        try? FileManager.default.removeItem(at: plistURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())/com.osxmb.aerialguard.\(assetID)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    func restartWallpaperProcesses() {
        for name in ["WallpaperAerialsExtension", "WallpaperAgent"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            process.arguments = [name]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
        }
    }
}
