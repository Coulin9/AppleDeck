import AppleDeckCore
import Foundation

@MainActor
final class CompatibilityManager: ObservableObject {
    @Published private(set) var diskStatus: CompatibilityStatus?
    @Published private(set) var statusDisk: String?
    @Published private(set) var diskBusy = false
    @Published private(set) var activeTool: String?
    @Published private(set) var downloadProgress: CompatibilityDownloadProgress?
    @Published private(set) var detail: String?
    @Published private(set) var error: String?
    @Published private(set) var ge: [CompatibilityCatalogItem] = []
    @Published private(set) var gePage = 1
    @Published private(set) var geMore = false
    @Published private(set) var catalogLoading = false
    @Published private(set) var catalogError: String?
    @Published private(set) var steamPrompt: SteamCompatibilityDownload.Prompt?
    private var catalogLoaded = false
    private var job: Task<Void, Never>?
    private var steamDownload: SteamCompatibilityDownload?

    private let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AppleDeck/Compatibility", isDirectory: true)

    func loadCatalog(page: Int? = nil) async {
        guard !catalogLoading, page != nil || !catalogLoaded else { return }
        let requested = page ?? gePage
        catalogLoading = true
        defer { catalogLoading = false }
        do {
            let result = try await CompatibilitySources.gePage(requested)
            ge = result.items
            gePage = requested
            geMore = result.more
            catalogLoaded = true
            catalogError = nil
        } catch {
            if !Task.isCancelled { catalogError = String(localized: "Could not load the GE-Proton release catalog. \(error.localizedDescription)") }
        }
    }

    func refreshDisk(_ disk: String?) async {
        guard !diskBusy else { return }
        guard let disk else {
            statusDisk = nil
            diskStatus = nil
            return
        }
        if statusDisk != disk { diskStatus = nil }
        error = nil
        await updateDisk(disk, request: .init(.list))
    }

    func synchronize(_ disk: String, backend: GraphicsBackend) async {
        await updateDisk(disk, request: .init(.synchronize, graphicsBackend: backend))
    }

    func toggle(_ key: String, enabled: Bool, disk: String, backend: GraphicsBackend) {
        guard !diskBusy else { return }
        Task {
            error = nil
            await updateDisk(disk, request: .init(.neptune, tool: key, enabled: enabled, graphicsBackend: backend))
        }
    }

    func hasDownload(_ item: CompatibilityCatalogItem) -> Bool {
        if item.source == .ge {
            let folder = geCache(item)
            return ["proton.tar.gz", "checksum"].allSatisfy {
                FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
            }
        }
        return (try? Self.steamFiles(package: steamCache(item), id: item.id)) != nil
    }

