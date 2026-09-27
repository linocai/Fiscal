import FiscalKit
import SwiftUI

/// The formal macOS composition root deliberately owns no legacy navigation
/// or presentation state. Its V15 services use the production API,
/// access-key, revision and offline-storage boundaries supplied by the app.
struct MacRootView: View {
    let services: V15Services
    let bootstrapAccessKey: String?
    @State private var proposalRequest: V15ProposalOpenRequest?
    @State private var routeError: String?

    var body: some View {
        V15MacLiveAppShell(services: services, bootstrapAccessKey: bootstrapAccessKey, proposalOpenRequest: proposalRequest)
            .tint(V15Palette.teal.color)
            .onOpenURL { url in
                if let request = V15ProposalOpenRequest(url: url) { proposalRequest = request }
                else { routeError = "这条内容链接无法识别。请返回记一笔，查看待确认内容。" }
            }
            .alert("无法打开内容", isPresented: Binding(get: { routeError != nil }, set: { if !$0 { routeError = nil } })) {
                Button("返回", role: .cancel) { routeError = nil }
            } message: {
                Text(routeError ?? "")
            }
    }
}
