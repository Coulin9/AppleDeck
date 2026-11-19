import AppKit
import AppleDeckCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    let host: HostCapabilities
    let vm = VMProcess()
    let deployment = DiskDeployment()
    @Published var showDeployment = false
    @Published private(set) var hasUsableDisk = false
    @Published var configuration: VMConfiguration {
        didSet {
            if configuration.diskImagePath != oldValue.diskImagePath { refreshDiskAvailability() }
            if configuration != oldValue && !isReloading {
                save()
            }
        }
    }
    @Published private(set) var displayCapabilities: HostDisplayCapabilities?
    @Published private(set) var store: ConfigurationStore?
    @Published private(set) var loadError: String?
    @Published private(set) var saveError: String?
    private var isReloading = false
    private var commandLineStartPending = CommandLine.arguments.dropFirst().contains("--start-vm")
    private var starting = false

    init() {
        host = HostCapabilities.detect()
        configuration = .defaults(for: host)
        reload()
        deployment.onInstalled = { [weak self] url in self?.useDisk(url, startAfterSelection: true) }
    }
    func refreshDisplayCapabilities() {
        let launcherScreen = NSApplication.shared.windows.first(where: { $0.title == "AppleDeck" })?.screen
        let id = vm.hostDisplayID ?? launcherScreen.flatMap { HostDisplayCapabilities.screenID($0) }
        displayCapabilities = HostDisplayCapabilities.detect(displayID: id)
        if let mode = displayCapabilities?.preferredMode(for: configuration.display) {
            configuration.display = mode
        }
    }
    var configurationPath: String { store?.url.path ?? String(localized: "Configuration path unavailable") }
    private var diskIsUsable: Bool {
        guard let path = configuration.diskImagePath,
              FileManager.default.isWritableFile(atPath: path) else { return false }
        return (try? SteamOSDisk.validateSystem(at: URL(fileURLWithPath: path))) != nil
    }
    func refreshDiskAvailability() {
        let wasAvailable = hasUsableDisk
        hasUsableDisk = diskIsUsable
        if wasAvailable && !hasUsableDisk && !vm.busy && !deployment.busy {
            showDeployment = true
        }
    }
    func offerDeploymentIfNeeded() {
        refreshDiskAvailability()
        if !vm.busy && !hasUsableDisk { showDeployment = true }
    }
    func start() {
        guard !vm.busy, !deployment.busy, !starting else { return }
        refreshDiskAvailability()
        guard hasUsableDisk, configuration.diskImagePath != nil else { showDeployment = true; return }
        starting = true
        defer { starting = false }
        vm.start(configuration: configuration, host: host, display: displayCapabilities)
    }

    func startFromCommandLineIfRequested() {
        guard commandLineStartPending else { return }
        commandLineStartPending = false
        guard loadError == nil else { return }
        start()
    }
    private func useDisk(_ url: URL, startAfterSelection: Bool) {
        configuration.diskImagePath = url.path
        guard saveError == nil, loadError == nil else { return }
        if startAfterSelection {
            showDeployment = false
            start()
        }
    }
    func reload() {
        guard !vm.busy, !deployment.busy else { return }
        isReloading = true
        defer { isReloading = false }
        saveError = nil
        do {
            let store = ConfigurationStore(url: try ConfigurationStore.defaultURL())
            self.store = store
            let loaded = try store.load(for: host)
            configuration = loaded
            loadError = nil
        } catch {
            if let store, let stored = try? store.decode() {
                configuration = stored
            }
            loadError = String(localized: "Could not load configuration (\(configurationPath)): \(error.localizedDescription)")
        }
        refreshDisplayCapabilities()
        refreshDiskAvailability()
    }
    private func save() {
        guard !vm.busy, let store else { return }
        do {
            guard let displayCapabilities else { throw DisplayUnavailable() }
            try displayCapabilities.validate(configuration.display)
            try store.save(configuration, for: host)
            loadError = nil
            saveError = nil
        } catch { saveError = String(localized: "Could not save configuration (\(store.url.path)): \(error.localizedDescription)") }
    }

    func setGameHUD(level: GameHUDLevel? = nil, position: GameHUDPosition? = nil) {
        guard !deployment.busy else { return }
        var updated = configuration
        if let level { updated.gameHUDLevel = level }
        if let position { updated.gameHUDPosition = position }
        configuration = updated
        vm.setGameHUD(level: updated.gameHUDLevel, position: updated.gameHUDPosition)
        guard vm.busy, let store else { return }
        do {
            try store.setGameHUD(level: updated.gameHUDLevel, position: updated.gameHUDPosition, for: host)
            saveError = nil
        } catch { saveError = String(localized: "Could not save configuration (\(store.url.path)): \(error.localizedDescription)") }
    }

    /// Backend selection stays editable while the VM runs: it only changes the
    /// preference used by the next game launch, never boot-only settings.
    func setGraphicsBackend(_ backend: GraphicsBackend) {
        guard !deployment.busy else { return }
        if vm.busy {
            // While running (or transitioning) the live runtime must accept the
            // backend before it is persisted; keep the previous config on
            // refusal so the stored choice still matches reality.
            guard vm.state == .running, vm.setGraphicsBackend(backend) else { return }
        }
        configuration.graphicsBackend = backend
        guard let store else { return }
        do {
            try store.setGraphicsBackend(backend, for: host)
            saveError = nil
        } catch { saveError = String(localized: "Could not save configuration (\(store.url.path)): \(error.localizedDescription)") }
    }

    private struct DisplayUnavailable: LocalizedError {
        var errorDescription: String? { String(localized: "Could not read the available display modes for the host display.") }
    }
    func chooseD3DMetalFramework() {
        guard !vm.busy, !deployment.busy else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select D3DMetal.framework")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        configuration.d3dMetalFrameworkPath = url.path
    }

    func chooseSharedFolder() {
        guard !vm.busy, !deployment.busy else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Shared Folder")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let folder = VMSharedFolder(path: url.path)
        do {
            _ = try folder.resolvedPath()
            configuration.sharedFolder = folder
        } catch { saveError = error.localizedDescription }
    }

    func chooseDisk(startAfterSelection: Bool = false) {
        guard !vm.busy, !deployment.busy else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Existing System Disk")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SteamOSDisk.validateSystem(at: url)
            guard FileManager.default.isWritableFile(atPath: url.path) else {
                saveError = String(localized: "The selected system disk is not writable.")
                return
            }
            useDisk(url, startAfterSelection: startAfterSelection)
        } catch { saveError = error.localizedDescription }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var vm: VMProcess?
    var deployment: DiskDeployment?
    private var quitting = false
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let deployment, deployment.busy {
            if !quitting {
                quitting = true
                Task { @MainActor in
                    await deployment.cancel()
                    sender.reply(toApplicationShouldTerminate: true)
                }
            }
            return .terminateLater
        }
        guard let vm, vm.busy else { return .terminateNow }
        if quitting { return .terminateLater }
        let alert = NSAlert()
        alert.messageText = String(localized: "The virtual machine is still running")
        alert.informativeText = String(localized: "Shut down the virtual machine before quitting AppleDeck?")
        alert.addButton(withTitle: String(localized: "Shut Down and Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        guard vm.busy else { return .terminateNow }
        quitting = true
        vm.onExit = { [weak self, weak sender] in
            self?.quitting = false
            sender?.reply(toApplicationShouldTerminate: true)
        }
        vm.stop()
        return .terminateLater
    }
}

