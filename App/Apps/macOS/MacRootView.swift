import FiscalKit
import SwiftUI

/// The formal macOS composition root deliberately owns no legacy navigation
/// or presentation state. Its V15 services use the production API,
/// access-key, revision and offline-storage boundaries supplied by the app.
struct MacRootView: View {
    let services: V15Services
    let bootstrapAccessKey: String?

    var body: some View {
        V15MacLiveAppShell(services: services, bootstrapAccessKey: bootstrapAccessKey)
            .tint(V15Palette.teal.color)
    }
}
