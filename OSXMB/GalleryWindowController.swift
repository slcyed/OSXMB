import AppKit
import SwiftUI

final class GalleryWindowController: NSWindowController {
    let model: GalleryModel

    init(model: GalleryModel, onApply: @escaping (XMBVariant) -> Void) {
        self.model = model
        let root = GalleryView(model: model, onApply: onApply)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "OSXMB Gallery"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 1120, height: 780))
        window.minSize = NSSize(width: 900, height: 620)
        window.center()
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        guard let window else { return }
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
