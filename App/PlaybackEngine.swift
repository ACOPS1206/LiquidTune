// SPDX-License-Identifier: Apache-2.0
import AVFoundation
import MediaPlayer
import MediaToolbox
import Observation
import OSLog
import Synchronization
import UIKit

@MainActor @Observable
final class PlaybackEngine {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.acops.liquidtune", category: "Playback")

    private(set) var snapshot: PlaybackSnapshot
    private(set) var statistics: PlayStatistics
    private(set) var playing = false
    private(set) var waiting = false
    private(set) var position = 0.0
    private(set) var duration = 0.0
    private(set) var error: String?
    private(set) var artwork: UIImage?
    private(set) var waveform: [Float] = []

    var current: Track? { snapshot.queue.current?.track }
    var queue: PlaybackQueue { snapshot.queue }
    var speed: Float { snapshot.speed }

    @ObservationIgnored private let storage: MediaStorage
    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var progressObserver: Any?
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var itemObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var itemStatus: NSKeyValueObservation?
    @ObservationIgnored private var playbackStatus: NSKeyValueObservation?
    @ObservationIgnored private var artTask: Task<Void, Never>?
    @ObservationIgnored private var bassTask: Task<Void, Never>?
    @ObservationIgnored private var bassMonitor: BassMonitor?

    var latestBassEvent: UInt64 { bassMonitor?.latestEvent ?? 0 }

    @ObservationIgnored private var waveTask: Task<Void, Never>?
    @ObservationIgnored private var visualizerEnabled = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var seekGeneration: UUID?
    @ObservationIgnored private var pendingPosition: Double?
    @ObservationIgnored private var wantsToPlay = false
    @ObservationIgnored private var interrupted = false
    @ObservationIgnored private var reachedEnd = false
    @ObservationIgnored private var lastTick: Double?
    @ObservationIgnored private var secondsSinceSave = 0.0
    @ObservationIgnored var resolve: ((Track) throws -> URL)?
    @ObservationIgnored var loadArtwork: ((Track) async -> UIImage?)?
    @ObservationIgnored var isFavorite: ((String) -> Bool)?
    @ObservationIgnored var setFavorite: ((String, Bool) -> Void)?
    @ObservationIgnored nonisolated private let favoriteCommandTrackID = Mutex<String?>(nil)

    init(storage: MediaStorage) {
        self.storage = storage
        snapshot = storage.read("playback.json", default: PlaybackSnapshot())
        statistics = storage.read("statistics.json", default: PlayStatistics())
        position = snapshot.position
        duration = snapshot.queue.current?.track.duration ?? 0
        player.allowsExternalPlayback = true
    }

