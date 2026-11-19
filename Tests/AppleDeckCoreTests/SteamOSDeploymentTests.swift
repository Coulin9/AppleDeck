import Darwin
import Foundation
import XCTest
@testable import AppleDeckCore

final class SteamOSDeploymentTests: XCTestCase {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    func testBlankDiskIsSparseAndNotYetAUsableSystem() throws {
        try withDirectory { directory in
            let disk = directory.appendingPathComponent("SteamOS.img")
            try SteamOSDisk.createBlank(at: disk, capacityGiB: 64)
            var attributes = stat()
            XCTAssertEqual(stat(disk.path, &attributes), 0)
            XCTAssertEqual(attributes.st_size, 64 * 1_073_741_824)
            XCTAssertLessThan(attributes.st_blocks * 512, 1024 * 1024)
            XCTAssertThrowsError(try SteamOSDisk.validateSystem(at: disk))
            try writeSystemSignatures(disk)
            XCTAssertNoThrow(try SteamOSDisk.validateSystem(at: disk))
            XCTAssertThrowsError(try SteamOSDisk.validateInstaller(at: disk)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Choose Existing System Disk"))
            }
        }
    }

    func testCreationNeverOverwritesExistingFilesOrSymlinks() throws {
        try withDirectory { directory in
            let existing = directory.appendingPathComponent("existing.img")
            let original = Data("user disk".utf8)
            try original.write(to: existing)
            XCTAssertThrowsError(try SteamOSDisk.createBlank(at: existing, capacityGiB: 128))
            XCTAssertEqual(try Data(contentsOf: existing), original)
            let link = directory.appendingPathComponent("link.img")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: existing)
            XCTAssertThrowsError(try SteamOSDisk.createBlank(at: link, capacityGiB: 128))
            XCTAssertEqual(try Data(contentsOf: existing), original)
        }
    }

    func testGPTCorruptionAndTruncationAreRejected() throws {
        try withDirectory { directory in
            let disk = directory.appendingPathComponent("disk.img")
            try SteamOSDisk.createBlank(at: disk, capacityGiB: 64)
            try writeSystemSignatures(disk)
            let file = try FileHandle(forUpdating: disk)
            defer { try? file.close() }
            try file.seek(toOffset: 512 + 16)
            let checksumByte = try XCTUnwrap(file.read(upToCount: 1)?.first)
            try file.seek(toOffset: 512 + 16)
            try file.write(contentsOf: Data([checksumByte ^ 0xff]))
            XCTAssertThrowsError(try SteamOSDisk.validateSystem(at: disk))
            try file.truncate(atOffset: 2048)
            XCTAssertThrowsError(try SteamOSDisk.validateSystem(at: disk))
        }
    }

    func testRecoveryImageIsAcceptedWithoutBeingWritten() throws {
        try withDirectory { directory in
            let disk = directory.appendingPathComponent("recovery.img")
            try makeRecovery(disk)
            let before = try Data(contentsOf: disk)
            XCTAssertNoThrow(try SteamOSDisk.validateInstaller(at: disk))
            XCTAssertThrowsError(try SteamOSDisk.validateSystem(at: disk)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Fresh Install"))
            }
            XCTAssertEqual(try Data(contentsOf: disk), before)
        }
    }

    func testTruncatedCompressedInstallerLeavesSourceAndNoOutput() throws {
        try withDirectory { directory in
            let archive = directory.appendingPathComponent("broken.img.bz2")
            let bytes = Data("BZh9incomplete archive".utf8)
            try bytes.write(to: archive)
            let output = directory.appendingPathComponent("installer.img")
            XCTAssertThrowsError(try SteamOSPreparation().extract(archive: archive, to: output))
            XCTAssertEqual(try Data(contentsOf: archive), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testCompressedInstallerRoundTripKeepsArchiveUnchanged() throws {
        try withDirectory { directory in
            let original = directory.appendingPathComponent("original.img")
            try makeRecovery(original)
            let archive = directory.appendingPathComponent("recovery.img.bz2")
            XCTAssertTrue(FileManager.default.createFile(atPath: archive.path, contents: nil))
            let output = try FileHandle(forWritingTo: archive)
            let compressor = Process()
            compressor.executableURL = URL(fileURLWithPath: "/usr/bin/bzip2")
            compressor.arguments = ["-c", original.path]
            compressor.standardOutput = output
            try compressor.run()
            compressor.waitUntilExit()
            try output.close()
            XCTAssertEqual(compressor.terminationStatus, 0)
            let before = try Data(contentsOf: archive)
            let extracted = directory.appendingPathComponent("extracted.img")
            try SteamOSPreparation().extract(archive: archive, to: extracted)
            XCTAssertEqual(try Data(contentsOf: extracted), try Data(contentsOf: original))
            XCTAssertEqual(try Data(contentsOf: archive), before)
        }
    }

    func testHelperSuccessRequiresStdoutAcknowledgementAndZeroExit() throws {
        try withDirectory { directory in
            let target = directory.appendingPathComponent("target.img")
            let source = directory.appendingPathComponent("source.img")
            try makeRecovery(source)
            let guid = try SteamOSDisk.createBlank(at: target, capacityGiB: 64)
            try writeSystemSignatures(target)
            let resources = directory.appendingPathComponent("Runtime")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
            try Data().write(to: resources.appendingPathComponent("initramfs.cpio.gz"))
            let helper = directory.appendingPathComponent("helper")
            let cases = [
                ("exit 0", false),
                ("echo 'APPLEDECK prepare done' >&2\nexit 0", false),
                ("echo 'APPLEDECK prepare done'\nexit 1", false),
                ("echo 'APPLEDECK prepare done'\nexit 0", true),
            ]
            for (script, succeeds) in cases {
                try Data("#!/bin/sh\n\(script)\n".utf8).write(to: helper)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
                let prepare = {
                    try SteamOSPreparation().prepare(source: source, target: target, diskGUID: guid,
                                                     helper: helper, resources: resources,
                                                     runDirectory: directory) { _ in }
                }
                if succeeds { XCTAssertNoThrow(try prepare()) }
                else { XCTAssertThrowsError(try prepare()) }
            }
        }
    }

    func testDownloadResumeRequiresSameStrongIdentityAndBoundedLength() {
        let url = SteamOSRelease.current.url
        let first = SteamOSDownload.Identity(url: url, bytes: 100, etag: "\"one\"", modified: "today")
        XCTAssertTrue(first.canResume(first, received: 30))
        XCTAssertTrue(first.canResume(first, received: 100))
        XCTAssertFalse(first.canResume(first, received: 101))
        XCTAssertFalse(first.canResume(first, received: 0))
        XCTAssertFalse(first.canResume(.init(url: url, bytes: 100, etag: "\"two\"", modified: "today"), received: 30))
        XCTAssertFalse(first.canResume(.init(url: url, bytes: 200, etag: "\"one\"", modified: "today"), received: 30))
        let noValidator = SteamOSDownload.Identity(url: url, bytes: 100, etag: "W/\"one\"", modified: nil)
        XCTAssertFalse(noValidator.canResume(noValidator, received: 30))
        let modified = SteamOSDownload.Identity(url: url, bytes: 100, etag: nil, modified: "today")
        XCTAssertTrue(modified.canResume(modified, received: 30))
    }

    private func writeSystemSignatures(_ url: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        let starts: [UInt64] = [2048, 526336, 657408, 788480, 21760000, 42731520, 44828672, 46925824]
        for index in 0..<3 {
            var fat = Data(repeating: 0, count: 512)
            fat.replaceSubrange(82..<85, with: Data("FAT".utf8))
            fat[510] = 0x55
            fat[511] = 0xaa
            try file.seek(toOffset: starts[index] * 512)
            try file.write(contentsOf: fat)
        }
        for index in 3..<5 {
            try file.seek(toOffset: starts[index] * 512 + 0x10040)
            try file.write(contentsOf: Data("_BHRfS_M".utf8))
        }
        for index in 5..<8 {
            try file.seek(toOffset: starts[index] * 512 + 1080)
            try file.write(contentsOf: Data([0x53, 0xef]))
        }
    }

    // Independent small GPT fixture: mirrors the UEFI byte layout, not production disk creation.
    private func makeRecovery(_ url: URL) throws {
        var image = Data(repeating: 0, count: 16 * 1024 * 1024)
        var entries = Data(repeating: 0, count: 128 * 128)
        let names = ["esp", "efi-A", "rootfs-A", "var-A", "home"]
        let starts: [UInt64] = [2048, 4096, 8192, 16384, 20480]
        for index in names.indices {
            let offset = index * 128
            entries[offset] = 1 // A non-empty partition type.
            entries[offset + 16] = UInt8(index + 1)
            put(starts[index], into: &entries, at: offset + 32)
            put(index == 4 ? UInt64(28671) : starts[index + 1] - 1, into: &entries, at: offset + 40)
            let name = names[index].data(using: .utf16LittleEndian)!
            entries.replaceSubrange((offset + 56)..<(offset + 56 + name.count), with: name)
        }
        func header(current: UInt64, other: UInt64, table: UInt64) -> Data {
            var result = Data(repeating: 0, count: 512)
            result.replaceSubrange(0..<8, with: Data("EFI PART".utf8))
            put(UInt32(0x10000), into: &result, at: 8)
            put(UInt32(92), into: &result, at: 12)
            put(current, into: &result, at: 24)
            put(other, into: &result, at: 32)
            put(UInt64(34), into: &result, at: 40)
            put(UInt64(32734), into: &result, at: 48)
            put(table, into: &result, at: 72)
            put(UInt32(128), into: &result, at: 80)
            put(UInt32(128), into: &result, at: 84)
            put(SteamOSDisk.crc32(entries), into: &result, at: 88)
            put(SteamOSDisk.crc32(result.prefix(92)), into: &result, at: 16)
            return result
        }
        image.replaceSubrange(512..<1024, with: header(current: 1, other: 32767, table: 2))
        image.replaceSubrange(1024..<(1024 + entries.count), with: entries)
        image.replaceSubrange((32735 * 512)..<(32767 * 512), with: entries)
        image.replaceSubrange((32767 * 512)..<(32768 * 512), with: header(current: 32767, other: 1, table: 32735))
        image[2048 * 512 + 510] = 0x55
        image[2048 * 512 + 511] = 0xaa
        image.replaceSubrange((2048 * 512 + 82)..<(2048 * 512 + 85), with: Data("FAT".utf8))
        image.replaceSubrange((8192 * 512 + 0x10040)..<(8192 * 512 + 0x10048), with: Data("_BHRfS_M".utf8))
        try image.write(to: url)
    }

    private func put<T: FixedWidthInteger>(_ value: T, into data: inout Data, at offset: Int) {
        for index in 0..<MemoryLayout<T>.size { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
}
