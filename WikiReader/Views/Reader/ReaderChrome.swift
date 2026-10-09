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

/// Hiding the navigation bar also turns off the swipe-from-the-left-edge gesture that goes back. This turns
/// it on again, so the reader can always be left without finding the top menu.
///
/// While something sits on top of the article (the saved words panel), a rightward swipe should put that away
/// first, and only the next one goes back to the library. Give `onSwipeBack` then: the system gesture is off
/// and a swipe to the right anywhere calls it instead. It also answers a two-finger trackpad swipe, like the
/// system gesture does.
struct SwipeBackEnabler: UIViewControllerRepresentable {
    var onSwipeBack: (() -> Void)?

    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onSwipeBack = onSwipeBack
        controller.applyIfVisible()
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var onSwipeBack: (() -> Void)?
        private let swipe = UIPanGestureRecognizer()
        private var isInstalled = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // Leaving: the library below must get the system gesture back.
            swipe.isEnabled = false
            navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        }

        func applyIfVisible() {
            if viewIfLoaded?.window != nil { apply() }
        }

        private func apply() {
            guard let navigationController else { return }
            if !isInstalled {
                swipe.addTarget(self, action: #selector(handleSwipe(_:)))
                swipe.delegate = self
                swipe.allowedScrollTypesMask = .all
                navigationController.view.addGestureRecognizer(swipe)
                isInstalled = true
            }
            // The system gesture's default delegate refuses it while the navigation bar is hidden.
            navigationController.interactivePopGestureRecognizer?.delegate = nil
            let intercepting = onSwipeBack != nil
            navigationController.interactivePopGestureRecognizer?.isEnabled = !intercepting
            swipe.isEnabled = intercepting
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            let velocity = swipe.velocity(in: swipe.view)
            return velocity.x > 0 && abs(velocity.x) > 2 * abs(velocity.y)
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
            if translation.x > 80 && abs(translation.x) > 2 * abs(translation.y) {
                onSwipeBack?()
            }
        }
    }
}
