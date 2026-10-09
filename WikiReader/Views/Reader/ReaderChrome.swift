import SwiftUI

private struct ReaderBarBackground: ViewModifier {
    let color: Color
    let edge: VerticalEdge

    func body(content: Content) -> some View {
        content
            .background {
                // Opaque color running into the safe area, so no text shows through or behind the bar.
                color.ignoresSafeArea(edges: edge == .top ? .top : .bottom)
            }
            .overlay(alignment: edge == .top ? .bottom : .top) {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 0.5)
            }
    }
}

extension View {
    /// Background for the reader's top and bottom menus: a solid color with a hairline on the edge facing the text.
    func readerBar(edge: VerticalEdge, color: Color) -> some View {
        modifier(ReaderBarBackground(color: color, edge: edge))
    }
}

enum SwipeDirection {
    case left, right
}

/// Takes over the horizontal swipe in the reader. The system's swipe-from-the-left-edge that goes back is turned
/// off while the reader is on screen (it would collide with the swipe that opens the table of contents; going back
/// is the button in the top bar). Instead, a clear sideways swipe anywhere, from a finger or a two-finger trackpad
/// swipe, calls `onSwipe`.
struct SwipeBackEnabler: UIViewControllerRepresentable {
    var onSwipe: (SwipeDirection) -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onSwipe = onSwipe
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var onSwipe: (SwipeDirection) -> Void = { _ in }
        private let swipe = UIPanGestureRecognizer()
        private var isInstalled = false
        /// Readers currently on screen. When one article gives way to the next, the old reader can disappear after
        /// the new one has appeared; the system gesture may only come back when none is left.
        private static var liveCount = 0
        private var isCounted = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let navigationController else { return }
            if !isInstalled {
                swipe.addTarget(self, action: #selector(handleSwipe(_:)))
                swipe.delegate = self
                swipe.allowedScrollTypesMask = .all
                navigationController.view.addGestureRecognizer(swipe)
                isInstalled = true
            }
            swipe.isEnabled = true
            if !isCounted {
                isCounted = true
                Self.liveCount += 1
            }
            navigationController.interactivePopGestureRecognizer?.isEnabled = false
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            swipe.isEnabled = false
            if isCounted {
                isCounted = false
                Self.liveCount -= 1
            }
            // Leaving: the library below gets the system gesture back.
            if Self.liveCount <= 0 {
                navigationController?.interactivePopGestureRecognizer?.isEnabled = true
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            let velocity = swipe.velocity(in: swipe.view)
            return abs(velocity.x) > 2 * abs(velocity.y)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc private func handleSwipe(_ gesture: UIPanGestureRecognizer) {
            guard gesture.state == .ended else { return }
            let translation = gesture.translation(in: gesture.view)
            guard abs(translation.x) > 80, abs(translation.x) > 2 * abs(translation.y) else { return }
            onSwipe(translation.x > 0 ? .right : .left)
        }
    }
}
