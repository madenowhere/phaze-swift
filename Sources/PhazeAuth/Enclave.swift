// The hardware backend for `Signer` — a Secure Enclave key — and the platform's answer to "what
// can this Mac verify a human with right now". The Swift half of phaze-auth's `enclave` module,
// and the same two questions it answers: which key signs, and what the platform demands first.
//
// WHERE THIS DIFFERS FROM THE RUST HALF, which is why a Swift shell can hold a non-exportable key
// on a binary that has never been signed. The Rust module mints a KEYCHAIN ITEM
// (`SecKeyCreateRandomKey` with `kSecAttrIsPermanent`), and a keychain item carrying an access
// control moves onto the data-protection keychain — which on macOS demands `keychain-access-groups`,
// an entitlement that needs a provisioning profile. CryptoKit persists a Secure Enclave key as its
// `dataRepresentation` instead: a blob only this device's enclave can use, written wherever the
// caller likes, with no keychain item to entitle. Measured 2026-09-15 on an unsigned binary —
// minted, reloaded in a new process, same public key.
//
// WHAT IS NOT MEASURED, and why `Gate` reports rather than promises. Whether an access control
// works on a key persisted as a blob is an open cell. The Rust half measured both neighbours: a
// keychain item with an ACL returns `-34018` unsigned, and an EPHEMERAL enclave key with a biometry
// ACL fails `-25293` because "an access control is a keychain concept; there is nothing for it to
// bind to on a key that is never stored". A `dataRepresentation` key is neither — not a keychain
// item, and not ephemeral. So ask `capabilities()` first, attempt the gate, and read what comes
// back; `EnclaveKey.init(gate:)` throws with the OSStatus rather than falling back silently.
import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// What the platform demands before the private key will sign.
///
/// The Rust half carries a fifth, `Pin` (Apple's `ApplicationPassword`, where the secret
/// participates in protecting the key rather than gating it). It is absent here because supplying
/// the PIN needs an `LAContext` carrying a credential the caller collected, and a shell that has
/// nowhere to ask has nothing to supply.
public enum Gate: Sendable, Equatable {
    /// Verify the human by whatever this Mac has — Touch ID, a paired Watch, or the login
    /// password, whichever the OS cascades to. The gate that lets `assert` set `UV` honestly.
    case userPresence
    /// Biometry or a paired companion device — usually an Apple Watch — and NOT the login
    /// password. The narrower sibling: it names the acceptable factors instead of accepting
    /// whatever the cascade lands on.
    ///
    /// The Rust half measured why this exists: on a Mac mini with a paired Watch in range,
    /// `userPresence` raised a PASSWORD dialog even though `capabilities()` reported the Watch
    /// available. Its cost is that key creation fails where neither factor exists, so ask
    /// `capabilities().biometricsOrCompanion` before requesting it.
    ///
    /// The Rust half spells this `BiometryOrWatch`. Apple renamed the Swift surface in macOS 15 —
    /// `LAPolicy.deviceOwnerAuthenticationWithWatch` became `…WithCompanion`, and
    /// `SecAccessControlCreateFlags.watch` became `.companion` — because a companion need not be a
    /// Watch. The raw values did not change, which is why the Rust half's FFI never saw the rename.
    case biometryOrCompanion
    /// The login password specifically — deterministic where `userPresence` is adaptive, which is
    /// what you want when the prompt must be the same on every machine.
    case devicePasscode
    /// No user interaction. A key that signs unattended is better storage, not a second factor.
    ///
    /// The Rust half spells this `Gate::None`. It is `unguarded` here because `gate` is an
    /// `Optional<Gate>` — a key reloaded from its blob has no gate it can report — and a case
    /// named `none` inside an Optional resolves to `Optional.none`, so every switch over `Gate?`
    /// silently loses the `.some(.none)` arm. Swift's own guidance is not to name a case `none`.
    case unguarded
}

/// What this Mac can actually use to verify a human — asked of the OS rather than guessed from the
/// hardware. These are LocalAuthentication's `LAPolicy` values, one per question.
///
/// A desktop Mac has no sensor, so `biometrics` is false there, but `deviceOwner` can still be
/// true: the OS cascades to a paired Apple Watch and then to the account password. Which is why a
/// gate is declared as "verify the human" and never as "use Touch ID".
public struct Capabilities: Sendable, Equatable {
    /// A physical biometric sensor, connected and enrolled.
    public let biometrics: Bool
    /// The full cascade — biometrics, or a paired companion, or the account password.
    public let deviceOwner: Bool
    /// A paired companion device, usually an Apple Watch.
    public let companion: Bool
    /// Biometrics or a companion, but NOT the password fallback.
    public let biometricsOrCompanion: Bool

    /// One line for a status report — the same summary the Rust half prints.
    public var summary: String {
        switch (biometrics, companion) {
        case (true, _): "Touch ID available"
        case (false, true): "no sensor, but a paired Apple Watch can approve"
        case (false, false) where deviceOwner: "no sensor, no Watch — the account password is the fallback"
        default: "no user verification available at all"
        }
    }
}

/// Ask the OS which authentication policies it can satisfy right now.
///
/// Cheap and side-effect free: `canEvaluatePolicy` inspects, it does not prompt. Worth calling
/// before a gate is chosen, so a machine with no sensor and no Watch is told to expect a password
/// rather than surprised by one — and worth calling AT USE rather than caching, because a Watch
/// off the wrist changes the answer minute to minute.
public func capabilities() -> Capabilities {
    let context = LAContext()
    func can(_ policy: LAPolicy) -> Bool {
        var error: NSError?
        return context.canEvaluatePolicy(policy, error: &error)
    }
    return Capabilities(
        biometrics: can(.deviceOwnerAuthenticationWithBiometrics),
        deviceOwner: can(.deviceOwnerAuthentication),
        companion: can(.deviceOwnerAuthenticationWithCompanion),
        biometricsOrCompanion: can(.deviceOwnerAuthenticationWithBiometricsOrCompanion)
    )
}

