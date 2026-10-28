import AppKit
import AVFoundation
import Observation
import EditRushCore

/// Records voiceovers from a microphone straight onto an audio track.
///
/// `start(on:)` counts down 3-2-1 while the microphone warms up, then records while the timeline
/// plays from the playhead, so the take can follow the picture. `stop()` (the record button again,
/// Space or Esc) keeps the take: it is saved as "Voiceover N.m4a" (see `VoiceoverFiles`) and placed
/// where recording began, as one undo step. Stopping during the countdown cancels.
@MainActor
@Observable
final class VoiceoverRecorder {
    enum Phase: Equatable { case idle, countdown(Int), recording, finishing }

    /// A microphone the user can pick.
    struct Microphone: Hashable, Sendable {
        let id: String
        let name: String
    }

    private(set) var phase: Phase = .idle
    /// Audio track the take goes onto (nil during the countdown when a new track will be added).
    private(set) var trackID: UUID?
    /// Timeline time the take starts at.
    private(set) var startTime: Seconds = 0
    /// Seconds recorded so far.
    private(set) var elapsed: Seconds = 0
    /// Input level 0...1, for meters.
    private(set) var level: Double = 0
    /// Connected microphones (filled in the background after launch and when devices come and go).
    private(set) var microphones: [Microphone] = []

    var isActive: Bool { phase != .idle }

    /// Microphone to record from (`AVCaptureDevice.uniqueID`); nil = the system default input.
    var microphoneID: String? {
        didSet { UserDefaults.standard.set(microphoneID, forKey: Self.microphoneKey) }
    }
    /// Silences the timeline while recording, so speakers don't bleed into the microphone.
    var mutesTimeline: Bool {
        didSet { UserDefaults.standard.set(mutesTimeline, forKey: Self.muteKey) }
    }

    @ObservationIgnored private let store: EditorStore
    @ObservationIgnored private let playback: PlaybackController
    @ObservationIgnored private var session: AVCaptureSession?
    @ObservationIgnored private var output: AVCaptureAudioFileOutput?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var meterTimer: Timer?
    /// True while the recorder has muted the player (`mutesTimeline`).
    @ObservationIgnored private var mutedPlayer = false
    @ObservationIgnored private let delegate = VoiceoverRecordingDelegate()
    @ObservationIgnored private var deviceObservers: [NSObjectProtocol] = []

    private static let microphoneKey = "VoiceoverMicrophoneID"
    private static let muteKey = "VoiceoverMutesTimeline"
    private static let countdownSeconds = 3
    /// AVCaptureSession calls block, so they run here, in order.
    private nonisolated static let sessionQueue = DispatchQueue(label: "EditRush.voiceover", qos: .userInitiated)

    init(store: EditorStore, playback: PlaybackController) {
        self.store = store
        self.playback = playback
        microphoneID = UserDefaults.standard.string(forKey: Self.microphoneKey)
        mutesTimeline = UserDefaults.standard.bool(forKey: Self.muteKey)
        delegate.onStart = { [weak self] in self?.recordingDidStart() }
        delegate.onFinish = { [weak self] url, error in self?.recordingDidFinish(url, error: error) }
    }

