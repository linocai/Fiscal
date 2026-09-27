import SwiftUI

public struct V15ProposalOpenRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let proposalID: UUID

    public init(proposalID: UUID) {
        id = UUID()
        self.proposalID = proposalID
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "fiscal", url.host?.lowercased() == "ai" else { return nil }
        let segments = url.pathComponents.filter { $0 != "/" }
        guard segments.count == 2, segments[0] == "proposals", let proposalID = UUID(uuidString: segments[1]) else { return nil }
        self.init(proposalID: proposalID)
    }
}

/// Formal application composition. Authentication remains a narrow gate; once
/// available, the only live roots are the v1.5.1 prototype-faithful platform
/// workspaces. Gallery routes and the former generic endpoint navigation are
/// deliberately absent.
#if os(iOS)
public struct V15IOSLiveAppShell: View {
    private let services: V15Services
    private let bootstrapAccessKey: String?
    private let proposalOpenRequest: V15ProposalOpenRequest?
    private let onProposalRouteAccepted: (UUID) -> Void
    @State private var isAvailable = false
    @State private var prepared = false

    public init(services: V15Services, bootstrapAccessKey: String? = nil, proposalOpenRequest: V15ProposalOpenRequest? = nil, onProposalRouteAccepted: @escaping (UUID) -> Void = { _ in }) {
        self.services = services
        self.bootstrapAccessKey = bootstrapAccessKey
        self.proposalOpenRequest = proposalOpenRequest
        self.onProposalRouteAccepted = onProposalRouteAccepted
    }

    public var body: some View {
        Group {
            if !prepared {
                V15LoadingSkeleton(layout: .decisionCard)
                    .accessibilityIdentifier("v15.live.bootstrap.preparing")
            } else if !isAvailable {
                V15BootstrapView(services: services, onAvailable: { isAvailable = true })
            } else {
                V151IOSWorkspace(services: services, proposalOpenRequest: proposalOpenRequest, onProposalRouteAccepted: onProposalRouteAccepted)
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
    private let proposalOpenRequest: V15ProposalOpenRequest?
    @State private var isAvailable = false
    @State private var prepared = false

    public init(services: V15Services, bootstrapAccessKey: String? = nil, proposalOpenRequest: V15ProposalOpenRequest? = nil) {
        self.services = services
        self.bootstrapAccessKey = bootstrapAccessKey
        self.proposalOpenRequest = proposalOpenRequest
    }

    public var body: some View {
        Group {
            if !prepared {
                V15LoadingSkeleton(layout: .decisionCard)
                    .accessibilityIdentifier("v15.live.bootstrap.preparing")
            } else if !isAvailable {
                V15BootstrapView(services: services, onAvailable: { isAvailable = true })
            } else {
                V151MacWorkspace(services: services, proposalOpenRequest: proposalOpenRequest)
            }
        }
        .frame(minWidth: V15MacLayout.minimumWindowWidth, minHeight: V15MacLayout.minimumWindowHeight)
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