    func configure() {
        guard progressObserver == nil else { return }
        progressObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                         queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor [weak self] in self?.tick(seconds) }
        }
        playbackStatus = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshPlaybackStatus() }
        }
        observeAudioSession()
        installRemoteCommands()
        // Keep the saved queue and position visible without reopening media during launch.
        publishNowPlaying()
    }

    func play(_ tracks: [Track], index: Int = 0, shuffle: Bool = false) {
        guard !tracks.isEmpty else { return }
        snapshot.queue.replace(tracks, start: index, shuffle: shuffle)
        resetCount()
        load(play: true)
    }

    func toggle() { if wantsToPlay { pause() } else { resume() } }

    func resume() {
        guard current != nil else { return }
        if player.currentItem == nil || player.currentItem?.status == .failed {
            load(play: true, at: position)
            return
        }
        wantsToPlay = true
        if reachedEnd {
            reachedEnd = false
            seek(to: 0)
        }
        beginIfReady()
    }

    func pause() {
        wantsToPlay = false
        player.pause()
        refreshPlaybackStatus()
        save()
    }

    func next(automatically: Bool = false) {
        guard current != nil else { return }
        if snapshot.queue.advance(automatically: automatically) {
            resetCount()
            load(play: true)
        } else if automatically {
            reachedEnd = true
            position = duration
            pause()
        }
    }

    func previous() {
        if position < 3 && snapshot.queue.previous() {
            resetCount()
            load(play: true)
        } else {
            seek(to: 0)
        }
    }

    func select(_ id: UUID) {
        if snapshot.queue.select(id) {
            resetCount()
            load(play: true)
        }
    }

    func add(_ track: Track, next: Bool) {
        addToQueue([track], next: next)
    }

    func appendToQueue(_ tracks: [Track]) {
        addToQueue(tracks, next: false)
    }

    private func addToQueue(_ tracks: [Track], next: Bool) {
        guard !tracks.isEmpty else { return }
        let wasEmpty = current == nil
        for track in tracks {
            snapshot.queue.add(track, next: next)
        }
        if wasEmpty { resetCount(); load(play: false) }
        save()
    }

    func remove(_ id: UUID) {
        if snapshot.queue.remove(id) {
            resetCount()
            load(play: wantsToPlay && current != nil)
        }
        save()
    }

    func move(_ id: UUID, by delta: Int) {
        snapshot.queue.move(id, by: delta)
        save()
        publishNowPlaying()
    }

    func toggleShuffle() {
        snapshot.queue.toggleShuffle()
        save()
        publishNowPlaying()
    }

    func cycleRepeat() {
        switch queue.repeatMode {
        case .off: snapshot.queue.repeatMode = .all
        case .all: snapshot.queue.repeatMode = .one
        case .one: snapshot.queue.repeatMode = .off
        }
        save()
    }

    func setSpeed(_ rate: Float) {
        snapshot.speed = max(0.5, min(2, rate))
        player.defaultRate = snapshot.speed
        if playing { player.rate = snapshot.speed }
        save()
        publishNowPlaying()
    }

    func setVisualizerEnabled(_ enabled: Bool) {
        guard visualizerEnabled != enabled else { return }
        visualizerEnabled = enabled
        if enabled {
            prepareWaveform()
        } else {
            waveTask?.cancel()
            waveTask = nil
            waveform = []
        }
    }

    func seek(to seconds: Double) {
        guard current != nil, seconds.isFinite else { return }
        let target = max(0, duration > 0 ? min(duration, seconds) : seconds)
        position = target
        lastTick = nil
        if target < duration { reachedEnd = false }
        if player.currentItem?.status == .readyToPlay {
            performSeek(target)
        } else {
            pendingPosition = target
        }
        publishNowPlaying()
        save()
    }

    func save() {
        snapshot.position = position.isFinite ? position : 0
        try? storage.write(snapshot, to: "playback.json")
        try? storage.write(statistics, to: "statistics.json")
    }

    private func resetCount() {
        snapshot.entryListeningSeconds = 0
        snapshot.entryCounted = false
    }

    private func load(play: Bool, at offset: Double = 0) {
        generation = UUID()
        let loadID = generation
        seekGeneration = nil
        lastTick = nil
        reachedEnd = false
        itemStatus?.invalidate()
        itemStatus = nil
        for observer in itemObservers { NotificationCenter.default.removeObserver(observer) }
        itemObservers.removeAll()
        player.pause()
        player.replaceCurrentItem(with: nil)
        artTask?.cancel()
        waveTask?.cancel()
        waveTask = nil
        bassTask?.cancel()
        bassTask = nil
        bassMonitor = nil
        artwork = nil
        waveform = []
        error = nil
        position = offset.isFinite ? max(0, offset) : 0
        duration = current?.duration ?? 0
        pendingPosition = position > 0 ? position : nil
        wantsToPlay = play
        playing = false
        waiting = play
        defer { publishNowPlaying(); save() }
        guard play, let current else { return }
        artTask = Task { [weak self] in
            guard let self else { return }
            let image = await self.loadArtwork?(current)
            guard self.generation == loadID, !Task.isCancelled else { return }
            self.artwork = image
            self.publishNowPlaying()
        }
        do {
            guard let url = try resolve?(current) else { throw MusicError.unavailable }
            Self.log.debug("Opening \(url.isFileURL ? "local" : "server", privacy: .public) audio")
            let item = AVPlayerItem(url: url)
            item.audioTimePitchAlgorithm = .timeDomain
            player.replaceCurrentItem(with: item)
            attachBassMonitor(to: item, url: url, generation: loadID)
            itemStatus = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == loadID else { return }
                    self.itemChanged()
                }
            }
            let center = NotificationCenter.default
            itemObservers.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == loadID, self.wantsToPlay else { return }
                    self.next(automatically: true)
                }
            })
            itemObservers.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == loadID else { return }
                    self.fail()
                }
            })
        } catch {
            let failure = error as NSError
            Self.log.error("Unable to open audio (\(failure.domain, privacy: .public) \(failure.code, privacy: .public))")
            self.error = error.localizedDescription
            wantsToPlay = false
            waiting = false
        }
    }

    private func attachBassMonitor(to item: AVPlayerItem, url: URL, generation loadID: UUID) {
        guard url.pathExtension.lowercased() != "m3u8" else { return }
        bassTask = Task { [weak self, weak item] in
            guard let item, let tracks = try? await item.asset.loadTracks(withMediaType: .audio),
                  let track = tracks.first, let self, !Task.isCancelled,
                  self.generation == loadID, self.player.currentItem === item else { return }
            let monitor = BassMonitor()
            guard let tap = monitor.makeTap() else { return }
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            item.audioMix = mix
            self.bassMonitor = monitor
        }
    }

    private func itemChanged() {
        guard let item = player.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            updateDuration()
            prepareWaveform()
            if let target = pendingPosition {
                pendingPosition = nil
                if !wantsToPlay, duration > 0, target >= duration - 0.25 { reachedEnd = true }
                performSeek(target)
            } else {
                beginIfReady()
            }
        case .failed: fail()
        default: break
        }
    }

    private func beginIfReady() {
        defer { refreshPlaybackStatus() }
        guard wantsToPlay, !interrupted, player.currentItem?.status == .readyToPlay, seekGeneration == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            player.defaultRate = snapshot.speed
            if player.timeControlStatus == .paused { player.play() }
        } catch {
            pause()
            self.error = "The iOS audio session could not be activated."
        }
    }

    private func performSeek(_ target: Double) {
        let id = UUID()
        seekGeneration = id
        player.seek(to: CMTime(seconds: duration > 0 ? min(target, duration) : target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.seekGeneration == id else { return }
                self.seekGeneration = nil
                self.beginIfReady()
            }
        }
    }

    private func fail() {
        if let failure = player.currentItem?.error as NSError? {
            Self.log.error("Player failed (\(failure.domain, privacy: .public) \(failure.code, privacy: .public))")
        }
        error = "Playback stopped. Check the audio format, server connection, and permissions, then tap Play to retry."
        pause()
    }

    private func refreshPlaybackStatus() {
        playing = player.timeControlStatus == .playing
        waiting = wantsToPlay && !playing && !interrupted
        if !playing { lastTick = nil }
        publishNowPlaying()
    }

    private func updateDuration() {
        guard let time = player.currentItem?.duration.seconds, time.isFinite, time > 0 else { return }
        duration = time
    }

    private func tick(_ time: Double) {
        guard current != nil, player.currentItem?.status == .readyToPlay, seekGeneration == nil,
              pendingPosition == nil, time.isFinite else { return }
        updateDuration()
        position = max(0, time)
        guard playing, let current else { return }
        defer { lastTick = time }
        guard let previous = lastTick else { return }
        let elapsed = (time - previous) / Double(snapshot.speed)
        guard elapsed > 0, elapsed < 2 else { return }
        statistics.listeningSeconds += elapsed
        snapshot.entryListeningSeconds += elapsed
        let threshold = duration > 0 ? min(30, duration / 2) : 30
        if !snapshot.entryCounted, snapshot.entryListeningSeconds >= threshold {
            statistics.record(current.id)
            snapshot.entryCounted = true
            save()
        }
        secondsSinceSave += elapsed
        if secondsSinceSave >= 5 {
            secondsSinceSave = 0
            save()
            publishNowPlaying()
        }
    }

    private func publishNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        let remote = MPRemoteCommandCenter.shared()
        let itemIsLoaded = player.currentItem != nil
        [remote.playCommand, remote.pauseCommand, remote.togglePlayPauseCommand, remote.nextTrackCommand,
         remote.previousTrackCommand, remote.changePlaybackPositionCommand].forEach { $0.isEnabled = itemIsLoaded }
        refreshFavoriteCommand()
        guard itemIsLoaded, let current else { center.nowPlayingInfo = nil; return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyArtist: current.artist,
            MPMediaItemPropertyAlbumTitle: current.album,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? snapshot.speed : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: snapshot.speed,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.entries.count
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let index = queue.index { info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = index }
        if let artwork {
            // MediaPlayer may call the request handler away from the main actor.
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { @Sendable _ in artwork }
        }
        center.nowPlayingInfo = info
    }

    func refreshFavoriteCommand() {
        let id = player.currentItem == nil ? nil : current?.id
        favoriteCommandTrackID.withLock { $0 = id }
        let command = MPRemoteCommandCenter.shared().likeCommand
        command.isActive = id.flatMap { isFavorite?($0) } ?? false
        command.isEnabled = id != nil && setFavorite != nil
    }

    private func installRemoteCommands() {
        let remote = MPRemoteCommandCenter.shared()
        remote.playCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in self?.resume() }
            return .success
        }
        remote.pauseCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in self?.pause() }
            return .success
        }
        remote.togglePlayPauseCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in self?.toggle() }
            return .success
        }
        remote.nextTrackCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in self?.next() }
            return .success
        }
        remote.previousTrackCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in self?.previous() }
            return .success
        }
        remote.changePlaybackPositionCommand.addTarget { @Sendable [weak self] event in
            guard let change = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = change.positionTime
            Task { @MainActor [weak self] in self?.seek(to: seconds) }
            return .success
        }
        remote.likeCommand.localizedTitle = "Favorite"
        remote.likeCommand.localizedShortTitle = "Favorite"
        remote.likeCommand.addTarget { @Sendable [weak self] event in
            guard let feedback = event as? MPFeedbackCommandEvent else { return .commandFailed }
            guard let id = self?.favoriteCommandTrackID.withLock({ $0 }) else { return .noActionableNowPlayingItem }
            let favorite = !feedback.isNegative
            Task { @MainActor [weak self] in self?.setFavorite?(id, favorite) }
            return .success
        }
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notice in
            guard let kind = notice.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
            let options = notice.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                if kind == AVAudioSession.InterruptionType.began.rawValue {
                    self.interrupted = true
                    self.player.pause()
                    self.refreshPlaybackStatus()
                    self.save()
                } else {
                    self.interrupted = false
                    if AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) { self.beginIfReady() }
                    else { self.pause() }
                }
            }
        })
        lifecycleObservers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notice in
            if notice.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor [weak self] in self?.pause() }
            }
        })
    }

    private func prepareWaveform() {
        guard visualizerEnabled, waveTask == nil, let item = player.currentItem, item.status == .readyToPlay,
              let url = (item.asset as? AVURLAsset)?.url, url.isFileURL else { return }
        let loadID = generation
        waveTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) { Self.analyze(url) }
            let data = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard let self, self.generation == loadID, !Task.isCancelled else { return }
            self.waveform = data
        }
    }

    // Sample decoded PCM across a local file, with bounded reads for very long tracks.
    nonisolated private static func analyze(_ url: URL) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2048) else { return [] }
        let length = file.length
        let bucketCount = min(1024, length)
        var result: [Float] = []
        for bucket in 0..<bucketCount {
            if Task.isCancelled { return [] }
            let start = (length / bucketCount) * bucket + ((length % bucketCount) * bucket / bucketCount)
            file.framePosition = start
            let remaining = AVAudioFrameCount(min(Int64(buffer.frameCapacity), length - start))
            guard (try? file.read(into: buffer, frameCount: remaining)) != nil,
                  let channels = buffer.floatChannelData, buffer.frameLength > 0 else { break }
            let channelCount = Int(buffer.format.channelCount)
            var peak: Float = 0
            for channel in 0..<channelCount {
                for frame in stride(from: 0, to: Int(buffer.frameLength), by: 4) {
                    peak = max(peak, abs(channels[channel][frame * buffer.stride]))
                }
            }
            result.append(min(1, peak))
        }
        return result
    }
}


