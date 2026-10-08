import CryptoKit
import Foundation

/// The trust anchor the relay publishes and the app pins (SPEC §3.2 step 3,
/// SPEC §6.3).
///
/// SPEC §6.3: "The pin is SHA-256 over DER SubjectPublicKeyInfo, not a hash of
/// the whole certificate or a platform-specific raw public key representation."
/// That is the whole contract: the digest covers exactly the DER bytes of the
/// `SubjectPublicKeyInfo` — the `AlgorithmIdentifier` plus the `BIT STRING` — and
/// is published base64-encoded.
///
/// Proven against a real vector: `Fixtures/relay-spki-pin.json` holds the live
/// relay's SPKI, its raw public key, and the pin the relay itself publishes
/// (`7pcXvn2Kosz4qWgFpUmIao9YQ05bXYTLbfP0IskaeN4=`), with the certificate's
/// Subject Alternative Names deliberately dropped.
public enum SPKIPin {
    /// The DER prefix every P-256 `SubjectPublicKeyInfo` starts with.
    ///
    /// ```text
    /// 30 59                                  SEQUENCE, 89 bytes
    ///    30 13                               SEQUENCE, 19 bytes (AlgorithmIdentifier)
    ///       06 07 2A 86 48 CE 3D 02 01       OID 1.2.840.10045.2.1  id-ecPublicKey
    ///       06 08 2A 86 48 CE 3D 03 01 07    OID 1.2.840.10045.3.1.7 prime256v1
    ///    03 42 00                            BIT STRING, 66 bytes, 0 unused bits
    /// ```
    ///
    /// The BIT STRING's payload is the 65-byte uncompressed point, so the whole
    /// SPKI is 91 bytes and the length octets are fixed — no long-form length,
    /// which is what keeps the wrapping a constant prefix rather than a DER
    /// encoder. This is the only place in the app that composes ASN.1.
    static let p256SubjectPublicKeyInfoPrefix: [UInt8] = [
        0x30, 0x59,
        0x30, 0x13,
        0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
        0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07,
        0x03, 0x42, 0x00,
    ]

    /// Length of a P-256 uncompressed point: `0x04` then X then Y, 32 bytes each.
    public static let rawP256PublicKeyByteCount = 65

    /// Length of the wrapped DER, `26 + 65`.
    public static let derP256SPKIByteCount = p256SubjectPublicKeyInfoPrefix.count + rawP256PublicKeyByteCount

    public enum WrappingError: Error, Sendable, Hashable, CustomStringConvertible {
        /// The input was not 65 bytes.
        case unsupportedRawKeyLength(Int)
        /// The input did not begin with the uncompressed-point tag `0x04`.
        case unsupportedPointFormat(UInt8)

        public var description: String {
            switch self {
            case .unsupportedRawKeyLength(let count):
                "raw P-256 public key must be 65 bytes, got \(count)"
            case .unsupportedPointFormat(let tag):
                "raw P-256 public key must start with 0x04 (uncompressed), got \(tag)"
            }
        }
    }

    // MARK: - Wrapping

    /// Wraps a raw P-256 public key into DER `SubjectPublicKeyInfo`.
    ///
    /// The input is the 65-byte uncompressed point `04 || X || Y` — exactly what
    /// `SecKeyCopyExternalRepresentation` returns for a P-256 `SecKey`, which is
    /// how the app obtains the server's key from a completed TLS handshake.
    ///
    /// - Throws: ``WrappingError`` when the input is not a P-256 uncompressed
    ///   point. A wrong length is refused rather than encoded, because a
    ///   fixed-length prefix on the wrong payload produces a *valid-looking* DER
    ///   that hashes to a pin nobody published — a silent pin mismatch instead of
    ///   an error.
    public static func derSPKI(fromRawP256PublicKey raw: Data) throws -> Data {
        guard raw.count == rawP256PublicKeyByteCount else {
            throw WrappingError.unsupportedRawKeyLength(raw.count)
        }
        guard let tag = raw.first else {
            throw WrappingError.unsupportedRawKeyLength(0)
        }
        guard tag == 0x04 else {
            throw WrappingError.unsupportedPointFormat(tag)
        }
        var der = Data(p256SubjectPublicKeyInfoPrefix)
        der.append(raw)
        return der
    }

    // MARK: - Hashing

    /// SHA-256 over DER `SubjectPublicKeyInfo`, base64-encoded — the published
    /// pin form (SPEC §6.3).
    ///
    /// Standard base64 with padding, matching the relay: the live value
    /// `7pcXvn2Kosz4qWgFpUmIao9YQ05bXYTLbfP0IskaeN4=` ends in `=`.
    public static func pin(derSPKI der: Data) -> String {
        base64(Data(SHA256.hash(data: der)))
    }

    /// Computes the pin from a raw P-256 public key, wrapping it first.
    public static func pin(rawP256PublicKey raw: Data) throws -> String {
        pin(derSPKI: try derSPKI(fromRawP256PublicKey: raw))
    }

    // MARK: - Comparing

    /// Whether two pins are the same.
    ///
    /// Compares decoded bytes when both sides are valid base64, so a pin that
    /// arrived with a different padding is not treated as a mismatch; falls back
    /// to a literal comparison when either side does not decode, so a malformed
    /// stored pin still fails closed.
    ///
    /// The comparison itself is length-checked then byte-accumulated rather than
    /// `==`, because a pin is compared against host-supplied input.
    public static func matches(pin expected: String, pin actual: String) -> Bool {
        guard let expectedBytes = Data(base64Encoded: expected),
              let actualBytes = Data(base64Encoded: actual)
        else { return constantTimeEquals(Array(expected.utf8), Array(actual.utf8)) }
        return constantTimeEquals([UInt8](expectedBytes), [UInt8](actualBytes))
    }

    /// Whether a pin matches a DER SPKI directly.
    public static func matches(pin expected: String, derSPKI der: Data) -> Bool {
        matches(pin: expected, pin: pin(derSPKI: der))
    }

    /// Whether a pin matches a raw P-256 public key. A key that cannot be wrapped
    /// is a non-match, never an error: this answers "does the certificate still
    /// match what I paired with", and for an unusable key the answer is no.
    public static func matches(pin expected: String, rawP256PublicKey raw: Data) -> Bool {
        guard let actual = try? pin(rawP256PublicKey: raw) else { return false }
        return matches(pin: expected, pin: actual)
    }

    // MARK: - Primitives

    static func base64(_ data: Data) -> String {
        data.base64EncodedString()
    }

    static func constantTimeEquals(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}
