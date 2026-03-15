import AppKit
import Foundation

/// Checks GitHub Releases API for app updates, downloads and installs.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published var latestVersion: String?
    @Published var updateAvailable = false
    @Published var releaseNotes: String?
    @Published var downloadURL: URL?
    @Published var isChecking = false

    // Download state
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var downloadedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var downloadComplete = false
    @Published var downloadedFileURL: URL?

    // UI state
    @Published var showUpdateDialog = false

    static let shared = UpdateChecker()

    let repoOwner = "lifedever"
    let repoName = "TaskTick"

    private var downloadTask: URLSessionDownloadTask?
    private var downloadDelegate: DownloadDelegate?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private init() {}

    struct GitHubRelease: Codable {
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: String
        let assets: [Asset]?

        struct Asset: Codable {
            let name: String
            let browser_download_url: String
            let size: Int?
        }
    }

    func checkForUpdates(userInitiated: Bool = false) async {
        isChecking = true

        do {
            let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                isChecking = false
                return
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let remoteVersion = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))

            latestVersion = remoteVersion
            releaseNotes = release.body

            // Find the correct DMG for current architecture
            let arch = currentArch()
            if let dmgAsset = release.assets?.first(where: { $0.name.contains(arch) && $0.name.hasSuffix(".dmg") }) {
                downloadURL = URL(string: dmgAsset.browser_download_url)
                totalBytes = Int64(dmgAsset.size ?? 0)
            } else if let dmgAsset = release.assets?.first(where: { $0.name.hasSuffix(".dmg") }) {
                downloadURL = URL(string: dmgAsset.browser_download_url)
                totalBytes = Int64(dmgAsset.size ?? 0)
            } else {
                downloadURL = URL(string: release.html_url)
            }

            // Skip if user has skipped this version
            let skippedVersion = UserDefaults.standard.string(forKey: "skippedVersion")
            if !userInitiated && remoteVersion == skippedVersion {
                updateAvailable = false
            } else {
                updateAvailable = isNewer(remote: remoteVersion, current: currentVersion)
            }

            UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")

            if updateAvailable {
                showUpdateDialog = true
            } else if userInitiated {
                // Show "up to date" alert
                showUpToDateAlert()
            }
        } catch {
            // Silently fail
        }

        isChecking = false
    }

    func skipVersion(_ version: String) {
        UserDefaults.standard.set(version, forKey: "skippedVersion")
        updateAvailable = false
        showUpdateDialog = false
    }

    func downloadUpdate() {
        guard let url = downloadURL else { return }

        isDownloading = true
        downloadProgress = 0
        downloadedBytes = 0
        downloadComplete = false

        let delegate = DownloadDelegate { [weak self] progress, received, total in
            Task { @MainActor in
                self?.downloadProgress = progress
                self?.downloadedBytes = received
                self?.totalBytes = total
            }
        } onComplete: { [weak self] fileURL in
            Task { @MainActor in
                self?.downloadComplete = true
                self?.downloadedFileURL = fileURL
                self?.isDownloading = false
            }
        }
        self.downloadDelegate = delegate

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        downloadTask = session.downloadTask(with: url)
        downloadTask?.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0
        downloadComplete = false
    }

    func installAndRestart() {
        guard let fileURL = downloadedFileURL else { return }

        let destApp = Bundle.main.bundlePath
        let filePath = fileURL.path

        Task.detached {
            do {
                // Mount the DMG
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                process.arguments = ["attach", filePath, "-nobrowse", "-noverify"]
                let pipe = Pipe()
                process.standardOutput = pipe
                try process.run()
                process.waitUntilExit()

                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                // Find the mount point
                let lines = output.components(separatedBy: "\n")
                guard let mountLine = lines.last(where: { $0.contains("/Volumes/") }),
                      let mountPoint = mountLine.components(separatedBy: "\t").last?.trimmingCharacters(in: .whitespaces) else {
                    await MainActor.run { NSWorkspace.shared.open(fileURL) }
                    return
                }

                // Find .app in mounted volume
                let appName = "TaskTick.app"
                let sourceApp = "\(mountPoint)/\(appName)"

                guard FileManager.default.fileExists(atPath: sourceApp) else {
                    await MainActor.run { NSWorkspace.shared.open(fileURL) }
                    return
                }

                // Create a shell script that waits for the app to quit, replaces it, and relaunches
                let script = """
                #!/bin/bash
                sleep 1
                rm -rf "\(destApp)"
                cp -R "\(sourceApp)" "\(destApp)"
                hdiutil detach "\(mountPoint)" -quiet
                open "\(destApp)"
                rm -f "$0"
                """

                let scriptPath = NSTemporaryDirectory() + "tasktick_update.sh"
                try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)

                let chmod = Process()
                chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
                chmod.arguments = ["+x", scriptPath]
                try chmod.run()
                chmod.waitUntilExit()

                let installer = Process()
                installer.executableURL = URL(fileURLWithPath: "/bin/bash")
                installer.arguments = [scriptPath]
                try installer.run()

                // Quit the current app
                await MainActor.run { NSApp.terminate(nil) }

            } catch {
                await MainActor.run { NSWorkspace.shared.open(fileURL) }
            }
        }
    }

    // MARK: - Private

    private func currentArch() -> String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    private func isNewer(remote: String, current: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(remoteParts.count, currentParts.count) {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            if r > c { return true }
            if r < c { return false }
        }
        return false
    }

    private func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("update.no_updates")
        alert.informativeText = L10n.tr("update.no_updates.message", currentVersion)
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func startPeriodicChecks() {
        let interval = UserDefaults.standard.integer(forKey: "updateCheckInterval")
        let hours = interval > 0 ? interval : 24

        Timer.scheduledTimer(withTimeInterval: TimeInterval(hours * 3600), repeats: true) { _ in
            Task { @MainActor in
                guard UserDefaults.standard.bool(forKey: "autoCheckUpdates") else { return }
                await UpdateChecker.shared.checkForUpdates()
            }
        }
    }
}

// MARK: - Download Delegate

final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let onProgress: @Sendable (Double, Int64, Int64) -> Void
    let onComplete: @Sendable (URL) -> Void

    init(
        onProgress: @escaping @Sendable (Double, Int64, Int64) -> Void,
        onComplete: @escaping @Sendable (URL) -> Void
    ) {
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Move to a persistent temp location
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("TaskTick-update.dmg")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.moveItem(at: location, to: dest)
        onComplete(dest)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 1
        let progress = Double(totalBytesWritten) / Double(total)
        onProgress(progress, totalBytesWritten, totalBytesExpectedToWrite)
    }
}