// Render callbacks own the filter state. The UI only reads the packed, atomic event.
private final class BassMonitor: @unchecked Sendable {
    private let event = Atomic<UInt64>(0)
    var latestEvent: UInt64 { event.load(ordering: .relaxed) }

    private var samplesPerWindow = 0
    private var highCoefficient: Float = 0
    private var lowCoefficient: Float = 0
    private var upper: Float = 0
    private var lower: Float = 0
    private var energy: Float = 0
    private var totalEnergy: Float = 0
    private var count = 0
    private var baseline: Float = 0
    private var previous: Float = 0
    private var cooldown = 0

    func makeTap() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(self).toOpaque(),
            init: { _, info, storage in
                guard let info else { return }
                storage.pointee = Unmanaged<BassMonitor>.fromOpaque(info).retain().toOpaque()
            },
            finalize: { tap in
                Unmanaged<BassMonitor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let monitor = Unmanaged<BassMonitor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                monitor.prepare(format.pointee)
            },
            unprepare: nil,
            process: { tap, requested, _, buffers, count, flags in
                let status = MTAudioProcessingTapGetSourceAudio(tap, requested, buffers, flags, nil, count)
                guard status == noErr else { count.pointee = 0; return }
                let monitor = Unmanaged<BassMonitor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                monitor.process(buffers, frames: count.pointee)
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        return status == noErr ? tap : nil
    }

