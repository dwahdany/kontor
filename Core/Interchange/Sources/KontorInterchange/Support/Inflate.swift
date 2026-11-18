import Foundation

/// A small, dependency-free DEFLATE (RFC 1951) decompressor.
///
/// Portfolio Performance can store its XML inside a ZIP container. Decoding that container with
/// pure Swift keeps the package portable (no zlib / Compression framework needed).
enum Inflate {
    enum Failure: Error { case truncated, corrupt, tooLarge }

    private struct BitReader {
        let input: UnsafeBufferPointer<UInt8>
        var position = 0
        var bitBuffer: UInt32 = 0
        var bitCount = 0

        mutating func bits(_ n: Int) throws -> Int {
            while bitCount < n {
                guard position < input.count else { throw Failure.truncated }
                bitBuffer |= UInt32(input[position]) << UInt32(bitCount)
                position += 1
                bitCount += 8
            }
            let value = Int(bitBuffer & ((1 << UInt32(n)) - 1))
            bitBuffer >>= UInt32(n)
            bitCount -= n
            return value
        }

        mutating func alignToByte() {
            bitBuffer = 0
            bitCount = 0
        }
    }

    /// Canonical Huffman decoding table (count-per-length + symbols sorted by code).
    private struct Huffman {
        var counts = [UInt16](repeating: 0, count: 16)
        var symbols: [UInt16]

        init(lengths: ArraySlice<UInt8>) {
            symbols = [UInt16](repeating: 0, count: lengths.count)
            for l in lengths { counts[Int(l)] += 1 }
            counts[0] = 0
            var offsets = [Int](repeating: 0, count: 16)
            for i in 1..<16 { offsets[i] = offsets[i - 1] + Int(counts[i - 1]) }
            for (symbol, l) in lengths.enumerated() where l != 0 {
                symbols[offsets[Int(l)]] = UInt16(symbol)
                offsets[Int(l)] += 1
            }
        }

        func decode(_ reader: inout BitReader) throws -> Int {
            var code = 0, first = 0, index = 0
            for length in 1..<16 {
                code |= try reader.bits(1)
                let count = Int(counts[length])
                if code - count < first { return Int(symbols[index + (code - first)]) }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            throw Failure.corrupt
        }
    }

    private static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distanceExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    private static let codeLengthOrder: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    private static let fixedTables: (Huffman, Huffman) = {
        var lengths = [UInt8](repeating: 8, count: 288)
        for i in 144..<256 { lengths[i] = 9 }
        for i in 256..<280 { lengths[i] = 7 }
        return (Huffman(lengths: lengths[...]), Huffman(lengths: [UInt8](repeating: 5, count: 30)[...]))
    }()

    /// Decompresses a raw DEFLATE stream.
    /// - Parameter limit: maximum accepted output size (guards against decompression bombs).
    static func inflate(_ data: some Collection<UInt8>, expectedSize: Int = 0, limit: Int = 1 << 31) throws -> [UInt8] {
        let source = Array(data)
        var output = [UInt8]()
        // `expectedSize` comes from an untrusted archive directory: use it as a hint only, bounded by
        // what DEFLATE can possibly expand to (at most 1032:1) and by the caller's limit.
        output.reserveCapacity(min(max(expectedSize, source.count * 3), source.count * 1032 + 64, limit))
        try source.withUnsafeBufferPointer { buffer in
            var reader = BitReader(input: buffer)
            var isFinal = false
            while !isFinal {
                isFinal = try reader.bits(1) == 1
                switch try reader.bits(2) {
                case 0:
                    reader.alignToByte()
                    guard reader.position + 4 <= buffer.count else { throw Failure.truncated }
                    let length = Int(buffer[reader.position]) | Int(buffer[reader.position + 1]) << 8
                    let inverse = Int(buffer[reader.position + 2]) | Int(buffer[reader.position + 3]) << 8
                    guard length == ~inverse & 0xFFFF else { throw Failure.corrupt }
                    reader.position += 4
                    guard reader.position + length <= buffer.count else { throw Failure.truncated }
                    guard output.count + length <= limit else { throw Failure.tooLarge }
                    output.append(contentsOf: UnsafeBufferPointer(rebasing: buffer[reader.position..<reader.position + length]))
                    reader.position += length
                case 1:
                    try block(&reader, fixedTables.0, fixedTables.1, &output, limit)
                case 2:
                    let literalCount = try reader.bits(5) + 257
                    let distanceCount = try reader.bits(5) + 1
                    let codeCount = try reader.bits(4) + 4
                    guard literalCount <= 286, distanceCount <= 30 else { throw Failure.corrupt }
                    var codeLengths = [UInt8](repeating: 0, count: 19)
                    for i in 0..<codeCount { codeLengths[codeLengthOrder[i]] = UInt8(try reader.bits(3)) }
                    let codeTable = Huffman(lengths: codeLengths[...])
                    var lengths = [UInt8](repeating: 0, count: literalCount + distanceCount)
                    var index = 0
                    while index < lengths.count {
                        let symbol = try codeTable.decode(&reader)
                        if symbol < 16 {
                            lengths[index] = UInt8(symbol)
                            index += 1
                            continue
                        }
                        var value: UInt8 = 0
                        var repeatCount: Int
                        switch symbol {
                        case 16:
                            guard index > 0 else { throw Failure.corrupt }
                            value = lengths[index - 1]
                            repeatCount = 3 + (try reader.bits(2))
                        case 17: repeatCount = 3 + (try reader.bits(3))
                        default: repeatCount = 11 + (try reader.bits(7))
                        }
                        guard index + repeatCount <= lengths.count else { throw Failure.corrupt }
                        while repeatCount > 0 {
                            lengths[index] = value
                            index += 1
                            repeatCount -= 1
                        }
                    }
                    guard lengths[256] != 0 else { throw Failure.corrupt }
                    try block(&reader, Huffman(lengths: lengths[..<literalCount]), Huffman(lengths: lengths[literalCount...]), &output, limit)
                default:
                    throw Failure.corrupt
                }
            }
        }
        return output
    }

