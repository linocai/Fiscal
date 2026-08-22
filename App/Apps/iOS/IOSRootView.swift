import FiscalKit
import SwiftUI

/// The formal iOS composition root deliberately owns no legacy navigation or
/// presentation state. Its V15 services use the production API, access-key,
/// revision and offline-storage boundaries supplied by the app target.
struct IOSRootView: View {
    let services: V15Services
    let bootstrapAccessKey: String?

    var body: some View {
        V15IOSLiveAppShell(services: services, bootstrapAccessKey: bootstrapAccessKey)
            .tint(V15Palette.teal.color)
    }
}
