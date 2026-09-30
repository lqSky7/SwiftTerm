import Foundation
import Observation

@MainActor @Observable final class CodeReviewCoordinator {
    private(set) var root: String?
    private(set) var summary = GitSummary()
    private(set) var selected: GitFileChange?
    private(set) var document: GitDiffDocument?
    private(set) var error: String?
    private(set) var isLoading = false
    private(set) var isChangingIndex = false
    private(set) var expandedLargeDiff = false
    var isPresented = false
    private(set) var sidebarWidth: CGFloat = 460
    private(set) var fileListHeight: CGFloat = 190
    @ObservationIgnored private var widthAtDragStart: CGFloat?
    @ObservationIgnored private var filesHeightAtDragStart: CGFloat?
    @ObservationIgnored var onSummary: ((GitSummary?) -> Void)?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var diffTask: Task<Void, Never>?

    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var directory: String?

    func width(available: CGFloat) -> CGFloat { min(sidebarWidth, max(0, available)) }

    func dragWidth(by translation: CGFloat, available: CGFloat) {
        if widthAtDragStart == nil { widthAtDragStart = width(available: available) }
        sidebarWidth = min(max(0, available), max(240, min(900, (widthAtDragStart ?? sidebarWidth) + translation)))
    }

    func endWidthDrag() { widthAtDragStart = nil }

    func filesHeight(available: CGFloat) -> CGFloat { min(fileListHeight, max(0, available - 174)) }

    func dragFilesHeight(by translation: CGFloat, available: CGFloat) {
        if filesHeightAtDragStart == nil { filesHeightAtDragStart = filesHeight(available: available) }
        fileListHeight = min(max(0, available - 174), max(64, (filesHeightAtDragStart ?? fileListHeight) + translation))
    }

    func endFilesDrag() { filesHeightAtDragStart = nil }

    func refresh(directory: String?) {
        refreshTask?.cancel()
        if self.directory != directory { clear() }
        self.directory = directory
        guard let directory else { clear(); return }
        refreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                let metadata = await Task.detached(priority: .utility) {
                    RepoMetadata.inspect(directory: directory)
                }.value
                try Task.checkCancellation()
                guard let self else { return }
                if root != metadata.repositoryRoot {
                    diffTask?.cancel()
                    root = metadata.repositoryRoot
                    selected = nil
                    document = nil
                    summary = GitSummary()
                    onSummary?(nil)
                }
                guard let root else { return }
                let result = try await GitRepositoryService.summary(root: root)
                try Task.checkCancellation()
                summary = result
                error = nil
                onSummary?(result)
                if let selected, let current = result.files.first(where: { $0.id == selected.id }) {
                    select(current)
                } else {
                    diffTask?.cancel()
                    selected = nil
                    document = nil
                    isLoading = false
                }
            } catch is CancellationError { } catch {
                guard !Task.isCancelled, let self else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func select(_ file: GitFileChange) {
        diffTask?.cancel()
        selected = file
        document = nil
        expandedLargeDiff = false
        error = nil
        guard let root else { return }
        isLoading = true
        diffTask = Task { [weak self] in
            do {
                let document = try await GitRepositoryService.diff(root: root, file: file)
                try Task.checkCancellation()
                guard let self else { return }
                self.document = document
                isLoading = false
            } catch is CancellationError { } catch {
                guard !Task.isCancelled, let self else { return }
                self.error = error.localizedDescription
                isLoading = false
            }
        }
    }

    func expandLargeDiff() { expandedLargeDiff = true }

    func changeIndex() {
        guard let root, let selected, !isChangingIndex else { return }
        isChangingIndex = true
        indexTask = Task { [weak self] in
            do {
                try await GitRepositoryService.stage(root: root, file: selected)
                guard let self else { return }
                isChangingIndex = false
                if self.root == root { refresh(directory: root) }
            } catch {
                guard let self else { return }
                isChangingIndex = false
                if self.root == root { self.error = error.localizedDescription }
            }
        }
    }

    func close() {
        isPresented = false
        diffTask?.cancel()
        document = nil
        selected = nil
        isLoading = false
    }

    func stop() { refreshTask?.cancel(); diffTask?.cancel(); indexTask?.cancel() }

    private func clear() {
        diffTask?.cancel()
        root = nil
        summary = GitSummary()
        selected = nil
        document = nil
        isLoading = false
        onSummary?(nil)
    }
}
