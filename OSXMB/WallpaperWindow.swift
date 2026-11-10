import AppKit
import MetalKit
import QuartzCore

final class LiveWallpaperView: MTKView, MTKViewDelegate {
    let core: XMBCoreRenderer
    private let startTime = CACurrentMediaTime()

    func setPaused(_ value: Bool) {
        isPaused = value
    }

    init(variant: XMBVariant, antiAliasing: AntiAliasingMode = .current) {
        let effectiveAA = AntiAliasingMode.supported(antiAliasing)
        core = XMBCoreRenderer(variant: variant, antiAliasing: effectiveAA)
        super.init(frame: .zero, device: MetalShared.shared.device)
        delegate = self
        colorPixelFormat = .bgra8Unorm
        sampleCount = effectiveAA.sampleCount
        framebufferOnly = true
        enableSetNeedsDisplay = false
        isPaused = false
        preferredFramesPerSecond = 60
        autoResizeDrawable = true
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        wantsLayer = true
        layer?.isOpaque = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(variant: XMBVariant) {
        core.update(variant: variant)
        if isPaused {
            draw()
        }
    }

    func setAntiAliasing(_ mode: AntiAliasingMode) {
        let effective = AntiAliasingMode.supported(mode)
        guard effective != core.antiAliasing else { return }
        sampleCount = effective.sampleCount
        core.setAntiAliasing(effective)
        if isPaused {
            draw()
        }
    }

    func draw(in view: MTKView) {
        guard drawableSize.width > 1, drawableSize.height > 1,
              let drawable = currentDrawable,
              let descriptor = currentRenderPassDescriptor,
              let commandBuffer = MetalShared.shared.commandQueue.makeCommandBuffer() else {
            return
        }
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        descriptor.colorAttachments[0].loadAction = .clear
        let time = Float(CACurrentMediaTime() - startTime)
        let aspect = Float(drawableSize.width / max(1, drawableSize.height))
        core.render(time: time, aspect: aspect, descriptor: descriptor,
                    commandBuffer: commandBuffer, viewport: drawableSize)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

final class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(screen: NSScreen, variant: XMBVariant, paused: Bool,
         antiAliasing: AntiAliasingMode = .current) {
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        level = NSWindow.Level(rawValue: iconLevel - 1)
        isReleasedWhenClosed = false

        let live = LiveWallpaperView(variant: variant, antiAliasing: antiAliasing)
        live.frame = NSRect(origin: .zero, size: screen.frame.size)
        live.autoresizingMask = [.width, .height]
        live.setPaused(paused)
        contentView = live
        setFrame(screen.frame, display: true)
    }

    var liveView: LiveWallpaperView? { contentView as? LiveWallpaperView }
}

final class WallpaperManager {
    private(set) var windows: [WallpaperWindow] = []
    private(set) var variant: XMBVariant
    private(set) var isPaused: Bool
    private(set) var antiAliasing: AntiAliasingMode

    init(variant: XMBVariant, isPaused: Bool, antiAliasing: AntiAliasingMode = .current) {
        self.variant = variant
        self.isPaused = isPaused
        self.antiAliasing = AntiAliasingMode.supported(antiAliasing)
    }

    func start() {
        rebuildWindows()
    }

    func rebuildWindows() {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows = NSScreen.screens.map { screen in
            WallpaperWindow(screen: screen, variant: variant, paused: isPaused,
                            antiAliasing: antiAliasing)
        }
        for window in windows {
            window.orderFrontRegardless()
        }
    }

    func apply(variant: XMBVariant) {
        self.variant = variant
        for window in windows {
            window.liveView?.update(variant: variant)
        }
    }

    func setAntiAliasing(_ mode: AntiAliasingMode) {
        antiAliasing = AntiAliasingMode.supported(mode)
        for window in windows {
            window.liveView?.setAntiAliasing(antiAliasing)
        }
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        for window in windows {
            window.liveView?.setPaused(paused)
        }
    }

    func stop() {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
    }
}
