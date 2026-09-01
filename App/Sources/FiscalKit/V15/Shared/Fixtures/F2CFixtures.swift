import Foundation

/// F2-C has its own named gallery routing, while deliberately reusing the
/// F2-A contract payloads.  There is no second macOS-only facts truth.
enum V15F2CFixtures {
    @MainActor static func services(route: String) -> V15Services {
        let f2BRoute: String
        switch route {
        case "today-error": f2BRoute = "today-facts-error"
        case "today-scope-error": f2BRoute = "today-scope-error"
        case "today-page-error": f2BRoute = "today-page-error"
        case "today-conflict": f2BRoute = "today-conflict"
        case "today-refresh-lens-race": f2BRoute = "today-refresh-lens-race"
        case "today-offline": f2BRoute = "today-offline"
        case "today-unknown": f2BRoute = "today-unknown-scope"
        case "today-long": f2BRoute = "today-long"
        case "today-zero-future": f2BRoute = "today-zero-future"
        default: f2BRoute = "today"
        }
        return V15F2BFixtures.services(route: f2BRoute)
    }

    static let offlineSnapshotAt = V15F2BFixtures.offlineSnapshotAt
}
