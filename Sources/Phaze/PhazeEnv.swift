import Foundation

/// The app's public env, as its build resolved it, read the way a view reads `env.public`:
/// `env.public.NEURALKIT_API_ORIGIN`.
///
/// `native()` writes it into the shipped directory as `phaze-env.json`: the `PUBLIC_` values Vite
/// loaded from `.env`, or `.env.production` in a production build — the values a view's
/// `env.public` is inlined with — named without the prefix, as `src/env.ts` declares them. The
/// file ships inside the app, so nothing private is ever in it. Without it (a shell pointed at a
/// dev server, a directory not built yet) every value is `nil`.
public struct PhazeEnv: Sendable {
    /// The public bucket, one value per name.
    public let `public`: Values

    /// Reads `phaze-env.json` from the shipped directory `PhazeRouter` serves.
    public init(dist: URL) {
        let file = dist.appending(path: "phaze-env.json")
        let values = (try? Data(contentsOf: file))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        self.public = Values(values: values)
    }

    @dynamicMemberLookup
    public struct Values: Sendable {
        let values: [String: String]

        public subscript(dynamicMember name: String) -> String? { values[name] }
    }
}
