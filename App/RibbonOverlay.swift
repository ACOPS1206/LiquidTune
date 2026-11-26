// SPDX-License-Identifier: Apache-2.0
import Darwin
import QuartzCore
import SwiftUI
import UIKit
import WebKit

enum RibbonStyle: String, CaseIterable, Identifiable {
    case ribbon, orbit, frame, bottom, off

    static let storageKey = "ribbonStyle"

    var id: Self { self }
    var title: String {
        switch self {
        case .ribbon: "Ribbon"
        case .orbit: "Orbit"
        case .frame: "Full frame"
        case .bottom: "Bottom"
        case .off: "Off"
        }
    }
}

struct RibbonOverlay: UIViewRepresentable {
    let playback: PlaybackEngine
    let style: RibbonStyle
    let playsAnimation: Bool
    let colors: RibbonColors

    func makeCoordinator() -> Coordinator { Coordinator(playback: playback) }

    func makeUIView(context: Context) -> Container {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(
            source: "window.ribbonIOS = true;", injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.underPageBackgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        let coordinator = context.coordinator
        let container = Container(webView: view)
        container.onCorners = { [weak coordinator] radii in coordinator?.update(corners: radii) }
        coordinator.connect(view)
        return container
    }

    func updateUIView(_ view: Container, context: Context) {
        context.coordinator.update(style: style, playing: playsAnimation, colors: colors)
    }

    static func dismantleUIView(_ view: Container, coordinator: Coordinator) {
        coordinator.stop()
        view.webView.navigationDelegate = nil
        view.webView.stopLoading()
    }

    final class Container: UIView {
        let webView: WKWebView
        var onCorners: (([CGFloat]) -> Void)?

        init(webView: WKWebView) {
            self.webView = webView
            super.init(frame: .zero)
            cornerConfiguration = .corners(radius: .containerConcentric())
            addSubview(webView)
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            webView.frame = bounds
            let corners: [UIRectCorner] = [.topLeft, .topRight, .bottomRight, .bottomLeft]
            let resolved = corners.map { effectiveRadius(corner: $0) }
            if resolved.contains(where: { $0 > 0 }) {
                onCorners?(resolved)
            } else {
                onCorners?(Array(repeating: fullDisplayFallback, count: 4))
            }
        }

        private var fullDisplayFallback: CGFloat {
            guard let scene = window?.windowScene, scene.session.role == .windowApplication,
                  !bounds.isEmpty else { return 0 }
            let screen = scene.screen
            let frame = screen.coordinateSpace.convert(bounds, from: self)
            let full = screen.coordinateSpace.bounds
            guard abs(frame.minX - full.minX) < 2, abs(frame.minY - full.minY) < 2,
                  abs(frame.maxX - full.maxX) < 2, abs(frame.maxY - full.maxY) < 2 else { return 0 }
            let nativeWidth = min(screen.nativeBounds.width, screen.nativeBounds.height)
            let nativeHeight = max(screen.nativeBounds.width, screen.nativeBounds.height)
            // Use the measured 17 Pro Max value and the same-screen 16e estimate for 17e.
            // Matching native panel dimensions also keeps the fallback off external displays.
            switch (Self.hardwareModel, nativeWidth, nativeHeight) {
            case ("iPhone18,2", 1320, 2868):
                return 62 * 3 * min(full.width, full.height) / nativeWidth
            case ("iPhone18,5", 1170, 2532), ("iPhone17,5", 1170, 2532):
                return 47.33 * 3 * min(full.width, full.height) / nativeWidth
            default:
                return 0
            }
        }

        private static let hardwareModel: String = {
            #if targetEnvironment(simulator)
            ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
            #else
            var info = utsname()
            uname(&info)
            return withUnsafeBytes(of: info.machine) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            #endif
        }()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private struct Configuration: Equatable {
            let style: RibbonStyle
            let playing: Bool
            let inputID: UUID
            let colors: RibbonColors
            let corners: [CGFloat]
        }

        private let playback: PlaybackEngine
        private weak var view: WKWebView?
        private var displayLink: CADisplayLink?
        private var ready = false
        private var commandPending = false
        private var pageID = UUID()
        private var style: RibbonStyle = .ribbon
        private var playing = false
        private var colors = RibbonColors.standard
        private var corners: [CGFloat] = [0, 0, 0, 0]
        private var applied: Configuration?

        init(playback: PlaybackEngine) { self.playback = playback }

        func connect(_ view: WKWebView) {
            self.view = view
            view.navigationDelegate = self
            loadPage()
        }

        func update(style: RibbonStyle, playing: Bool, colors: RibbonColors) {
            self.style = style
            self.playing = playing
            self.colors = colors
            updateDisplayLink()
            flush()
        }

        func update(corners: [CGFloat]) {
            guard self.corners != corners else { return }
            self.corners = corners
            flush(includeAudio: false)
        }

        func stop() {
            ready = false
            view = nil
            displayLink?.invalidate()
            displayLink = nil
        }

        private func loadPage() {
            ready = false
            commandPending = false
            applied = nil
            pageID = UUID()
            updateDisplayLink()
            guard let page = Bundle.main.url(forResource: "Ribbon-Web", withExtension: "html") else { return }
            view?.loadFileURL(page, allowingReadAccessTo: page)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            updateDisplayLink()
            flush()
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            loadPage()
        }

        private func updateDisplayLink() {
            if ready && playing {
                guard displayLink == nil else { return }
                let displayLink = CADisplayLink(target: self, selector: #selector(refresh(_:)))
                displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
                displayLink.add(to: .main, forMode: .common)
                self.displayLink = displayLink
            } else {
                displayLink?.invalidate()
                displayLink = nil
            }
        }

        @objc private func refresh(_ link: CADisplayLink) { flush() }

        private func flush(includeAudio: Bool = true) {
            guard ready, !commandPending, let view else { return }
            let target = Configuration(style: style, playing: playing, inputID: playback.ribbonInputID,
                                       colors: colors, corners: corners)
            var script = ""
            if applied?.inputID != target.inputID { script += "ribbon.resetLive();" }
            if applied != target {
                let mode = target.playing ? "live" : "still"
                let radii = target.corners.map { String(describing: Double($0)) }.joined(separator: ",")
                script += """
                ribbon.configure({mode:'\(mode)',style:'\(target.style.rawValue)',
                  colorA:'\(target.colors.first)',colorB:'\(target.colors.second)',cornerRadii:[\(radii)]});
                """
            }
            if includeAudio, target.playing {
                let frames = playback.drainRibbonFrames()
                if !frames.isEmpty, let data = try? JSONSerialization.data(withJSONObject: frames),
                   let json = String(data: data, encoding: .utf8) {
                    script += "ribbon.pushLive(\(json));"
                }
            }
            guard !script.isEmpty else { return }
            commandPending = true
            let pageID = self.pageID
            view.evaluateJavaScript(script) { [weak self] _, error in
                guard let self, pageID == self.pageID else { return }
                self.commandPending = false
                guard error == nil else { return }
                self.applied = target
                // Commit changes made during this call, even if playback just paused.
                self.flush(includeAudio: false)
            }
        }
    }
}

struct RibbonColors: Equatable {
    let first: String
    let second: String

    static let standard = Self(first: "#649bff", second: "#986ceb")
}