/// A P-256 key held by the Secure Enclave — non-exportable, which is what makes it a hardware
/// credential rather than a file with better permissions.
///
/// Persisted as `dataRepresentation`: not the private key, but a blob usable only by this device's
/// enclave. It is device-bound by construction, so it does not survive a migration to another Mac —
/// correct for a machine credential, and the re-enrolment path is the fallback that already exists.
public struct EnclaveKey: Signer {
    private let key: SecureEnclave.P256.Signing.PrivateKey

    /// The gate this VALUE knows about. `nil` for a key reloaded from its blob, whose access
    /// control the platform does not report back.
    ///
    /// THE RELOADED KEY MUST BE TOLD ITS GATE. The Rust half learned this the expensive way: a key
    /// minted behind a gate reported `user_verified() == false` on every run after the first,
    /// because the lookup could not read the access control back. The OS still enforced it — the
    /// ACL is on the key, not on this struct — so the effect was a shell telling the server no
    /// human was present moments after one had been verified. The caller asked for the gate and the
    /// OS enforced it; saying so is not an assumption.
    public let gate: Gate?

    public static var isAvailable: Bool { SecureEnclave.isAvailable }

    /// Mint a key. `gate: .unguarded` sets no access control at all, rather than one carrying only
    /// `.privateKeyUsage` — on the Rust side the mere presence of an access control is what moved
    /// the item onto the data-protection keychain, and an absent one is absent, not empty.
    public init(gate: Gate = .unguarded) throws {
        if let flags = try Self.accessControlFlags(for: gate) {
            var error: Unmanaged<CFError>?
            guard let control = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &error
            ) else {
                let cause = error?.takeRetainedValue().localizedDescription ?? "no CFError"
                throw AuthenticatorError(message: "SecAccessControlCreateWithFlags: \(cause)")
            }
            key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: control)
        } else {
            key = try SecureEnclave.P256.Signing.PrivateKey()
        }
        self.gate = gate
    }

    /// Reload from the blob `dataRepresentation` produced. Pass the `gate` the key was minted
    /// behind — the platform does not report it, and `userVerified` understates it otherwise.
    public init(dataRepresentation: Data, gate: Gate? = nil) throws {
        key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: dataRepresentation)
        self.gate = gate
    }

    /// The blob to persist. Not the private key — usable only by this device's enclave.
    public var dataRepresentation: Data { key.dataRepresentation }

    /// Record which access control the caller knows guards this key. Only meaningful after a
    /// reload; minting already knows.
    public func withGate(_ gate: Gate) -> EnclaveKey {
        EnclaveKey(key: key, gate: gate)
    }

    private init(key: SecureEnclave.P256.Signing.PrivateKey, gate: Gate?) {
        self.key = key
        self.gate = gate
    }

    /// The access control for a gate, or `nil` for `.none`.
    ///
    /// `.biometryOrCompanion` is BUILT FROM WHAT THIS MAC HAS, because the flags are validated
    /// INDIVIDUALLY at creation — OR-ing them does not make an impossible one tolerable. Measured
    /// on the Rust side, on a Mac mini with a paired Watch: `biometryAny | watch | or` failed
    /// `-25293`, the same way `biometryAny` fails alone on a sensorless desktop. So a machine with
    /// no sensor asks for the companion and a laptop asks for both — the gate names the INTENT, and
    /// the flags are how this particular hardware expresses it.
    private static func accessControlFlags(for gate: Gate) throws -> SecAccessControlCreateFlags? {
        switch gate {
        case .unguarded:
            return nil
        case .userPresence:
            return [.privateKeyUsage, .userPresence]
        case .devicePasscode:
            return [.privateKeyUsage, .devicePasscode]
        case .biometryOrCompanion:
            let available = capabilities()
            switch (available.biometrics, available.companion) {
            case (true, true): return [.privateKeyUsage, .biometryAny, .companion, .or]
            case (true, false): return [.privateKeyUsage, .biometryAny]
            case (false, true): return [.privateKeyUsage, .companion]
            case (false, false):
                throw AuthenticatorError(
                    message: "no biometrics and no paired Apple Watch — this gate cannot be satisfied here"
                )
            }
        }
    }

    public func publicSEC1() throws -> Data { key.publicKey.x963Representation }
    public func signDER(_ message: Data) throws -> Data { try key.signature(for: message).derRepresentation }

    /// Claims a verified human only for a key this value knows carries a gate. A reloaded key with
    /// no stated gate stays false rather than guessing, because guessing puts a false `UV` flag on
    /// the wire and the server cannot detect it.
    public var userVerified: Bool {
        switch gate {
        case .userPresence, .biometryOrCompanion, .devicePasscode: true
        case .unguarded, nil: false
        }
    }

    public var describe: String {
        switch gate {
        case .userPresence: "Secure Enclave P-256 (user verification required)"
        case .biometryOrCompanion: "Secure Enclave P-256 (biometrics or Apple Watch required)"
        case .devicePasscode: "Secure Enclave P-256 (password required)"
        case .unguarded, nil: "Secure Enclave P-256"
        }
    }
}
