import Darwin
import Foundation

public struct SteamOSDeploymentError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The raw GPT layout consumed by AppleDeck's SteamOS initramfs.
public enum SteamOSDisk {
    public static let capacitiesGiB = [64, 128, 256, 512, 1024]
    private static let systemNames = ["esp", "efi-A", "efi-B", "rootfs-A", "rootfs-B", "var-A", "var-B", "home"]
    private static let recoveryNames = ["esp", "efi-A", "rootfs-A", "var-A", "home"]
    private static let starts: [UInt64] = [2048, 526336, 657408, 788480, 21760000, 42731520, 44828672, 46925824]

    public static func validateSystem(at url: URL) throws {
        let disk = try Reader(url)
        let partitions = try disk.partitions()
        guard partitions.map(\.name) == systemNames else {
            if partitions.map(\.name) == recoveryNames {
                throw SteamOSDeploymentError(String(localized: "This is a SteamOS installation image. Choose Fresh Install."))
            }
            throw SteamOSDeploymentError(String(localized: "This file is not a usable SteamOS system disk. Choose a different disk or use Fresh Install."))
        }
        for partition in partitions {
            if partition.name == "esp" || partition.name.hasPrefix("efi-") {
                try disk.validateFAT(partition)
            } else if partition.name.hasPrefix("rootfs-") {
                try disk.validateBtrfs(partition)
            } else {
                let magic = try disk.read(at: partition.start * 512 + 1080, count: 2)
                guard magic == Data([0x53, 0xef]) else {
                    throw SteamOSDeploymentError(String(localized: "The system disk was not fully formatted (\(partition.name)). Reinstall SteamOS."))
                }
            }
        }
    }

    public static func validateInstaller(at url: URL) throws {
        let disk = try Reader(url)
        let partitions = try disk.partitions()
        if partitions.map(\.name) == systemNames {
            throw SteamOSDeploymentError(String(localized: "This disk already contains SteamOS. Use Choose Existing System Disk."))
        }
        guard partitions.map(\.name) == recoveryNames else {
            throw SteamOSDeploymentError(String(localized: "Choose a SteamOS ARM64 recovery image in .img, .raw, or .img.bz2 format."))
        }
        try disk.validateFAT(partitions[0])
        try disk.validateBtrfs(partitions[2])
    }

    /// Creates only a new sparse file. Existing files and symlinks are never opened for writing.
    @discardableResult
    public static func createBlank(at url: URL, capacityGiB: Int) throws -> UUID {
        guard capacitiesGiB.contains(capacityGiB) else {
            throw SteamOSDeploymentError(String(localized: "Choose a disk capacity of 64, 128, 256, 512, or 1024 GB."))
        }
        let parent = url.deletingLastPathComponent()
        guard try parent.resourceValues(forKeys: [.volumeSupportsSparseFilesKey]).volumeSupportsSparseFiles == true else {
            throw SteamOSDeploymentError(String(localized: "This location does not support sparse disk images. Choose a folder on an APFS volume."))
        }
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw SteamOSDeploymentError(String(localized: "Could not create the system disk. Choose a writable folder and make sure the destination file does not already exist."))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var success = false
        defer {
            try? handle.close()
            if !success { try? FileManager.default.removeItem(at: url) }
        }
        let size = UInt64(capacityGiB) * 1_073_741_824
        guard ftruncate(descriptor, off_t(size)) == 0 else {
            throw SteamOSDeploymentError(String(localized: "Could not allocate the system disk. Check the destination and available space."))
        }
        let lastSector = size / 512 - 1
        let diskGUID = UUID()
        var entries = Data(repeating: 0, count: 128 * 128)
        for index in systemNames.indices {
            let offset = index * 128
            let type = index < 3 ? "C12A7328-F81F-11D2-BA4B-00A0C93EC93B" : "0FC63DAF-8483-4772-8E79-3D69D8477DE4"
            entries.replaceSubrange(offset..<(offset + 16), with: guidBytes(UUID(uuidString: type)!))
            entries.replaceSubrange((offset + 16)..<(offset + 32), with: guidBytes(UUID()))
            entries.put(starts[index], at: offset + 32)
            entries.put(index + 1 < starts.count ? starts[index + 1] - 1 : lastSector - 33, at: offset + 40)
            let name = systemNames[index].data(using: .utf16LittleEndian)!
            entries.replaceSubrange((offset + 56)..<(offset + 56 + name.count), with: name)
        }
        var mbr = Data(repeating: 0, count: 512)
        mbr[450] = 0xee
        mbr.put(UInt32(1), at: 454)
        mbr.put(UInt32(min(lastSector, UInt64(UInt32.max))), at: 458)
        mbr[510] = 0x55
        mbr[511] = 0xaa
        func write(_ data: Data, sector: UInt64) throws {
            try handle.seek(toOffset: sector * 512)
            try handle.write(contentsOf: data)
        }
        try write(mbr, sector: 0)
        try write(header(current: 1, backup: lastSector, entries: 2, lastUsable: lastSector - 33, guid: diskGUID, table: entries), sector: 1)
        try write(entries, sector: 2)
        try write(entries, sector: lastSector - 32)
        try write(header(current: lastSector, backup: 1, entries: lastSector - 32, lastUsable: lastSector - 33, guid: diskGUID, table: entries), sector: lastSector)
        try handle.synchronize()
        success = true
        return diskGUID
    }