    /// Starts listing microphones in the background (device discovery can be slow, so never at launch).
    func watchMicrophones() {
        guard deviceObservers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            deviceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshMicrophones() }
            })
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.refreshMicrophones()
        }
    }

    private func refreshMicrophones() {
        Task.detached(priority: .utility) {
            let found = Self.discoverMicrophones()
            await MainActor.run { [weak self] in self?.microphones = found }
        }
    }

    private nonisolated static func discoverMicrophones() -> [Microphone] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { Microphone(id: $0.uniqueID, name: $0.localizedName) }
    }

    // MARK: - Start / stop

    /// Starts the countdown for a take on `trackID`, or on a free audio track when nil. Asks for
    /// microphone access the first time.
    func start(on trackID: UUID? = nil) {
        guard phase == .idle else { return }
        if let trackID {
            guard let track = store.project.tracks.first(where: { $0.id == trackID }), track.kind == .audio else { return }
            if track.isLocked {
                store.statusMessage = "Unlock \(store.project.displayName(of: trackID)) to record onto it."
                return
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginCountdown(on: trackID)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor [weak self] in
                    if granted { self?.beginCountdown(on: trackID) } else { self?.explainMicrophoneAccess() }
                }
            }
        default:
            explainMicrophoneAccess()
        }
    }

    /// Ends the take and keeps it; during the countdown, cancels.
    func stop() {
        switch phase {
        case .idle, .finishing:
            return
        case .countdown:
            countdownTask?.cancel()
            countdownTask = nil
            tearDown()
            phase = .idle
        case .recording:
            phase = .finishing
            playback.pause()
            restoreTimelineAudio()
            if let output {
                nonisolated(unsafe) let output = output
                Self.sessionQueue.async { output.stopRecording() }
            }
        }
    }

    func toggle(on trackID: UUID? = nil) {
        if isActive { stop() } else { start(on: trackID) }
    }

    /// Stops any take and waits (at most `timeout`) until it has been saved and placed (before quitting).
    func stopAndWait(timeout: Duration = .seconds(5)) async {
        stop()
        let deadline = ContinuousClock.now + timeout
        while isActive, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func beginCountdown(on requestedTrack: UUID?) {
        guard phase == .idle else { return }
        let device = microphoneID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .audio)
        guard let device else {
            store.statusMessage = "No microphone found. Connect one and try again."
            return
        }
        let session = AVCaptureSession()
        let output = AVCaptureAudioFileOutput()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input), session.canAddOutput(output) else {
                throw CocoaError(.featureUnsupported)
            }
            session.addInput(input)
            session.addOutput(output)
        } catch {
            store.statusMessage = "Couldn't record from “\(device.localizedName)”: \(error.localizedDescription)"
            return
        }
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 160_000,
        ]
        self.session = session
        self.output = output
        playback.pause()
        trackID = requestedTrack ?? defaultTrack()
        startTime = store.project.canvas.quantize(store.playhead)
        elapsed = 0
        level = 0
        phase = .countdown(Self.countdownSeconds)
        nonisolated(unsafe) let running = session
        Self.sessionQueue.async { running.startRunning() }
        startMeter()
        countdownTask = Task { [weak self] in
            for n in stride(from: Self.countdownSeconds, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                self?.phase = .countdown(n)
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            self?.startRecording()
        }
    }

    private func startRecording() {
        guard case .countdown = phase, let fileOutput = output else { return }
        countdownTask = nil
        if trackID == nil { trackID = store.addTrack(.audio) }
        let url: URL
        do {
            url = try Self.prepareFile(in: VoiceoverFiles.folder(forProject: store.projectURL))
        } catch {
            do {
                url = try Self.prepareFile(in: VoiceoverFiles.defaultFolder)
            } catch {
                store.statusMessage = "Couldn't create a file for the recording: \(error.localizedDescription)"
                tearDown()
                phase = .idle
                return
            }
        }
        phase = .recording
        nonisolated(unsafe) let output = fileOutput
        let delegate = delegate
        Self.sessionQueue.async { output.startRecording(to: url, outputFileType: .m4a, recordingDelegate: delegate) }
    }

    private static func prepareFile(in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return VoiceoverFiles.nextURL(in: folder)
    }

    /// The first unlocked audio track with nothing after the playhead, else one free at the playhead
    /// (nil = add a new track when recording starts).
    private func defaultTrack() -> UUID? {
        let t = store.project.canvas.quantize(store.playhead)
        let tracks = store.project.tracks.filter { $0.kind == .audio && !$0.isLocked }
        return (tracks.first { $0.clips.allSatisfy { $0.end <= t + 1e-6 } }
            ?? tracks.first { $0.isFree(start: t, duration: store.frameDuration) })?.id
    }

    // MARK: - Recording callbacks

    private func recordingDidStart() {
        guard phase == .recording else { return }
        // The take starts now, so the picture starts with it (never rewinding from the end).
        if store.playhead < store.project.duration - store.frameDuration / 2 {
            if mutesTimeline, !playback.player.isMuted {
                playback.player.isMuted = true
                mutedPlayer = true
            }
            playback.play()
        }
    }

    private func recordingDidFinish(_ url: URL, error: Error?) {
        // AVFoundation can report an error for a file that was still written completely.
        let complete = error == nil
            || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false)
        let track = trackID, start = startTime
        if phase == .recording {
            // Ended by itself (e.g. the microphone was unplugged).
            phase = .finishing
            playback.pause()
        }
        restoreTimelineAudio()
        tearDown()
        guard complete else {
            try? FileManager.default.removeItem(at: url)
            store.statusMessage = "Recording failed: \(error?.localizedDescription ?? "unknown error")"
            phase = .idle
            return
        }
        Task {
            do {
                let item = try await MediaImporter.probe(url)
                store.addRecording(item, trackID: track, at: start)
                store.statusMessage = "Recorded “\(url.lastPathComponent)” (\(Self.format(item.duration)))"
            } catch {
                try? FileManager.default.removeItem(at: url)
                store.statusMessage = "The recording was too short to keep."
            }
            phase = .idle
        }
    }

    private func restoreTimelineAudio() {
        guard mutedPlayer else { return }
        playback.player.isMuted = false
        mutedPlayer = false
    }

    private func tearDown() {
        meterTimer?.invalidate()
        meterTimer = nil
        level = 0
        if let session {
            nonisolated(unsafe) let session = session
            Self.sessionQueue.async { session.stopRunning() }
        }
        session = nil
        output = nil
    }

    // MARK: - Meter

    private func startMeter() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMeter() }
        }
    }

    private func updateMeter() {
        guard let output else { return }
        let channels = output.connections.flatMap(\.audioChannels)
        let db = channels.map { Double($0.averagePowerLevel) }.max() ?? -160
        // -50 dB … 0 dB → 0 … 1.
        level = max(0, min(1, (db + 50) / 50))
        if phase == .recording {
            let recorded = output.recordedDuration.seconds
            if recorded.isFinite { elapsed = recorded }
        }
    }

    // MARK: - Permission

    private func explainMicrophoneAccess() {
        let alert = NSAlert()
        alert.messageText = "EditRush needs access to your microphone"
        alert.informativeText = "To record voiceovers, turn on EditRush in System Settings ▸ Privacy & Security ▸ Microphone."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }

    /// "0:07" / "1:23".
    static func format(_ t: Seconds) -> String {
        let s = Int(max(0, t).rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Receives AVCaptureFileOutput callbacks (on an AVFoundation queue) and hands them to the main actor.
private final class VoiceoverRecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    @MainActor var onStart: (() -> Void)?
    @MainActor var onFinish: ((URL, Error?) -> Void)?

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        Task { @MainActor in self.onStart?() }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor in self.onFinish?(outputFileURL, error) }
    }
}
