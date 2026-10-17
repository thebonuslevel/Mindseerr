import SwiftUI
import UIKit

/// Puts the logo in the tvOS tab bar's trailing accessory view, the spot UIKit provides for an app logo.
/// Living inside the tab bar, it slides away with the bar as content scrolls instead of floating over it.
///
/// SwiftUI has no API for the tab bar's accessory views, so this adds an invisible view controller to a
/// tab's content, which can reach the tab bar controller around it. Attach it to every tab's content;
/// the logo is only installed once. The tab bar is shared by every tab, so `visible` decides whether the
/// logo shows (only on Settings); every tab passes the same value.
struct TabBarLogo: UIViewControllerRepresentable {
    let visible: Bool

    func makeUIViewController(context: Context) -> Installer { Installer() }
    func updateUIViewController(_ controller: Installer, context: Context) {
        controller.visible = visible
    }

    final class Installer: UIViewController {
        private static let logoTag = 0x0BB5
        private var timer: Timer?
        var visible = false {
            didSet { if visible != oldValue { install() } }
        }

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            install()
            // tvOS rebuilds the accessory view's contents after navigation and tab switches, dropping the
            // logo, so check about once a second and put it back if it's gone.
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.install() }
                }
            }
        }

        deinit { timer?.invalidate() }

        private func install() {
            guard let tabBar = tabBarController?.tabBar else { return }
            let container = tabBar.trailingAccessoryView
            if let existing = container.viewWithTag(Self.logoTag) {
                existing.isHidden = !visible
                existing.alpha = 1
                return
            }
            guard let image = UIImage(named: "CthulhuMark") else { return }

            let logo = UIImageView(image: image)
            logo.tag = Self.logoTag
            logo.contentMode = .scaleAspectFit
            logo.isAccessibilityElement = false
            logo.isHidden = !visible
            logo.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(logo)
            NSLayoutConstraint.activate([
                logo.heightAnchor.constraint(equalToConstant: 64),
                logo.widthAnchor.constraint(equalTo: logo.heightAnchor, multiplier: image.size.width / image.size.height),
                logo.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                logo.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                logo.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                logo.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor),
                logo.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
            ])
        }
    }
}

extension View {
    /// Installs the logo in the tab bar (see `TabBarLogo`), shown only when `visible`. Apply to each tab's root view.
    func tabBarLogo(visible: Bool) -> some View {
        background(TabBarLogo(visible: visible).frame(width: 0, height: 0).allowsHitTesting(false))
    }
}
