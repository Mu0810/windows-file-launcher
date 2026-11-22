import Foundation

enum WineLaunchError: LocalizedError {
    case unsupportedFile
    case badFile(String)
    case missingStorage
    case unsuitableStorage
    case pathTranslation(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile:
            return "Choose a Windows .exe or .msi file."
        case .badFile(let name):
            return "“\(name)” does not have the expected Windows file header."
        case .missingStorage:
            return "The selected storage folder is unavailable. Reconnect its drive or choose another folder."
        case .unsuitableStorage:
            return "Wine needs a writable drive that supports symbolic links. Choose an APFS drive or use this Mac."
        case .pathTranslation(let details):
            return "Wine could not map this file to a Windows path.\n\(details)"
        }
    }
}

enum WindowsFile {
    case executable
    case installer

    static func identify(_ url: URL) throws -> WindowsFile {
        guard url.isFileURL else { throw WineLaunchError.unsupportedFile }

        let expected: [UInt8]
        let kind: WindowsFile
        switch url.pathExtension.lowercased() {
        case "exe":
            expected = [0x4d, 0x5a]
            kind = .executable
        case "msi":
            expected = [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]
            kind = .installer
        default:
            throw WineLaunchError.unsupportedFile
        }

        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw WineLaunchError.badFile(url.lastPathComponent)
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let header = try file.read(upToCount: expected.count)
        guard header == Data(expected) else { throw WineLaunchError.badFile(url.lastPathComponent) }
        return kind
    }
}

struct WineRunResult {
    let status: Int32
    let output: String
}

enum WineLaunch {
    private static let fm = FileManager.default
    static let supportFolder = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Windows File Launcher", isDirectory: true)

    static func windowsFolder(storage: URL?, intel: Bool = false) -> URL {
        let base = storage?.appendingPathComponent("Windows File Launcher", isDirectory: true)
            ?? supportFolder
        if intel { return base.appendingPathComponent("Windows Intel", isDirectory: true) }
        let legacy = base.appendingPathComponent("Windows", isDirectory: true)
        let ntdll = legacy.appendingPathComponent("drive_c/windows/system32/ntdll.dll")
        if isIntelWindowsLibrary(ntdll) {
            return base.appendingPathComponent("Windows ARM", isDirectory: true)
        }
        return legacy
    }

