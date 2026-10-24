import SwiftUI
import AppKit

@main
struct WifiScannerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("WiFi Scanner") {
            ContentView()
                .frame(
                    minWidth: 980, idealWidth: 1320, maxWidth: .infinity,
                    minHeight: 640, idealHeight: 860, maxHeight: .infinity
                )
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1320, height: 860)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Scansione") {
                    NotificationCenter.default.post(name: .triggerScan, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let triggerScan = Notification.Name("WifiScannerApp.triggerScan")
    static let appWillTerminate = Notification.Name("WifiScannerApp.willTerminate")
}

/// AppDelegate per gestire pulitamente il ciclo di vita.
/// - Termina l'app quando l'ultima finestra si chiude (comportamento atteso per app utility a finestra singola)
/// - Notifica le view perché possano cancellare i task in corso prima del teardown
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Notifica le view, che cancellano i loro task prima che SwiftUI smonti tutto.
        NotificationCenter.default.post(name: .appWillTerminate, object: nil)
    }
}
