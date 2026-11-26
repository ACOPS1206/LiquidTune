// SPDX-License-Identifier: Apache-2.0
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

    func makeCoordinator() -> Coordinator { Coordinator(playback: playback) }

    func makeUIView(context: Context) -> WKWebView {
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
        context.coordinator.connect(view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.update(style: style, playing: playsAnimation)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        view.navigationDelegate = nil
        view.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private struct Configuration: Equatable {
            let style: RibbonStyle
            let playing: Bool
            let inputID: UUID
        }

        private let playback: PlaybackEngine
        private weak var view: WKWebView?
        private var displayLink: CADisplayLink?
        private var ready = false
        private var commandPending = false
        private var pageID = UUID()
        private var style: RibbonStyle = .ribbon
        private var playing = false
        private var applied: Configuration?

        init(playback: PlaybackEngine) { self.playback = playback }

        func connect(_ view: WKWebView) {
            self.view = view
            view.navigationDelegate = self
            loadPage()
        }

        func update(style: RibbonStyle, playing: Bool) {
            self.style = style
            self.playing = playing
            updateDisplayLink()
            flush()
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
            let target = Configuration(style: style, playing: playing, inputID: playback.ribbonInputID)
            var script = ""
            if applied?.inputID != target.inputID { script += "ribbon.resetLive();" }
            if applied != target {
                let mode = target.playing ? "live" : "still"
                script += "ribbon.configure({mode:'\(mode)',style:'\(target.style.rawValue)'});"
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
