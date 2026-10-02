import AppKit
import CryptoKit
import Foundation
import Observation

/// Fetching, checking and installing a newer build of this app from its own GitHub release.
///
/// **Nothing here happens until somebody presses a button.** The app's rule is that launching it does no
/// network work — `AccountController` is inert for the same reason — so there is no timer, no check at
/// startup and nothing that survives a quit. A person who never opens the Updates page never makes a request.
///
/// The release this reads is the one `.github/workflows/release.yml` publishes: a zip of the built bundle,
/// with a `.sha256` beside it. **The checksum is not decoration.** This code replaces the application that is
/// running, so the file it replaces it with is verified before anything on disk is moved, and a download that
/// does not match is thrown away rather than installed.
///
/// The last step is deliberately a *restart* and not a relaunch. A running process keeps the copy it was
/// started from, so the new build is on disk and the old one is in memory; quitting is what puts the two back
/// together, and quitting is the user's decision rather than something an update does behind their back.
@MainActor
@Observable
final class UpdateController {
    /// The repository whose releases are the update source.
    ///
    /// A constant rather than a setting: this app is built from this repository, and a build whose update
    /// source could be pointed somewhere else is a build that can be made to install something else.
    ///
    /// `nonisolated` because it is a string, and the code that reads it runs off the main actor on purpose.
    nonisolated static let repository = "lqSky7/SwiftTerm"

    /// Where the update is.
    ///
    /// One enum rather than a handful of booleans, because most of the combinations are impossible: it cannot
    /// be checking and installing at once, and `failed` has no version to show. A shape that cannot express
    /// the impossible states is a shape no view has to guard against them.
    enum Status: Equatable {
        case idle
        case checking
        /// The newest release is not newer than this build.
        case upToDate
        /// A newer release exists and is ready to install. The string is its version.
        case available(String)
        case downloading
        case installing
        /// Already replaced on disk; the running process is still the build that was replaced. This is the
        /// state that ends in "restart", not in a relaunch nobody asked for.
        case installed(String)
        case failed(String)
    }

    private(set) var status: Status = .idle