    private static func isIntelWindowsLibrary(_ url: URL) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        do {
            guard let dos = try file.read(upToCount: 64), dos.count == 64,
                  dos.starts(with: [0x4d, 0x5a]) else { return false }
            let offset = dos.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 60, as: UInt32.self) }
            try file.seek(toOffset: UInt64(UInt32(littleEndian: offset)))
            let header = try file.read(upToCount: 6)
            return header == Data([0x50, 0x45, 0, 0, 0x64, 0x86])
        } catch {
            return false
        }
    }

    static func rosettaAvailable() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        process.arguments = ["-x86_64", "/usr/bin/true"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func requiresRosetta(_ executable: URL) -> Bool {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/file")
        process.arguments = ["-b", executable.resolvingSymlinksInPath().path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let description = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return description.contains("x86_64") && !description.contains("arm64")
        } catch {
            return false
        }
    }

    static func run(wine: URL, file: URL, storage: URL?, installerLog: Bool = false) throws -> WineRunResult {
        let kind = try WindowsFile.identify(file)
        if let storage {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: storage.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw WineLaunchError.missingStorage
            }
            let volume = try storage.resourceValues(forKeys: [.volumeSupportsSymbolicLinksKey, .volumeIsReadOnlyKey])
            guard volume.volumeSupportsSymbolicLinks != false, volume.volumeIsReadOnly != true else {
                throw WineLaunchError.unsuitableStorage
            }
        }
        let prefix = windowsFolder(storage: storage, intel: requiresRosetta(wine))
        try fm.createDirectory(at: prefix, withIntermediateDirectories: true)

        var environment = ProcessInfo.processInfo.environment
        for key in ["WINEARCH", "WINELOADER", "WINESERVER", "WINEDLLPATH"] {
            environment.removeValue(forKey: key)
        }
        let bin = wine.resolvingSymlinksInPath().deletingLastPathComponent().path
        let searchPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "\(bin):\(searchPath)"
        environment["WINEPREFIX"] = prefix.path
        environment["WINEDEBUG"] = environment["WINEDEBUG"] ?? "fixme-all"

        let workingDirectory = file.deletingLastPathComponent()
        let translation = try execute(wine, arguments: ["winepath.exe", "-w", file.path],
                                      cwd: workingDirectory, environment: environment, pathTimeout: 90)
        let path = translation.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard translation.status == 0, !path.isEmpty, !path.contains("\n") else {
            throw WineLaunchError.pathTranslation(translation.errors)
        }

        var arguments = kind == .installer ? ["msiexec.exe", "/i", path] : [path]
        var logURL: URL?
        if kind == .executable && installerLog {
            let name = "WindowsFileLauncher-\(UUID().uuidString).log"
            logURL = prefix.appendingPathComponent("drive_c/windows/temp/\(name)")
            arguments.append("/LOG=C:\\windows\\temp\\\(name)")
            let channels = [environment["WINEDEBUG"] ?? "fixme-all", "+file", "+process", "+msgbox"]
            environment["WINEDEBUG"] = channels.joined(separator: ",")
        }
        let result = try execute(wine, arguments: arguments, cwd: workingDirectory, environment: environment)
        var output = [result.output, result.errors].filter { !$0.isEmpty }.joined(separator: "\n")
        if let logURL {
            let logValues = try? logURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let isLogFile = logValues?.isRegularFile == true && logValues?.isSymbolicLink != true
            let installerOutput = isLogFile ? (try? readTail(logURL)) : nil
            let log = installerOutput.flatMap { $0.isEmpty ? nil : $0 }
            let report = log.map { "Installer log (last lines)\n\($0)" }
                ?? "The installer did not write a log. It may have exited before logging began."
            output = output.isEmpty ? report : "\(output)\n\n\(report)"
            if isLogFile { try? fm.removeItem(at: logURL) }
        }
        return WineRunResult(status: result.status, output: output)
    }

    private static func execute(
        _ executable: URL, arguments: [String], cwd: URL, environment: [String: String],
        pathTimeout: TimeInterval? = nil
    ) throws -> (status: Int32, output: String, errors: String) {
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: folder) }

        let stdoutURL = folder.appendingPathComponent("stdout")
        let stderrURL = folder.appendingPathComponent("stderr")
        try Data().write(to: stdoutURL)
        try Data().write(to: stderrURL)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        defer { try? stdout.close() }
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stderr.close() }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        let exited = DispatchSemaphore(value: 0)
        if pathTimeout != nil {
            process.terminationHandler = { _ in exited.signal() }
        }
        try process.run()
        if let pathTimeout, exited.wait(timeout: .now() + pathTimeout) == .timedOut {
            if process.isRunning { process.terminate() }
            let errors = (try? readTail(stderrURL)) ?? ""
            throw WineLaunchError.pathTranslation(
                "Wine timed out while starting Windows or resolving the path.\n\(errors)"
            )
        }
        process.waitUntilExit()

        return (process.terminationStatus, try readTail(stdoutURL), try readTail(stderrURL))
    }

    private static func readTail(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let bom = try file.read(upToCount: 2)
        let end = try file.seekToEnd()
        let limit: UInt64 = 24_000
        try file.seek(toOffset: end > limit ? end - limit : 0)
        let data = try file.read(upToCount: Int(limit)) ?? Data()
        let encoding: String.Encoding = bom == Data([0xff, 0xfe]) ? .utf16LittleEndian : .utf8
        let log = String(data: data, encoding: encoding)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
        return log.trimmingCharacters(in: .newlines)
    }
}
