import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct WindowsFileLauncherApp: App {
    @StateObject private var model = LauncherModel()

    var body: some Scene {
        Window("Windows File Launcher", id: "launcher") {
            LauncherView(model: model)
                .frame(minWidth: 555, minHeight: 490)
        }
        .defaultSize(width: 585, height: 520)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Choose Windows File…", action: model.chooseProgram)
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(model.busy)
                Button("Choose Storage Folder…", action: model.chooseStorage)
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(model.busy)
            }
        }
    }
}

@MainActor
final class LauncherModel: ObservableObject {
    @Published private(set) var program: URL?
    @Published private(set) var wine: URL?
    @Published private(set) var storage: URL?
    @Published private(set) var rosetta = WineLaunch.rosettaAvailable()
    @Published private(set) var needsRosetta = true
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var details = ""
    @Published private(set) var failed = false
    @Published var dropTargeted = false

    private let defaults = UserDefaults.standard
    static let rosettaGuide = URL(string: "https://support.apple.com/en-us/102527")!

    init() {
        if let path = defaults.string(forKey: "WinePath") {
            wine = WineRuntime.resolve(URL(fileURLWithPath: path))
        }
        wine = wine ?? WineRuntime.discover()
        if let wine { needsRosetta = WineLaunch.requiresRosetta(wine) }
        if let path = defaults.string(forKey: "StoragePath") {
            storage = URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    var canUseWine: Bool {
        wine != nil && (rosetta || !needsRosetta) && !busy
    }

    var canRun: Bool {
        program != nil && canUseWine
    }

    var canLogInstaller: Bool {
        canRun && program?.pathExtension.lowercased() == "exe"
    }

    var storageLabel: String {
        guard let storage else { return "This Mac" }
        let isInternal = (try? storage.resourceValues(forKeys: [.volumeIsInternalKey]))?.volumeIsInternal
        return isInternal == true ? "This Mac · \(storage.path)" : storage.path
    }

    func select(_ url: URL) {
        guard !busy else { return }
        do {
            _ = try WindowsFile.identify(url)
            program = url
            updateStatus("")
        } catch {
            updateStatus(error.localizedDescription, failed: true)
        }
    }

    func chooseProgram() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Windows program"
        panel.allowedContentTypes = ["exe", "msi"].compactMap { UTType(filenameExtension: $0) }
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            select(url)
        }
    }

    func chooseWine() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Wine app or the wine executable"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let executable = WineRuntime.resolve(url) else {
            updateStatus("No Wine executable was found in that selection.", failed: true)
            return
        }
        setWine(executable)
    }

    func downloadWine() {
        busy = true
        updateStatus("Downloading Wine Staging from GitHub…")
        Task {
            defer { busy = false }
            do {
                let executable = try await WineRuntime.install()
                setWine(executable)
            } catch {
                updateStatus(error.localizedDescription, failed: true)
            }
        }
    }

    func checkRosetta() {
        rosetta = WineLaunch.rosettaAvailable()
        if rosetta { updateStatus("Rosetta is ready.") }
    }

    func chooseStorage() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder on your Mac or external drive"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            storage = url
            defaults.set(url.path, forKey: "StoragePath")
            updateStatus("Storage location selected. Existing Windows files stay in their original folder.")
        }
    }

    func resetStorage() {
        storage = nil
        defaults.removeObject(forKey: "StoragePath")
        updateStatus("Storage set to this Mac.")
    }

    func showWindowsFolder() {
        let folder = WineLaunch.windowsFolder(storage: storage, intel: wine != nil && needsRosetta)
        if FileManager.default.fileExists(atPath: folder.path) {
            NSWorkspace.shared.open(folder)
        } else {
            updateStatus("The Windows folder is created the first time you run a file here.")
        }
    }

    func run(installerLog: Bool = false) {
        guard canRun, let program, let wine else { return }
        let storage = self.storage
        busy = true
        updateStatus("Running \(program.lastPathComponent)…")
        Task {
            defer { busy = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try WineLaunch.run(wine: wine, file: program, storage: storage, installerLog: installerLog)
                }.value
                if result.status == 0 {
                    updateStatus("\(program.lastPathComponent) finished.", details: result.output)
                } else {
                    updateStatus("Wine exited with code \(result.status).",
                                 details: result.output, failed: true)
                }
            } catch {
                updateStatus(error.localizedDescription, failed: true)
            }
        }
    }

    func testWine() {
        guard canUseWine, let wine else { return }
        guard let x86 = Bundle.main.url(forResource: "WineTest32", withExtension: "exe"),
              let x64 = Bundle.main.url(forResource: "WineTest64", withExtension: "exe") else {
            updateStatus("The test programs are missing from the launcher.", failed: true)
            return
        }
        let storage = self.storage
        busy = true
        updateStatus("Testing 32-bit and 64-bit Windows programs…")
        Task {
            defer { busy = false }
            let checks = await Task.detached(priority: .userInitiated) {
                [("32-bit", x86), ("64-bit", x64)].map { name, file in
                    do {
                        let log = file == x86
                        let result = try WineLaunch.run(wine: wine, file: file, storage: storage, installerLog: log)
                        let passed = result.status == 0 && result.output.contains("Windows executable ran successfully")
                            && (!log || result.output.contains("Installer log capture test passed"))
                        let summary = "\(name) test \(passed ? "passed" : "failed")"
                        let details = "\(summary) (exit code \(result.status))\n\(result.output)"
                        return (passed, summary, details)
                    } catch {
                        return (false, "\(name) test failed", "\(name): \(error.localizedDescription)")
                    }
                }
            }.value
            updateStatus(checks.map { $0.1 }.joined(separator: " · "),
                         details: checks.map { $0.2 }.joined(separator: "\n\n"),
                         failed: checks.contains { !$0.0 })
        }
    }

    private func setWine(_ executable: URL) {
        wine = executable
        needsRosetta = WineLaunch.requiresRosetta(executable)
        defaults.set(executable.path, forKey: "WinePath")
        updateStatus("Wine is ready.")
    }

    private func updateStatus(_ message: String, details: String = "", failed: Bool = false) {
        status = message
        self.details = details
        self.failed = failed
    }
}

