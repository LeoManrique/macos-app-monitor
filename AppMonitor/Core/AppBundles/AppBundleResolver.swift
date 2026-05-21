import Foundation

enum AppBundleResolver {
    /// Maps an executable path to its enclosing `.app` bundle by finding the
    /// *leftmost* `.app/` substring. For nested bundles (e.g. Chrome Helper
    /// inside Google Chrome.app), the leftmost match is the outermost bundle,
    /// which is the user-facing app. Returns nil when the exe lives outside
    /// any `.app`.
    static func resolve(executablePath: String) -> (name: String, bundlePath: String)? {
        guard let range = executablePath.range(of: ".app/") else { return nil }
        let prefix = String(executablePath[..<range.lowerBound])
        let nameStart = prefix.lastIndex(of: "/").map { prefix.index(after: $0) } ?? prefix.startIndex
        let name = String(prefix[nameStart...])
        let bundlePath = String(executablePath[..<range.upperBound]).trimmingSuffix("/")
        return (name, bundlePath)
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