    private static func block(_ reader: inout BitReader, _ literals: Huffman, _ distances: Huffman, _ output: inout [UInt8], _ limit: Int) throws {
        while true {
            let symbol = try literals.decode(&reader)
            if symbol < 256 {
                guard output.count < limit else { throw Failure.tooLarge }
                output.append(UInt8(symbol))
            } else if symbol == 256 {
                return
            } else {
                let li = symbol - 257
                guard li < lengthBase.count else { throw Failure.corrupt }
                let length = lengthBase[li] + (try reader.bits(lengthExtra[li]))
                let di = try distances.decode(&reader)
                guard di < distanceBase.count else { throw Failure.corrupt }
                let distance = distanceBase[di] + (try reader.bits(distanceExtra[di]))
                guard distance <= output.count else { throw Failure.corrupt }
                guard output.count + length <= limit else { throw Failure.tooLarge }
                var from = output.count - distance
                for _ in 0..<length {
                    output.append(output[from])
                    from += 1
                }
            }
        }
    }
}

/// Minimal read-only ZIP reader (stored + deflated entries, no ZIP64, no encryption).
struct ZipArchive {
    struct Entry {
        var name: String
        var method: Int
        var isEncrypted: Bool
        var compressedSize: Int
        var uncompressedSize: Int
        var crc32: UInt32
        var localHeaderOffset: Int
    }

    enum Failure: Error { case notAnArchive, corrupt, encrypted, unsupportedMethod(Int), checksumMismatch }

    static func isZip(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B && bytes[2] == 0x03 && bytes[3] == 0x04
    }

    let bytes: [UInt8]
    let entries: [Entry]

    init(_ bytes: [UInt8]) throws {
        self.bytes = bytes
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        // Locate the end-of-central-directory record (it may be followed by a comment).
        guard bytes.count >= 22 else { throw Failure.notAnArchive }
        var eocd = -1
        var probe = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 65_535)
        while probe >= lowest {
            if bytes[probe] == 0x50, bytes[probe + 1] == 0x4B, bytes[probe + 2] == 0x05, bytes[probe + 3] == 0x06 {
                eocd = probe
                break
            }
            probe -= 1
        }
        guard eocd >= 0 else { throw Failure.notAnArchive }
        let count = u16(eocd + 10)
        var offset = u32(eocd + 16)
        var entries: [Entry] = []
        for _ in 0..<count {
            guard offset + 46 <= bytes.count, u32(offset) == 0x0201_4B50 else { throw Failure.corrupt }
            let nameLength = u16(offset + 28), extraLength = u16(offset + 30), commentLength = u16(offset + 32)
            guard offset + 46 + nameLength <= bytes.count else { throw Failure.corrupt }
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            entries.append(Entry(
                name: name, method: u16(offset + 10), isEncrypted: u16(offset + 8) & 1 != 0,
                compressedSize: u32(offset + 20), uncompressedSize: u32(offset + 24),
                crc32: UInt32(truncatingIfNeeded: u32(offset + 16)), localHeaderOffset: u32(offset + 42)
            ))
            offset += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    func contents(of entry: Entry, limit: Int = 1 << 31) throws -> [UInt8] {
        guard !entry.isEncrypted else { throw Failure.encrypted }
        let o = entry.localHeaderOffset
        guard o + 30 <= bytes.count, bytes[o] == 0x50, bytes[o + 1] == 0x4B, bytes[o + 2] == 0x03, bytes[o + 3] == 0x04 else {
            throw Failure.corrupt
        }
        let nameLength = Int(bytes[o + 26]) | Int(bytes[o + 27]) << 8
        let extraLength = Int(bytes[o + 28]) | Int(bytes[o + 29]) << 8
        let start = o + 30 + nameLength + extraLength
        guard start + entry.compressedSize <= bytes.count else { throw Failure.corrupt }
        let payload = bytes[start..<(start + entry.compressedSize)]
        let result: [UInt8]
        switch entry.method {
        case 0: result = Array(payload)
        case 8:
            do {
                result = try Inflate.inflate(payload, expectedSize: entry.uncompressedSize, limit: limit)
            } catch {
                throw Failure.corrupt
            }
        default: throw Failure.unsupportedMethod(entry.method)
        }
        guard CRC32.checksum(result) == entry.crc32 else { throw Failure.checksumMismatch }
        return result
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
