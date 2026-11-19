import AppleDeckCore
import CryptoKit
import Foundation
import Synchronization

struct CompatibilityCatalogItem: Identifiable, Sendable {
    let id: String
    let name: String
    let architecture: String
    let source: CompatibilityTool.Source
    var archive: URL?
    var checksum: URL?

    static let steam: [Self] = [
        official(1493710, "Proton Experimental"),
        official(4628710, "Proton 11.0"),
        official(3658110, "Proton 10.0"),
        official(2805730, "Proton 9.0"),
        official(2348590, "Proton 8.0"),
        official(1887720, "Proton 7.0"),
        official(1580130, "Proton 6.3"),
        official(1420170, "Proton 5.13"),
        official(1245040, "Proton 5.0"),
        official(1113280, "Proton 4.11"),
        official(1054830, "Proton 4.2"),
        official(961940, "Proton 3.16"),
        official(858280, "Proton 3.7"),
        official(2180100, "Proton Hotfix"),
        official(4427310, "Proton Experimental (ARM64)", "aarch64"),
        official(4628740, "Proton 11.0 (ARM64)", "aarch64"),
    ]

    private static func official(_ appID: UInt32, _ name: String, _ arch: String = "x86_64") -> Self {
        .init(id: "steam:\(appID)", name: name, architecture: arch, source: .steam)
    }
}

enum CompatibilitySources {
    private struct Release: Decodable {
        struct Asset: Decodable { let name: String }
        let tag_name: String
        let draft: Bool
        let assets: [Asset]
    }

    static func gePage(_ page: Int) async throws -> (items: [CompatibilityCatalogItem], more: Bool) {
        let root = "https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases"
        let url = URL(string: "\(root)?per_page=24&page=\(page)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try checked(response)
        let releases = try JSONDecoder().decode([Release].self, from: data)
        var items: [CompatibilityCatalogItem] = []
        for release in releases where !release.draft {
            let tag = release.tag_name
            guard tag.wholeMatch(of: /GE-Proton[0-9][A-Za-z0-9.-]{0,39}/) != nil else { continue }
            let assets = Set(release.assets.map(\.name))
            for arch in ["x86_64", "aarch64"] {
                var stem = "\(tag)-\(arch)"
                if arch == "x86_64", !assets.contains(stem + ".tar.gz") { stem = tag }
                guard assets.contains(stem + ".tar.gz"), assets.contains(stem + ".sha512sum") else { continue }
                let base = "https://github.com/GloriousEggroll/proton-ge-custom/releases/download/\(tag)/\(stem)"
                items.append(.init(id: "ge:\(tag.lowercased()):\(arch)", name: tag, architecture: arch, source: .ge,
                                   archive: URL(string: base + ".tar.gz"), checksum: URL(string: base + ".sha512sum")))
            }
        }
        return (items, http.value(forHTTPHeaderField: "Link")?.contains("rel=\"next\"") == true)
    }

    static func downloadGE(_ item: CompatibilityCatalogItem, into directory: URL,
                           onProgress: @escaping @MainActor @Sendable (CompatibilityDownloadProgress) -> Void) async throws {
        guard let archive = item.archive, let checksum = item.checksum else {
            throw CompatibilityFailure(String(localized: "This release is missing the GE-Proton archive."))
        }
        let (checksumData, checksumResponse) = try await URLSession.shared.data(from: checksum)
        _ = try checked(checksumResponse)
        let fields = String(decoding: checksumData, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        guard fields.count == 2, fields[0].wholeMatch(of: /[0-9A-Fa-f]{128}/) != nil,
              fields[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == archive.lastPathComponent else {
            throw CompatibilityFailure(String(localized: "The GE-Proton checksum file is invalid."))
        }
        let expected = fields[0].lowercased()
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("appledeck-ge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let temporary = work.appendingPathComponent("proton.tar.gz")
        try await downloadArchive(archive, to: temporary, onProgress: onProgress)
        let valid = try await Task.detached(priority: .utility) { try digest(temporary, SHA512()) == expected }.value
        guard valid else { throw CompatibilityFailure(String(localized: "GE-Proton download verification failed.")) }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let package = directory.appendingPathComponent("proton.tar.gz")
        if FileManager.default.fileExists(atPath: package.path) { try FileManager.default.removeItem(at: package) }
        try FileManager.default.moveItem(at: temporary, to: package)
        try Data(expected.utf8).write(to: directory.appendingPathComponent("checksum"), options: .atomic)
    }

    private static func downloadArchive(_ url: URL, to destination: URL,
                                        onProgress: @MainActor @Sendable (CompatibilityDownloadProgress) -> Void) async throws {
        try Task.checkCancellation()
        let (updates, progress) = AsyncThrowingStream<CompatibilityDownloadProgress, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let delegate = ArchiveDownload(destination: destination, progress: progress)
        // The convenience async download does not deliver download delegate progress on macOS.
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        session.downloadTask(with: url).resume()
        for try await update in updates { await onProgress(update) }
        try Task.checkCancellation()
    }

    private final class ArchiveDownload: NSObject, URLSessionDownloadDelegate {
        private let destination: URL
        private let progress: AsyncThrowingStream<CompatibilityDownloadProgress, Error>.Continuation
        private let lastReport = Mutex<TimeInterval>(0)

        init(destination: URL, progress: AsyncThrowingStream<CompatibilityDownloadProgress, Error>.Continuation) {
            self.destination = destination
            self.progress = progress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let now = ProcessInfo.processInfo.systemUptime
            let shouldReport = lastReport.withLock { last in
                guard now - last >= 0.2 || totalBytesWritten == totalBytesExpectedToWrite else { return false }
                last = now
                return true
            }
            guard shouldReport else { return }
            progress.yield(.init(receivedBytes: totalBytesWritten, expectedBytes: totalBytesExpectedToWrite))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            do {
                _ = try checked(downloadTask.response)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                progress.finish(throwing: error)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            progress.finish(throwing: error)
        }
    }

    static func checked(_ response: URLResponse?) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CompatibilityFailure(String(localized: "The download server returned an error (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))."))
        }
        return http
    }

    static func digest<H: HashFunction>(_ url: URL, _ hash: H) throws -> String {
        var hash = hash
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        while let data = try reader.read(upToCount: 1 << 20), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct CompatibilityFailure: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
