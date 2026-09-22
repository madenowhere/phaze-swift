// The AUTHENTICATOR half — producing WebAuthn assertions from a native app, with no browser.
// phaze-auth's `authenticator.rs`, in Swift: the same bytes, so the verifier the server already
// runs accepts them unchanged and the public key stores in the same COSE_Key form a browser
// passkey uses. Origin and rpIdHash binding are inherited from WebAuthn's structures rather than
// reinvented, which is the whole reason for emitting them instead of signing a bare nonce.
//
// TWO BACKENDS, ONE SHAPE. `SoftwareKey` holds the key in process (CryptoKit P-256) and works on
// every machine with no OS involvement; `EnclaveKey` holds it in the Secure Enclave. Everything
// else is written against `Signer`, so which one is in use never reaches a caller.
import CryptoKit
import Foundation

/// A P-256 key that can sign, wherever it happens to live.
public protocol Signer {
    /// The public half as SEC1 uncompressed `04‖X‖Y` (65 bytes for P-256).
    func publicSEC1() throws -> Data
    /// Sign `message` as ES256 — SHA-256 the message, sign the digest — returning ASN.1 DER,
    /// the form the server's `Signature::from_der` reads. Takes the MESSAGE, not a digest.
    func signDER(_ message: Data) throws -> Data
    /// Whether producing a signature actually verified the human. THE BACKEND ANSWERS THIS: it
    /// sets WebAuthn's `UV` flag, and a caller that could pass it in could claim a verification
    /// that never happened.
    var userVerified: Bool { get }
    /// For display. Not a security property.
    var describe: String { get }
}

/// A P-256 key held in process — no keychain, no entitlement, every machine.
///
/// THE HONEST LIMITS: the scalar is exportable by whoever can read wherever the caller puts it,
/// and there is no user-verification gate, so `userVerified` is always false. A machine
/// credential, not a second factor.
public struct SoftwareKey: Signer {
    private let key: P256.Signing.PrivateKey

    public init() {
        key = P256.Signing.PrivateKey()
    }

    /// Reload from the 32-byte scalar `bytes` produced.
    public init(bytes: Data) throws {
        key = try P256.Signing.PrivateKey(rawRepresentation: bytes)
    }

    /// The 32-byte scalar. SECRET — persist it the way a private key deserves.
    public var bytes: Data { key.rawRepresentation }

    public func publicSEC1() throws -> Data { key.publicKey.x963Representation }
    public func signDER(_ message: Data) throws -> Data { try key.signature(for: message).derRepresentation }
    public var userVerified: Bool { false }
    public var describe: String { "software P-256 (in-process key)" }
}

/// The three byte strings a WebAuthn assertion is, ready for the server's `verify_assertion`.
public struct Assertion {
    public let authenticatorData: Data
    public let clientDataJSON: Data
    /// ASN.1 DER.
    public let signature: Data
}

/// What a registration produces: the `attestationObject` the server parses, and the credential
/// id it will be looked up by afterwards — chosen HERE, since a native signer has no
/// authenticator to return one; it serves purely as the lookup key.
public struct Registration {
    public let attestationObject: Data
    public let credentialId: Data
}

/// The AAGUID phaze's native authenticator stamps on every credential it registers. A CLAIM, not
/// evidence: nothing signs or verifies it. What it buys is that a native credential is
/// distinguishable at a glance from a row of zeros. Fixed for all time — an AAGUID names the
/// authenticator, not the install. The same sixteen bytes as the Rust half's `NATIVE_AAGUID`.
public let nativeAAGUID = Data([
    0x91, 0xee, 0xc8, 0xac, 0x7c, 0x27, 0x44, 0x85, 0x9d, 0x3b, 0x4b, 0x98, 0xf7, 0xb3, 0x02, 0x7e,
])

/// WebAuthn's authenticator-data flags — the values `webauthn.rs` reads.
private let flagUP: UInt8 = 0x01
private let flagUV: UInt8 = 0x04
private let flagAT: UInt8 = 0x40

public struct AuthenticatorError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// The public key as a COSE_Key — the form `credentials.public_key` stores and the server's
/// `cose_key_to_public` reads. All five labels are written, as the Rust half writes them: a
/// two-entry map would work for this reader and be wrong for any other that reads the column.
public func coseKey(_ signer: any Signer) throws -> Data {
    let sec1 = try signer.publicSEC1()
    guard sec1.count == 65, sec1[sec1.startIndex] == 0x04 else {
        throw AuthenticatorError(message: "expected 65-byte uncompressed SEC1 starting 0x04, got \(sec1.count) bytes")
    }
    let x = sec1.subdata(in: sec1.startIndex + 1 ..< sec1.startIndex + 33)
    let y = sec1.subdata(in: sec1.startIndex + 33 ..< sec1.startIndex + 65)
    // CBOR, by hand — the map is fixed:
    //   a5            map(5)
    //   01 02         kty: EC2
    //   03 26         alg: ES256 (-7)
    //   20 01         crv: P-256 (-1 → 1)
    //   21 58 20 …    x  (-2 → bytes(32))
    //   22 58 20 …    y  (-3 → bytes(32))
    var out = Data([0xa5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20])
    out.append(x)
    out.append(contentsOf: [0x22, 0x58, 0x20])
    out.append(y)
    return out
}

