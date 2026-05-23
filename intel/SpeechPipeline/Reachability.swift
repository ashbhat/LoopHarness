import Foundation
import Network

/// Tiny reachability gate. Used by AgentHarness to decide whether to take
/// the cloud chat path or the offline Apple LLM path, and by MessageBox to
/// decide whether to attempt Deepgram's WebSocket.
///
/// Lives in SpeechPipeline (not the iOS-only MessageBox) so the macOS app
/// can use the same gate without dragging UIKit.
enum Reachability {
    private static let monitor: NWPathMonitor = {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            isOnlineStorage = (path.status == .satisfied)
        }
        monitor.start(queue: DispatchQueue(label: "Reachability.NWPathMonitor"))
        return monitor
    }()

    private static var isOnlineStorage: Bool = true

    static var isOnline: Bool {
        _ = monitor
        return isOnlineStorage
    }
}
