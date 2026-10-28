import Foundation
import Darwin

/// Watch directories rather than file descriptors for individual files so atomic
/// replacement saves from external editors are observed. All watcher state is
/// confined to one queue; the stream is debounced by ModesFeature's refresh logic.
final class ModeFileObservation: @unchecked Sendable {
    private let root: URL
    private let queue = DispatchQueue(label: "Hex.mode-files")
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var stopped = false
    private let continuation: AsyncStream<Void>.Continuation
    let stream: AsyncStream<Void>

    init(root: URL) {
        self.root = root
        (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        queue.async { [self] in rebuild() }
    }
    func cancel() {
        queue.async { [self] in
            stopped = true
            for source in sources.values { source.cancel() }
            sources.removeAll(); continuation.finish()
        }
    }
    private func rebuild() {
        guard !stopped else { return }
        let modes = root.appendingPathComponent("modes")
        let children = (try? FileManager.default.contentsOfDirectory(at: modes, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        let desired = Set(([root, modes, root.appendingPathComponent("processors")] + children).map(\.path))
        for path in Array(sources.keys) where !desired.contains(path) { sources.removeValue(forKey: path)?.cancel() }
        for path in desired where sources[path] == nil {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                let events = self.sources[path]?.data ?? []
                if events.contains(.delete) || events.contains(.rename) { self.sources.removeValue(forKey: path)?.cancel() }
                self.rebuild(); self.continuation.yield(())
            }
            source.setCancelHandler { close(fd) }
            sources[path] = source; source.resume()
        }
    }
}
