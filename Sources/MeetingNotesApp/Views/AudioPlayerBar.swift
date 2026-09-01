import MeetingNotesCore
import SwiftUI

/// Persistent playback controls pinned under the transcript and notes tabs.
struct AudioPlayerBar: View {
    @Bindable var player: AudioPlayerController

    private static let rates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    /// "1×", "0.75×" — trailing zeros dropped.
    private static func label(for rate: Double) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    var body: some View {
        HStack(spacing: 12) {
            if player.loadFailed {
                Label("Audio unavailable", systemImage: "waveform.slash")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 24)
                }
                .buttonStyle(.plain)
                .help(player.isPlaying ? "Pause" : "Play")

                Text(MarkdownExporter.timestamp(player.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Slider(
                    value: Binding(
                        get: { player.currentTime },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...max(player.duration, 0.01),
                    onEditingChanged: { editing in
                        if editing {
                            player.beginScrubbing()
                        } else {
                            player.endScrubbing(at: player.currentTime)
                        }
                    }
                )
                .disabled(player.duration <= 0)

                Text(MarkdownExporter.timestamp(player.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Divider()
                    .frame(height: 16)

                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $player.volume, in: 0...1)
                    .frame(width: 80)
                    .help("Volume")

                Menu {
                    Picker("Speed", selection: $player.rate) {
                        ForEach(Self.rates, id: \.self) { rate in
                            Text(Self.label(for: rate)).tag(rate)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Text(Self.label(for: player.rate))
                        .font(.caption.monospacedDigit())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Playback speed")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
