import Foundation

/// Pure-Swift SHA-256 (FIPS 180-4). CryptoKit is Apple-only and swift-crypto is
/// not a dependency, so download verification carries its own implementation.
/// Supports one-shot (`hash(data:)`) and incremental (`update`/`finalizedHex`)
/// use so large files can be verified without loading them into memory.
public struct SHA256Digest: Sendable {
    private var state: [UInt32] = [
        0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
        0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
    ]
    private var pending: [UInt8] = []
    private var totalBytes: UInt64 = 0

    public init() {}

    /// Lowercase hex SHA-256 of `data` in one shot.
    public static func hash(data: Data) -> String {
        var digest = SHA256Digest()
        digest.update(data: data)
        return digest.finalizedHex()
    }

    /// Absorbs the next chunk of the message.
    public mutating func update(data: Data) {
        totalBytes &+= UInt64(data.count)
        pending.append(contentsOf: data)
        var offset = 0
        while pending.count - offset >= 64 {
            Self.compress(block: pending[offset..<(offset + 64)], into: &state)
            offset += 64
        }
        if offset > 0 {
            pending.removeFirst(offset)
        }
    }

    /// Lowercase hex digest of everything absorbed so far. Non-mutating: the
    /// digest can keep absorbing after a call.
    public func finalizedHex() -> String {
        var finalState = state
        var block = pending
        let bitLength = totalBytes &* 8
        block.append(0x80)
        while block.count % 64 != 56 {
            block.append(0)
        }
        var shift = 56
        while shift >= 0 {
            block.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
            shift -= 8
        }
        var offset = 0
        while offset < block.count {
            Self.compress(block: block[offset..<(offset + 64)], into: &finalState)
            offset += 64
        }
        return Self.hex(finalState)
    }

    private static let roundConstants: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5,
        0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3,
        0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc,
        0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7,
        0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13,
        0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3,
        0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5,
        0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208,
        0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]

    private static func compress(block: ArraySlice<UInt8>, into state: inout [UInt32]) {
        var w = [UInt32](repeating: 0, count: 64)
        let start = block.startIndex
        for i in 0..<16 {
            let j = start + 4 * i
            w[i] = (UInt32(block[j]) << 24)
                | (UInt32(block[j + 1]) << 16)
                | (UInt32(block[j + 2]) << 8)
                | UInt32(block[j + 3])
        }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }

        var a = state[0]
        var b = state[1]
        var c = state[2]
        var d = state[3]
        var e = state[4]
        var f = state[5]
        var g = state[6]
        var h = state[7]

        for i in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = h &+ s1 &+ ch &+ roundConstants[i] &+ w[i]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            h = g
            g = f
            f = e
            e = d &+ t1
            d = c
            c = b
            b = a
            a = t1 &+ t2
        }

        state[0] &+= a
        state[1] &+= b
        state[2] &+= c
        state[3] &+= d
        state[4] &+= e
        state[5] &+= f
        state[6] &+= g
        state[7] &+= h
    }

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }

    private static func hex(_ words: [UInt32]) -> String {
        var out = String()
        out.reserveCapacity(64)
        for word in words {
            let digits = String(word, radix: 16)
            out.append(String(repeating: "0", count: 8 - digits.count))
            out.append(digits)
        }
        return out
    }
}
