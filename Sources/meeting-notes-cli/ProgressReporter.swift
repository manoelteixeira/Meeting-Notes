import Foundation
import MeetingNotesCore
import Synchronization

/// Draws a single-line progress indicator on stderr, so piping stdout to a file
/// still gets clean Markdown.
final class ProgressReporter: Sendable {

    private let lastLine = Mutex<String>("")

    func report(_ progress: PipelineProgress) {
        var line = progress.detail ?? progress.stage.title
        switch progress.kind {
        case .running(let fraction), .downloadingModels(.some(let fraction)):
            line += String(format: " %3.0f%%", fraction * 100)
        case .downloadingModels(nil), .indeterminate:
            line += "…"
        case .finished:
            line += " ✓"
        }

        let shouldDraw = lastLine.withLock { previous in
            guard previous != line else { return false }
            previous = line
            return true
        }
        guard shouldDraw else { return }
        FileHandle.standardError.write(Data("\r\u{1B}[2K\(line)".utf8))
    }

    func finish() {
        FileHandle.standardError.write(Data("\n".utf8))
    }
}