@main
@MainActor
struct AppleDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("AppleDeck", id: "main") {
            MainView(model: model, vm: model.vm, deployment: model.deployment) {
                delegate.vm = model.vm
                delegate.deployment = model.deployment
            }
        }.defaultSize(width: 540, height: 620)
        .defaultLaunchBehavior(.presented)
        Settings {
            SettingsView(model: model, vm: model.vm, deployment: model.deployment)
                .frame(width: 660, height: 680)
        }
    }
}

private struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var vm: VMProcess
    @ObservedObject var deployment: DiskDeployment
    @State private var confirmForce = false
    let bindDelegate: () -> Void

    var body: some View {
        Form {
            Section("SteamOS") {
                LabeledContent("Status", value: vm.state.title)
                if let error = vm.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if let warning = vm.workContextWarning {
                    Text(warning).foregroundStyle(.orange).textSelection(.enabled)
                }
                HStack {
                    Button("Start") { model.start() }
                        .disabled(vm.busy || deployment.busy || model.loadError != nil)
                    Button("Shut Down") { vm.stop() }.disabled(!vm.busy || vm.state == .stopping)
                    Button("Force Stop") { confirmForce = true }.disabled(!vm.busy)
                    SettingsLink { Text("Open Settings") }
                }
                if let path = vm.runDirectory?.path { LabeledContent("Run Directory", value: path).textSelection(.enabled) }
                if let path = vm.logPath { LabeledContent("Host Log", value: path).textSelection(.enabled) }
            }
            UUPluginView(vm: vm)
            Section("Host") {
                LabeledContent("Architecture", value: model.host.architecture)
                LabeledContent("Logical CPUs", value: "\(model.host.logicalCPUCount)")
                LabeledContent("Unified Memory", value: ByteCountFormatter.string(fromByteCount: Int64(model.host.physicalMemoryBytes), countStyle: .memory))
                LabeledContent("GPU", value: model.host.metalDeviceName ?? String(localized: "Unavailable"))
            }
            Section("Configuration") {
                LabeledContent("Disk", value: model.hasUsableDisk ? (model.configuration.diskImagePath ?? "") : String(localized: "No usable system disk")).textSelection(.enabled)
                if !model.hasUsableDisk {
                    Button("Choose System Disk or Install SteamOS") { model.showDeployment = true }.disabled(vm.busy)
                }
                if let error = model.loadError {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                    Button("Reload Configuration") { model.reload() }.disabled(vm.busy)
                }
                if let error = model.saveError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            bindDelegate()
            model.refreshDisplayCapabilities()
            model.offerDeploymentIfNeeded()
            model.startFromCommandLineIfRequested()
        }
        .sheet(isPresented: $model.showDeployment) {
            DiskDeploymentView(model: model, deployment: deployment)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { _ in model.refreshDisplayCapabilities() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in model.refreshDisplayCapabilities() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshDiskAvailability() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in model.refreshDiskAvailability() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in model.refreshDiskAvailability() }
        .onChange(of: vm.hostDisplayID) { model.refreshDisplayCapabilities() }
        .confirmationDialog("Force stopping may corrupt guest data.", isPresented: $confirmForce) {
            Button("Force Stop Virtual Machine", role: .destructive) { vm.forceStop() }
            Button("Cancel", role: .cancel) { }
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var vm: VMProcess
    @ObservedObject var deployment: DiskDeployment
    @State private var language = AppLanguage.selected

    private var resolutionSelection: Binding<DisplayResolution> {
        Binding(get: { model.configuration.display.resolution }, set: { resolution in
            var requested = model.configuration.display
            requested.resolution = resolution
            if let mode = model.displayCapabilities?.preferredMode(for: requested) {
                model.configuration.display = mode
            }
        })
    }

    private var displayError: String? {
        do {
            guard let capabilities = model.displayCapabilities else { return String(localized: "Could not read the available display modes for the host display.") }
            try capabilities.validate(model.configuration.display)
            return nil
        } catch { return error.localizedDescription }
    }

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $language) {
                    Text("Follow System").tag(AppLanguage.system)
                    Text(verbatim: "English").tag(AppLanguage.english)
                    Text(verbatim: "简体中文").tag(AppLanguage.simplifiedChinese)
                }
                .onChange(of: language) { _, selection in selection.save() }
                if language != AppLanguage.atLaunch {
                    Text("Quit and reopen AppleDeck to apply a language change.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Guest Disk") {
                if let path = model.configuration.diskImagePath {
                    Text(path).textSelection(.enabled)
                    Button("Clear Disk Path") { model.configuration.diskImagePath = nil }
                } else { Text("No disk selected").foregroundStyle(.secondary) }
                Button("Choose Existing File") { model.chooseDisk() }
            }.disabled(vm.busy)
            Section("Shared Folder") {
                if let folder = model.configuration.sharedFolder {
                    Text(folder.path).textSelection(.enabled)
                    Toggle("Read Only", isOn: Binding(
                        get: { model.configuration.sharedFolder?.readOnly ?? true },
                        set: { model.configuration.sharedFolder?.readOnly = $0 }
                    ))
                    Text("After the next boot, open /run/appledeck/shared in SteamOS.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button(model.configuration.sharedFolder == nil ? String(localized: "Choose Folder") : String(localized: "Change Folder")) {
                        model.chooseSharedFolder()
                    }
                    if model.configuration.sharedFolder != nil {
                        Button("Remove Share") { model.configuration.sharedFolder = nil }
                    }
                }
            }.disabled(vm.busy)
            Section("Network") {
                Toggle("Enable Proxy", isOn: $model.configuration.network.proxyEnabled)
                TextField("Proxy Address", text: $model.configuration.network.proxyURL,
                          prompt: Text("socks5://127.0.0.1:7890"))
                Text("SOCKS5, HTTP, and HTTPS are supported. Include a port in the address. With the proxy off, traffic goes directly through the Mac’s physical network interface and bypasses TUN.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("HTTP and HTTPS proxies do not support UDP. Games and services that rely on UDP may fail to connect. Use a SOCKS5 proxy with UDP support if needed.")
                    .font(.callout).foregroundStyle(.secondary)
            }.disabled(vm.busy)
            Section("Resources") {
                Stepper("CPU: \(model.configuration.cpuCount)", value: $model.configuration.cpuCount, in: 1...model.host.maximumCPUs)
                Stepper("Memory: \(model.configuration.memoryGiB) GiB", value: $model.configuration.memoryGiB, in: 1...model.host.maximumMemoryGiB)
            }.disabled(vm.busy)
            Section("Virtual Machine Display") {
                if let capabilities = model.displayCapabilities {
                    LabeledContent("Host Display", value: capabilities.name)
                    Picker("Resolution", selection: resolutionSelection) {
                        ForEach(capabilities.resolutions, id: \.self) { resolution in
                            Text(verbatim: resolution.label).tag(resolution)
                        }
                    }
                    Picker("Refresh Rate", selection: $model.configuration.display.refreshRate) {
                        ForEach(capabilities.refreshRates(for: model.configuration.display.resolution), id: \.self) { rate in
                            Text("\(rate) Hz").tag(rate)
                        }
                    }
                    Text("Up to \(capabilities.maximumResolution.label) at \(capabilities.maximumRefreshRate) Hz. Available modes depend on the current host display.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text("The Steam interface follows the display resolution. The window scales proportionally and stays within the limits of the current display.")
                    .font(.callout).foregroundStyle(.secondary)
                if let error = displayError { Text(error).foregroundStyle(.red) }
            }.disabled(vm.busy)
            Section("Graphics Backend") {
                Picker("Backend", selection: Binding(
                    get: { model.configuration.graphicsBackend },
                    set: { model.setGraphicsBackend($0) }
                )) {
                    Text("Neptune / D3DMetal").tag(GraphicsBackend.neptune)
                    Text("Neptune / Mullion").tag(GraphicsBackend.mullion)
                    Text("Venus Only").tag(GraphicsBackend.venus)
                }
                if vm.state == .running {
                    Text("Backend changes apply to the next game launch; the framework, aperture, and multi-ring settings still only apply at boot.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let applied = vm.graphicsApplied {
                        Text("Active: \(applied.title)").font(.callout).foregroundStyle(.secondary)
                    }
                    if let error = vm.graphicsError { Text(error).foregroundStyle(.red) }
                }
                Group {
                    if model.configuration.graphicsBackend == .neptune {
                        LabeledContent("D3DMetal") {
                            Text(model.configuration.d3dMetalFrameworkPath ?? String(localized: "None selected"))
                                .textSelection(.enabled)
                        }
                        HStack {
                            Button("Choose Framework") { model.chooseD3DMetalFramework() }
                            if model.configuration.d3dMetalFrameworkPath != nil {
                                Button("Clear") { model.configuration.d3dMetalFrameworkPath = nil }
                            }
                        }
                    }
                    if model.configuration.graphicsBackend != .venus {
                        Stepper("Neptune aperture: \(model.configuration.neptuneApertureMiB) MiB",
                                value: $model.configuration.neptuneApertureMiB, in: 8192...65536, step: 8192)
                        Toggle("Experimental Multi-Ring (Global)", isOn: $model.configuration.neptuneMultiRing)
                    }
                }.disabled(vm.busy)
            }
            Section("Game Performance") {
                Picker("Overlay Level", selection: Binding(
                    get: { model.configuration.gameHUDLevel },
                    set: { model.setGameHUD(level: $0) }
                )) {
                    ForEach(GameHUDLevel.allCases, id: \.self) { level in
                        Text(level.title).tag(level)
                    }
                }
                Text(model.configuration.gameHUDLevel.detail)
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Overlay Position", selection: Binding(
                    get: { model.configuration.gameHUDPosition },
                    set: { model.setGameHUD(position: $0) }
                )) {
                    ForEach(GameHUDPosition.allCases, id: \.self) { position in
                        Text(position.title).tag(position)
                    }
                }.disabled(model.configuration.gameHUDLevel == .off)
                Text("Game frame times measure the interval between successful frame submissions. CPU, GPU, memory, and battery metrics cover the whole Mac. A dash (—) indicates unavailable data.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Frame statistics are available for Neptune and Vulkan X11 games. Native Wayland games are currently unsupported. The SteamOS performance overlay can stay off.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Configuration File") {
                Text(model.configurationPath).textSelection(.enabled)
                if let error = model.loadError {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                    Button("Reload Configuration") { model.reload() }.disabled(vm.busy)
                }
                if let error = model.saveError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
        }.formStyle(.grouped)
            .disabled(deployment.busy)
    }
}
