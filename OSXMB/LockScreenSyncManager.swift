import Foundation

final class LockScreenSyncManager {
    static let shared = LockScreenSyncManager()

    var onStatusChange: ((String) -> Void)?
    private(set) var statusText = "Lock Screen: Idle"

    private var pendingVariant: XMBVariant?
    private var isSyncing = false
    private var cancelExport: (() -> Void)?
    private var generation = 0

    private var baseDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OSXMB/Lock Screen",
                                    isDirectory: true)
    }
    private var finalURL: URL {
        baseDirectory.appendingPathComponent("OSXMB Lock Screen.mov")
    }
    private var temporaryURL: URL {
        baseDirectory.appendingPathComponent("OSXMB Lock Screen.tmp.mov")
    }

    private init() {}

    func sync(variant: XMBVariant) {
        DispatchQueue.main.async {
            self.request(variant)
        }
    }

    func cancel() {
        DispatchQueue.main.async {
            self.pendingVariant = nil
            self.cancelExport?()
            self.cancelExport = nil
            self.isSyncing = false
            self.generation += 1
            try? FileManager.default.removeItem(at: self.temporaryURL)
            self.setStatus("Lock Screen: Auto-sync off")
        }
    }

    private func request(_ variant: XMBVariant) {
        if isSyncing {
            pendingVariant = variant
            cancelExport?()
            return
        }
        start(variant)
    }

    private func start(_ variant: XMBVariant) {
        isSyncing = true
        pendingVariant = nil
        generation += 1
        let currentGeneration = generation

        guard AerialInstaller.shared.isCatalogAvailable else {
            isSyncing = false
            setStatus("Lock Screen: Aerial catalog unavailable")
            return
        }

        setStatus("Lock Screen: Syncing \(variant.name)…")

        do {
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: temporaryURL)
        } catch {
            finishFailure(error, generation: currentGeneration)
            return
        }

        cancelExport = ExportManager.shared.exportForLockScreenSync(
            variant: variant,
            url: temporaryURL
        ) { [weak self] result in
            guard let self, self.generation == currentGeneration else { return }
            self.cancelExport = nil

            switch result {
            case .failure(let error):
                if let exportError = error as? WaveExportError,
                   case .cancelled = exportError,
                   let next = self.pendingVariant {
                    self.pendingVariant = nil
                    self.start(next)
                } else {
                    self.finishFailure(error, generation: currentGeneration)
                }
            case .success(let url):
                do {
                    if FileManager.default.fileExists(atPath: self.finalURL.path) {
                        try FileManager.default.removeItem(at: self.finalURL)
                    }
                    try FileManager.default.moveItem(at: url, to: self.finalURL)
                } catch {
                    self.finishFailure(error, generation: currentGeneration)
                    return
                }
                self.install(variant: variant, generation: currentGeneration)
            }
        }
    }

    private func install(variant: XMBVariant, generation currentGeneration: Int) {
        setStatus("Lock Screen: Installing \(variant.name)…")

        DispatchQueue.global(qos: .utility).async {
            do {
                _ = try AerialInstaller.shared.syncLockScreen(movieURL: self.finalURL, variant: variant)
                DispatchQueue.main.async {
                    guard self.generation == currentGeneration else { return }
                    self.isSyncing = false
                    self.setStatus("Lock Screen: Synced \(variant.name)")
                    self.startPendingIfNeeded()
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.generation == currentGeneration else { return }
                    self.finishFailure(error, generation: currentGeneration)
                }
            }
        }
    }

    private func finishFailure(_ error: Error, generation currentGeneration: Int) {
        try? FileManager.default.removeItem(at: temporaryURL)
        isSyncing = false
        cancelExport = nil
        setStatus("Lock Screen: Sync failed")
        if generation == currentGeneration {
            startPendingIfNeeded()
        }
    }

    private func startPendingIfNeeded() {
        guard let next = pendingVariant else { return }
        pendingVariant = nil
        start(next)
    }

    private func setStatus(_ text: String) {
        statusText = text
        onStatusChange?(text)
    }
}
