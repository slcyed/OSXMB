import AppKit
import AVFoundation
import VideoToolbox
import CoreMedia
import CoreVideo
import Metal
import UniformTypeIdentifiers

enum WaveExportError: LocalizedError {
    case writerSetup(String)
    case encoderSetup(String)
    case pixelBuffer(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .writerSetup(let message): return "Movie writer setup failed: \(message)"
        case .encoderSetup(let message): return "HEVC encoder setup failed: \(message)"
        case .pixelBuffer(let message): return "Frame buffer failed: \(message)"
        case .cancelled: return "Export cancelled."
        }
    }
}

private final class CancelToken {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

final class ExportManager {
    static let shared = ExportManager()
    private static let exportSeconds = 20
    private static let fullFrameCount = exportSeconds * 60
    static let exportWidth = 3840
    static let exportHeight = 2160

    private var progressController: ExportProgressWindowController?
    private var cancelToken: CancelToken?

    private init() {}

    func presentExport(for variant: XMBVariant) {
        let panel = NSSavePanel()
        panel.title = "Export Lock Screen Movie"
        panel.message = "OSXMB renders this variant into a 4K HEVC movie with a 60 fps stream and a 30 fps base temporal layer."
        panel.nameFieldStringValue = "OSXMB - \(sanitize(variant.name)).mov"
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first

        guard panel.runModal() == .OK, let url = panel.url else { return }
        startExport(variant: variant, url: url, frameCount: Self.fullFrameCount, showUI: true)
    }

    /// Used by the --export-test launch argument.
    func exportForTesting(variant: XMBVariant, url: URL, seconds: Double,
                          completion: @escaping (Result<URL, Error>) -> Void) {
        startExport(variant: variant, url: url,
                    frameCount: max(1, Int(seconds * 60)), showUI: false,
                    testingCompletion: completion)
    }

    @discardableResult
    func exportForLockScreenSync(variant: XMBVariant, url: URL,
                                 completion: @escaping (Result<URL, Error>) -> Void) -> () -> Void {
        let token = CancelToken()
        let frameCount = ProcessInfo.processInfo.environment["OSXMB_AUTO_SYNC_SECONDS"]
            .flatMap(Double.init)
            .map { max(1, Int($0 * 60)) } ?? Self.fullFrameCount
        let job: HEVCExportJob
        do {
            job = try HEVCExportJob(
                variant: variant,
                outputURL: url,
                width: Self.exportWidth,
                height: Self.exportHeight,
                frameCount: frameCount,
                antiAliasing: .current,
                cancelToken: token,
                progress: { _, _ in }
            )
        } catch {
            DispatchQueue.main.async {
                completion(.failure(error))
            }
            return {}
        }

        DispatchQueue.global(qos: .utility).async {
            job.run { result in
                DispatchQueue.main.async {
                    completion(result)
                }
            }
        }
        return { token.cancel() }
    }

    private func startExport(variant: XMBVariant, url: URL, frameCount: Int, showUI: Bool,
                             testingCompletion: ((Result<URL, Error>) -> Void)? = nil) {
        let token = CancelToken()
        cancelToken = token

        var controller: ExportProgressWindowController?
        if showUI {
            controller = ExportProgressWindowController(title: "Exporting \(variant.name)")
            controller?.cancelHandler = { [weak self] in
                self?.cancelToken?.cancel()
            }
            progressController = controller
            controller?.show()
        }

        let job: HEVCExportJob
        do {
            job = try HEVCExportJob(
                variant: variant,
                outputURL: url,
                width: Self.exportWidth,
                height: Self.exportHeight,
                frameCount: frameCount,
                antiAliasing: .current,
                cancelToken: token,
                progress: { [weak self] fraction, text in
                    DispatchQueue.main.async {
                        self?.progressController?.update(fraction: fraction, text: text)
                    }
                }
            )
        } catch {
            self.progressController?.close()
            self.progressController = nil
            self.cancelToken = nil
            if let testingCompletion {
                testingCompletion(.failure(error))
            } else {
                self.showFailure(error)
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            job.run { result in
                DispatchQueue.main.async {
                    self.progressController?.close()
                    self.progressController = nil
                    self.cancelToken = nil
                    UserDefaults.standard.set(url.path, forKey: "lastExportPath")

                    if let testingCompletion {
                        testingCompletion(result)
                        return
                    }

                    switch result {
                    case .success(let output):
                        self.showSuccess(output: output, variant: variant)
                    case .failure(let error):
                        self.showFailure(error)
                    }
                }
            }
        }
    }

    private func showSuccess(output: URL, variant: XMBVariant) {
        let alert = NSAlert()
        alert.messageText = "Lock screen movie exported"
        alert.informativeText = """
        \(output.lastPathComponent)

        The movie uses HEVC with temporal-layer sample metadata so it can survive the Aerial player's lock-to-desktop transition. You can install it into the Aerial catalog from the next dialog.
        """
        alert.addButton(withTitle: "Install Into Aerial Catalog…")
        alert.addButton(withTitle: "Reveal in Finder")
        alert.addButton(withTitle: "Done")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            do {
                _ = try AerialInstaller.shared.installAndActivate(movieURL: output, variant: variant)
                let installed = NSAlert()
                installed.messageText = "Installed into the Aerial catalog"
                installed.informativeText = "\(variant.name) is now available under System Settings → Wallpaper and Screen Saver → Landscapes → OSXMB."
                installed.runModal()
            } catch {
                let failure = NSAlert()
                failure.messageText = "Could not install the Aerial"
                failure.informativeText = error.localizedDescription
                failure.alertStyle = .warning
                failure.runModal()
            }
        } else if response == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([output])
        }
    }

