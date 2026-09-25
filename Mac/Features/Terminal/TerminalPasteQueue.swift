import Foundation

/// Serializes user paste actions. Each send closure is bound to the original terminal connection.
@MainActor
final class TerminalPasteQueue {
    private struct Job {
        let bytes: [UInt8]
        let bracketed: Bool
        let send: ([UInt8]) -> Bool
        var offset = 0
    }

    private static let start = Array("\u{1B}[200~".utf8)
    private static let end = Array("\u{1B}[201~".utf8)
    private let chunkSize: Int
    private let schedule: (@escaping @MainActor () -> Void) -> Void
    private var jobs: [Job] = []
    private var generation = UUID()
    private var scheduled = false

    init(
        chunkSize: Int = 1024,
        schedule: @escaping (@escaping @MainActor () -> Void) -> Void = { action in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) { action() }
        }
    ) {
        precondition(chunkSize > 0)
        self.chunkSize = chunkSize
        self.schedule = schedule
    }

    func enqueue(_ text: String, bracketed: Bool, send: @escaping ([UInt8]) -> Bool) {
        guard !text.isEmpty else { return }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(
            of: "\r", with: "\n")
        jobs.append(Job(bytes: Array(normalized.utf8), bracketed: bracketed, send: send))
        if !scheduled { sendNext() }
    }

    func cancel() {
        generation = UUID()
        scheduled = false
        let active = jobs.first
        jobs.removeAll()
        // Leave bracketed-paste mode only on the original connection, if it still accepts input.
        if let active, active.bracketed, active.offset > 0 { _ = active.send(Self.end) }
    }

    private func sendNext() {
        scheduled = false
        guard !jobs.isEmpty else { return }
        var job = jobs.removeFirst()
        let next = min(job.offset + chunkSize, job.bytes.count)
        var chunk = Array(job.bytes[job.offset..<next])
        if job.bracketed, job.offset == 0 { chunk.insert(contentsOf: Self.start, at: 0) }
        if job.bracketed, next == job.bytes.count { chunk.append(contentsOf: Self.end) }
        let identity = generation
        let accepted = job.send(chunk)
        guard generation == identity else { return }
        if accepted, next < job.bytes.count {
            job.offset = next
            jobs.insert(job, at: 0)
        }
        guard !jobs.isEmpty else { return }
        scheduled = true
        schedule { [weak self] in
            guard let self, self.generation == identity else { return }
            self.sendNext()
        }
    }
}
