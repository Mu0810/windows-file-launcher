import CryptoKit
import Foundation

enum WineRuntime {
    private static let version = "11.21"
    private static let bundleName = "Wine Staging.app"
    private static let archiveName = "wine-staging-\(version)-osx64.tar.xz"
    private static let expectedSHA256 = "d7bcd5abf4df27aae397a7898aef074fea4a2e0b51e0a55aa9659517bbf9d452"
    private static let repository = URL(string: "https://github.com/Gcenx/macOS_Wine_builds")!

    static let releasePage = repository.appendingPathComponent("releases/tag/\(version)")

    static let defaultAppURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Windows File Launcher", isDirectory: true)
        .appendingPathComponent("Runtime", isDirectory: true)
        .appendingPathComponent(version, isDirectory: true)
        .appendingPathComponent(bundleName, isDirectory: true)

    static func resolve(_ selection: URL) -> URL? {
        let files = FileManager.default
        var isDirectory: ObjCBool = false
        guard selection.isFileURL, files.fileExists(atPath: selection.path, isDirectory: &isDirectory) else {
            return nil
        }

        if !isDirectory.boolValue {
            let executableNames = ["wine", "wine64"]
            guard executableNames.contains(selection.lastPathComponent), files.isExecutableFile(atPath: selection.path) else {
                return nil
            }
            let macOSDirectory = selection.deletingLastPathComponent()
            if macOSDirectory.lastPathComponent == "MacOS" {
                let app = macOSDirectory.deletingLastPathComponent().deletingLastPathComponent()
                let command = app.appendingPathComponent("Contents/Resources/wine/bin/wine")
                if files.isExecutableFile(atPath: command.path) { return command }
            }
            return selection
        }

        let binaryPaths = [
            "Contents/Resources/wine/bin/wine",
            "Contents/Resources/wine/bin/wine64",
            "Contents/Resources/bin/wine",
            "Contents/Resources/bin/wine64",
            "Contents/MacOS/wine",
            "Contents/MacOS/wine64",
            "bin/wine",
            "bin/wine64",
            "wine",
            "wine64"
        ]
        return binaryPaths.lazy
            .map { selection.appendingPathComponent($0) }
            .first { candidate in
                var candidateIsDirectory: ObjCBool = false
                return files.fileExists(atPath: candidate.path, isDirectory: &candidateIsDirectory)
                    && !candidateIsDirectory.boolValue
                    && files.isExecutableFile(atPath: candidate.path)
            }
    }

    static func discover() -> URL? {
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let nativeBundle = "MetalSharp-Wine.app"
        let bundledNative = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent(nativeBundle, isDirectory: true)
        let bundleNames = [nativeBundle, bundleName, "Wine Stable.app", "Wine Devel.app",
                           "Wine Development.app", "Wine.app"]
        let commonLocations = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
        let pathLocations = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":")
            .map(String.init).filter { $0.hasPrefix("/") } ?? []
        let candidates = [bundledNative, defaultAppURL]
            + [applications, userApplications].flatMap { directory in
                bundleNames.map { directory.appendingPathComponent($0, isDirectory: true) }
            }
            + (commonLocations + pathLocations).map { URL(fileURLWithPath: $0, isDirectory: true) }
        return candidates.lazy.compactMap { resolve($0) }.first
    }

    static func install() async throws -> URL {
        if let existing = resolve(defaultAppURL) {
            return existing
        }

        let files = FileManager.default
        let destination = defaultAppURL.deletingLastPathComponent()
        let staging = destination.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        do {
            try files.createDirectory(at: destination, withIntermediateDirectories: true)
            try files.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            throw InstallError.files("create the Wine installation folder", error)
        }
        defer { try? files.removeItem(at: staging) }

        let archive = staging.appendingPathComponent(archiveName)
        let downloadURL = repository.appendingPathComponent("releases/download/\(version)/\(archiveName)")
        do {
            let (download, response) = try await URLSession.shared.download(from: downloadURL)
            defer { try? files.removeItem(at: download) }
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw InstallError.server((response as? HTTPURLResponse)?.statusCode)
            }
            try files.moveItem(at: download, to: archive)
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.files("download Wine Staging \(version)", error)
        }

        try Task.checkCancellation()
        try verify(archive)
        try extract(archive, into: staging)
        try Task.checkCancellation()

        let stagedApp = staging.appendingPathComponent(bundleName, isDirectory: true)
        let stagedAppPath = stagedApp.resolvingSymlinksInPath()
        guard stagedAppPath.deletingLastPathComponent().path == staging.resolvingSymlinksInPath().path,
              let stagedExecutable = resolve(stagedApp),
              stagedExecutable.resolvingSymlinksInPath().path.hasPrefix(stagedAppPath.path + "/") else {
            throw InstallError.invalidBundle
        }

        do {
            try files.moveItem(at: stagedApp, to: defaultAppURL)
        } catch {
            // Another launcher window may have completed the same installation.
            if let existing = resolve(defaultAppURL) { return existing }
            throw InstallError.files("save Wine to \(defaultAppURL.path)", error)
        }

        guard let executable = resolve(defaultAppURL) else { throw InstallError.invalidBundle }
        return executable
    }

    private static func verify(_ archive: URL) throws {
        var hash = SHA256()
        do {
            let file = try FileHandle(forReadingFrom: archive)
            defer { try? file.close() }
            while let bytes = try file.read(upToCount: 1024 * 1024), !bytes.isEmpty {
                hash.update(data: bytes)
            }
        } catch {
            throw InstallError.files("read the Wine download for verification", error)
        }

        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expectedSHA256 else { throw InstallError.checksum }
    }

    private static func extract(_ archive: URL, into directory: URL) throws {
        let tar = Process()
        let errors = Pipe()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xf", archive.path, "-C", directory.path]
        tar.standardOutput = FileHandle.nullDevice
        tar.standardError = errors
        do {
            try tar.run()
        } catch {
            throw InstallError.files("start the Wine archive extractor", error)
        }
        let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else {
            let details = String(decoding: diagnostics.prefix(500), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw InstallError.extraction(tar.terminationStatus, details)
        }
    }

    private enum InstallError: LocalizedError {
        case files(String, Error)
        case server(Int?)
        case checksum
        case invalidBundle
        case extraction(Int32, String)

        var errorDescription: String? {
            switch self {
            case let .files(operation, underlying):
                return "Could not \(operation). \(underlying.localizedDescription)"
            case let .server(code):
                let status = code.map { " (HTTP \($0))" } ?? ""
                return "GitHub did not return the Wine download\(status)."
            case .checksum:
                return "The Wine download did not match its published SHA-256 checksum."
            case .invalidBundle:
                return "The Wine archive did not contain a usable Wine Staging application."
            case let .extraction(code, details):
                return "Could not extract Wine (tar exit code \(code)). \(details)"
            }
        }
    }
}
