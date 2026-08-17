import Foundation
import ModelStore
import Testing

// FIPS 180-4 / NIST canonical vectors.

@Test func emptyMessageMatchesCanonicalVector() {
    #expect(
        SHA256Digest.hash(data: Data())
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    )
}

@Test func abcMatchesCanonicalVector() {
    #expect(
        SHA256Digest.hash(data: Data("abc".utf8))
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )
}

/// The 448-bit two-block FIPS vector — exercises padding that spills into a
/// second compression block.
@Test func twoBlockMessageMatchesCanonicalVector() {
    let message = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
    #expect(
        SHA256Digest.hash(data: Data(message.utf8))
            == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
    )
}

/// The canonical long vector: one million repetitions of "a" (0x61).
@Test func millionRepeatedBytesMatchesCanonicalVector() {
    let message = Data(repeating: 0x61, count: 1_000_000)
    #expect(
        SHA256Digest.hash(data: message)
            == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
    )
}

@Test(arguments: [1, 7, 63, 64, 65, 128])
func incrementalUpdatesMatchOneShot(chunkSize: Int) {
    let payload = Data((0..<300).map { UInt8($0 % 251) })
    let oneShot = SHA256Digest.hash(data: payload)

    var digest = SHA256Digest()
    var index = 0
    while index < payload.count {
        let end = min(index + chunkSize, payload.count)
        digest.update(data: payload.subdata(in: index..<end))
        index = end
    }
    #expect(digest.finalizedHex() == oneShot)
}

/// Byte-level hashing is encoding-agnostic; multibyte UTF-8 (CJK, emoji) must
/// hash identically whether fed whole or split mid-scalar.
@Test func multibyteUTF8SplitAnywhereMatchesOneShot() {
    let payload = Data("héllo 🌍 中文测试".utf8)
    let oneShot = SHA256Digest.hash(data: payload)
    for splitAt in 0...payload.count {
        var digest = SHA256Digest()
        digest.update(data: payload.subdata(in: 0..<splitAt))
        digest.update(data: payload.subdata(in: splitAt..<payload.count))
        #expect(digest.finalizedHex() == oneShot)
    }
}

@Test func finalizedHexIsNonMutating() {
    var digest = SHA256Digest()
    digest.update(data: Data("ab".utf8))
    _ = digest.finalizedHex()
    digest.update(data: Data("c".utf8))
    #expect(
        digest.finalizedHex()
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )
}
