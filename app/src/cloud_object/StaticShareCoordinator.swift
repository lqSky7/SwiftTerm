import Foundation
import Observation

@MainActor @Observable
final class StaticShareCoordinator {
    var blocks: [StaticShareBlockDraft] = []
    private(set) var isPreparing = true
    private(set) var isWorking = false
    private(set) var isFrozen = false
    private(set) var link: String?
    private(set) var error: String?
    private(set) var isRevoked = false
    @ObservationIgnored private let api: CloudAPI
    @ObservationIgnored private let origin: String
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pending: CloudRequest?
    @ObservationIgnored private var secret: String?
    @ObservationIgnored private var shareID: String?

    init(blocks: [Block], api: CloudAPI, origin: String) {
        self.api = api
        self.origin = origin
        do {
            let captured = try StaticShareExport.capture(blocks)
            task = Task {
                let masked = await Task.detached { StaticShareExport.redacted(captured) }.value
                guard !Task.isCancelled else { return }
                self.blocks = masked
                isPreparing = false
            }
        } catch {
            self.error = "No completed commands to export, or this pane exceeds the export limit."
            isPreparing = false
        }
    }

    func publish() {
        guard !isPreparing, !isWorking, link == nil else { return }
        error = nil
        do {
            if pending == nil {
                let snapshot = try StaticShareExport.snapshot(blocks, id: UUID().uuidString.lowercased())
                guard let credential = DeviceCredential.generate() else { throw CloudError.malformedResponse }
                let capability = credential.base64.replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                secret = capability
                pending = try CloudRoutes.publishShare(snapshot: snapshot,
                    requestID: UUID().uuidString.lowercased(), secret: capability)
                isFrozen = true
            }
        } catch {
            self.error = "Select a completed command and remove unsupported control characters or oversized text."
            return
        }
        guard let pending else { return }
        isWorking = true
        task = Task {
            defer { isWorking = false }
            do {
                let published = try await api.send(pending, as: CloudPublishedShare.self)
                guard !Task.isCancelled, let secret else { return }
                shareID = published.shareId
                link = "\(origin)/s/?id=\(published.publicLocator)#\(secret)"
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "Upload failed. Retry keeps the same snapshot and public link."
            }
        }
    }

    func revoke() {
        guard let shareID, !isWorking, !isRevoked else { return }
        isWorking = true
        error = nil
        task = Task {
            defer { isWorking = false }
            do {
                _ = try await api.send(CloudRoutes.revokeShare(id: shareID))
                guard !Task.isCancelled else { return }
                isRevoked = true
                link = nil
            } catch { self.error = "Could not revoke this link. Try again." }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isWorking = false
    }
}