    private static func header(current: UInt64, backup: UInt64, entries: UInt64, lastUsable: UInt64, guid: UUID, table: Data) -> Data {
        var data = Data(repeating: 0, count: 512)
        data.replaceSubrange(0..<8, with: Data("EFI PART".utf8))
        data.put(UInt32(0x10000), at: 8)
        data.put(UInt32(92), at: 12)
        data.put(current, at: 24)
        data.put(backup, at: 32)
        data.put(UInt64(34), at: 40)
        data.put(lastUsable, at: 48)
        data.replaceSubrange(56..<72, with: guidBytes(guid))
        data.put(entries, at: 72)
        data.put(UInt32(128), at: 80)
        data.put(UInt32(128), at: 84)
        data.put(crc32(table), at: 88)
        data.put(crc32(data.prefix(92)), at: 16)
        return data
    }

    private static func guidBytes(_ uuid: UUID) -> Data {
        var value = uuid.uuid
        var data = withUnsafeBytes(of: &value) { Data($0) }
        data.replaceSubrange(0..<4, with: data[0..<4].reversed())
        data.replaceSubrange(4..<6, with: data[4..<6].reversed())
        data.replaceSubrange(6..<8, with: data[6..<8].reversed())
        return data
    }

    struct Partition {
        let name: String
        let start: UInt64
        let end: UInt64
    }

    private final class Reader {
        let handle: FileHandle
        let size: UInt64

