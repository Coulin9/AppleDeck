// swift-tools-version: 6.0
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let environment = ProcessInfo.processInfo.environment
let include = environment["APPLEDECK_LIBKRUN_INCLUDE"] ?? root.appendingPathComponent("libkrun/include").path
let frameworks = environment["APPLEDECK_LIBKRUN_DIR"] ?? root.appendingPathComponent("AppleDeck/.build/out/libkrun").path

let package = Package(
    name: "AppleDeck",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AppleDeckCore", targets: ["AppleDeckCore"]),
        .library(name: "AppleDeckDisplay", targets: ["AppleDeckDisplay"]),
        .library(name: "AppleDeckVMRuntime", targets: ["AppleDeckVMRuntime"]),
        .executable(name: "AppleDeck", targets: ["AppleDeckApp"]),
        .executable(name: "appledeck-vm", targets: ["AppleDeckVM"]),
        .executable(name: "appledeck-diagnostics", targets: ["AppleDeckDiagnostics"]),
    ],
    targets: [
        .systemLibrary(name: "CKrun"),
        .target(name: "AppleDeckCore", linkerSettings: [.linkedFramework("Metal"), .linkedFramework("AppKit")]),
        .target(name: "AppleDeckDisplay", linkerSettings: [
            .linkedFramework("AppKit"), .linkedFramework("Metal"), .linkedFramework("MetalKit"),
            .linkedFramework("IOSurface"), .linkedFramework("QuartzCore"),
        ]),
        // The VM runtime (libkrun VMM + guest window/input/network) lives in a
        // library so both the launcher (in-process VM) and the standalone
        // appledeck-vm executable can run it. The launcher runs the VM in its
        // own process so game mode binds to its CFBundleExecutable.
        .target(name: "AppleDeckVMRuntime", dependencies: ["CKrun", "AppleDeckCore", "AppleDeckDisplay"],
                swiftSettings: [.unsafeFlags(["-Xcc", "-I\(include)"])],
                linkerSettings: [.unsafeFlags(["-L", frameworks, "-lkrun.1", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks", "-Xlinker", "-rpath", "-Xlinker", frameworks]), .linkedFramework("AppKit"), .linkedFramework("GameController"), .linkedFramework("SystemConfiguration")]),
        .executableTarget(name: "AppleDeckApp", dependencies: ["AppleDeckCore", "AppleDeckVMRuntime"],
                          swiftSettings: [.unsafeFlags(["-Xcc", "-I\(include)"])],
                          linkerSettings: [.unsafeFlags(["-L", frameworks, "-lkrun.1", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks", "-Xlinker", "-rpath", "-Xlinker", frameworks]), .linkedFramework("SwiftUI"), .linkedFramework("AppKit"), .linkedFramework("GameController")]),
        .executableTarget(name: "AppleDeckVM", dependencies: ["AppleDeckVMRuntime"],
                          swiftSettings: [.unsafeFlags(["-Xcc", "-I\(include)"])],
                          linkerSettings: [.unsafeFlags(["-L", frameworks, "-lkrun.1", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks", "-Xlinker", "-rpath", "-Xlinker", frameworks]), .linkedFramework("AppKit"), .linkedFramework("GameController")]),
        .executableTarget(name: "AppleDeckDiagnostics", dependencies: ["AppleDeckCore"]),
        .testTarget(name: "AppleDeckCoreTests", dependencies: ["AppleDeckCore"]),
        .testTarget(name: "AppleDeckDisplayTests", dependencies: ["AppleDeckDisplay"]),
        .testTarget(name: "AppleDeckVMTests", dependencies: ["AppleDeckVMRuntime"],
                    swiftSettings: [.unsafeFlags(["-Xcc", "-I\(include)"])],
                    linkerSettings: [.unsafeFlags(["-L", frameworks, "-Xlinker", "-rpath", "-Xlinker", frameworks])]),
    ],
    swiftLanguageModes: [.v6]
)
