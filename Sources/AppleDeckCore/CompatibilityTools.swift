import Foundation

public struct CompatibilityRequest: Encodable, Sendable {
    public enum Action: String, Encodable, Sendable {
        case list, install, neptune, synchronize
    }

    public let id = UUID()
    public let action: Action
    private let tool: String?
    private let enabled: Bool?
    private let graphicsBackend: GraphicsBackend?

    public init(_ action: Action, tool: String? = nil, enabled: Bool? = nil,
                graphicsBackend: GraphicsBackend? = nil) {
        self.action = action
        self.tool = tool
        self.enabled = enabled
        self.graphicsBackend = graphicsBackend
    }
}

public struct CompatibilityTool: Decodable, Identifiable, Sendable {
    public enum Source: String, Decodable, Sendable {
        case steam, ge
    }

    public let id: String
    public let name: String
    public let source: Source
    public let architecture: String
    public let installed: Bool
    public let downloading: Bool
    public let progress: Double?
    public let neptuneEnabled: Bool
    public let neptuneGenerated: Bool
    public let neptuneProblem: String?
    public let neptuneError: String?
    public var neptuneBuild: String? = nil

    public func neptuneProblem(for backend: GraphicsBackend) -> String? {
        if architecture == "aarch64" && backend != .mullion {
            return backend == .neptune
                ? String(localized: "D3DMetal supports x86-64 Neptune compatibility tools only. ARM64 requires Mullion.")
                : String(localized: "ARM64 Neptune compatibility tools require Mullion.")
        }
        return neptuneProblem
    }

    public func canToggleNeptune(for backend: GraphicsBackend) -> Bool {
        neptuneEnabled || (installed && neptuneProblem(for: backend) == nil)
    }
}

public struct CompatibilityStatus: Decodable, Sendable {
    public let items: [CompatibilityTool]

    public init(items: [CompatibilityTool]) {
        self.items = items
    }
}

public struct CompatibilityReply: Decodable, Sendable {
    public let id: UUID
    public let status: CompatibilityStatus?
    public let error: String?
}

public struct CompatibilityDownloadProgress: Equatable, Sendable {
    public let receivedBytes: Int64
    public let expectedBytes: Int64?

    public init(receivedBytes: Int64, expectedBytes: Int64) {
        self.receivedBytes = max(0, receivedBytes)
        self.expectedBytes = expectedBytes > 0 ? expectedBytes : nil
    }

    public var fraction: Double? {
        expectedBytes.map { min(1, Double(receivedBytes) / Double($0)) }
    }

    public static func steamCMD(in output: String) -> Self? {
        let download = /Update state \(0x[0-9a-fA-F]+\) downloading, progress: [0-9.]+ \(([0-9]+) \/ ([0-9]+)\)/
        guard let match = output.matches(of: download).last,
              let received = Int64(match.1), let expected = Int64(match.2), expected > 0 else { return nil }
        return Self(receivedBytes: received, expectedBytes: expected)
    }
}
