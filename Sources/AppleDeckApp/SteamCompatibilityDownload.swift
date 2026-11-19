import AppleDeckCore
import CryptoKit
import Foundation

/// Valve's host client owns the Steam session and native appmanifest.
@MainActor
final class SteamCompatibilityDownload {
    enum Prompt: Sendable {
        case password, guardCode

        var title: String {
            switch self {
            case .password: String(localized: "Steam Password")
            case .guardCode: String(localized: "Steam Guard Code")
            }
        }
    }
    enum Event: Sendable {
        case prompt(Prompt)
        case waitingForApproval
        case progress(CompatibilityDownloadProgress)
    }

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var continuation: CheckedContinuation<Int32, Error>?
    private var buffer = ""
    private var reportedError: String?
    private var lastProgress: CompatibilityDownloadProgress?

    static func prepare(at directory: URL) async throws -> URL {
        let executable = directory.appendingPathComponent("steamcmd")
        if FileManager.default.isExecutableFile(atPath: executable.path) { return executable }
        let url = URL(string: "https://steamcdn-a.akamaihd.net/client/steamcmd_osx.zip.6bbc1e7314dedcf49293f7b80d2ab667de4bbd3d")!
        let (archive, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: archive) }
        _ = try CompatibilitySources.checked(response)
        guard try CompatibilitySources.digest(archive, SHA256()) ==
            "3f554ad38ae87a431f3788bf4cacd29a5484c93d61f399810f150a2af0804a1c" else {
            throw CompatibilityFailure(String(localized: "Valve SteamCMD bootstrap verification failed."))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-qq", archive.path, "steamcmd", "-d", directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try await Task.detached(priority: .utility) {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw CompatibilityFailure(String(localized: "Could not extract Valve SteamCMD."))
            }
        }.value
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CompatibilityFailure(String(localized: "The Valve SteamCMD executable could not be found."))
        }
        return executable
    }

    func download(_ executable: URL, appID: UInt32, arm64: Bool, account: String, destination: URL,
                  onEvent: @escaping @MainActor @Sendable (Event) -> Void) async throws {
        let arguments = ["-nobreakpad", "-nominidumps", "+@ShutdownOnFailedCommand", "1",
                         "+@sSteamCmdForcePlatformType", "linux", "+@sSteamCmdForcePlatformBitness", "64",
                         "+@sSteamCmdForcePlatformCPU", arm64 ? "arm64" : "x86",
                         "+force_install_dir", destination.path,
                         "+login", account, "+app_update", String(appID), "+quit"]
        let first = try await run(executable, arguments: arguments, onEvent: onEvent)
        let status = first == 42
            ? try await run(executable, arguments: arguments, onEvent: onEvent)
            : first
        guard status == 0, reportedError == nil else {
            throw CompatibilityFailure(reportedError ?? String(localized: "Valve SteamCMD did not finish the download. Check your network connection and Steam sign-in."))
        }
    }

    func answer(_ value: String) throws {
        guard !value.isEmpty, !value.contains(where: \.isNewline), let input else { return }
        try input.write(contentsOf: Data((value + "\n").utf8))
    }

    func cancel() {
        try? input?.close()
        if let process, process.isRunning { process.terminate() }
    }

    private func run(_ executable: URL, arguments: [String],
                     onEvent: @escaping @MainActor @Sendable (Event) -> Void) async throws -> Int32 {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            let child = Process()
            let messages = Pipe()
            let commands = Pipe()
            child.executableURL = executable
            child.currentDirectoryURL = executable.deletingLastPathComponent()
            child.arguments = arguments
            var env = ProcessInfo.processInfo.environment
            env["DYLD_LIBRARY_PATH"] = child.currentDirectoryURL?.path
            env["DYLD_FRAMEWORK_PATH"] = child.currentDirectoryURL?.path
            child.environment = env
            child.standardInput = commands
            child.standardOutput = messages
            child.standardError = messages
            buffer = ""
            reportedError = nil
            lastProgress = nil
            input = commands.fileHandleForWriting
            output = messages.fileHandleForReading
            self.continuation = continuation
            process = child
            messages.fileHandleForReading.readabilityHandler = { [weak self] file in
                let data = file.availableData
                if data.isEmpty { file.readabilityHandler = nil }
                Task { @MainActor in
                    guard let self, self.process === child else { return }
                    self.receive(data, onEvent: onEvent)
                    if data.isEmpty, !child.isRunning { self.finish(child.terminationStatus) }
                }
            }
            child.terminationHandler = { [weak self] child in
                Task { @MainActor in
                    guard let self, self.process === child else { return }
                    // The pipe may still contain the final server error.
                    if self.output == nil { self.finish(child.terminationStatus) }
                }
            }
            do {
                try child.run()
            } catch {
                teardown()
                continuation.resume(throwing: error)
            }
        }
    }

    private func receive(_ data: Data, onEvent: (Event) -> Void) {
        if data.isEmpty {
            output = nil
            return
        }
        buffer += String(decoding: data, as: UTF8.self)
        let lower = buffer.lowercased()
        let tail = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        if tail.hasSuffix("password:") {
            onEvent(.prompt(.password))
            buffer = ""
        } else if tail.hasSuffix("code:"), lower.contains("guard") || lower.contains("two-factor") {
            onEvent(.prompt(.guardCode))
            buffer = ""
        } else {
            if lower.contains("no subscription") {
                reportedError = String(localized: "Valve has not granted this account access to download this Proton version.")
            } else if lower.contains("failed to install app") || lower.contains("login failure") {
                reportedError = String(localized: "Valve SteamCMD rejected the sign-in or download. Check Steam Guard and account permissions.")
            }
            if let progress = CompatibilityDownloadProgress.steamCMD(in: buffer) {
                if progress != lastProgress {
                    lastProgress = progress
                    onEvent(.progress(progress))
                }
            } else if lastProgress == nil, lower.contains("confirmation") || lower.contains("steam guard mobile authenticator") {
                onEvent(.waitingForApproval)
            }
            if buffer.count > 4096 { buffer = String(buffer.suffix(2048)) }
        }
    }

    private func finish(_ status: Int32) {
        let completion = continuation
        teardown()
        completion?.resume(returning: status)
    }

    private func teardown() {
        output?.readabilityHandler = nil
        try? input?.close()
        input = nil
        output = nil
        process = nil
        continuation = nil
        buffer = ""
    }
}
