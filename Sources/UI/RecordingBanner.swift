import SwiftUI

/// Shown at the top of the screen while BOT is recording meeting notes or a journal entry.
struct RecordingBanner: View {
    @ObservedObject var recorder: MeetingRecorder
    let theme: Theme
    let onStop: () -> Void

    @State private var pulse = false

    var body: some View {
        if recorder.isRecording {
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                        .opacity(pulse ? 0.25 : 1)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                    Text(recorder.kind == .journal ? "Journal" : (recorder.title ?? "Meeting notes"))
                        .lineLimit(1)
                        .font(theme.font(15, .semibold))
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(Self.clock(ctx.date.timeIntervalSince(recorder.startedAt)))
                            .font(theme.font(15, .medium))
                            .monospacedDigit()
                            .foregroundStyle(theme.subtext)
                    }
                    Spacer()
                    Button(action: onStop) {
                        Text("Stop")
                            .font(theme.font(14, .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(Color.red, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                if !recorder.transcript.isEmpty {
                    Text("\u{2026}" + String(recorder.transcript.suffix(90)))
                        .font(theme.font(12))
                        .foregroundStyle(theme.subtext)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .foregroundStyle(theme.text)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.red.opacity(0.4), lineWidth: 1))
            .padding(.horizontal, 20)
            .onAppear { pulse = true }
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
