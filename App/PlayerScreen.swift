// SPDX-License-Identifier: Apache-2.0
import AVFAudio
import Combine
import MediaPlayer
import SwiftUI
import UIKit

struct PlayerScreen: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(RibbonStyle.storageKey) private var ribbonStyle: RibbonStyle = .off
    @State private var mode: Mode = .artwork
    @State private var showsLyricsControls = true
    @State private var previousIdleTimerDisabled: Bool?
    @State private var showsLandscapeControls = false
    @State private var landscapeControlActivity = 0
    @State private var outputName = ""
    @State private var panel: Panel?
    @State private var artworkColors: ArtworkPalette.Sample?
    @State private var backdropTile: UIImage?
    @State private var bassPulse: UInt64 = 0
    @State private var loadedArtwork: (trackID: String, image: UIImage)?
    @GestureState private var draftPosition: Double?
    @State private var showWaveformMessage = false
    @State private var mixError: String?
    @GestureState private var dismissalDrag: CGFloat = 0

    private var playback: PlaybackEngine { model.playback }
    private var playerArtwork: UIImage? {
        playback.artwork ?? (loadedArtwork?.trackID == playback.current?.id ? loadedArtwork?.image : nil)
    }
    private var animatesBass: Bool {
        playback.playing && scenePhase == .active && model.dynamicColor && !reduceMotion
    }
    private var ribbonCaptureEnabled: Bool {
        ribbonStyle != .off && scenePhase == .active && !reduceMotion
    }
    private var dark: Bool { colorScheme == .dark }
    private var artworkPalette: ArtworkPalette? { model.dynamicColor ? artworkColors?.palette : nil }
    private var accent: Color { artworkPalette?.accent(dark: dark) ?? .primary }

    private enum Mode: Hashable {
        case artwork, lyrics, queue
    }

    private enum Panel: String, Identifiable {
        case volume = "Output volume"
        case speed = "Playback speed"
        case stats = "Playback statistics"
        case info = "Audio information"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            playerGrabber

            GeometryReader { geometry in
                if let track = playback.current {
                    ZStack(alignment: .top) {
                        layout(for: track, bounds: geometry.size)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .id(mode)
                            .transition(modeTransition)
                    }
                    .clipped()
                }
            }
        }
        .offset(y: reduceMotion ? 0 : dismissalDrag * 0.55)
        .animation(reduceMotion || dismissalDrag > 0 ? nil : .smooth(duration: 0.24), value: dismissalDrag)
        .background {
            GeometryReader { geometry in
                let diameter = max(geometry.size.width, geometry.size.height)
                let base = Color(uiColor: .systemBackground)
                ZStack {
                    base
                    if let glow = artworkPalette?.backdrop(dark: dark) {
                        glow.opacity(dark ? 0.46 : 0.54)
                        RadialGradient(colors: [glow.opacity(0.92), glow.opacity(0)], center: .topTrailing,
                                       startRadius: 0, endRadius: max(1, diameter * 0.98))
                        RadialGradient(colors: [glow.opacity(0.68), glow.opacity(0)], center: .bottomLeading,
                                       startRadius: 0, endRadius: max(1, diameter * 0.74))
                    }
                    if model.dynamicColor, let backdropTile {
                        ArtworkDrift(tile: backdropTile,
                                     playing: playback.playing && scenePhase == .active && !reduceMotion,
                                     dark: dark, bassRegion: animatesBass ? artworkColors?.bassRegion : nil,
                                     pulse: bassPulse)
                            .transition(.opacity)
                    }
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .overlay {
            if ribbonStyle != .off {
                RibbonOverlay(playback: playback, style: ribbonStyle,
                              playsAnimation: ribbonCaptureEnabled && playback.playing)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: ribbonCaptureEnabled, initial: true) { _, enabled in
            playback.setRibbonCaptureEnabled(enabled)
        }
        .onDisappear { playback.setRibbonCaptureEnabled(false) }
        .task(id: animatesBass) {
            bassPulse = 0
            guard animatesBass else { return }
            while !Task.isCancelled {
                let event = playback.latestBassEvent
                let now = DispatchTime.now().uptimeNanoseconds / 1_000_000
                if event != 0, event != bassPulse, now - min(now, event >> 8) <= 150 {
                    bassPulse = event
                }
                do { try await Task.sleep(for: .milliseconds(28)) }
                catch { return }
            }
        }
        .task(id: playback.current?.id) {
            loadedArtwork = nil
            guard let track = playback.current, playback.artwork == nil else { return }
            // A restored queue can show artwork before an audio item has opened.
            guard let image = await model.artwork(for: track), !Task.isCancelled,
                  playback.current?.id == track.id else { return }
            loadedArtwork = (track.id, image)
        }
        .onChange(of: playerArtwork, initial: true) { _, image in
            let tile = image?.preparingThumbnail(of: CGSize(width: 192, height: 192))
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) {
                artworkColors = image.flatMap(ArtworkPalette.sample)
                backdropTile = tile
            }
        }
        .onAppear {
            refreshOutput()
            updateIdleTimer(for: scenePhase)
        }
        .onChange(of: scenePhase) { _, phase in updateIdleTimer(for: phase) }
        .onDisappear(perform: restoreIdleTimer)
        .onChange(of: mode) { _, mode in
            if mode != .lyrics { showsLyricsControls = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: RunLoop.main)) { _ in
            refreshOutput()
        }
        .sheet(item: $panel) { item in
            panelContent(item)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert("Audio visualization", isPresented: $showWaveformMessage) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The waveform is available for imported audio files.")
        }
        .alert("Instant Mix", isPresented: Binding(get: { mixError != nil }, set: { if !$0 { mixError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(mixError ?? "")
        }
    }

    private var playerGrabber: some View {
        Button {
            dismiss()
        } label: {
            Capsule()
                .fill(.secondary)
                .frame(width: 38, height: 5)
                .frame(width: 112, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close player")
        .accessibilityHint("Returns to the library")
        .highPriorityGesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .global)
                .updating($dismissalDrag) { value, offset, _ in
                    let down = value.translation.height
                    offset = down > abs(value.translation.width) ? down : 0
                }
                .onEnded { value in
                    let down = value.translation.height
                    guard down > abs(value.translation.width) else { return }
                    if down >= 76 || (down >= 20 && value.predictedEndTranslation.height >= 145) {
                        dismiss()
                    }
                }
        )
        .frame(maxWidth: .infinity)
    }

    private var modeTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .offset(y: 16).combined(with: .opacity),
            removal: .offset(y: -10).combined(with: .opacity)
        )
    }

    private func switchMode(to target: Mode) {
        guard mode != target else { return }
        let animation: Animation = reduceMotion ? .easeInOut(duration: 0.18) : .smooth(duration: 0.32)
        withAnimation(animation) { mode = target }
    }

    @ViewBuilder private func layout(for track: Track, bounds: CGSize) -> some View {
        let horizontal = bounds.width >= 660 || (bounds.width >= 540 && bounds.width > bounds.height * 1.32)
        if mode != .artwork {
            detailLayout(for: track, viewport: bounds, horizontal: horizontal)
        } else if horizontal {
            HStack(spacing: 24) {
                stage(for: track, viewport: bounds)
                    .frame(maxWidth: 530, maxHeight: .infinity)
                ScrollView {
                    VStack(spacing: 16) {
                        trackSummary(track)
                        controlDeck(airy: false)
                    }
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(.center, for: .alignment)
                .frame(minWidth: 254, maxWidth: 390)
            }
            .padding(.horizontal, 22)
            .frame(maxWidth: 1020, maxHeight: .infinity)
            .frame(maxWidth: .infinity)
        } else if dynamicType.isAccessibilitySize || bounds.height < 450 {
            ScrollView {
                VStack(spacing: 12) {
                    stage(for: track, viewport: bounds).frame(height: max(215, min(bounds.width, 340)))
                    trackSummary(track)
                    controlDeck(airy: false)
                }
                .padding(16)
            }
        } else {
            let airy = bounds.height >= 600
            VStack(spacing: 12) {
                if airy {
                    stage(for: track, viewport: bounds)
                        .frame(height: min(bounds.width - 52 + 14, bounds.height * 0.52))
                } else {
                    stage(for: track, viewport: bounds)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                trackSummary(track)
                controlDeck(airy: airy)
            }
            .padding(.horizontal, 26)
            .padding(.top, 3)
            .padding(.bottom, 8)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func detailLayout(for track: Track, viewport: CGSize, horizontal: Bool) -> some View {
        if horizontal && mode == .lyrics {
            landscapeLyrics(for: track, viewport: viewport)
        } else if horizontal {
            HStack(spacing: 26) {
                VStack(spacing: 18) {
                    detailHeader(track)
                    playerTools()
                }
                .frame(minWidth: 280, maxWidth: 380)
                stage(for: track, viewport: viewport)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 8)
            .frame(maxWidth: 1020, maxHeight: .infinity)
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 12) {
                detailHeader(track)
                stage(for: track, viewport: viewport)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if mode == .lyrics {
                    VStack(spacing: 4) {
                        if showsLyricsControls {
                            lyricsControls
                                .transition(reduceMotion ? .opacity : .offset(y: 18).combined(with: .opacity))
                        }
                        playerTools(showsVolume: !showsLyricsControls)
                    }
                } else {
                    playerTools()
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func landscapeLyrics(for track: Track, viewport: CGSize) -> some View {
        let width = min(viewport.width, 1020)
        let artWidth = (width - 72) * 0.46
        return HStack(spacing: 24) {
            GeometryReader { geometry in
                let side = max(0, min(520, geometry.size.width, geometry.size.height - 8))
                art(track)
                    .frame(width: side, height: side)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: artWidth)

            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    trackTitle(track, includeAlbum: false)
                    favoriteButton(track)
                    playbackOptions(includesLandscapeControls: true)
                }
                .fixedSize(horizontal: false, vertical: true)

                LyricsScreen(viewport: viewport, usesSplitLayout: true, onVerticalSwipe: setLandscapeControls)

                if showsLandscapeControls {
                    landscapeControls
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(reduceMotion ? .opacity : .offset(y: 64).combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
        .frame(width: width)
        .clipped()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: showsLandscapeControls && draftPosition == nil ? landscapeControlActivity : nil) {
            guard showsLandscapeControls, draftPosition == nil else { return }
            do { try await Task.sleep(for: .seconds(4)) }
            catch { return }
            guard !Task.isCancelled else { return }
            setLandscapeControls(visible: false)
        }
        .onDisappear { showsLandscapeControls = false }
    }

    private var landscapeControls: some View {
        let playing = playback.playing || playback.waiting
        return HStack(spacing: 10) {
            Button {
                switchMode(to: .artwork)
            } label: {
                PlayerRoundIcon(title: "Close lyrics", icon: "quote.bubble")
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)

            seekBar(showFormat: false, compact: true)

            Button {
                landscapeControlActivity += 1
                playback.toggle()
            } label: {
                PlayerRoundIcon(title: playing ? "Pause" : "Play", icon: playing ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
        }
    }

    private func setLandscapeControls(visible: Bool) {
        if visible { landscapeControlActivity += 1 }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
            showsLandscapeControls = visible
        }
    }

    private func detailHeader(_ track: Track) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Button {
                switchMode(to: .artwork)
            } label: {
                Cover(track: track, knownImage: playerArtwork, radius: 10)
                    .frame(width: 70, height: 70)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show album artwork")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    trackTitle(track, albumFirst: true)
                    favoriteButton(track)
                    playbackOptions()
                }
                if mode != .lyrics { seekBar(showFormat: false) }
            }
        }
    }

    private func trackTitle(_ track: Track, albumFirst: Bool = false, includeAlbum: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(track.title).font(.title3.weight(.semibold)).lineLimit(2)
            let fields = includeAlbum
                ? (albumFirst ? [track.album, track.artist] : [track.artist, track.album])
                : [track.artist]
            let subtitle = fields.filter { !$0.isEmpty }.joined(separator: " · ")
            if !subtitle.isEmpty {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trackSummary(_ track: Track) -> some View {
        HStack(spacing: 8) {
            trackTitle(track)
            favoriteButton(track)
            playbackOptions()
        }
        .frame(minHeight: 52)
    }

    private func favoriteButton(_ track: Track) -> some View {
        let favorite = model.favorites.contains(track.id)
        return Button {
            model.toggleFavorite(track)
        } label: {
            PlayerRoundIcon(title: favorite ? "Remove favorite" : "Favorite",
                            icon: favorite ? "heart.fill" : "heart")
                .foregroundStyle(favorite ? accent : .primary)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityAddTraits(favorite ? .isSelected : [])
    }

    @ViewBuilder private func stage(for track: Track, viewport: CGSize) -> some View {
        switch mode {
        case .artwork:
            GeometryReader { geometry in
                let side = max(0, min(geometry.size.width, geometry.size.height - 14, 520))
                art(track)
                    .frame(width: side, height: side)
                    .scaleEffect(playback.playing || reduceMotion ? 1 : 0.9)
                    .animation(reduceMotion ? nil : .timingCurve(0.455, 1, 0.509, 0.91, duration: 0.49),
                               value: playback.playing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipped()
        case .lyrics:
            LyricsScreen(viewport: viewport, onVerticalSwipe: setLyricsControls)
        case .queue:
            QueueScreen(artworkAccent: artworkPalette?.accent(dark: dark))
                .clipped()
        }
    }

    private func art(_ track: Track) -> some View {
        Cover(track: track, knownImage: playerArtwork, radius: 18)
            .overlay(alignment: .bottom) {
                if model.visualizer, !playback.waveform.isEmpty {
                    Waveform(samples: playback.waveform, position: playback.position, duration: playback.duration)
                        .frame(height: 57)
                        .padding(.horizontal, 18).padding(.bottom, 15)
                        .background(alignment: .bottom) {
                            LinearGradient(colors: [.black.opacity(0.72), .clear], startPoint: .bottom, endPoint: .top)
                        }
                        .clipShape(.rect(cornerRadius: 18))
                        .accessibilityHidden(true)
                }
            }
    }

    private func playbackOptions(includesLandscapeControls: Bool = false) -> some View {
        Menu {
            if includesLandscapeControls {
                Button(showsLandscapeControls ? "Hide playback controls" : "Show playback controls",
                       systemImage: "slider.horizontal.3") {
                    setLandscapeControls(visible: !showsLandscapeControls)
                }
                Button("Queue", systemImage: "list.bullet") { switchMode(to: .queue) }
            }
            playbackOptionItems
        } label: {
            PlayerRoundIcon(title: "Playback options", icon: "ellipsis")
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
    }

    @ViewBuilder private var playbackOptionItems: some View {
        if let track = playback.current {
            Button("Instant Mix", systemImage: "music.note.list") {
                Task {
                    do { try await model.startInstantMix(from: track) }
                    catch { mixError = error.localizedDescription }
                }
            }
            .disabled(model.isPreparingMix)
        }
        if mode != .artwork {
            let active = playback.playing || playback.waiting
            Button(active ? "Pause" : "Play", systemImage: active ? "pause.fill" : "play.fill") {
                playback.toggle()
            }
            if playback.error != nil { Button("Retry playback") { playback.resume() } }
        }
        Button("Playback speed", systemImage: "speedometer") { panel = .speed }
        Menu("Edge lighting", systemImage: "light.strip.2") {
            Picker("Edge lighting", selection: $ribbonStyle) {
                ForEach(RibbonStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
        }
        Button(model.visualizer ? "Hide waveform" : "Show waveform", systemImage: "waveform") {
            if let track = playback.current, case .server = track.location { showWaveformMessage = true }
            else { model.visualizer.toggle() }
        }
        Button("Playback statistics", systemImage: "chart.bar") { panel = .stats }
        Button("Audio information", systemImage: "info.circle") { panel = .info }
    }

    private func controlDeck(airy: Bool) -> some View {
        VStack(spacing: airy ? 12 : 8) {
            seekBar()
            if airy { Spacer(minLength: 10) }
            transport
            if airy { Spacer(minLength: 10) }
            playerTools()
            if let error = playback.error {
                HStack {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("Retry") { playback.resume() }.buttonStyle(.glass)
                }
            }
        }
    }

    private var lyricsControls: some View {
        VStack(spacing: 4) {
            seekBar(showFormat: false, compact: true)
            transport
                .padding(.vertical, 10)
            SystemVolumeSlider().frame(height: 32)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setLyricsControls(visible: Bool) {
        guard visible != showsLyricsControls else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            showsLyricsControls = visible
        }
    }

    private func playerTools(showsVolume: Bool = true) -> some View {
        HStack(spacing: 2) {
            toolButton("Playback speed", icon: "speedometer") { panel = .speed }
                .frame(maxWidth: .infinity)
            if showsVolume {
                toolButton("Volume", icon: "speaker.wave.2") { panel = .volume }
                    .frame(maxWidth: .infinity)
            }
            RoutePicker(tint: UIColor.secondaryLabel)
                .frame(width: 44, height: 44)
                .accessibilityValue(outputName)
                .frame(maxWidth: .infinity)
            modeButton(.lyrics, "Lyrics", "quote.bubble")
                .frame(maxWidth: .infinity)
            modeButton(.queue, "Queue", "list.bullet")
                .frame(maxWidth: .infinity)
        }
    }

    private func toolButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func modeButton(_ target: Mode, _ title: String, _ icon: String) -> some View {
        Button {
            switchMode(to: mode == target ? .artwork : target)
        } label: {
            Label(title, systemImage: icon)
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(mode == target ? .regular.interactive() : .identity, in: .circle)
        .foregroundStyle(mode == target ? Color.primary : Color.secondary)
        .accessibilityAddTraits(mode == target ? .isSelected : [])
    }

    private func refreshOutput() {
        outputName = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName).joined(separator: ", ")
    }

    private func updateIdleTimer(for phase: ScenePhase) {
        guard phase == .active else {
            restoreIdleTimer()
            return
        }
        guard previousIdleTimerDisabled == nil else { return }
        previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func restoreIdleTimer() {
        guard let previousIdleTimerDisabled else { return }
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        self.previousIdleTimerDisabled = nil
    }

    private func seekBar(showFormat: Bool = true, compact: Bool = false) -> some View {
        let duration = playback.duration.isFinite ? max(0, playback.duration) : 0
        let position = draftPosition ?? playback.position
        let value = position.isFinite ? max(0, min(position, duration)) : 0
        return VStack(spacing: 1) {
            seekRail(value: value, duration: duration)
                .frame(height: compact ? 34 : 44)
                .id(playback.queue.current?.id)

            if mode == .artwork {
                HStack {
                    Text(clock(value))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if showFormat, let format = playback.current?.format, !format.isEmpty, !format.contains(",") {
                        Button { panel = .info } label: {
                            Text(format.uppercased())
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: 80)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Audio information")
                    }
                    Text(duration > 0 ? "−\(clock(max(0, duration - value)))" : "–:––")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .foregroundStyle(.secondary)
                .font(.caption.monospacedDigit())
            }
        }
    }

    private func seekRail(value: Double, duration: Double) -> some View {
        GeometryReader { geometry in
            let progress = duration > 0 ? value / duration : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.23))
                Capsule().fill(.primary.opacity(0.85))
                    .frame(width: geometry.size.width * progress)
            }
            .frame(height: 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($draftPosition) { drag, draft, _ in
                        draft = seekPosition(at: drag.location.x, width: geometry.size.width, duration: duration)
                    }
                    .onEnded { drag in
                        guard duration > 0 else { return }
                        playback.seek(to: seekPosition(at: drag.location.x, width: geometry.size.width, duration: duration))
                    },
                isEnabled: duration > 0
            )
        }
        .accessibilityRepresentation {
            Slider(value: Binding(get: { value }, set: { playback.seek(to: $0) }),
                   in: 0...(duration > 0 ? duration : 1),
                   step: min(5, max(0.1, duration / 10))) {
                Text("Playback position")
            }
            .disabled(duration <= 0)
            .accessibilityValue("\(clock(value)) of \(clock(duration))")
        }
    }

    private func seekPosition(at x: CGFloat, width: CGFloat, duration: Double) -> Double {
        guard width > 0 else { return 0 }
        let fraction = min(1, max(0, x / width))
        return (layoutDirection == .rightToLeft ? 1 - fraction : fraction) * duration
    }

    private var transport: some View {
        let active = playback.playing || playback.waiting
        let shuffled = playback.queue.shuffled
        let repeatMode = playback.queue.repeatMode
        return HStack(spacing: 0) {
            toolButton("Shuffle", icon: "shuffle") { playback.toggleShuffle() }
                .foregroundStyle(shuffled ? accent : Color.secondary)
                .accessibilityAddTraits(shuffled ? .isSelected : [])
            Button {
                playback.previous()
            } label: {
                Label("Previous", systemImage: "backward.end.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .frame(minHeight: 52)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                playback.toggle()
            } label: {
                Group {
                    if playback.waiting {
                        ProgressView()
                    } else {
                        Image(systemName: active ? "pause.fill" : "play.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .font(.system(size: 34, weight: .semibold))
                .frame(width: 58, height: 58)
                .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel(active ? "Pause" : "Play")
            Button {
                playback.next()
            } label: {
                Label("Next", systemImage: "forward.end.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .frame(minHeight: 52)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            toolButton("Repeat \(repeatMode.rawValue)", icon: repeatMode == .one ? "repeat.1" : "repeat") {
                playback.cycleRepeat()
            }
            .foregroundStyle(repeatMode == .off ? Color.secondary : accent)
            .accessibilityAddTraits(repeatMode == .off ? [] : .isSelected)
        }
        .labelStyle(.iconOnly)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: active)
    }

    private var speedLabel: String { String(format: "%.1f×", playback.speed) }

    private func panelContent(_ item: Panel) -> some View {
        PlayerDetails(title: item.rawValue) {
            switch item {
            case .volume:
                SystemVolumeSlider().frame(height: 44)
                if !outputName.isEmpty { LabeledContent("Output", value: outputName) }
            case .speed:
                Stepper(value: Binding(
                    get: { Int((playback.speed * 10).rounded()) },
                    set: { playback.setSpeed(Float($0) / 10) }
                ), in: 5...20) {
                    LabeledContent("Speed", value: speedLabel)
                }
                Button("Reset to 1.0×") { playback.setSpeed(1) }
            case .stats:
                if let track = playback.current {
                    LabeledContent("Times played", value: String(playback.statistics.plays[track.id, default: 0]))
                }
                LabeledContent("Listening time", value: clock(playback.statistics.listeningSeconds))
                LabeledContent("In queue", value: String(playback.queue.entries.count))
            case .info:
                if let track = playback.current {
                    LabeledContent("Title", value: track.title)
                    LabeledContent("Format", value: track.format?.uppercased() ?? "Unknown")
                    LabeledContent("Duration", value: clock(playback.duration))
                    LabeledContent("Source", value: track.sourceType)
                }
            }
        }
    }
}

private struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = false
        view.tintColor = .secondaryLabel
        view.accessibilityLabel = "Output volume"
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {}
}

private struct PlayerDetails<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form { content }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark") { dismiss() }.buttonStyle(.glassProminent)
                    }
                }
        }
    }
}

private extension Track {
    var sourceType: String {
        switch location {
        case .local: "On this device"
        case .server: "Music server"
        }
    }
}

private struct Waveform: View {
    let samples: [Float]
    let position: Double
    let duration: Double

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty, duration > 0, position.isFinite else { return }
            let center = Int(min(1, max(0, position / duration)) * Double(samples.count - 1))
            let count = 35
            let spacing = size.width / Double(count)
            for index in 0..<count {
                let sample = center + index - count / 2
                guard samples.indices.contains(sample) else { continue }
                let magnitude = min(1, sqrt(Double(samples[sample])) * 2.8)
                let height = max(2, magnitude * size.height)
                let rect = CGRect(x: Double(index) * spacing, y: (size.height - height) / 2,
                                  width: max(1, spacing * 0.63), height: height)
                let opacity = sample == center ? 1.0 : (sample < center ? 0.45 : 0.8)
                context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(.white.opacity(opacity)))
            }
        }
    }
}

private struct PlayerRoundIcon: View {
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon)
            .labelStyle(.iconOnly)
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 44, height: 44)
            .contentShape(Circle())
    }
}

private struct QueueScreen: View {
    let artworkAccent: Color?
    @Environment(LibraryModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var editing = EditMode.inactive

    private var playback: PlaybackEngine { model.playback }
    private var accent: Color { artworkAccent ?? (colorScheme == .dark ? .white : .black) }

    private var accentInk: Color {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        guard UIColor(accent).getRed(&red, green: &green, blue: &blue, alpha: nil) else {
            return colorScheme == .dark ? .black : .white
        }
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        return luminance >= 0.179 ? .black : .white
    }

    private var firstUpcoming: Int { playback.queue.index.map { $0 + 1 } ?? 0 }
    private var upcoming: ArraySlice<PlaybackQueue.Entry> { playback.queue.entries.dropFirst(firstUpcoming) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            queueHeader
            if upcoming.isEmpty {
                ContentUnavailableView("No upcoming songs", systemImage: "list.bullet")
            } else {
                List {
                    ForEach(upcoming) { entry in
                        row(entry)
                            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                            .listRowBackground(Color.clear)
                    }
                    .onDelete { offsets in
                        let entries = Array(upcoming)
                        for index in offsets where entries.indices.contains(index) {
                            playback.remove(entries[index].id)
                        }
                    }
                    .onMove(perform: reorder)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollEdgeEffectStyle(.soft, for: .vertical)
                .environment(\.editMode, $editing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var queueHeader: some View {
        let repeatMode = playback.queue.repeatMode
        let shuffled = playback.queue.shuffled
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                queueAction("Shuffle", icon: "shuffle", selected: shuffled) { playback.toggleShuffle() }
                queueAction("Repeat \(repeatMode.rawValue)", icon: repeatMode == .one ? "repeat.1" : "repeat",
                            selected: repeatMode != .off) { playback.cycleRepeat() }
                queueAction(editing.isEditing ? "Done" : "Edit queue", icon: editing.isEditing ? "checkmark" : "line.3.horizontal",
                            selected: editing.isEditing, action: toggleEditing)
                    .disabled(upcoming.isEmpty)
            }
            HStack(spacing: 8) {
                Text("Queue").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                if !upcoming.isEmpty, upcoming.allSatisfy({ $0.track.duration > 0 }) {
                    let duration = clock(upcoming.reduce(0) { $0 + $1.track.duration })
                    Text(duration)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Total upcoming duration")
                        .accessibilityValue(duration)
                }
            }
        }
        .padding(.bottom, 4)
        .onChange(of: upcoming.isEmpty) { _, empty in
            if empty { editing = .inactive }
        }
    }

    private func queueAction(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(selected ? accentInk : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .glassEffect(.regular.tint(accent.opacity(selected ? 1 : 0.16)).interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func toggleEditing() {
        withAnimation { editing = editing.isEditing ? .inactive : .active }
    }

    private func row(_ entry: PlaybackQueue.Entry) -> some View {
        let track = entry.track
        return HStack(spacing: 6) {
            Button {
                playback.select(entry.id)
            } label: {
                HStack(spacing: 10) {
                    Cover(track: track, radius: 7).frame(width: 42, height: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).font(.subheadline.weight(.medium))
                        let subtitle = [track.album, track.artist].filter { !$0.isEmpty }.joined(separator: " · ")
                        if !subtitle.isEmpty {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if track.duration > 0 {
                        Text(clock(track.duration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(editing.isEditing)

            if !editing.isEditing {
                Menu {
                    Button("Play now", systemImage: "play.fill") { playback.select(entry.id) }
                    Button("Remove from queue", systemImage: "minus.circle", role: .destructive) {
                        playback.remove(entry.id)
                    }
                } label: {
                    PlayerRoundIcon(title: "Options for \(track.title)", icon: "ellipsis")
                }
                .buttonStyle(.borderless)
                .tint(.primary)
            }
        }
    }

    private func reorder(_ offsets: IndexSet, _ destination: Int) {
        let entries = Array(upcoming)
        let earlier = offsets.prefix { $0 < destination }.count
        let start = firstUpcoming + destination - earlier
        let selected = offsets.map { entries[$0].id }
        // Move the rows approaching the insertion point from either side in order.
        let order = Array((0..<earlier).reversed()) + Array(earlier..<selected.count)
        for offset in order {
            let target = start + offset
            let id = selected[offset]
            guard let from = playback.queue.entries.firstIndex(where: { $0.id == id }), from != target else { continue }
            playback.move(id, by: target - from)
        }
    }
}

// Orbit speeds and layer proportions adapted from this project's earlier
// Apple-Music-Web-Server/public/artwork-backdrop.js.
private struct ArtworkDrift: View {
    let tile: UIImage
    let playing: Bool
    let dark: Bool
    let bassRegion: ArtworkPalette.BassRegion?
    let pulse: UInt64
    @State private var elapsed: TimeInterval = 0
    @State private var started: Date?

    private struct ArtworkLayer {
        let center: CGPoint
        let angle: Double
        let edge: CGFloat
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing)) { timeline in
            let time = elapsed + (started.map { max(0, timeline.date.timeIntervalSince($0)) } ?? 0)
            ZStack {
                Canvas { context, size in
                    let image = context.resolve(Image(uiImage: tile))
                    for layer in layers(in: size, time: time) {
                        paint(image, in: context, layer: layer)
                    }
                }
                .blur(radius: 75)
                .saturation(1.25)
                .brightness(dark ? -0.12 : 0)
                .opacity(dark ? 0.34 : 0.24)

                if let bassRegion {
                    expandingColor(bassRegion, time: time)
                }
            }
            .clipped()
        }
        .onChange(of: playing, initial: true) { _, active in
            let now = Date()
            if active {
                started = now
            } else if let started {
                elapsed += max(0, now.timeIntervalSince(started))
                self.started = nil
            }
        }
        .accessibilityHidden(true)
    }

    private func expandingColor(_ region: ArtworkPalette.BassRegion, time: TimeInterval) -> some View {
        KeyframeAnimator(initialValue: CGFloat.zero, trigger: pulse) { amount in
            let intensity = min(1, max(0, amount))
            region.color
                .opacity(0.52 * intensity)
                .mask {
                    Canvas { context, size in
                        let position = intensity * CGFloat(region.masks.count - 1)
                        let lower = Int(position)
                        let upper = min(lower + 1, region.masks.count - 1)
                        let inner = context.resolve(Image(uiImage: region.masks[lower]))
                        let outer = context.resolve(Image(uiImage: region.masks[upper]))
                        var overlay = context
                        overlay.opacity = position - CGFloat(lower)
                        // The opaque grayscale tiles use the same transforms and occlusion as the artwork.
                        for layer in layers(in: size, time: time) {
                            paint(inner, in: context, layer: layer)
                            paint(outer, in: overlay, layer: layer)
                        }
                    }
                    .blur(radius: 46)
                    .luminanceToAlpha()
                }
        } keyframes: { _ in
            let strength = CGFloat(pulse & 0xff) / 255
            LinearKeyframe(strength > 0 ? 0.30 + 0.70 * strength : 0, duration: 0.18,
                           timingCurve: .bezier(startControlPoint: .init(x: 0.18, y: 0.72),
                                                endControlPoint: .init(x: 0.32, y: 1)))
            LinearKeyframe(0, duration: 1.12,
                           timingCurve: .bezier(startControlPoint: .init(x: 0.24, y: 0.08),
                                                endControlPoint: .init(x: 0.36, y: 1)))
        }
    }

    private func layers(in size: CGSize, time: TimeInterval) -> [ArtworkLayer] {
        let edge = max(size.width, size.height)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let outerOrbit = time * 0.16 + 0.7
        let innerOrbit = -time * 0.13 + 3
        return [
            ArtworkLayer(center: center, angle: 0.31 + time * 0.09, edge: edge * 1.46),
            ArtworkLayer(center: center, angle: -0.58 - time * 0.23, edge: edge * 0.81),
            ArtworkLayer(center: CGPoint(x: center.x + cos(outerOrbit) * edge * 0.24,
                                         y: center.y + sin(outerOrbit) * edge * 0.24),
                         angle: 0.42 + time * 0.17, edge: edge * 0.51),
            ArtworkLayer(center: CGPoint(x: center.x + cos(innerOrbit) * edge * 0.29,
                                         y: center.y + sin(innerOrbit) * edge * 0.29),
                         angle: -0.24 - time * 0.14, edge: edge * 0.27)
        ]
    }

    private func paint(_ image: GraphicsContext.ResolvedImage, in context: GraphicsContext, layer: ArtworkLayer) {
        let size = tile.size
        guard size.width > 0, size.height > 0 else { return }
        var drawing = context
        drawing.translateBy(x: layer.center.x, y: layer.center.y)
        drawing.rotate(by: .radians(layer.angle))
        let scale = layer.edge / min(size.width, size.height)
        let width = size.width * scale
        let height = size.height * scale
        drawing.draw(image, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
    }
}

private struct LyricsScreen: View {
    let viewport: CGSize
    var usesSplitLayout = false
    var onVerticalSwipe: ((Bool) -> Void)? = nil
    @Environment(LibraryModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @ScaledMetric(relativeTo: .title3) private var timedFontScale = 1.44
    @ScaledMetric(relativeTo: .title3) private var plainFontScale = 1.155
    @State private var state = LoadState.loading
    @State private var follow = true
    @State private var isScrollingLyrics = false
    @State private var retry = 0
    @State private var scrollPosition = ScrollPosition()
    @State private var rowFrames: [Int: CGRect] = [:]
    @State private var targetOffset: CGFloat = 0
    @State private var rowMotion: RowMotion?

    nonisolated private static let scrollDuration = 0.58
    nonisolated private static let leadDelay = 0.044
    private static let resumeDelay: Duration = .seconds(4)
    private static let topFadeEnd: CGFloat = 0.04
    private static let blurBleed: CGFloat = 18
    private static let maximumBlur: CGFloat = 5.5
    nonisolated private static let cueCurve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.16, y: 0),
                                                  endControlPoint: UnitPoint(x: 0.19, y: 1.07))

    private struct LyricRowFrames: PreferenceKey {
        static let defaultValue: [Int: CGRect] = [:]

        static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
        }
    }

    private struct RowMotion {
        let id = UUID()
        let started: Date
        let distanceByRow: [Int: CGFloat]
        let leadingRows: Int?
        let curve: UnitCurve

        func displacement(for index: Int, elapsed: TimeInterval) -> CGFloat {
            let distance = distanceByRow[index] ?? 0
            guard abs(distance) >= 0.5 else { return 0 }
            let delaySteps = leadingRows.map { min(4, max(0, index - $0)) } ?? 0
            let delay = Double(delaySteps) * LyricsScreen.leadDelay
            let progress = (elapsed - delay) / LyricsScreen.scrollDuration
            if progress <= 0 { return distance }
            if progress >= 1 { return 0 }
            return distance * CGFloat(1 - curve.value(at: progress))
        }
    }

    private var playback: PlaybackEngine { model.playback }
    private var shouldAnimateScroll: Bool { !reduceMotion && !voiceOver }

    private enum LoadState {
        case loading, unavailable, loaded(TrackLyrics), failed(String)
    }

    private struct RequestID: Equatable {
        let track: String?
        let retry: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Group {
                switch state {
                case .loading:
                    ProgressView("Loading lyrics")
                case .unavailable:
                    ContentUnavailableView("No lyrics available", systemImage: "quote.bubble",
                                           description: Text("Lyrics are available for songs that have lyrics on Jellyfin."))
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn’t load lyrics", systemImage: "exclamationmark.bubble")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Retry") { retry += 1 }.buttonStyle(.glass)
                    }
                case .loaded(let lyrics):
                    lyricList(lyrics)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .bottomTrailing) {
            if !follow, case .loaded(let lyrics) = state, lyrics.isTimed {
                Button("Follow lyrics", systemImage: "location.fill") { follow = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .padding(6)
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 12).onEnded { drag in
                let vertical = drag.translation.height
                if abs(vertical) >= 32 && abs(vertical) > abs(drag.translation.width) {
                    onVerticalSwipe?(vertical > 0)
                }
            },
            isEnabled: onVerticalSwipe != nil
        )
        .task(id: RequestID(track: playback.current?.id, retry: retry)) {
            state = .loading
            follow = true
            isScrollingLyrics = false
            rowMotion = nil
            rowFrames.removeAll()
            targetOffset = 0
            scrollPosition = ScrollPosition()
            guard let track = playback.current else { state = .unavailable; return }
            do {
                let lyrics = try await model.lyrics(for: track)
                try Task.checkCancellation()
                state = lyrics.map(LoadState.loaded) ?? .unavailable
            } catch is CancellationError {
                // The active track changed or the lyrics view was dismissed.
            } catch {
                if !Task.isCancelled { state = .failed(error.localizedDescription) }
            }
        }
    }

    private func lyricList(_ lyrics: TrackLyrics) -> some View {
        let active = lyrics.activeLine(at: playback.position)
        let softenSurrounding = lyrics.isTimed && follow && !voiceOver
        let portrait = viewport.width <= viewport.height
        // Layout units for tracking from public/style.css in the earlier web player.
        let unit = portrait ? min(viewport.height * 0.00075, viewport.width * 0.0015)
            : min(viewport.height * 0.0010834236, viewport.width * 0.0008695652)
        return GeometryReader { geo in
            let edgeInset = voiceOver ? 0 : geo.size.height * Self.topFadeEnd
            let referenceWidth = usesSplitLayout ? geo.size.width + 48 : viewport.width
            let fontSize = referenceFontSize(timed: lyrics.isTimed, width: referenceWidth)
                * (lyrics.isTimed ? timedFontScale : plainFontScale)
            let tracking = portrait ? -0.025 * fontSize : -0.74 * min(unit, viewport.width * 0.000725)
            let lineHeight = fontSize * (lyrics.isTimed ? (portrait ? 1.18 : 59 / 48.5) : 1.53)
            let focusInset = voiceOver ? 0 : min(geo.size.height * 0.24, edgeInset + lineHeight + 18)
            let showsPrevious = softenSurrounding && (active ?? 0) > 0
            let topFadeEnd = showsPrevious ? min(0.14, focusInset / max(1, geo.size.height) * 0.72) : Self.topFadeEnd

            ScrollView {
                if lyrics.isTimed {
                    TimelineView(.animation(minimumInterval: 1.0 / 60, paused: rowMotion == nil)) { timeline in
                        let elapsed = rowMotion.map { timeline.date.timeIntervalSince($0.started) } ?? 0
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(lyrics.lines.indices, id: \.self) { index in
                                lyricRow(lyrics.lines[index], at: index, active: active, softenSurrounding: softenSurrounding,
                                         fontSize: fontSize, tracking: tracking, lineHeight: lineHeight)
                                    .offset(y: rowMotion?.displacement(for: index, elapsed: elapsed) ?? 0)
                                    .background {
                                        GeometryReader { row in
                                            Color.clear.preference(key: LyricRowFrames.self,
                                                                   value: [index: row.frame(in: .named("lyricTrack"))])
                                        }
                                    }
                            }
                        }
                        .padding(.top, edgeInset)
                        .padding(.bottom, max(0, geo.size.height - focusInset))
                        .frame(maxWidth: .infinity)
                        .coordinateSpace(name: "lyricTrack")
                        .padding(.horizontal, Self.blurBleed)
                    }
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(lyrics.lines.indices, id: \.self) { index in
                            lyricText(lyrics.lines[index].text, selected: false, timed: false, fontSize: fontSize,
                                      tracking: -0.025 * fontSize, lineHeight: lineHeight, blurRadius: 0)
                        }
                    }
                    .padding(.vertical, 16)
                    .padding(.horizontal, Self.blurBleed)
                }
            }
            .scrollPosition($scrollPosition)
            .scrollEdgeEffectHidden(true, for: .vertical)
            .mask {
                if voiceOver { Rectangle() }
                else { lyricEdgeFade(topFadeEnd: topFadeEnd) }
            }
            .onScrollPhaseChange { _, phase, context in
                guard lyrics.isTimed else { return }
                isScrollingLyrics = phase != .idle
                if phase == .interacting || !follow {
                    targetOffset = context.geometry.contentOffset.y + context.geometry.contentInsets.top
                }
                if phase == .interacting {
                    rowMotion = nil
                    follow = false
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                if !follow { targetOffset = offset }
            }
            .task(id: lyrics.isTimed && !follow && !isScrollingLyrics) {
                guard lyrics.isTimed, !follow, !isScrollingLyrics else { return }
                do { try await Task.sleep(for: Self.resumeDelay) }
                catch { return }
                guard !Task.isCancelled, !isScrollingLyrics else { return }
                follow = true
            }
            .onPreferenceChange(LyricRowFrames.self) { frames in
                guard frames != rowFrames else { return }
                rowFrames = frames
                if follow, lyrics.isTimed {
                    positionLyrics(at: active ?? 0, height: geo.size.height, topInset: focusInset, animate: false)
                }
            }
            .onChange(of: active) { previous, current in
                guard follow, lyrics.isTimed else { return }
                let advancesOneLine = previous.map { current == $0 + 1 } ?? false
                positionLyrics(at: current ?? 0, height: geo.size.height, topInset: focusInset,
                               animate: advancesOneLine && shouldAnimateScroll && playback.playing)
            }
            .onChange(of: follow) { _, enabled in
                if enabled, lyrics.isTimed {
                    positionLyrics(at: active ?? 0, height: geo.size.height, topInset: focusInset,
                                   animate: shouldAnimateScroll, stagger: false)
                }
            }
            .task(id: rowMotion?.id) {
                guard rowMotion != nil else { return }
                do { try await Task.sleep(for: .seconds(Self.scrollDuration + 4 * Self.leadDelay)) }
                catch { return }
                guard !Task.isCancelled else { return }
                rowMotion = nil
            }
            // Keep the same text column while allowing blur to extend past its sides.
            .padding(.horizontal, -Self.blurBleed)
        }
    }

    // Port of updateLyrics in the earlier web player: sample previous row positions,
    // snap the track to its new target, then animate the old-to-new distance per row.
    private func positionLyrics(at index: Int, height: CGFloat, topInset: CGFloat, animate: Bool, stagger: Bool = true) {
        guard let focused = rowFrames[index], height > 0 else { return }
        let destination = max(0, focused.minY - topInset)
        let now = Date()
        var nextMotion: RowMotion?
        if animate, abs(destination - targetOffset) >= 0.5 || rowMotion != nil {
            let elapsed = rowMotion.map { now.timeIntervalSince($0.started) } ?? 0
            let previousTops = Dictionary(uniqueKeysWithValues: rowFrames.map { row, frame in
                (row, frame.minY - targetOffset + (rowMotion?.displacement(for: row, elapsed: elapsed) ?? 0))
            })
            let firstVisible = previousTops.keys.sorted().first {
                previousTops[$0, default: 0] >= height * 0.10
            } ?? 0
            let distances = Dictionary(uniqueKeysWithValues: previousTops.map { row, previous in
                (row, previous - (rowFrames[row, default: .zero].minY - destination))
            })
            nextMotion = RowMotion(started: now, distanceByRow: distances,
                                   leadingRows: stagger ? firstVisible + 1 : nil,
                                   curve: stagger ? Self.cueCurve : .easeInOut)
        }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            rowMotion = nextMotion
            targetOffset = destination
            scrollPosition.scrollTo(y: destination)
        }
    }

    private func lyricEdgeFade(topFadeEnd: CGFloat) -> some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black.opacity(0.42), location: topFadeEnd * 0.425),
            .init(color: .black, location: topFadeEnd),
            .init(color: .black, location: 0.89),
            .init(color: .black.opacity(0.72), location: 0.935),
            .init(color: .black.opacity(0.24), location: 0.977),
            .init(color: .clear, location: 1)
        ], startPoint: .top, endPoint: .bottom)
    }

    private func referenceFontSize(timed: Bool, width: CGFloat) -> CGFloat {
        // Use the web player's portrait proportions for each reading column.
        timed ? min(42, max(23, width * 0.062)) : min(33, max(18, width * 0.057))
    }

    @ViewBuilder private func lyricRow(_ line: TrackLyrics.Line, at index: Int, active: Int?,
                                       softenSurrounding: Bool, fontSize: CGFloat, tracking: CGFloat, lineHeight: CGFloat) -> some View {
        let distance = index - (active ?? 0)
        let blurRadius: CGFloat = switch (softenSurrounding, distance) {
        case (true, ..<0): 4
        case (true, 1...): Self.maximumBlur * (1 - exp(-CGFloat(distance) / 3.3))
        default: 0
        }
        let opacity: Double = switch (softenSurrounding, distance) {
        case (true, ..<(-1)): 0
        case (true, -1): 0.48
        case (true, 2...): 1 - 0.43 * (1 - exp(-Double(distance - 1) / 5))
        default: 1
        }
        if let start = line.start, !line.text.isEmpty {
            Button {
                playback.seek(to: start)
            } label: {
                lyricText(line.text, selected: active == index, timed: true, fontSize: fontSize,
                          tracking: tracking, lineHeight: lineHeight, blurRadius: blurRadius, opacity: opacity)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(active == index ? .isSelected : [])
        } else {
            lyricText(line.text, selected: active == index, timed: line.start != nil, fontSize: fontSize,
                          tracking: tracking, lineHeight: lineHeight, blurRadius: blurRadius, opacity: opacity)
        }
    }

    private func lyricText(_ text: String, selected: Bool, timed: Bool, fontSize: CGFloat,
                           tracking: CGFloat, lineHeight: CGFloat, blurRadius: CGFloat, opacity: Double = 1) -> some View {
        Text(verbatim: text.isEmpty ? " " : text)
            .font(.system(size: fontSize, weight: timed ? .bold : .regular))
            .tracking(tracking)
            .lineHeight(.exact(points: lineHeight))
            .foregroundStyle(selected || !timed ? .primary : .secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Self.blurBleed)
            .blur(radius: blurRadius)
            .padding(-Self.blurBleed)
            .opacity(opacity)
            .animation(shouldAnimateScroll ? .easeOut(duration: 0.115) : nil, value: blurRadius)
            .animation(shouldAnimateScroll ? .easeOut(duration: 0.28) : nil, value: opacity)
            .contentShape(Rectangle())
    }

}
