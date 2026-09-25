# Phaze

The macOS shell for a [Phaze](https://phaze.build) app, on SwiftUI's `WebView` (macOS 26). Two products:

- `Phaze` — `PhazeRouter`, the scheme handler that serves the built app from the bundle, the forward to the app's worker, the window drag, and `PhazeEnv`.
- `PhazeAuth` — the machine credential: a Secure Enclave key, its gate, and the WebAuthn authenticator bytes a phaze-auth server verifies.

```swift
// Package.swift
.package(url: "https://github.com/madenowhere/phaze-swift", from: "0.1.0"),
// …
.product(name: "Phaze",     package: "phaze-swift"),
.product(name: "PhazeAuth", package: "phaze-swift"),
```

Documentation is available to licensed users and partners: [Phaze + Swift](https://phaze.build/integrations/swift/) and [Security → Native](https://phaze.build/security/native/), access on request at [neuralkit.ai](https://neuralkit.ai).

## License

PolyForm Noncommercial 1.0.0 ([LICENSE.md](LICENSE.md)). Free for noncommercial use, and for government institutions. Commercial use by written agreement: [neuralkit.ai](https://neuralkit.ai). See [NOTICE](NOTICE).