    private func showFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Export failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: "·", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }
}

final class ExportProgressWindowController: NSWindowController {
    var cancelHandler: (() -> Void)?

    private let statusLabel = NSTextField(labelWithString: "Preparing…")
    private let progressBar = NSProgressIndicator()

    init(title: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 142),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildContent() {
        guard let window else { return }
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.maximumNumberOfLines = 2

        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.bezelStyle = .rounded

        let stack = NSStackView(views: [statusLabel, progressBar, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
                progressBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
                statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ])
        }
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(fraction: Double, text: String) {
        statusLabel.stringValue = text
        progressBar.doubleValue = min(max(fraction, 0), 1)
    }

    @objc private func cancelPressed() {
        cancelHandler?()
        statusLabel.stringValue = "Cancelling…"
        progressBar.isIndeterminate = true
        progressBar.startAnimation(nil)
    }
}

private final class HEVCExportJob {
    private let variant: XMBVariant
    private let outputURL: URL
    private let width: Int
    private let height: Int
    private let frameCount: Int
    private let antiAliasing: AntiAliasingMode
    private let cancelToken: CancelToken
    private let progress: (Double, String) -> Void

    private let renderer: XMBCoreRenderer
    private let writer: AVAssetWriter
    private let writerInput: AVAssetWriterInput
    private var compressionSession: VTCompressionSession?
    private var pixelBufferPool: CVPixelBufferPool?
    private var textureCache: CVMetalTextureCache?
    private var msaaTexture: MTLTexture?
    private let appendLock = NSLock()
    private var encodingError: Error?
    private var appendedFrames = 0

    init(variant: XMBVariant, outputURL: URL, width: Int, height: Int,
         frameCount: Int, antiAliasing: AntiAliasingMode,
         cancelToken: CancelToken,
         progress: @escaping (Double, String) -> Void) throws {
        self.variant = variant
        self.outputURL = outputURL
        self.width = width
        self.height = height
        self.frameCount = frameCount
        let effectiveAA = AntiAliasingMode.supported(antiAliasing)
        self.antiAliasing = effectiveAA
        self.cancelToken = cancelToken
        self.progress = progress
        self.renderer = XMBCoreRenderer(variant: variant, antiAliasing: effectiveAA)

        try? FileManager.default.removeItem(at: outputURL)
        self.writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        self.writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
        self.writerInput.expectsMediaDataInRealTime = false
        self.writer.add(writerInput)
    }

    func run(completion: @escaping (Result<URL, Error>) -> Void) {
        do {
            try setupWriter()
            try setupEncoder()
            try renderLoop()
            try finishWriting()
            completion(.success(outputURL))
        } catch {
            if let session = compressionSession {
                VTCompressionSessionInvalidate(session)
            }
            writer.cancelWriting()
            completion(.failure(error))
        }
    }

    private func setupWriter() throws {
        guard writer.startWriting() else {
            throw WaveExportError.writerSetup(writer.error?.localizedDescription ?? "unknown error")
        }
        writer.startSession(atSourceTime: .zero)
    }

