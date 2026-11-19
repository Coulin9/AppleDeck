import AppleDeckCore
import SwiftUI

struct CompatibilitySettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var vm: VMProcess
    @ObservedObject var manager: CompatibilityManager
    @State private var search = ""
    @State private var steamItem: CompatibilityCatalogItem?
    @State private var account = ""
    @State private var credential = ""

    private var disk: String? { model.configuration.diskImagePath }
    private var canWriteDisk: Bool { disk != nil && !vm.busy && !manager.diskBusy }
    private var inventory: CompatibilityStatus? {
        if vm.busy { return vm.compatibility }
        return manager.statusDisk == disk ? manager.diskStatus : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search Compatibility Tools", text: $search).textFieldStyle(.roundedBorder)
                Button("Refresh") {
                    Task {
                        if vm.state == .running { vm.refreshCompatibilityInventory() }
                        if !vm.busy { await manager.refreshDisk(disk) }
                        await manager.loadCatalog(page: manager.gePage)
                    }
                }.disabled(manager.diskBusy || manager.catalogLoading)
            }
            Text(disk == nil
                 ? String(localized: "You can download tools to the Mac first and install them after choosing a SteamOS disk.")
                 : vm.busy
                 ? String(localized: "You can download and inspect versions while the virtual machine is running. Shut it down to install tools or change Neptune settings.")
                 : String(localized: "AppleDeck writes directly to the selected SteamOS disk. After the next boot, select the generated Neptune version under Compatibility in the game’s Steam properties."))
                .font(.callout).foregroundStyle(.secondary)
            if let error = manager.error ?? vm.compatibilityError {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            if let detail = manager.detail {
                operationStatus(detail)
            } else if manager.diskBusy {
                ProgressView("Reading or updating the SteamOS disk…").controlSize(.small)
            }
            if let prompt = manager.steamPrompt {
                HStack {
                    SecureField(prompt.title, text: $credential).textFieldStyle(.roundedBorder)
                        .onSubmit(submitCredential)
                    Button("Submit to Steam", action: submitCredential)
                        .disabled(credential.isEmpty)
                }
            }
            toolList
        }
        .padding(16)
        .task { await manager.loadCatalog() }
        .task(id: DiskState(path: disk, state: vm.state)) {
            if !vm.busy { await manager.refreshDisk(disk) }
            while vm.state == .running && !Task.isCancelled {
                vm.refreshCompatibilityInventory()
                do { try await Task.sleep(for: .seconds(3)) }
                catch { break }
            }
        }
        .onChange(of: manager.steamPrompt) { credential = "" }
        .sheet(item: $steamItem) { item in
            VStack(alignment: .leading, spacing: 12) {
                Text("Download \(item.name) from Valve").font(.headline)
                Text("Steam requires account authorization. Your password and Steam Guard code are sent only to Valve SteamCMD running on this Mac.")
                    .font(.callout)
                TextField("Steam Account Name", text: $account).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { steamItem = nil }
                    Button("Continue") {
                        let user = account.trimmingCharacters(in: .whitespacesAndNewlines)
                        steamItem = nil
                        acquire(item, account: user)
                    }.keyboardShortcut(.defaultAction)
                     .disabled(account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(20).frame(width: 400)
        }
    }

    private func operationStatus(_ detail: String) -> some View {
        let progress = manager.downloadProgress
        let fraction = progress?.fraction
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                if manager.activeTool != nil && fraction == nil { ProgressView().controlSize(.small) }
                Text(detail).font(.callout)
                if let progress {
                    Spacer()
                    Text(downloadSummary(progress)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if manager.activeTool != nil && !manager.diskBusy {
                    Button("Cancel") { manager.cancelDownload() }
                }
            }
            if let fraction {
                ProgressView(value: fraction).controlSize(.small).accessibilityLabel("Download Progress")
            }
        }
    }

    private func downloadSummary(_ progress: CompatibilityDownloadProgress) -> String {
        let received = ByteCountFormatter.string(fromByteCount: progress.receivedBytes, countStyle: .file)
        guard let total = progress.expectedBytes, let fraction = progress.fraction else { return String(localized: "Downloaded \(received)") }
        let expected = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return "\(Int(fraction * 100))% · \(received) / \(expected)"
    }

    private var toolList: some View {
        let items = Dictionary(uniqueKeysWithValues: (inventory?.items ?? []).map { ($0.id, $0) })
        let upstream = CompatibilityCatalogItem.steam + manager.ge
        let known = Set(upstream.map(\.id))
        let local = items.values.filter { !known.contains($0.id) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let entries = (upstream + local.map {
            CompatibilityCatalogItem(id: $0.id, name: $0.name, architecture: $0.architecture, source: $0.source)
        }).filter { item in
            search.isEmpty || (items[item.id]?.name ?? item.name).localizedCaseInsensitiveContains(search)
            || item.name.localizedCaseInsensitiveContains(search)
        }.enumerated().sorted { left, right in
            let a = items[left.element.id]?.installed == true
            let b = items[right.element.id]?.installed == true
            return a != b ? a : left.offset < right.offset
        }.map(\.element)
        return List {
            if entries.contains(where: { $0.source == .steam }) {
                Section("Official Steam Releases") {
                    ForEach(entries.filter { $0.source == .steam }) { item in
                        row(item, installed: items[item.id])
                    }
                }
            }
            Section("GE-Proton") {
                if let error = manager.catalogError {
                    Text(error).foregroundStyle(.red)
                }
                ForEach(entries.filter { $0.source == .ge }) { item in
                    row(item, installed: items[item.id])
                }
                if manager.catalogLoading || manager.geMore || manager.gePage > 1 {
                    HStack {
                        Button("Previous Page") { Task { await manager.loadCatalog(page: manager.gePage - 1) } }
                            .disabled(manager.gePage == 1 || manager.catalogLoading)
                        Text("Page \(manager.gePage)").foregroundStyle(.secondary)
                        Button("Next Page") { Task { await manager.loadCatalog(page: manager.gePage + 1) } }
                            .disabled(!manager.geMore || manager.catalogLoading)
                        if manager.catalogLoading { ProgressView().controlSize(.small) }
                    }.buttonStyle(.borderless)
                }
            }
        }
    }

    private func row(_ item: CompatibilityCatalogItem, installed tool: CompatibilityTool?) -> some View {
        let downloaded = manager.hasDownload(item)
        let isInstalled = tool?.installed == true
        let isARM64 = (tool?.architecture ?? item.architecture) == "aarch64"
        let arch = isARM64 ? "ARM64" : "x86-64"
        let name = tool?.name ?? item.name
        let backend = model.configuration.graphicsBackend
        let showsMullionRequirement = isARM64 && tool?.neptuneEnabled == true
        let problem = showsMullionRequirement ? tool?.neptuneProblem : tool?.neptuneProblem(for: backend)
        let canToggle = tool?.canToggleNeptune(for: backend) == true
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name).fontWeight(.medium)
                Text(arch + " · " + rowStatus(tool, downloaded: downloaded)).font(.caption).foregroundStyle(.secondary)
                if let build = tool?.neptuneBuild, !build.isEmpty {
                    Text("Neptune runtime · \(build)").font(.caption).foregroundStyle(.secondary)
                }
                if showsMullionRequirement {
                    Text("ARM64 Neptune compatibility tools require the Mullion graphics backend.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let problem = problem ?? tool?.neptuneError {
                    Text(NSLocalizedString(problem, comment: "SteamOS compatibility tool message"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let tool, isInstalled || tool.neptuneEnabled || tool.neptuneGenerated {
                Toggle("Neptune", isOn: Binding(get: { tool.neptuneEnabled }, set: { enabled in
                    if let disk, canWriteDisk, canToggle {
                        manager.toggle(tool.id, enabled: enabled, disk: disk, backend: backend)
                    }
                }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(!canWriteDisk || !canToggle)
                .accessibilityLabel("\(name) Neptune")
            }
            if !isInstalled && tool?.downloading != true && (item.source == .steam || item.archive != nil || downloaded) {
                Button(downloaded ? String(localized: "Install") : canWriteDisk ? String(localized: "Download and Install") : String(localized: "Download")) {
                    if item.source == .steam && !downloaded {
                        account = ""
                        steamItem = item
                    } else {
                        acquire(item)
                    }
                }
                .disabled(manager.activeTool != nil || manager.diskBusy || (downloaded && !canWriteDisk))
                .accessibilityLabel("Install \(name) \(arch)")
            }
        }.padding(.vertical, 3)
    }

    private func rowStatus(_ tool: CompatibilityTool?, downloaded: Bool) -> String {
        if tool?.neptuneGenerated == true && tool?.installed == true { return String(localized: "Neptune generated") }
        if tool?.installed == true { return String(localized: "Installed") }
        if let tool, tool.downloading {
            if let progress = tool.progress { return String(localized: "SteamOS is installing (\(progress.formatted(.percent.precision(.fractionLength(0)))))") }
            return String(localized: "SteamOS is installing")
        }
        if downloaded { return String(localized: "Downloaded to the Mac") }
        return inventory == nil && disk != nil ? String(localized: "Checking installation status") : String(localized: "Not installed")
    }

    private func acquire(_ item: CompatibilityCatalogItem, account: String? = nil) {
        let selected = disk
        manager.acquire(item, account: account, disk: selected, backend: model.configuration.graphicsBackend) { [weak model, weak vm] in
            guard let model, let vm else { return false }
            return !vm.busy && model.configuration.diskImagePath == selected
        }
    }

    private func submitCredential() {
        let submitted = credential
        credential = ""
        manager.answerSteam(submitted)
    }

    private struct DiskState: Equatable {
        let path: String?
        let state: VMProcess.State
    }
}