    /// What this build says it is, read from the bundle rather than written down here — so the number the
    /// page shows and the number the build carries cannot disagree.
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// Whether the app is somewhere it can replace itself. False for a bare executable — `swift run`, or a
    /// copy inside `.build` — where there is no bundle to swap and the honest answer is to say so rather
    /// than to fail halfway through.
    var canInstall: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Whether a request is in flight, so a second press does not start a second one.
    var isBusy: Bool {
        switch status {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    /// The release the last successful check found, if it was newer than this build.
    @ObservationIgnored private var pending: Release?
    @ObservationIgnored private var work: Task<Void, Never>?

    // MARK: - Checking

    /// Ask GitHub for the newest release and decide whether it is worth offering.
    func check() {
        guard !isBusy else { return }
        work?.cancel()
        status = .checking
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let release = try await Self.latestRelease()
                guard !Task.isCancelled else { return }
                if Self.isNewer(release.version, than: self.currentVersion) {
                    self.pending = release
                    self.status = .available(release.version)
                } else {
                    self.pending = nil
                    self.status = .upToDate
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.status = .failed(Self.describe(error))
            }
        }
    }

    // MARK: - Installing

    /// Download the release found by `check`, verify it, and put it where the running app is.
    func install() {
        guard let release = pending, !isBusy, canInstall else { return }
        work?.cancel()
        status = .downloading
        work = Task { [weak self] in
            guard let self else { return }
            var archive: URL?
            defer { if let archive { try? FileManager.default.removeItem(at: archive) } }
            do {
                let downloaded = try await Self.download(release.archive)
                archive = downloaded
                guard !Task.isCancelled else { return }

                // Before anything on disk is touched: a zip that does not match the checksum the release
                // published is a zip this app will not run.
                if let checksum = release.checksum {
                    let expected = try await Self.publishedChecksum(at: checksum)
                    guard try Self.sha256(of: downloaded) == expected else {
                        throw UpdateError.checksumMismatch
                    }
                }

                guard !Task.isCancelled else { return }
                self.status = .installing
                try await Self.swapInBundle(from: downloaded)
                guard !Task.isCancelled else { return }
                self.status = .installed(release.version)
            } catch {
                guard !Task.isCancelled else { return }
                self.status = .failed(Self.describe(error))
            }
        }
    }

    /// Quit and come back on the new build.
    ///
    /// The opening has to happen *after* this process is gone, and nothing inside a process can run after it
    /// exits — so it is handed to a shell that outlives us, waits for the pid to disappear, and only then
    /// opens the bundle. The path is passed as an argument rather than interpolated into the script, so a
    /// bundle under a directory with a space in its name is not a syntax error.
    func restart() {
        let bundle = Bundle.main.bundleURL
        guard canInstall else { return }
        let script = """
            while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            open "$2"
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", script, "swiftterm-restart",
            String(ProcessInfo.processInfo.processIdentifier), bundle.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        NSApplication.shared.terminate(nil)
    }

    // MARK: - The release

    /// One release, reduced to the two things this needs: what it is called, and the zip to fetch.
    struct Release: Sendable {
        let version: String
        let archive: URL
        /// The published `.sha256`, when the release carries one. Optional because an older release
        /// published before the workflow wrote checksums is still a release somebody can install.
        let checksum: URL?
    }

    /// The subset of GitHub's release JSON this reads. Named after the wire, not after what we do with it —
    /// the same rule `contracts/` follows, and for the same reason: a decoder that renames a field is a
    /// decoder that has to be re-read every time somebody wonders what the server actually sent.
    private struct Payload: Decodable, Sendable {
        struct Asset: Decodable, Sendable {
            let name: String
            let url: URL

            private enum CodingKeys: String, CodingKey {
                case name
                case url = "browser_download_url"
            }
        }

        let tagName: String
        let assets: [Asset]

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    nonisolated private static func latestRelease() async throws -> Release {
        var request = URLRequest(url: endpoint)
        // GitHub answers `application/vnd.github+json` and asks for a `User-Agent` on every request; one
        // that does not name itself is refused rather than defaulted.
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("swiftTerm", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.noResponse }
        guard http.statusCode == 200 else { throw UpdateError.http(http.statusCode) }

        let payload = try JSONDecoder().decode(Payload.self, from: data)
        // The zip the workflow attaches, and the checksum beside it. Matching by suffix rather than by an
        // exact name, because the name carries the version and the version is the thing that changes.
        guard let archive = payload.assets.first(where: { $0.name.hasSuffix(".zip") })?.url else {
            throw UpdateError.noArchive
        }
        let checksum = payload.assets.first(where: { $0.name.hasSuffix(".zip.sha256") })?.url
        return Release(version: payload.tagName, archive: archive, checksum: checksum)
    }

    nonisolated private static var endpoint: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    // MARK: - Downloading and verifying

    nonisolated private static func download(_ url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue("swiftTerm", forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.noResponse }
        guard http.statusCode == 200 else { throw UpdateError.http(http.statusCode) }

        // The file `download(for:)` hands back is deleted as soon as this returns, so it is moved out of
        // that location immediately rather than read from it later.
        let kept = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftTerm-\(UUID().uuidString).zip")
        try? FileManager.default.removeItem(at: kept)
        try FileManager.default.moveItem(at: temporary, to: kept)
        return kept
    }

    /// The hex digest out of a `shasum -a 256` line, which is `<digest>  <filename>`.
    nonisolated private static func publishedChecksum(at url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("swiftTerm", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let text = String(data: data, encoding: .utf8),
            let digest = text.split(whereSeparator: \.isWhitespace).first
        else { throw UpdateError.noChecksum }
        return digest.lowercased()
    }

    nonisolated private static func sha256(of file: URL) throws -> String {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Putting it in place

    /// Unpack the zip and swap it in where the running bundle is.
    ///
    /// Off the main actor, because it moves a few megabytes and blocks while it does: a progress indicator
    /// that has stopped animating is the one thing a person watching an install will notice.
    nonisolated private static func swapInBundle(from archive: URL) async throws {
        try await Task.detached(priority: .utility) {
            try replaceBundle(with: archive)
        }.value
    }

    nonisolated private static func replaceBundle(with archive: URL) throws {
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app" else { throw UpdateError.notAnApp }

        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory
            .appendingPathComponent("swiftTerm-unpack-\(UUID().uuidString)")
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }

        // `ditto` rather than `FileManager.unzipItem`: the zip was written by `ditto -c -k` precisely
        // because a bundle is more than a directory of files — an ad-hoc signature, an `Assets.car` and
        // symlinks all have to survive the round trip — and `ditto` is the half of that pair that puts them
        // back the way they were.
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, work.path])

        guard
            let unpacked = try fileManager.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" })
        else { throw UpdateError.malformedArchive }

        // The staging names sit beside the target rather than in `/tmp`, so both moves are renames on one
        // volume — a rename either happens or does not, and a copy across filesystems can stop halfway.
        let parent = target.deletingLastPathComponent()
        let incoming = parent.appendingPathComponent(".swiftTerm-incoming.app")
        let previous = parent.appendingPathComponent(".swiftTerm-previous.app")
        try? fileManager.removeItem(at: incoming)
        try? fileManager.removeItem(at: previous)
        try fileManager.moveItem(at: unpacked, to: incoming)

        // A running bundle can be moved aside — the process keeps the copy it opened — which is the whole
        // reason this can end in "restart to use it" instead of "quit first and try again".
        try fileManager.moveItem(at: target, to: previous)
        do {
            try fileManager.moveItem(at: incoming, to: target)
        } catch {
            // Put the old build back rather than leaving nothing where the app was. An update that fails
            // should leave a working app behind it.
            try? fileManager.moveItem(at: previous, to: target)
            throw error
        }
        try? fileManager.removeItem(at: previous)

        // Belt and braces: a downloaded archive can carry a quarantine bit that would make the fresh copy
        // unopenable, and an app that will not launch is the exact failure this path exists to avoid.
        try? run("/usr/bin/xattr", ["-cr", target.path])
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        // Read before waiting: a pipe nobody drains fills up and hangs the tool writing to it.
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: message, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw UpdateError.toolFailed((tool as NSString).lastPathComponent, text)
        }
    }

    // MARK: - Versions

    /// Whether `candidate` is later than `current`, by the numbers rather than by the text.
    ///
    /// `"0.10.0"` sorts *before* `"0.9.0"` as a string and after it as a version, so a release that stopped
    /// being offered the moment a minor number grew a digit is a bug nobody would think to look for.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = numbers(in: candidate)
        let right = numbers(in: current)
        for index in 0..<max(left.count, right.count) {
            let lhs = index < left.count ? left[index] : 0
            let rhs = index < right.count ? right[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    /// The leading integers of a version, so a `v` prefix and a `-beta` suffix cost nothing. A tag that is
    /// not a number at all reads as `0`, which makes it older than anything rather than newer than everything.
    nonisolated private static func numbers(in version: String) -> [Int] {
        version.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: ".")
            .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    nonisolated private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// What can go wrong, in the words the settings page shows.
///
/// Every case carries what is needed to say something useful: "Update failed" with no reason is a message
/// that costs a support round trip to turn into the sentence that should have been there already.
enum UpdateError: Error, LocalizedError, Equatable {
    case noResponse
    case http(Int)
    case noArchive
    case noChecksum
    case checksumMismatch
    case malformedArchive
    case notAnApp
    case toolFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .noResponse:
            "The update server did not answer."
        case .http(404):
            "No published release was found."
        case .http(let code):
            "The update server answered \(code)."
        case .noArchive:
            "That release has no downloadable build."
        case .noChecksum:
            "That release has no checksum to verify against."
        case .checksumMismatch:
            "The download did not match its checksum, so it was discarded."
        case .malformedArchive:
            "The downloaded build was not a readable app."
        case .notAnApp:
            "This copy is not an app bundle, so it cannot replace itself."
        case .toolFailed(let tool, let message):
            message.isEmpty ? "\(tool) failed." : "\(tool) failed: \(message)"
        }
    }
}
