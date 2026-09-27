import FiscalKit
import SwiftUI

/// The formal iOS composition root deliberately owns no legacy navigation or
/// presentation state. Its V15 services use the production API, access-key,
/// revision and offline-storage boundaries supplied by the app target.
struct IOSRootView: View {
    let services: V15Services
    let bootstrapAccessKey: String?
    let qaURLScheme: String?
    @State private var proposalRequest: V15ProposalOpenRequest?
    @State private var routeError: String?

    init(services: V15Services, bootstrapAccessKey: String?, qaURLScheme: String? = nil) {
        self.services = services
        self.bootstrapAccessKey = bootstrapAccessKey
        self.qaURLScheme = qaURLScheme
    }

    var body: some View {
        V15IOSLiveAppShell(
            services: services,
            bootstrapAccessKey: bootstrapAccessKey,
            proposalOpenRequest: proposalRequest,
            onProposalRouteAccepted: { FiscalProposalNavigation.consume($0) }
        )
            .tint(V15Palette.teal.color)
            .onAppear {
                if let id = FiscalProposalNavigation.pendingProposalID() {
                    proposalRequest = V15ProposalOpenRequest(proposalID: id)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: FiscalProposalNavigation.didRequest)) { notification in
                if let id = notification.userInfo?[FiscalProposalNavigation.proposalIDKey] as? UUID {
                    proposalRequest = V15ProposalOpenRequest(proposalID: id)
                }
            }
            .onOpenURL { url in
                let routedURL: URL
                if let qaURLScheme, url.scheme == qaURLScheme, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    components.scheme = "fiscal"
                    routedURL = components.url ?? url
                } else {
                    routedURL = url
                }
                if let request = V15ProposalOpenRequest(url: routedURL) { proposalRequest = request }
                else { routeError = "这条内容链接无法识别。请返回记一笔，查看待确认内容。" }
            }
            .alert("无法打开内容", isPresented: Binding(get: { routeError != nil }, set: { if !$0 { routeError = nil } })) {
                Button("返回", role: .cancel) { routeError = nil }
            } message: {
                Text(routeError ?? "")
            }
    }
}