/// `clientDataJSON` — exactly the three fields the server reads. `kind` is `webauthn.create` for
/// a registration and `webauthn.get` for an assertion; the server checks it, so the two
/// ceremonies cannot be confused. The bytes returned are the bytes signed and sent.
public func clientData(kind: String, challenge: String, origin: String) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: ["type": kind, "challenge": challenge, "origin": origin],
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
}

/// A CBOR byte string header for `count` bytes.
private func cborBytesHeader(_ count: Int) -> Data {
    if count < 24 { return Data([0x40 | UInt8(count)]) }
    if count < 256 { return Data([0x58, UInt8(count)]) }
    return Data([0x59, UInt8(count >> 8), UInt8(count & 0xff)])
}

/// Build a `none`-attestation registration for this key — the SAME request a browser makes, so
/// the server's existing register/finish reads it and nothing there learns about native keys.
/// `none` is not a downgrade: the browser ceremony already requests it.
public func attestationObject(_ signer: any Signer, rpId: String, credentialId: Data) throws -> Registration {
    guard !credentialId.isEmpty, credentialId.count <= Int(UInt16.max) else {
        throw AuthenticatorError(message: "credential id must be 1..65535 bytes")
    }
    let cose = try coseKey(signer)

    // attestedCredentialData: aaguid[16] ‖ credIdLen[2 BE] ‖ credId ‖ COSE_Key
    var acd = Data()
    acd.append(nativeAAGUID)
    acd.append(contentsOf: [UInt8(credentialId.count >> 8), UInt8(credentialId.count & 0xff)])
    acd.append(credentialId)
    acd.append(cose)

    // authData: rpIdHash[32] ‖ flags[1] ‖ signCount[4 BE] ‖ attestedCredentialData.
    // AT is what marks attestedCredentialData present; the parser rejects its absence.
    var authData = Data(SHA256.hash(data: Data(rpId.utf8)))
    authData.append(flagUP | flagAT | (signer.userVerified ? flagUV : 0))
    authData.append(contentsOf: [0, 0, 0, 0])
    authData.append(acd)

    // { "fmt": "none", "attStmt": {}, "authData": <bytes> } — in that order, as the Rust half.
    var obj = Data([0xa3])
    obj.append(contentsOf: [0x63] + Array("fmt".utf8) + [0x64] + Array("none".utf8))
    obj.append(contentsOf: [0x67] + Array("attStmt".utf8) + [0xa0])
    obj.append(contentsOf: [0x68] + Array("authData".utf8))
    obj.append(cborBytesHeader(authData.count))
    obj.append(authData)
    return Registration(attestationObject: obj, credentialId: credentialId)
}

/// Sign a server-issued challenge as a WebAuthn assertion. `signCount: 0` is correct for keys
/// that keep no counter: the verifier skips the clone check when either side is zero, the same
/// accommodation synced passkeys rely on.
public func assert(_ signer: any Signer, rpId: String, origin: String, challenge: String, signCount: UInt32 = 0) throws -> Assertion {
    // rpIdHash[32] ‖ flags[1] ‖ signCount[4 BE] — the fixed 37-byte prefix the parser reads. No
    // attestedCredentialData: that belongs to a registration.
    var authenticatorData = Data(SHA256.hash(data: Data(rpId.utf8)))
    authenticatorData.append(flagUP | (signer.userVerified ? flagUV : 0))
    authenticatorData.append(contentsOf: [
        UInt8(signCount >> 24), UInt8((signCount >> 16) & 0xff), UInt8((signCount >> 8) & 0xff), UInt8(signCount & 0xff),
    ])
    let clientDataJSON = try clientData(kind: "webauthn.get", challenge: challenge, origin: origin)
    var signed = authenticatorData
    signed.append(Data(SHA256.hash(data: clientDataJSON)))
    let signature = try signer.signDER(signed)
    return Assertion(authenticatorData: authenticatorData, clientDataJSON: clientDataJSON, signature: signature)
}

extension Data {
    /// base64url, no padding — the encoding every WebAuthn field rides in.
    public var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }

    public var hex: String { map { String(format: "%02x", $0) }.joined() }

    public init?(hex: String) {
        let s = hex.trimmingCharacters(in: .whitespaces)
        guard s.count % 2 == 0 else { return nil }
        var out = Data(capacity: s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        self = out
    }
}
