import Darwin

/// One entry of a directory listing, read with `getattrlistbulk`.
public struct DirEntry {
    public enum Kind: UInt8 { case file, directory, symlink, other }

    public var name = ""
    public var kind = Kind.other
    public var flags: UInt32 = 0
    public var device: Int32 = 0
    public var fileID: UInt64 = 0
    public var linkCount: UInt32 = 1
    /// Bytes the file says it holds.
    public var logical: Int64 = 0
    /// Bytes allocated on disk.
    public var allocated: Int64 = 0
    /// Bytes freed right away by deleting: excludes blocks shared with APFS clones and snapshots.
    /// -1 when the file system can't tell.
    public var privateSize: Int64 = -1
    public var extFlags: UInt64 = 0
    public var modified: Int64 = 0
    public var accessed: Int64 = 0
    public var added: Int64 = 0
    public var isMountPoint = false

    public init() {}

    /// Offloaded to iCloud or another file provider: nothing on disk, and reading it would download it.
    public var isDataless: Bool { flags & BulkLister.datalessFlag != 0 }
    public var isHidden: Bool { name.hasPrefix(".") || flags & UInt32(UF_HIDDEN) != 0 }

    /// Bytes deleting this file gives back, not counting APFS clones. Blocks held only by a Time Machine
    /// snapshot still count: they come back when the snapshot expires.
    public var reclaimable: Int64 {
        guard extFlags & UInt64(EF_MAY_SHARE_BLOCKS) != 0, privateSize >= 0 else { return allocated }
        return min(privateSize, allocated)
    }
}

/// Reads whole directories with `getattrlistbulk`, the fastest way to list a directory on APFS.
/// Never opens files, so offloaded iCloud files are not downloaded.
/// Not thread-safe: give each thread its own lister.
public final class BulkLister {
    static let datalessFlag: UInt32 = 0x4000_0000  // SF_DATALESS

    private static let cmnReturnedAttrs: attrgroup_t = 0x8000_0000
    private static let cmnName: attrgroup_t = 0x0000_0001
    private static let cmnDevID: attrgroup_t = 0x0000_0002
    private static let cmnObjType: attrgroup_t = 0x0000_0008
    private static let cmnModTime: attrgroup_t = 0x0000_0400
    private static let cmnAccTime: attrgroup_t = 0x0000_1000
    private static let cmnFlags: attrgroup_t = 0x0004_0000
    private static let cmnFileID: attrgroup_t = 0x0200_0000
    private static let cmnAddedTime: attrgroup_t = 0x1000_0000
    private static let cmnError: attrgroup_t = 0x2000_0000
    private static let dirMountStatus: attrgroup_t = 0x0000_0004
    private static let fileLinkCount: attrgroup_t = 0x0000_0001
    private static let fileTotalSize: attrgroup_t = 0x0000_0002
    private static let fileAllocSize: attrgroup_t = 0x0000_0004
    private static let cmnExtPrivateSize: attrgroup_t = 0x0000_0008
    private static let cmnExtFlags: attrgroup_t = 0x0000_0200

    private let bufferSize = 256 * 1024
    private let buffer: UnsafeMutableRawPointer
    private var attributes = attrlist()
    private var options: UInt64

    public init(privateSizes: Bool = true) {
        buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = Self.cmnReturnedAttrs | Self.cmnName | Self.cmnError | Self.cmnDevID
            | Self.cmnObjType | Self.cmnModTime | Self.cmnAccTime | Self.cmnFlags | Self.cmnFileID
            | Self.cmnAddedTime
        attributes.dirattr = Self.dirMountStatus
        attributes.fileattr = Self.fileLinkCount | Self.fileTotalSize | Self.fileAllocSize
        if privateSizes {
            attributes.forkattr = Self.cmnExtPrivateSize | Self.cmnExtFlags
            options = UInt64(FSOPT_ATTR_CMN_EXTENDED)
        } else {
            options = 0
        }
    }

    deinit { buffer.deallocate() }

