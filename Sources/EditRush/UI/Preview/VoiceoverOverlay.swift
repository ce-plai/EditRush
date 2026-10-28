import SwiftUI
import EditRushCore

/// Voiceover feedback over the viewer: a big 3-2-1 before recording, then a REC badge with the
/// take's length and the microphone level.
struct VoiceoverOverlay: View {
    @Environment(VoiceoverRecorder.self) private var recorder

    var body: some View {
        switch recorder.phase {
        case .idle:
            EmptyView()
        case .countdown(let n):
            VStack(spacing: 14) {
                Text("\(n)")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(width: 120, height: 120)
                    .background(Circle().fill(Color.black.opacity(0.62)))
                    .overlay(Circle().strokeBorder(Theme.playhead, lineWidth: 3))
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.easeOut(duration: 0.2), value: n)
                VStack(spacing: 6) {
                    VoiceoverLevelMeter(level: recorder.level)
                        .frame(width: 140, height: 5)
                    Text("Get ready to speak · Esc to cancel")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.62)))
            }
            .allowsHitTesting(false)
        case .recording, .finishing:
            VStack {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Theme.playhead)
                        .frame(width: 9, height: 9)
                    Text(recorder.phase == .finishing ? "Saving…" : "REC " + VoiceoverRecorder.format(recorder.elapsed))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                    VoiceoverLevelMeter(level: recorder.level)
                        .frame(width: 70, height: 5)
                    Button(action: recorder.stop) {
                        Text("Stop")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .frame(height: 20)
                            .background(Capsule().fill(Theme.playhead))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .disabled(recorder.phase == .finishing)
                    .help("Stop Recording (Space)")
                }
                .padding(.leading, 11)
                .padding(.trailing, 5)
                .frame(height: 30)
                .background(Capsule().fill(Color.black.opacity(0.72)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
                .padding(.top, 8)
                Spacer()
            }
        }
    }
}

/// Horizontal input level bar: green, turning amber then red near clipping.
private struct VoiceoverLevelMeter: View {
    let level: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule()
                    .fill(level > 0.9 ? Color.red : level > 0.75 ? Color.orange : Color.green)
                    .frame(width: geo.size.width * level)
            }
        }
        .animation(.linear(duration: 1.0 / 15), value: level)
    }
}
