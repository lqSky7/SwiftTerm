import Foundation

@main struct SharingOfflineTest {
    @MainActor static func main() {
        let core = AppCore(persistsSession: false)
        func cloudIsAbsent() -> Bool {
            let value = Mirror(reflecting: core).children.first { $0.label == "cloudAccount" }!.value
            return Mirror(reflecting: value).children.isEmpty
        }
        precondition(cloudIsAbsent(), "Opening a workspace must not initialize cloud state")
        core.applySharingEnabled(false, persist: false)
        precondition(!core.openShareSheet())
        core.openAccount()
        core.openStaticShare(PaneID(rawValue: 1))
        core.preparePublicShare(PaneID(rawValue: 1), live: true)
        precondition(!core.startSharing(PaneID(rawValue: 1)))
        precondition(cloudIsAbsent() && !core.isPreparingShare && core.sharing.isEmpty)
        core.applySharingEnabled(true, persist: false)
        _ = core.account
        precondition(!cloudIsAbsent())
        core.applySharingEnabled(false, persist: false)
        precondition(cloudIsAbsent(), "Disabling must release existing cloud state")
        core.terminate()
        precondition(cloudIsAbsent(), "Teardown must not initialize cloud state")
        print("PASS: lazy cloud state, disabled entry points, release on disable, offline teardown; no windows or network")
    }
}