        init(_ url: URL) throws {
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { throw SteamOSDeploymentError(String(localized: "Could not read the selected image. Check that it exists and that you have permission to read it.")) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 34 * 512 else {
                close(fd)
                throw SteamOSDeploymentError(String(localized: "Choose a complete raw disk image."))
            }
            handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            size = UInt64(info.st_size)
        }

        func read(at offset: UInt64, count: Int) throws -> Data {
            guard offset <= size, UInt64(count) <= size - offset else { throw invalidGPT() }
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else { throw invalidGPT() }
            return data
        }

        func partitions() throws -> [Partition] {
            let header = try read(at: 512, count: 512)
            let table = try validateHeader(header, current: 1)
            let backupSector: UInt64 = header.integer(at: 32)
            let backup = try read(at: backupSector * 512, count: 512)
            let backupTable = try validateHeader(backup, current: backupSector)
            guard backup.integer(at: 32, as: UInt64.self) == 1,
                  header[40..<72] == backup[40..<72], table == backupTable else { throw invalidGPT() }
            let first: UInt64 = header.integer(at: 40)
            let last: UInt64 = header.integer(at: 48)
            var result: [Partition] = []
            for offset in stride(from: 0, to: table.count, by: 128) {
                if table[offset..<(offset + 16)].allSatisfy({ $0 == 0 }) { continue }
                let start: UInt64 = table.integer(at: offset + 32)
                let end: UInt64 = table.integer(at: offset + 40)
                guard start >= first, end >= start, end <= last else { throw invalidGPT() }
                let nameData = table.subdata(in: (offset + 56)..<(offset + 128))
                let name = (String(data: nameData, encoding: .utf16LittleEndian) ?? "").prefix { $0 != "\0" }
                result.append(Partition(name: String(name), start: start, end: end))
            }
            let sorted = result.sorted { $0.start < $1.start }
            for (left, right) in zip(sorted, sorted.dropFirst()) where left.end >= right.start { throw invalidGPT() }
            return result
        }

        private func validateHeader(_ data: Data, current: UInt64) throws -> Data {
            guard data.prefix(8) == Data("EFI PART".utf8) else { throw invalidGPT() }
            let length = Int(data.integer(at: 12, as: UInt32.self))
            guard (92...512).contains(length), data.integer(at: 24, as: UInt64.self) == current else { throw invalidGPT() }
            var checksumData = Data(data.prefix(length))
            checksumData.put(UInt32(0), at: 16)
            guard crc32(checksumData) == data.integer(at: 16, as: UInt32.self) else { throw invalidGPT() }
            let count = Int(data.integer(at: 80, as: UInt32.self))
            let entrySize = Int(data.integer(at: 84, as: UInt32.self))
            let tableSector: UInt64 = data.integer(at: 72)
            let alternate: UInt64 = data.integer(at: 32)
            let first: UInt64 = data.integer(at: 40)
            let last: UInt64 = data.integer(at: 48)
            guard (1...128).contains(count), entrySize == 128,
                  alternate < size / 512, alternate != current, first <= last, last < size / 512,
                  tableSector >= 2, tableSector < size / 512 else { throw invalidGPT() }
            let table = try read(at: tableSector * 512, count: count * entrySize)
            guard crc32(table) == data.integer(at: 88, as: UInt32.self) else { throw invalidGPT() }
            return table
        }

        func validateFAT(_ partition: Partition) throws {
            let boot = try read(at: partition.start * 512, count: 512)
            let fat = Data("FAT".utf8)
            guard boot[510] == 0x55, boot[511] == 0xaa,
                  boot[54..<57] == fat || boot[82..<85] == fat else {
                throw SteamOSDeploymentError(String(localized: "The image’s boot partition is incomplete (\(partition.name)). Choose a complete image."))
            }
        }

        func validateBtrfs(_ partition: Partition) throws {
            guard partition.end - partition.start >= 129,
                  try read(at: partition.start * 512 + 0x10040, count: 8) == Data("_BHRfS_M".utf8) else {
                throw SteamOSDeploymentError(String(localized: "The image’s system partition is incomplete (\(partition.name)). Choose a complete image."))
            }
        }

        private func invalidGPT() -> SteamOSDeploymentError {
            SteamOSDeploymentError(String(localized: "The disk image’s GPT partition table is incomplete or damaged. Select another image or download it again."))
        }
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb8_8320 : 0) }
        }
        return ~crc
    }
}

private extension Data {
    mutating func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { replaceSubrange(offset..<(offset + MemoryLayout<T>.size), with: $0) }
    }

    func integer<T: FixedWidthInteger>(at offset: Int, as: T.Type = T.self) -> T {
        var value: T = 0
        for index in 0..<MemoryLayout<T>.size { value |= T(self[offset + index]) << (index * 8) }
        return value
    }
}
