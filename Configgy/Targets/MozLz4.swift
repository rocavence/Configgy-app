import Foundation

/// Mozilla's mozLz4 container (Zen's zen-sessions.jsonlz4). Every read is
/// bounds-checked: a damaged file, or one from another Mac, returns nil instead
/// of crashing.
enum MozLz4 {
    static let magic = Array("mozLz40\0".utf8)

    static func decode(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 12, Array(bytes[0..<8]) == magic else { return nil }
        let size = Int(bytes[8]) | Int(bytes[9]) << 8 | Int(bytes[10]) << 16 | Int(bytes[11]) << 24
        // Session files are a few MB; refuse absurd sizes from a corrupt header.
        guard size >= 0, size <= 512 << 20 else { return nil }
        return decompress(Array(bytes[12...]), size: size)
    }

    /// A single all-literal LZ4 block: valid, uncompressed. Zen re-compresses on its next save.
    static func encode(_ json: Data) -> Data {
        let input = [UInt8](json)
        var out = magic
        let n = UInt32(input.count)
        out += [UInt8(n & 0xff), UInt8(n >> 8 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 24 & 0xff)]
        let length = input.count
        out.append(UInt8(min(length, 15) << 4))
        if length >= 15 {
            var rest = length - 15
            while rest >= 255 { out.append(255); rest -= 255 }
            out.append(UInt8(rest))
        }
        out += input
        return Data(out)
    }

    private static func decompress(_ src: [UInt8], size: Int) -> Data? {
        var dst = [UInt8](repeating: 0, count: size)
        var s = 0, d = 0
        func byte() -> Int? {
            guard s < src.count else { return nil }
            defer { s += 1 }
            return Int(src[s])
        }
        while s < src.count {
            guard let token = byte() else { return nil }
            var literal = token >> 4
            if literal == 15 {
                while true {
                    guard let x = byte() else { return nil }
                    literal += x
                    if x != 255 { break }
                }
            }
            guard s + literal <= src.count, d + literal <= size else { return nil }
            dst.replaceSubrange(d..<d + literal, with: src[s..<s + literal])
            s += literal; d += literal
            if s >= src.count { break }
            guard let lo = byte(), let hi = byte() else { return nil }
            let offset = lo | hi << 8
            var match = token & 15
            if match == 15 {
                while true {
                    guard let x = byte() else { return nil }
                    match += x
                    if x != 255 { break }
                }
            }
            match += 4
            guard offset > 0, offset <= d, d + match <= size else { return nil }
            for i in 0..<match { dst[d + i] = dst[d - offset + i] }
            d += match
        }
        return Data(dst[0..<d])
    }
}
