import AppIntents
import SwiftUI

@main
struct MiniWattsApp: App {
    /// Held plainly, not as `@StateObject`: an `ObservableObject` held that way
    /// re-runs `body` on every change, which would rebuild the whole window once a
    /// second. `init` runs once per process, so a plain `let` lives as long.
    private let monitor: PowerMonitor
    /// One per process, and alive for as long as the app is: the layer Picture in
    /// Picture draws from cannot come and go with a settings sheet.
    private let floatingMeter = FloatingMeterController()

    init() {
        let monitor = PowerMonitor()
        self.monitor = monitor
        // The Shortcuts action runs in this process — launched in the background, with
        // no scene, when the app is not already running — and has to read through this
        // monitor's sensors rather than open its own: a process gets one working HID
        // client, and a second one reads NaN. Registered here because `init` is the
        // one place that runs on every launch, scene or no scene.
        AppDependencyManager.shared.add(dependency: monitor)
    }

    var body: some Scene {
        WindowGroup {
            RootView(monitor: monitor, floatingMeter: floatingMeter)
                .environmentObject(monitor)
                .environment(\.powerMonitor, monitor)
                .environmentObject(floatingMeter)
        }
    }
}
