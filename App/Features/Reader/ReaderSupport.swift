import SwiftUI
import UIKit

struct ReaderInteractivePopEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.enableInteractivePopIfAvailable()
    }

    static func dismantleUIViewController(_ uiViewController: Controller, coordinator: Void) {
        uiViewController.restoreInteractivePopDelegate()
    }

    final class Controller: UIViewController {
        private weak var popGesture: UIGestureRecognizer?
        private var previousDelegate: (any UIGestureRecognizerDelegate)?
        private var releasedDelegate = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            enableInteractivePopIfAvailable()
        }

        func enableInteractivePopIfAvailable() {
            guard let navigationController,
                  navigationController.viewControllers.count > 1,
                  let gesture = navigationController.interactivePopGestureRecognizer else { return }
            if gesture.delegate != nil {
                previousDelegate = gesture.delegate
                gesture.delegate = nil
                releasedDelegate = true
            }
            gesture.isEnabled = true
            popGesture = gesture
        }

        func restoreInteractivePopDelegate() {
            guard releasedDelegate, let popGesture, popGesture.delegate == nil else { return }
            popGesture.delegate = previousDelegate
            previousDelegate = nil
            releasedDelegate = false
        }

    }
}

/// 阅读器点击区域换算。
/// 中央「菜单」区不再局限于九宫格正中间 1/3×1/3，而是放大到视口中间的一半
/// （各方向 ±25%），给手指落点留下容差，避免稍微点偏就触发翻页。
enum ReaderTapMapping {
    /// 中央判定半径占视口宽/高的比例。0.25 → 中央区为中间 1/2。
    static let centerRadiusRatio: CGFloat = 0.25

    static func isCenter(_ point: CGPoint, in size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0 else { return true }
        let dx = abs(point.x - size.width / 2)
        let dy = abs(point.y - size.height / 2)
        return dx <= size.width * centerRadiusRatio && dy <= size.height * centerRadiusRatio
    }

    /// 返回命中的点击动作（0 = 菜单）。坐标需为视口坐标。
    static func action(for point: CGPoint, in size: CGSize, clickActions: [Int]) -> Int {
        if isCenter(point, in: size) { return 0 }
        let column = min(max(Int(point.x / max(size.width / 3, 1)), 0), 2)
        let row = min(max(Int(point.y / max(size.height / 3, 1)), 0), 2)
        let index = row * 3 + column
        return clickActions.indices.contains(index) ? clickActions[index] : 0
    }
}

struct ReaderMenuDismissShape: Shape {
    var leadingExclusion: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        Path(CGRect(
            x: min(max(leadingExclusion, 0), rect.width),
            y: 0,
            width: max(rect.width - leadingExclusion, 0),
            height: rect.height
        ))
    }
}

@MainActor enum ReaderScreenOrientation {
    static private(set) var supportedOrientations: UIInterfaceOrientationMask = .allButUpsideDown

    static func apply(_ value: String) {
        let mask: UIInterfaceOrientationMask = switch value {
        case "1": .portrait
        case "2": .landscape
        case "3": .all
        case "4": .portraitUpsideDown
        case "5": .landscapeLeft
        default: .allButUpsideDown
        }
        supportedOrientations = mask
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        if #available(iOS 16.0, *) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
            scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        } else {
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    static func restoreApplicationDefault() { apply("0") }
}