    private func prepare(_ format: AudioStreamBasicDescription) {
        samplesPerWindow = 0
        upper = 0
        lower = 0
        energy = 0
        totalEnergy = 0
        count = 0
        baseline = 0
        previous = 0
        cooldown = 0
        event.store(0, ordering: .relaxed)
        guard format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              format.mSampleRate.isFinite, (8_000...384_000).contains(format.mSampleRate) else { return }
        samplesPerWindow = Int(format.mSampleRate * 0.025)
        highCoefficient = Float(1 - exp(-2 * Double.pi * 175 / format.mSampleRate))
        lowCoefficient = Float(1 - exp(-2 * Double.pi * 42 / format.mSampleRate))
    }

    private func process(_ buffers: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard samplesPerWindow > 0, frames > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(buffers)
        guard let first = buffers.first, let bytes = first.mData, first.mNumberChannels > 0 else { return }
        let stride = Int(first.mNumberChannels)
        let available = Int(first.mDataByteSize) / MemoryLayout<Float>.stride / stride
        let samples = bytes.assumingMemoryBound(to: Float.self)
        let right = buffers.count > 1 ? buffers[1] : nil
        let rightSamples = right?.mNumberChannels == 1 && right?.mDataByteSize == first.mDataByteSize
            ? right?.mData?.assumingMemoryBound(to: Float.self) : nil
        for frame in 0..<min(frames, available) {
            let left = samples[frame * stride]
            let other = stride > 1 ? samples[frame * stride + 1] : (rightSamples?[frame] ?? left)
            let mixed = (left + other) * 0.5
            guard mixed.isFinite else { continue }
            let sample = max(-1, min(1, mixed))
            upper += highCoefficient * (sample - upper)
            lower += lowCoefficient * (sample - lower)
            let bass = upper - lower
            energy += bass * bass
            totalEnergy += sample * sample
            count += 1
            if count == samplesPerWindow { finishWindow() }
        }
    }

    private func finishWindow() {
        let power = energy / Float(count)
        let broadbandPower = totalEnergy / Float(count)
        if cooldown == 0, power > max(0.00015, baseline * 2.3),
           power > previous * 1.18, power > broadbandPower * 0.095 {
            let strength = UInt64(min(255, max(82, sqrt(power) * 1300)))
            let milliseconds = DispatchTime.now().uptimeNanoseconds / 1_000_000
            event.store((milliseconds << 8) | strength, ordering: .relaxed)
            cooldown = 8
        }
        cooldown = max(0, cooldown - 1)
        baseline += 0.04 * (power - baseline)
        previous = power
        energy = 0
        totalEnergy = 0
        count = 0
    }
}
