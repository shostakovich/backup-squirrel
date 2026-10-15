import Foundation

enum NotificationPermission: Hashable, Sendable {
    case notDetermined
    case allowed
    case denied
}

struct SystemState: Hashable, Sendable {
    var hasFullDiskAccess = true
    var opensAtLogin = true
    var notifications = NotificationPermission.allowed
    /// Paths of mounted volumes such as "/Volumes/Daten"; nil when unknown, which counts as mounted.
    var mountedVolumes: Set<String>?

    func missingVolume(for folders: [URL]) -> String? {
        guard let mountedVolumes else { return nil }
        for folder in folders {
            let components = folder.standardizedFileURL.pathComponents
            guard components.count >= 3, components[1] == "Volumes" else { continue }
            if !mountedVolumes.contains("/Volumes/\(components[2])") { return components[2] }
        }
        return nil
    }
}

enum FullDiskAccessProbe {
    static let protectedFolders = ["Library/Safari", "Library/Mail", "Library/Messages"]

    /// Without Full Disk Access, listing a folder that privacy protection guards fails with EPERM.
    static func isGranted(home: URL, listDirectory: (URL) throws -> Void) -> Bool {
        for folder in protectedFolders {
            do {
                try listDirectory(home.appendingPathComponent(folder, isDirectory: true))
                return true
            } catch {
                if isPermissionDenied(error) { return false }
            }
        }
        return true
    }

    private static func isPermissionDenied(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(EPERM) || error.code == Int(EACCES) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? any Error { return isPermissionDenied(underlying) }
        return false
    }
}

enum LoginItemStatus: Hashable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
}

enum LoginItemPolicy {
    /// Development builds run from DerivedData and must never touch the developer's login items.
    static func shouldRegister(appURL: URL, status: LoginItemStatus) -> Bool {
        guard status == .notRegistered || status == .notFound else { return false }
        return appURL.standardizedFileURL.path.hasPrefix("/Applications/")
    }
}
