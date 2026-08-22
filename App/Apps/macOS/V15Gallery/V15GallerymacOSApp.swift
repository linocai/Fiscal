import AppKit
import FiscalKit
import SwiftUI

private final class V15GallerymacOSActivationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct V15GallerymacOSApp: App {
    @NSApplicationDelegateAdaptor(V15GallerymacOSActivationDelegate.self) private var activationDelegate

    var body: some Scene {
        WindowGroup { V15GalleryShell() }
            .windowResizability(.contentMinSize)
    }
}
