import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let catalog = XMBCatalog.shared
    private var manager: WallpaperManager!
    private var statusItem: NSStatusItem!
    private var galleryController: GalleryWindowController?
    private var galleryModel: GalleryModel?

    private var currentVariant: XMBVariant!
    private var pauseItem: NSMenuItem?
    private var loginItem: NSMenuItem?
    private var autoSyncItem: NSMenuItem?
    private var lockScreenStatusItem: NSMenuItem?
    private var seasonalTimer: Timer?
    private var antiAliasing: AntiAliasingMode = .current

    private var isPaused = false {
        didSet {
            pauseItem?.state = isPaused ? .on : .off
            manager?.setPaused(isPaused)
        }
    }

    private enum DefaultsKey {
        static let appliedVariantID = "appliedVariantID"
        static let paused = "paused"
        static let autoSyncLockScreen = "autoSyncLockScreen"
    }

    private var autoSyncLockScreenEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: DefaultsKey.autoSyncLockScreen) == nil {
            return true
        }
        return defaults.bool(forKey: DefaultsKey.autoSyncLockScreen)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if handleAerialCLI() { return }

        let defaults = UserDefaults.standard
        let savedID = defaults.string(forKey: DefaultsKey.appliedVariantID)
        currentVariant = savedID.flatMap { catalog.variant(id: $0) } ?? catalog.defaultVariant
        if currentVariant.id == SeasonalTheme.variantID {
            currentVariant = SeasonalTheme.makeVariant()
        }
        isPaused = defaults.bool(forKey: DefaultsKey.paused)
        antiAliasing = AntiAliasingMode.current

        manager = WallpaperManager(variant: currentVariant, isPaused: isPaused,
                                   antiAliasing: antiAliasing)
        manager.start()
        buildStatusItem()
        if CommandLine.arguments.contains("--show-gallery") {
            openGallery()
        }
        handleTestingArguments()
        startSeasonalTimer()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        seasonalTimer?.invalidate()
        LockScreenSyncManager.shared.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        manager?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openGallery()
        }
        return true
    }

    @objc private func screensChanged() {
        manager.rebuildWindows()
    }

    private func startSeasonalTimer() {
        seasonalTimer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.refreshLiveTheme()
        }
        seasonalTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func systemDidWake() {
        refreshLiveTheme()
    }

    private func refreshLiveTheme() {
        guard currentVariant.id == SeasonalTheme.variantID else { return }
        let updated = SeasonalTheme.makeVariant()
        currentVariant = updated
        manager.apply(variant: updated)
        galleryModel?.refreshLiveVariant(updated)
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "water.waves", accessibilityDescription: "OSXMB")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "OSXMB — XMB live wallpaper"
        }

        let menu = NSMenu()

        let header = NSMenuItem(title: "OSXMB", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let current = NSMenuItem(title: "Current: \(currentVariant.name)", action: nil, keyEquivalent: "")
        current.isEnabled = false
        current.tag = 1001
        menu.addItem(current)
        menu.addItem(.separator())

        let gallery = NSMenuItem(title: "Open OSXMB Gallery…",
                                 action: #selector(openGallery), keyEquivalent: "g")
        gallery.target = self
        menu.addItem(gallery)

        let shortlist = NSMenuItem(title: "Quick Variants", action: nil, keyEquivalent: "")
        shortlist.submenu = buildQuickVariantsMenu()
        menu.addItem(shortlist)

        let antiAliasingItem = NSMenuItem(title: "Anti-Aliasing", action: nil, keyEquivalent: "")
        antiAliasingItem.submenu = buildAntiAliasingMenu()
        menu.addItem(antiAliasingItem)
        menu.addItem(.separator())

        let pause = NSMenuItem(title: "Pause Animation",
                               action: #selector(togglePause), keyEquivalent: "p")
        pause.target = self
        pause.state = isPaused ? .on : .off
        pauseItem = pause
        menu.addItem(pause)

        let login = NSMenuItem(title: "Launch at Login",
                               action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        loginItem = login
        menu.addItem(login)
        refreshLoginState()
        menu.addItem(.separator())

        let autoSync = NSMenuItem(title: "Auto-Sync Lock Screen",
                                  action: #selector(toggleAutoSyncLockScreen), keyEquivalent: "")
        autoSync.target = self
        autoSync.state = autoSyncLockScreenEnabled ? .on : .off
        autoSyncItem = autoSync
        menu.addItem(autoSync)

        let syncNow = NSMenuItem(title: "Sync Lock Screen Now",
                                 action: #selector(syncLockScreenNow), keyEquivalent: "")
        syncNow.target = self
        menu.addItem(syncNow)

        let lockStatus = NSMenuItem(title: LockScreenSyncManager.shared.statusText,
                                    action: nil, keyEquivalent: "")
        lockStatus.isEnabled = false
        lockScreenStatusItem = lockStatus
        menu.addItem(lockStatus)
        LockScreenSyncManager.shared.onStatusChange = { [weak self] text in
            self?.lockScreenStatusItem?.title = text
        }
        menu.addItem(.separator())

        let export = NSMenuItem(title: "Export Lock Screen Movie…",
                                action: #selector(exportMovie), keyEquivalent: "e")
        export.target = self
        menu.addItem(export)

        let aerials = NSMenuItem(title: "Install Into Aerial Catalog (experimental)…",
                                 action: #selector(installAerial), keyEquivalent: "")
        aerials.target = self
        menu.addItem(aerials)
        menu.addItem(.separator())

        let about = NSMenuItem(title: "About OSXMB", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit OSXMB", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func buildAntiAliasingMenu() -> NSMenu {
        let menu = NSMenu()
        for mode in AntiAliasingMode.allCases {
            let item = NSMenuItem(title: mode.title,
                                  action: #selector(selectAntiAliasing(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == antiAliasing ? .on : .off
            item.isEnabled = mode.isSupported
            menu.addItem(item)
        }
        return menu
    }

    private func buildQuickVariantsMenu() -> NSMenu {
        let menu = NSMenu()
        let calendar = Calendar.current
        let month = calendar.component(.month, from: Date())

        let original = NSMenuItem(title: "Original · Midnight Blue",
                                  action: #selector(applyFromMenu(_:)), keyEquivalent: "")
        original.target = self
        original.representedObject = "original-midnight-blue"
        menu.addItem(original)

        let live = NSMenuItem(title: "Live Seasonal · Date & Hour",
                              action: #selector(applyFromMenu(_:)), keyEquivalent: "")
        live.target = self
        live.representedObject = SeasonalTheme.variantID
        menu.addItem(live)

        let dayID = String(format: "%02d-day-classic", month)
        let day = NSMenuItem(title: "\(XMBCatalog.monthNames[month - 1]) Day · Classic",
                             action: #selector(applyFromMenu(_:)), keyEquivalent: "")
        day.target = self
        day.representedObject = dayID
        menu.addItem(day)

        let nightID = String(format: "%02d-night-classic", month)
        let night = NSMenuItem(title: "\(XMBCatalog.monthNames[month - 1]) Night · Classic",
                               action: #selector(applyFromMenu(_:)), keyEquivalent: "")
        night.target = self
        night.representedObject = nightID
        menu.addItem(night)

        menu.addItem(.separator())

        for family in ["Soft", "Deep", "Vivid", "Crystal"] {
            let id = String(format: "%02d-day-%@", month, family.lowercased())
            let item = NSMenuItem(title: "\(XMBCatalog.monthNames[month - 1]) Day · \(family)",
                                  action: #selector(applyFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let random = NSMenuItem(title: "Surprise Me", action: #selector(applyRandom), keyEquivalent: "")
        random.target = self
        menu.addItem(random)
        return menu
    }

    @objc private func applyFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let variant = catalog.variant(id: id) else { return }
        apply(variant)
    }

    @objc private func applyRandom() {
        apply(catalog.variants.randomElement() ?? catalog.defaultVariant)
    }

    private func apply(_ variant: XMBVariant) {
        let effective = variant.id == SeasonalTheme.variantID ? SeasonalTheme.makeVariant() : variant
        currentVariant = effective
        UserDefaults.standard.set(effective.id, forKey: DefaultsKey.appliedVariantID)
        manager.apply(variant: effective)
        galleryModel?.markApplied(effective)
        if let item = statusItem.menu?.item(withTag: 1001) {
            item.title = "Current: \(effective.name)"
        }
        if autoSyncLockScreenEnabled {
            LockScreenSyncManager.shared.sync(variant: effective)
        }
    }

    @objc private func openGallery() {
        if galleryModel == nil {
            galleryModel = GalleryModel(initialID: currentVariant.id)
        }
        if galleryController == nil {
            galleryController = GalleryWindowController(model: galleryModel!) { [weak self] variant in
                self?.apply(variant)
            }
        }
        galleryModel?.appliedID = currentVariant.id
        galleryController?.present()
    }

    @objc private func selectAntiAliasing(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int,
              let mode = AntiAliasingMode(rawValue: raw) else { return }
        antiAliasing = AntiAliasingMode.supported(mode)
        AntiAliasingMode.save(antiAliasing)
        manager.setAntiAliasing(antiAliasing)
        for item in sender.menu?.items ?? [] {
            item.state = (item.representedObject as? Int) == antiAliasing.rawValue ? .on : .off
        }
    }

    @objc private func togglePause() {
        isPaused.toggle()
        UserDefaults.standard.set(isPaused, forKey: DefaultsKey.paused)
    }

    @objc private func toggleAutoSyncLockScreen() {
        let enabled = !autoSyncLockScreenEnabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.autoSyncLockScreen)
        autoSyncItem?.state = enabled ? .on : .off
        if enabled {
            LockScreenSyncManager.shared.sync(variant: currentVariant)
        } else {
            LockScreenSyncManager.shared.cancel()
        }
    }

    @objc private func syncLockScreenNow() {
        LockScreenSyncManager.shared.sync(variant: currentVariant)
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not update login item"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
        refreshLoginState()
    }

    private func refreshLoginState() {
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func exportMovie() {
        ExportManager.shared.presentExport(for: currentVariant)
    }

    @objc private func installAerial() {
        AerialInstaller.shared.presentInstallFlow(for: currentVariant)
    }

    @objc private func showAbout() {
        let credits = NSAttributedString(
            string: """
            A native Metal live wallpaper inspired by the PlayStation 3 XMB wave.

            Rendering pipeline adapted from the MIT-licensed PlayStation-3-XMB project by Mart (linkev). No Sony assets are bundled. Not affiliated with or endorsed by Sony Interactive Entertainment.

            OSXMB renders live on the desktop and exports its own HEVC movie for the lock screen.
            """,
            attributes: [.font: NSFont.systemFont(ofSize: 11)]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "OSXMB",
            .applicationVersion: "1.0",
            .credits: credits,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func handleAerialCLI() -> Bool {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--aerial-install"), i + 2 < args.count {
            let movieURL = URL(fileURLWithPath: args[i + 1])
            let variant = catalog.variant(id: args[i + 2]) ?? catalog.defaultVariant
            do {
                let assetID = try AerialInstaller.shared.installAndActivate(movieURL: movieURL, variant: variant)
                print("OSXMB_AERIAL_OK \(assetID)")
                NSApp.terminate(nil)
            } catch {
                print("OSXMB_AERIAL_FAIL \(error.localizedDescription)")
                exit(1)
            }
            return true
        }

        if let i = args.firstIndex(of: "--aerial-reinstall"), i + 4 < args.count {
            let assetID = args[i + 1]
            let movieURL = URL(fileURLWithPath: args[i + 2])
            let variantName = args[i + 3]
            let variantID = args[i + 4]
            let shotID = i + 5 < args.count ? args[i + 5] : nil
            do {
                try AerialInstaller.shared.reinstall(assetID: assetID, movieURL: movieURL,
                                                    variantName: variantName, variantID: variantID,
                                                    shotID: shotID)
                print("OSXMB_AERIAL_REINSTALL_OK \(assetID)")
                NSApp.terminate(nil)
            } catch {
                print("OSXMB_AERIAL_REINSTALL_FAIL \(error.localizedDescription)")
                exit(1)
            }
            return true
        }

        if let i = args.firstIndex(of: "--aerial-uninstall"), i + 1 < args.count {
            do {
                try AerialInstaller.shared.uninstall(assetID: args[i + 1])
                AerialInstaller.shared.restartWallpaperProcesses()
                print("OSXMB_AERIAL_UNINSTALL_OK")
                NSApp.terminate(nil)
            } catch {
                print("OSXMB_AERIAL_UNINSTALL_FAIL \(error.localizedDescription)")
                exit(1)
            }
            return true
        }

        return false
    }

    private func handleTestingArguments() {
        let args = CommandLine.arguments
        if args.contains("--apply-live") {
            apply(SeasonalTheme.makeVariant())
            return
        }

        guard let flagIndex = args.firstIndex(of: "--export-test"),
              flagIndex + 1 < args.count else { return }

        let path = args[flagIndex + 1]
        let seconds = Double(ProcessInfo.processInfo.environment["OSXMB_EXPORT_SECONDS"] ?? "3") ?? 3
        let variantID = ProcessInfo.processInfo.environment["OSXMB_EXPORT_VARIANT"]
            ?? catalog.defaultVariant.id
        let variant = catalog.variant(id: variantID) ?? catalog.defaultVariant

        ExportManager.shared.exportForTesting(
            variant: variant,
            url: URL(fileURLWithPath: path),
            seconds: seconds
        ) { result in
            switch result {
            case .success(let url):
                print("OSXMB_EXPORT_OK \(url.path)")
            case .failure(let error):
                print("OSXMB_EXPORT_FAIL \(error.localizedDescription)")
            }
            NSApp.terminate(nil)
        }
    }
}
