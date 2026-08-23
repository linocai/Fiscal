import SwiftUI

/// Formal application composition. Authentication remains a narrow gate; once
/// available, the only live roots are the v1.5.1 prototype-faithful platform
/// workspaces. Gallery routes and the former generic endpoint navigation are
/// deliberately absent.
#if os(iOS)
public struct V15IOSLiveAppShell: View {
    private let services: V15Services
    private let bootstrapAccessKey: String?
    @State private var isAvailable = false
    @State private var prepared = false

    public init(services: V15Services, bootstrapAccessKey: String? = nil) {
        self.services = services
        self.bootstrapAccessKey = bootstrapAccessKey
    }

    public var body: some View {
        Group {
            if !prepared {
                V15LoadingSkeleton(layout: .decisionCard)
                    .accessibilityIdentifier("v15.live.bootstrap.preparing")
            } else if !isAvailable {
                V15BootstrapView(services: services, onAvailable: { isAvailable = true })
            } else {
                V151IOSWorkspace(services: services)
            }
        }
        .background(V15Palette.paper.color)
        .accessibilityElement(children: .contain)
        .task {
            guard !prepared else { return }
            _ = try? await services.session.saveBootstrapAccessKeyIfPresent(bootstrapAccessKey)
            prepared = true
        }
    }
}
#endif

#if os(macOS)
public struct V15MacLiveAppShell: View {
    private let services: V15Services
    private let bootstrapAccessKey: String?
    @State private var isAvailable = false
    @State private var prepared = false

    public init(services: V15Services, bootstrapAccessKey: String? = nil) {
        self.services = services
        self.bootstrapAccessKey = bootstrapAccessKey
    }

    public var body: some View {
        Group {
            if !prepared {
                V15LoadingSkeleton(layout: .decisionCard)
                    .accessibilityIdentifier("v15.live.bootstrap.preparing")
            } else if !isAvailable {
                V15BootstrapView(services: services, onAvailable: { isAvailable = true })
            } else {
                V151MacWorkspace(services: services)
            }
        }
        .frame(minWidth: 1_000, minHeight: 680)
        .background(V15Palette.paper.color)
        .accessibilityElement(children: .contain)
        .task {
            guard !prepared else { return }
            _ = try? await services.session.saveBootstrapAccessKeyIfPresent(bootstrapAccessKey)
            prepared = true
        }
    }
}
#endif
