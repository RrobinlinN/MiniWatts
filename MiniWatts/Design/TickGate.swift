import Combine
import SwiftUI
import UIKit

/// Hands the monitor's once-a-second change on to the views that redraw with it —
/// `Panel`, and `PageScaffold`'s content and backdrop — except while a page is moving.
///
/// On an iPhone 12 (iOS 16, 60 Hz) a scroll left to coast on Power stuttered at every
/// tick, and taking out the dial's glow or the live chart, one at a time, did not
/// stop it: the redraw as a whole does not fit in a frame there. While the page
/// moves, the change is held; once it has been still for a moment, the newest
/// reading is drawn. The readings themselves are taken and recorded as before — only
/// the drawing waits.
final class TickGate: ObservableObject {
    /// How long the page has to stay still before a held change is drawn.
    private static let settleDelay: Duration = .milliseconds(150)

    private var forwarding: AnyCancellable?
    private var isMoving = false
    private var heldChange = false
    private var settle: Task<Void, Never>?

    init(monitor: PowerMonitor) {
        forwarding = monitor.objectWillChange.sink { [weak self] _ in
            self?.monitorWillChange()
        }
    }

    /// Called by `ScrollMotionProbe` whenever the page's scroll offset changes.
    func scrollMoved() {
        isMoving = true
        settle?.cancel()
        settle = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            self?.becameStill()
        }
    }

    private func monitorWillChange() {
        if isMoving {
            heldChange = true
        } else {
            objectWillChange.send()
        }
    }

    private func becameStill() {
        isMoving = false
        guard heldChange else { return }
        heldChange = false
        objectWillChange.send()
    }
}

/// Reports every move of the scroll view it sits in. Placed in a page's scroll
/// content; it finds the `UIScrollView` behind SwiftUI's `ScrollView` by walking up
/// its own superviews, and watches its offset. iOS 16 has no SwiftUI call for this.
struct ScrollMotionProbe: UIViewRepresentable {
    let onMove: () -> Void

    func makeUIView(context: Context) -> ProbeView {
        ProbeView(onMove: onMove)
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.onMove = onMove
    }

    final class ProbeView: UIView {
        var onMove: () -> Void
        private var observation: NSKeyValueObservation?

        init(onMove: @escaping () -> Void) {
            self.onMove = onMove
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used from a storyboard") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            observation = nil
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
            guard let scrollView = ancestor as? UIScrollView else { return }
            observation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                self?.onMove()
            }
        }
    }
}

/// The gate, handed down without observing it, for the scaffold that reports motion
/// to it. The views that redraw on a tick observe it as an environment object.
private nonisolated struct TickGateKey: EnvironmentKey {
    static let defaultValue: TickGate? = nil
}

extension EnvironmentValues {
    var tickGate: TickGate? {
        get { self[TickGateKey.self] }
        set { self[TickGateKey.self] = newValue }
    }
}
