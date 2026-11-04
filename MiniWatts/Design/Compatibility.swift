import SwiftUI
import UIKit

/// SwiftUI calls that are iOS 17, with what stands in for them on iOS 16.
extension View {
    /// Pins a scroll column to the width of its container, capped at `maximum`, so
    /// nothing inside can widen the scroll content. See `PageScaffold` for why the
    /// cap has to be part of the same frame.
    ///
    /// `containerRelativeFrame` is iOS 17. Before it the container is taken to be the
    /// screen: every page that uses this fills the width of the window, and on an
    /// iPhone the window is the screen.
    @ViewBuilder
    func pinnedToContainerWidth(maximum: CGFloat? = nil) -> some View {
        if #available(iOS 17.0, *) {
            containerRelativeFrame(.horizontal) { width, _ in
                maximum.map { min(width, $0) } ?? width
            }
        } else {
            let width = UIScreen.main.bounds.width
            frame(width: maximum.map { min(width, $0) } ?? width)
        }
    }

    /// `onChange(of:initial: true)`, which is iOS 17: runs `action` once with the
    /// value the view appears with, then on every change.
    @ViewBuilder
    func onChangeIncludingInitial<Value: Equatable>(of value: Value,
                                                    perform action: @escaping (Value) -> Void) -> some View {
        if #available(iOS 17.0, *) {
            onChange(of: value, initial: true) { _, newValue in action(newValue) }
        } else {
            onAppear { action(value) }
                .onChange(of: value, perform: action)
        }
    }
}