    private func setupEncoder() throws {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pixelBufferPool)
        guard let pool = pixelBufferPool else {
            throw WaveExportError.encoderSetup("could not create pixel buffer pool")
        }
        _ = pool

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, MetalShared.shared.device, nil, &textureCache)
        guard textureCache != nil else {
            throw WaveExportError.encoderSetup("could not create Metal texture cache")
        }
        if antiAliasing.sampleCount > 1 {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.textureType = .type2DMultisample
            descriptor.sampleCount = antiAliasing.sampleCount
            descriptor.usage = .renderTarget
            descriptor.storageMode = .private
            guard let texture = MetalShared.shared.device.makeTexture(descriptor: descriptor) else {
                throw WaveExportError.encoderSetup("could not create MSAA texture")
            }
            msaaTexture = texture
        }

        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
        ]

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: hevcOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw WaveExportError.encoderSetup("VTCompressionSessionCreate returned \(status)")
        }
        compressionSession = session

        func set(_ key: CFString, _ value: Any, required: Bool = true,
                 name: String) throws {
            let result = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
            if required && result != noErr {
                throw WaveExportError.encoderSetup("\(name) returned \(result)")
            }
        }

        try set(kVTCompressionPropertyKey_RealTime, false,
                name: "RealTime")
        try set(kVTCompressionPropertyKey_ExpectedFrameRate, 60,
                name: "ExpectedFrameRate")
        try set(kVTCompressionPropertyKey_BaseLayerFrameRate, 30,
                name: "BaseLayerFrameRate")
        try set(kVTCompressionPropertyKey_AverageBitRate, 60_000_000,
                name: "AverageBitRate")
        try set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 120,
                name: "MaxKeyFrameInterval")
        try set(kVTCompressionPropertyKey_AllowFrameReordering, true,
                name: "AllowFrameReordering")
        let main10Status = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_HEVC_Main10_AutoLevel
        )
        if main10Status != noErr {
            try set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel,
                    name: "ProfileLevel")
        }
        try set(kVTCompressionPropertyKey_ColorPrimaries,
                kCVImageBufferColorPrimaries_ITU_R_709_2,
                name: "ColorPrimaries")
        try set(kVTCompressionPropertyKey_TransferFunction,
                kCVImageBufferTransferFunction_ITU_R_709_2,
                name: "TransferFunction")
        try set(kVTCompressionPropertyKey_YCbCrMatrix,
                kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                name: "YCbCrMatrix")

        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    private func renderLoop() throws {
        guard let session = compressionSession,
              let pool = pixelBufferPool,
              let cache = textureCache else {
            throw WaveExportError.encoderSetup("encoder is not ready")
        }

        for frame in 0..<frameCount {
            if cancelToken.isCancelled {
                throw WaveExportError.cancelled
            }
            if let encodingError {
                throw encodingError
            }

            var pixelBuffer: CVPixelBuffer?
            let bufferStatus = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard bufferStatus == kCVReturnSuccess, let pixelBuffer else {
                throw WaveExportError.pixelBuffer("CVPixelBufferPoolCreatePixelBuffer returned \(bufferStatus)")
            }

            var cvTexture: CVMetalTexture?
            let texStatus = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, cache, pixelBuffer, nil,
                .bgra8Unorm, width, height, 0, &cvTexture
            )
            guard texStatus == kCVReturnSuccess, let cvTexture,
                  let metalTexture = CVMetalTextureGetTexture(cvTexture) else {
                throw WaveExportError.pixelBuffer("could not wrap pixel buffer as a Metal texture")
            }

            let descriptor = MTLRenderPassDescriptor()
            if let msaaTexture {
                descriptor.colorAttachments[0].texture = msaaTexture
                descriptor.colorAttachments[0].resolveTexture = metalTexture
                descriptor.colorAttachments[0].storeAction = .multisampleResolve
            } else {
                descriptor.colorAttachments[0].texture = metalTexture
                descriptor.colorAttachments[0].storeAction = .store
            }
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

            guard let commandBuffer = MetalShared.shared.commandQueue.makeCommandBuffer() else {
                throw WaveExportError.pixelBuffer("could not create command buffer")
            }
            let time = Float(frame) / 60.0
            renderer.render(time: time,
                            aspect: Float(width) / Float(height),
                            descriptor: descriptor,
                            commandBuffer: commandBuffer,
                            viewport: CGSize(width: width, height: height))
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()

            if let error = commandBuffer.error {
                throw WaveExportError.pixelBuffer(error.localizedDescription)
            }

            var frameProperties: CFDictionary?
            if frame % 120 == 0 {
                frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            }

            let pts = CMTime(value: Int64(frame), timescale: 60)
            let duration = CMTime(value: 1, timescale: 60)
            let encodeStatus = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: pts,
                duration: duration,
                frameProperties: frameProperties,
                sourceFrameRefcon: nil,
                infoFlagsOut: nil
            )
            if encodeStatus != noErr {
                throw WaveExportError.encoderSetup("VTCompressionSessionEncodeFrame returned \(encodeStatus)")
            }

            if frame % 30 == 0 || frame == frameCount - 1 {
                let fraction = Double(frame + 1) / Double(frameCount)
                progress(fraction, "Frame \(frame + 1) of \(frameCount) · \(Int(fraction * 100))%")
            }
        }

        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)

        let deadline = Date().addingTimeInterval(120)
        while appendedFrames < frameCount {
            if let encodingError { throw encodingError }
            if Date() > deadline { break }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }

    private func finishWriting() throws {
        if let encodingError { throw encodingError }
        guard let session = compressionSession else {
            throw WaveExportError.encoderSetup("encoder is not ready")
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        compressionSession = nil

        writerInput.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(frameCount), timescale: 60))

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now() + 0.1) == .timedOut {
            if cancelToken.isCancelled {
                writer.cancelWriting()
                throw WaveExportError.cancelled
            }
        }
        if writer.status != .completed {
            throw WaveExportError.writerSetup(writer.error?.localizedDescription ?? "writer did not complete")
        }
    }

    fileprivate func handleEncodedFrame(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr, let sampleBuffer else {
            if status != noErr {
                appendLock.lock()
                encodingError = WaveExportError.encoderSetup("encoder output returned \(status)")
                appendLock.unlock()
            }
            return
        }

        attachTemporalMetadata(to: sampleBuffer)

        while !writerInput.isReadyForMoreMediaData {
            if cancelToken.isCancelled { return }
            Thread.sleep(forTimeInterval: 0.002)
        }
        appendLock.lock()
        let ok = writerInput.append(sampleBuffer)
        if ok {
            appendedFrames += 1
        } else if encodingError == nil {
            encodingError = WaveExportError.writerSetup(writer.error?.localizedDescription ?? "append failed")
        }
        appendLock.unlock()
    }

    private func attachTemporalMetadata(to sampleBuffer: CMSampleBuffer) {
        guard let temporalID = temporalID(from: sampleBuffer) else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
              let dict = (attachments as NSArray).firstObject as? NSMutableDictionary else {
            return
        }

        let info: [String: Any] = [
            kCMHEVCTemporalLevelInfoKey_TemporalLevel as String: temporalID,
            kCMHEVCTemporalLevelInfoKey_ProfileSpace as String: 0,
            kCMHEVCTemporalLevelInfoKey_TierFlag as String: 0,
            kCMHEVCTemporalLevelInfoKey_ProfileIndex as String: 1,
            kCMHEVCTemporalLevelInfoKey_ProfileCompatibilityFlags as String: Data([0, 0, 0, 0]),
            kCMHEVCTemporalLevelInfoKey_ConstraintIndicatorFlags as String: Data([0, 0, 0, 0, 0, 0]),
            kCMHEVCTemporalLevelInfoKey_LevelIndex as String: 120,
        ]
        dict[kCMSampleAttachmentKey_HEVCTemporalLevelInfo as String] = info
        dict[kCMSampleAttachmentKey_HEVCTemporalSubLayerAccess as String] = temporalID == 0
    }

    private func temporalID(from sampleBuffer: CMSampleBuffer) -> Int? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(dataBuffer)
        guard length > 4 else { return nil }
        var bytes = [UInt8](repeating: 0, count: length)
        let copied = CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0,
                                                dataLength: length,
                                                destination: &bytes)
        guard copied == kCMBlockBufferNoErr else { return nil }

        var offset = 0
        var maxTemporalID = 0
        while offset + 6 <= length {
            let nalLength = (Int(bytes[offset]) << 24) |
                            (Int(bytes[offset + 1]) << 16) |
                            (Int(bytes[offset + 2]) << 8) |
                            Int(bytes[offset + 3])
            offset += 4
            guard nalLength > 2, offset + nalLength <= length else { break }
            let nalType = (bytes[offset] >> 1) & 0x3f
            if nalType <= 31 {
                let temporalPlusOne = Int(bytes[offset + 1] & 0x07)
                maxTemporalID = max(maxTemporalID, max(0, temporalPlusOne - 1))
            }
            offset += nalLength
        }
        return maxTemporalID
    }
}

private func hevcOutputCallback(_ refcon: UnsafeMutableRawPointer?,
                                _ sourceFrameRefCon: UnsafeMutableRawPointer?,
                                _ status: OSStatus,
                                _ infoFlags: VTEncodeInfoFlags,
                                _ sampleBuffer: CMSampleBuffer?) {
    guard let refcon else { return }
    let job = Unmanaged<HEVCExportJob>.fromOpaque(refcon).takeUnretainedValue()
    job.handleEncodedFrame(status: status, sampleBuffer: sampleBuffer)
}
