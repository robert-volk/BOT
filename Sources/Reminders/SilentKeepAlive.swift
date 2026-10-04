import AVFoundation

/// Plays a looping track of pure silence so iOS keeps BOT running in the background (the "audio" background mode).
/// That lets BOT speak a reminder itself at the right moment. Audio played by an app ignores the silent switch,
/// unlike notification sounds. Only runs while an alert is pending, and only if you enable it in Settings.
@MainActor
final class SilentKeepAlive {
    private var player: AVAudioPlayer?
    private var observer: NSObjectProtocol?
    private var wanted = false

    init() {
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in
                guard let self, self.wanted, raw == AVAudioSession.InterruptionType.ended.rawValue else { return }
                self.restart()   // a phone call or Siri ended: resume
            }
        }
    }

    func start() {
        wanted = true
        guard player?.isPlaying != true else { return }
        restart()
    }

    func stop() {
        wanted = false
        player?.stop()
        player = nil
    }

    private func restart() {
        Listener.configureAudioSession()
        guard let url = Self.silenceFile() else { return }
        player?.stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.numberOfLoops = -1
        player?.prepareToPlay()
        player?.play()
    }

    /// One second of digital silence, written once to the temp directory.
    private static func silenceFile() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bot-silence.caf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8000, channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000) else { return nil }
        buffer.frameLength = 8000
        if let p = buffer.int16ChannelData?[0] { for i in 0..<8000 { p[i] = 0 } }
        guard let file = try? AVAudioFile(forWriting: url, settings: format.settings,
                                          commonFormat: .pcmFormatInt16, interleaved: true) else { return nil }
        try? file.write(from: buffer)
        return url
    }
}