    func acquire(_ item: CompatibilityCatalogItem, account: String? = nil, disk: String?, backend: GraphicsBackend,
                 mayInstall: @escaping @MainActor () -> Bool) {
        guard job == nil, !diskBusy else { return }
        error = nil
        detail = nil
        activeTool = item.id
        job = Task {
            defer {
                downloadProgress = nil
                self.job = nil
                activeTool = nil
                steamDownload = nil
                steamPrompt = nil
            }
            do {
                if !hasDownload(item) {
                    if item.source == .ge {
                        detail = String(localized: "Downloading \(item.name) to the Mac…")
                        try await CompatibilitySources.downloadGE(item, into: geCache(item)) { progress in
                            if !Task.isCancelled { self.downloadProgress = progress }
                        }
                    } else {
                        guard let account, account.wholeMatch(of: /[A-Za-z0-9_]{1,64}/) != nil,
                              let appID = UInt32(item.id.dropFirst("steam:".count)) else {
                            throw CompatibilityFailure(String(localized: "Enter a valid Steam account name."))
                        }
                        detail = String(localized: "Preparing Valve SteamCMD…")
                        let executable = try await SteamCompatibilityDownload.prepare(at: engine)
                        let downloader = SteamCompatibilityDownload()
                        let destination = steamCache(item)
                        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true,
                                                                attributes: [.posixPermissions: 0o700])
                        steamDownload = downloader
                        detail = String(localized: "Connecting to Valve SteamCMD…")
                        try await downloader.download(executable, appID: appID, arm64: item.architecture == "aarch64",
                                                      account: account, destination: destination) { event in
                            guard self.job?.isCancelled == false else { return }
                            switch event {
                            case .prompt(let prompt):
                                self.steamPrompt = prompt
                            case .waitingForApproval:
                                self.detail = String(localized: "Confirm the sign-in in the Steam mobile app, or wait for the Steam Guard prompt.")
                            case .progress(let progress):
                                if self.downloadProgress == nil {
                                    self.steamPrompt = nil
                                    self.detail = String(localized: "Valve is downloading \(item.name)…")
                                }
                                self.downloadProgress = progress
                            }
                        }
                        steamPrompt = nil
                        _ = try Self.steamFiles(package: destination, id: item.id)
                    }
                }
                downloadProgress = nil
                try Task.checkCancellation()
                guard let disk, mayInstall(), !diskBusy else {
                    detail = String(localized: "Downloaded \(item.name). Shut down the virtual machine and choose a disk to install it.")
                    return
                }
                detail = String(localized: "Writing to the SteamOS disk…")
                let source = item.source == .ge ? geCache(item) : steamCache(item)
                await updateDisk(disk, request: .init(.install, tool: item.id, graphicsBackend: backend), package: (item, source))
                detail = error == nil ? String(localized: "Installed \(item.name). It will be available after the next SteamOS boot.") : nil
            } catch {
                detail = nil
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func answerSteam(_ input: String) {
        guard steamPrompt != nil, !input.isEmpty, !input.contains(where: \.isNewline) else { return }
        do {
            try steamDownload?.answer(input)
            steamPrompt = nil
            detail = String(localized: "Waiting for Valve to verify the sign-in…")
        } catch {
            self.error = String(localized: "Could not send sign-in information to Valve SteamCMD.")
        }
    }

    func cancelDownload() {
        guard !diskBusy else { return }
        job?.cancel()
        downloadProgress = nil
        steamDownload?.cancel()
    }

    private var engine: URL { cache.appendingPathComponent("SteamCMD", isDirectory: true) }

    private func geCache(_ item: CompatibilityCatalogItem) -> URL {
        cache.appendingPathComponent(item.id.replacingOccurrences(of: ":", with: "-"), isDirectory: true)
    }

    private func steamCache(_ item: CompatibilityCatalogItem) -> URL {
        cache.appendingPathComponent("SteamPackages", isDirectory: true)
            .appendingPathComponent(String(item.id.dropFirst("steam:".count)), isDirectory: true)
    }

    private func updateDisk(_ disk: String, request: CompatibilityRequest,
                            package: (CompatibilityCatalogItem, URL)? = nil) async {
        guard !diskBusy else { return }
        diskBusy = true
        defer { diskBusy = false }
        let bundle = Bundle.main.bundleURL
        do {
            let reply = try await Task.detached(priority: .userInitiated) {
                try Self.accessDisk(bundle: bundle, disk: disk, request: request, package: package)
            }.value
            if let error = reply.error {
                throw CompatibilityFailure(NSLocalizedString(error, comment: "SteamOS compatibility service message"))
            }
            guard let status = reply.status else { throw CompatibilityFailure(String(localized: "The SteamOS disk did not return a list of compatibility tools.")) }
            statusDisk = disk
            diskStatus = status
        } catch {
            self.error = error.localizedDescription
        }
    }

    nonisolated private static func accessDisk(bundle: URL, disk: String, request: CompatibilityRequest,
                                              package: (CompatibilityCatalogItem, URL)?) throws -> CompatibilityReply {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("appledeck-compat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let exchange = work.appendingPathComponent("exchange", isDirectory: true)
        try FileManager.default.createDirectory(at: exchange, withIntermediateDirectories: false)
        try JSONEncoder().encode(request).write(to: exchange.appendingPathComponent("request.json"))
        if let (item, source) = package {
            if item.source == .ge {
                for name in ["proton.tar.gz", "checksum"] {
                    try FileManager.default.copyItem(at: source.appendingPathComponent(name),
                                                     to: exchange.appendingPathComponent(name))
                }
            } else {
                let files = try steamFiles(package: source, id: item.id)
                let apps = exchange.appendingPathComponent("native/steamapps", isDirectory: true)
                let common = apps.appendingPathComponent("common", isDirectory: true)
                try FileManager.default.createDirectory(at: common, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: files.manifest, to: apps.appendingPathComponent(files.manifest.lastPathComponent))
                let target = common.appendingPathComponent(files.name, isDirectory: true)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                for entry in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                    where entry.lastPathComponent != "steamapps" {
                    try FileManager.default.copyItem(at: entry, to: target.appendingPathComponent(entry.lastPathComponent))
                }
            }
        }
        let reply = try SteamOSPreparation().accessCompatibilityDisk(URL(fileURLWithPath: disk),
                            writing: request.action != .list,
                            helper: bundle.appendingPathComponent("Contents/MacOS/appledeck-vm"),
                            resources: bundle.appendingPathComponent("Contents/Resources/Runtime"),
                            runDirectory: work)
        guard reply.id == request.id else { throw CompatibilityFailure(String(localized: "The response from the SteamOS disk did not match the request.")) }
        return reply
    }

    nonisolated private static func steamFiles(package: URL, id: String) throws -> (manifest: URL, name: String) {
        guard let appID = UInt32(id.dropFirst("steam:".count)) else {
            throw CompatibilityFailure(String(localized: "Invalid Steam App ID."))
        }
        let apps = package.appendingPathComponent("steamapps", isDirectory: true)
        let manifest = apps.appendingPathComponent("appmanifest_\(appID).acf")
        let incomplete = CompatibilityFailure(String(localized: "Valve SteamCMD did not produce a complete Proton installation."))
        guard let text = try? String(contentsOf: manifest, encoding: .utf8),
              let directory = text.firstMatch(of: /"installdir"\s+"([^"\/\\]+)"/)?.1,
              directory != ".", directory != "..",
              let stateText = text.firstMatch(of: /"StateFlags"\s+"([0-9]+)"/)?.1,
              let state = Int(stateText), state & 4 != 0 else { throw incomplete }
        guard FileManager.default.isReadableFile(atPath: package.appendingPathComponent("proton").path) else { throw incomplete }
        return (manifest, String(directory))
    }
}