    /// Calls `body` for every entry in the directory. Returns 0, or the errno that stopped the listing
    /// (entries read before the error were still delivered).
    @discardableResult
    public func list(_ path: String, _ body: (inout DirEntry) -> Void) -> Int32 {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd < 0 { return errno }
        defer { close(fd) }
        var entry = DirEntry()
        while true {
            let count = getattrlistbulk(fd, &attributes, buffer, bufferSize, options)
            if count < 0 {
                let err = errno
                if err == EINTR { continue }
                if err == EINVAL && options != 0 {
                    // This file system doesn't take the extended attributes: list without private sizes.
                    attributes.forkattr = 0
                    options = 0
                    continue
                }
                return err
            }
            if count == 0 { return 0 }
            var cursor = buffer
            for _ in 0..<count {
                let length = Int(cursor.loadUnaligned(as: UInt32.self))
                if parse(cursor, into: &entry) { body(&entry) }
                cursor += length
            }
        }
    }

    private func parse(_ start: UnsafeMutableRawPointer, into e: inout DirEntry) -> Bool {
        var p = start + 4
        let returned = p.loadUnaligned(as: attribute_set_t.self)
        p += MemoryLayout<attribute_set_t>.size
        let common = returned.commonattr

        if common & Self.cmnError != 0 {
            let err = p.loadUnaligned(as: UInt32.self)
            p += 4
            if err != 0 { return false }
        }
        guard common & Self.cmnName != 0 else { return false }
        let ref = p.loadUnaligned(as: attrreference_t.self)
        e.name = String(cString: (p + Int(ref.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
        p += MemoryLayout<attrreference_t>.size

        e.device = 0
        if common & Self.cmnDevID != 0 { e.device = p.loadUnaligned(as: Int32.self); p += 4 }
        e.kind = .other
        if common & Self.cmnObjType != 0 {
            switch p.loadUnaligned(as: UInt32.self) {
            case UInt32(VREG.rawValue): e.kind = .file
            case UInt32(VDIR.rawValue): e.kind = .directory
            case UInt32(VLNK.rawValue): e.kind = .symlink
            default: e.kind = .other
            }
            p += 4
        }
        e.modified = 0
        if common & Self.cmnModTime != 0 { e.modified = Int64(p.loadUnaligned(as: timespec.self).tv_sec); p += 16 }
        e.accessed = 0
        if common & Self.cmnAccTime != 0 { e.accessed = Int64(p.loadUnaligned(as: timespec.self).tv_sec); p += 16 }
        e.flags = 0
        if common & Self.cmnFlags != 0 { e.flags = p.loadUnaligned(as: UInt32.self); p += 4 }
        e.fileID = 0
        if common & Self.cmnFileID != 0 { e.fileID = p.loadUnaligned(as: UInt64.self); p += 8 }
        e.added = 0
        if common & Self.cmnAddedTime != 0 { e.added = Int64(p.loadUnaligned(as: timespec.self).tv_sec); p += 16 }

        e.isMountPoint = false
        if returned.dirattr & Self.dirMountStatus != 0 {
            e.isMountPoint = p.loadUnaligned(as: UInt32.self) & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0
            p += 4
        }

        e.linkCount = 1
        e.logical = 0
        e.allocated = 0
        let file = returned.fileattr
        if file & Self.fileLinkCount != 0 { e.linkCount = p.loadUnaligned(as: UInt32.self); p += 4 }
        if file & Self.fileTotalSize != 0 { e.logical = p.loadUnaligned(as: Int64.self); p += 8 }
        if file & Self.fileAllocSize != 0 { e.allocated = p.loadUnaligned(as: Int64.self); p += 8 }

        e.privateSize = -1
        if returned.forkattr & Self.cmnExtPrivateSize != 0 {
            e.privateSize = p.loadUnaligned(as: Int64.self)
            p += 8
        }
        e.extFlags = 0
        if returned.forkattr & Self.cmnExtFlags != 0 {
            e.extFlags = p.loadUnaligned(as: UInt64.self)
            p += 8
        }
        return true
    }
}