private struct LauncherView: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                HStack(spacing: 13) {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 46, height: 46)
                        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Windows File Launcher").font(.title2.bold())
                        Text("Run compatible Windows programs on your Mac.")
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(model.wine == nil ? "Wine needed" : "Wine selected",
                                  systemImage: model.wine == nil ? "shippingbox" : "checkmark.circle.fill")
                                .foregroundStyle(model.wine == nil ? Color.primary : Color.green)
                            Spacer()
                            Button("Choose Wine…", action: model.chooseWine)
                            if model.wine != nil {
                                Button("Test Wine", action: model.testWine)
                                    .disabled(!model.canUseWine)
                            } else {
                                Button("Download Wine", action: model.downloadWine)
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                        if model.needsRosetta && !model.rosetta {
                            Divider()
                            HStack {
                                Label("Rosetta needed", systemImage: "cpu")
                                Spacer()
                                Link("Install instructions", destination: LauncherModel.rosettaGuide)
                                Button("Check Again", action: model.checkRosetta)
                            }
                        }
                    }
                    .padding(5)
                }
                .disabled(model.busy)

                Button(action: model.chooseProgram) {
                    VStack(spacing: 6) {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 23, weight: .light))
                            .accessibilityHidden(true)
                        Text(model.program?.lastPathComponent ?? "Choose or drop a Windows file")
                            .font(.headline)
                            .lineLimit(1)
                        Text(model.program?.deletingLastPathComponent().path ?? ".exe or .msi")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, minHeight: 103)
                    .padding(.horizontal)
                    .background(Color.accentColor.opacity(model.dropTargeted ? 0.15 : 0.045),
                                in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(model.dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5),
                                          style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .dropDestination(for: URL.self) { files, _ in
                    guard files.count == 1, let url = files.first, !model.busy else { return false }
                    model.select(url)
                    return true
                } isTargeted: {
                    model.dropTargeted = $0
                }
                .disabled(model.busy)

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.wine != nil && model.needsRosetta ? "Intel Windows C: drive storage" : "Windows C: drive storage")
                            .font(.headline)
                        Text(model.storageLabel)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(model.storageLabel)
                    }
                    Spacer()
                    Menu("Storage") {
                        Button("Choose Folder…", action: model.chooseStorage)
                        Button("Use This Mac", action: model.resetStorage)
                        Divider()
                        Button("Open Windows Folder", action: model.showWindowsFolder)
                    }
                    .fixedSize()
                    .disabled(model.busy)
                }

                Divider()

                HStack(spacing: 8) {
                    if model.busy {
                        ProgressView().controlSize(.small)
                    }
                    Text(model.status)
                        .foregroundStyle(model.failed ? Color.red : Color.secondary)
                        .font(.callout)
                        .textSelection(.enabled)
                    Spacer(minLength: 12)
                    if model.program?.pathExtension.lowercased() == "exe" {
                        Button("Run with Installer Log") { model.run(installerLog: true) }
                            .help("Request a diagnostic log from an Inno Setup installer.")
                            .disabled(!model.canLogInstaller)
                    }
                    Button("Run Windows File") { model.run() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canRun)
                }
                if !model.details.isEmpty {
                    DisclosureGroup("Wine output") {
                        ScrollView {
                            Text(model.details)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 115)
                    }
                }
            }
            .padding(23)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !model.rosetta { model.checkRosetta() }
        }
    }
}
