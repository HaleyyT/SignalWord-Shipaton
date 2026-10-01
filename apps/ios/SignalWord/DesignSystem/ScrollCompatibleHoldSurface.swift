import SwiftUI
import UIKit

/// UIKit lets the enclosing scroll view recognise a pan alongside the hold.
/// The recognizer fails once movement exceeds 18 points; only a stationary
/// 1.5-second hold confirms. VoiceOver uses the separate review action.
struct ScrollCompatibleHoldSurface: UIViewRepresentable {
    let duration: TimeInterval
    let enabled: Bool
    let pressing: (Bool) -> Void
    let confirmed: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        let recognizer = TrackingHoldRecognizer(target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        recognizer.minimumPressDuration = duration
        recognizer.allowableMovement = 18
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = context.coordinator
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.confirmed = confirmed
        guard let recognizer = view.gestureRecognizers?.first as? TrackingHoldRecognizer else { return }
        recognizer.pressing = { value in
            // Disabling a recognizer can synchronously cancel touches during
            // updateUIView. Deliver visual state after that SwiftUI update.
            DispatchQueue.main.async { pressing(value) }
        }
        if recognizer.isEnabled != enabled { recognizer.isEnabled = enabled }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var confirmed: (() -> Void)?
        @objc func changed(_ recognizer: UILongPressGestureRecognizer) {
            if recognizer.state == .began { confirmed?() }
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // SwiftUI scroll containers also install private pan recognizers.
            // Let movement compete; allowableMovement cancels this hold.
            true
        }
    }
}

final class TrackingHoldRecognizer: UILongPressGestureRecognizer {
    var pressing: ((Bool) -> Void)?
    private var start: CGPoint?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        start = touches.first?.location(in: view)
        pressing?(true)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        if let start, let position = touches.first?.location(in: view),
           hypot(position.x - start.x, position.y - start.y) > allowableMovement {
            pressing?(false)
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        pressing?(false)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        pressing?(false)
    }
}
