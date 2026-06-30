import Foundation

// Decode Mozilla's mozLz4 container (used by Zen's zen-sessions.jsonlz4) → raw bytes.
// Port of the LZ4 block decoder in the original Node tool.
enum MozLz4 {
    static func decode(_ buf: Data) -> Data? {
        let b = [UInt8](buf)
        guard b.count > 12 else { return nil }
        let magic = String(bytes: b[0..<8], encoding: .isoLatin1)
        guard magic == "mozLz40\0" else { return nil }
        let destLen = Int(b[8]) | (Int(b[9]) << 8) | (Int(b[10]) << 16) | (Int(b[11]) << 24)
        return lz4dec(Array(b[12...]), destLen)
    }

    // Encode raw bytes into a mozLz4 container as a single all-literal LZ4 block.
    // Zen reads it fine and re-compresses on its next save. (Mirrors the Node tool.)
    static func encode(_ json: Data) -> Data {
        let input = [UInt8](json)
        var out = [UInt8]()
        out.append(contentsOf: Array("mozLz40\0".utf8))            // 8-byte magic
        let n = UInt32(input.count)
        out.append(UInt8(n & 0xff)); out.append(UInt8((n >> 8) & 0xff))
        out.append(UInt8((n >> 16) & 0xff)); out.append(UInt8((n >> 24) & 0xff))
        let L = input.count
        out.append(UInt8((L >= 15 ? 15 : L) << 4))                 // token: literal length in high nibble
        if L >= 15 { var r = L - 15; while r >= 255 { out.append(255); r -= 255 }; out.append(UInt8(r)) }
        out.append(contentsOf: input)
        return Data(out)
    }

    private static func lz4dec(_ src: [UInt8], _ destLen: Int) -> Data {
        var dst = [UInt8](repeating: 0, count: max(destLen, 0))
        var s = 0, d = 0
        let n = src.count
        while s < n {
            let tok = Int(src[s]); s += 1
            var lit = tok >> 4
            if lit == 15 { var x = 0; repeat { x = Int(src[s]); s += 1; lit += x } while x == 255 }
            if lit > 0 { for i in 0..<lit { dst[d + i] = src[s + i] }; s += lit; d += lit }
            if s >= n { break }
            let off = Int(src[s]) | (Int(src[s + 1]) << 8); s += 2
            var mlen = tok & 15
            if mlen == 15 { var x = 0; repeat { x = Int(src[s]); s += 1; mlen += x } while x == 255 }
            mlen += 4
            var mp = d - off
            for _ in 0..<mlen { dst[d] = dst[mp]; d += 1; mp += 1 }
        }
        return Data(dst[0..<d])
    }
}
