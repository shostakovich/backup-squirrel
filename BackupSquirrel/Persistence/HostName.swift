import Foundation
import SystemConfiguration

enum HostName {
    static func ofThisMac() -> String {
        let name = (SCDynamicStoreCopyLocalHostName(nil) as String?) ?? ProcessInfo.processInfo.hostName
        return sanitized(name)
    }

    /// Letters, digits and single hyphens, as restic shows it in `snapshots`.
    static func sanitized(_ name: String) -> String {
        var name = name
        if name.lowercased().hasSuffix(".local") { name.removeLast(".local".count) }
        var result = ""
        for character in name {
            if character.isASCII && (character.isLetter || character.isNumber) {
                result.append(character)
            } else if !result.isEmpty && !result.hasSuffix("-") {
                result.append("-")
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? "mac" : result
    }
}
