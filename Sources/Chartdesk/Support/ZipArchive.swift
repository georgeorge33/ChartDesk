import Compression
import Foundation

/// Enough of a zip reader to take one file out of a small archive.
///
/// The X-Plane Scenery Gateway hands an airport over as a zip, base64'd inside a JSON
/// answer, with the airport file deflated inside it. Foundation has no zip reader on the Mac,
/// and starting `unzip` for one file is a process per airport — but the format is simple
/// enough to read directly: a directory at the end of the archive says where each file starts
/// and how it was packed, and Apple's Compression framework does the deflate. Stored and
/// deflated files only, and no zip64: an airport's archive is a megabyte, not four gigabytes.
enum ZipArchive {

    struct Entry {
        let name: String
        /// 0 for stored as it is, 8 for deflated.
        let method: UInt16
        /// Bytes in the archive, and bytes once unpacked.
        let packed: Int
        let size: Int
        /// Where the file's own header starts.
        let offset: Int
    }

    /// The first file whose name passes `wanted`, unpacked, or nil if there is none or it
    /// will not unpack.
    static func file(in archive: Data, where wanted: (String) -> Bool) -> Data? {
        let bytes = [UInt8](archive)
        for entry in entries(bytes) where wanted(entry.name) {
            return extract(entry, from: bytes)
        }
        return nil
    }

    /// Every file the archive's directory lists.
    static func names(in archive: Data) -> [String] {
        entries([UInt8](archive)).map(\.name)
    }

    private static func entries(_ bytes: [UInt8]) -> [Entry] {
        // The end-of-directory record: twenty-two bytes, then a comment of up to 64KB, so it
        // is looked for backwards from the end.
        guard bytes.count >= 22 else { return [] }
        let lowest = max(0, bytes.count - 22 - 65_535)
        var end = -1
        var at = bytes.count - 22
        while at >= lowest {
            if word(bytes, at) == 0x0605_4B50 {
                end = at
                break
            }
            at -= 1
        }
        guard end >= 0 else { return [] }

        let count = Int(half(bytes, end + 10))
        var cursor = Int(word(bytes, end + 16))
        var found: [Entry] = []
        for _ in 0..<count {
            guard cursor >= 0, cursor + 46 <= bytes.count,
                  word(bytes, cursor) == 0x0201_4B50 else { break }
            let length = Int(half(bytes, cursor + 28))
            let extra = Int(half(bytes, cursor + 30))
            let comment = Int(half(bytes, cursor + 32))
            guard cursor + 46 + length <= bytes.count else { break }
            let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + length)], as: UTF8.self)
            found.append(Entry(name: name,
                               method: half(bytes, cursor + 10),
                               packed: Int(word(bytes, cursor + 20)),
                               size: Int(word(bytes, cursor + 24)),
                               offset: Int(word(bytes, cursor + 42))))
            cursor += 46 + length + extra + comment
        }
        return found
    }

    private static func extract(_ entry: Entry, from bytes: [UInt8]) -> Data? {
        // The sizes come from the directory, which always has them; the file's own header
        // can leave them out and put them after the data instead.
        let header = entry.offset
        guard header >= 0, header + 30 <= bytes.count,
              word(bytes, header) == 0x0403_4B50 else { return nil }
        let start = header + 30 + Int(half(bytes, header + 26)) + Int(half(bytes, header + 28))
        guard entry.packed >= 0, start + entry.packed <= bytes.count else { return nil }

        switch entry.method {
        case 0:
            guard entry.packed == entry.size else { return nil }
            return Data(bytes[start..<(start + entry.packed)])
        case 8:
            guard entry.size > 0 else { return Data() }
            // Nothing an airport needs is anywhere near this; a header that says otherwise
            // is not to be believed with an allocation.
            guard entry.size <= 256 << 20 else { return nil }
            var out = [UInt8](repeating: 0, count: entry.size)
            let size = entry.size, packed = entry.packed
            let written = bytes.withUnsafeBufferPointer { source -> Int in
                out.withUnsafeMutableBufferPointer { destination -> Int in
                    guard let from = source.baseAddress, let into = destination.baseAddress
                    else { return 0 }
                    // COMPRESSION_ZLIB is raw deflate, which is what a zip holds.
                    return compression_decode_buffer(into, size, from + start, packed,
                                                     nil, COMPRESSION_ZLIB)
                }
            }
            guard written == entry.size else { return nil }
            return Data(out)
        default:
            return nil
        }
    }

    /// Little-endian, as everything in a zip is.
    private static func half(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        guard at >= 0, at + 2 <= bytes.count else { return 0 }
        let low = UInt16(bytes[at])
        let high = UInt16(bytes[at + 1])
        return low | (high << 8)
    }

    private static func word(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= bytes.count else { return 0 }
        let first = UInt32(bytes[at])
        let second = UInt32(bytes[at + 1]) << 8
        let third = UInt32(bytes[at + 2]) << 16
        let fourth = UInt32(bytes[at + 3]) << 24
        return first | second | third | fourth
    }
}
