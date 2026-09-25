import Foundation

/// Shell command substitution strips trailing newlines; a sentinel preserves the exact UTF-8 path.
enum RemoteShellPath {
    enum Variable: String { case path = "P", source = "F", target = "T" }

    static func assign(_ path: String, to variable: Variable = .path) -> String {
        let name = variable.rawValue
        let encoded = Data(path.utf8).base64EncodedString()
        return "\(name)=$(printf %s '\(encoded)' | base64 -d && printf .) || exit 1; \(name)=${\(name)%.}"
    }
}
