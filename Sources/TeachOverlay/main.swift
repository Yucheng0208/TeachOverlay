import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // 只顯示在選單列，不出現在 Dock
    withExtendedLifetime(delegate) { app.run() }
}
