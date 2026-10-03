import Foundation
import Combine

/// Stable Core Audio UIDs, with a bounded fresh-list probe on the backend.
@MainActor
final class DeviceCatalog: ObservableObject {
    struct Device: Identifiable, Equatable {
        let index: Int
        let name: String
        let isLoopback: Bool
        let isDefault: Bool
        var endpointID: String?
        var followsDefault = false
        var isSystemAudio = false
        var id: String { followsDefault ? "default-input" : endpointID ?? "\(isLoopback ? "out" : "in")-\(index)" }
        var target: AudioInputTarget {
            AudioInputTarget(kind: isLoopback ? "loopback" : "microphone",
                             endpointID: endpointID, name: followsDefault ? nil : name,
                             index: followsDefault ? nil : index, followDefault: followsDefault || isSystemAudio)
        }
    }

    static let defaultInput = Device(index: -1, name: "macOS default (Input)",
        isLoopback: false, isDefault: true, followsDefault: true)
    static let systemAudio = Device(index: -1, name: "System audio (this Mac)",
        isLoopback: true, isDefault: true, endpointID: "system-audio", isSystemAudio: true)

    @Published private(set) var inputs: [Device] = []
    @Published private(set) var outputs: [Device] = [systemAudio]
    @Published private(set) var selected: Device?
    @Published private(set) var selectedName: String?
    @Published private(set) var lastRefreshWasStale = false
    private var httpPort = 8765
    private var refreshGeneration = 0
    private var reconciled = false

    func claimReconcile() -> Bool {
        guard !reconciled else { return false }
        reconciled = true
        return true
    }

    func configure(httpPort: Int) { self.httpPort = httpPort }

    func select(_ device: Device) {
        selected = device
        selectedName = device.name
    }

    func select(_ target: AudioInputTarget) {
        if target.kind == "loopback" { select(Self.systemAudio); return }
        if target.followDefault { select(Self.defaultInput); return }
        if let found = inputs.first(where: { $0.endpointID == target.endpointID && target.endpointID != nil }) {
            select(found)
        } else {
            selected = nil
            selectedName = target.name ?? "Selected input unavailable"
        }
    }

    func resolve(index: Int?, name: String?, isLoopback: Bool) -> Device? {
        if name == Self.systemAudio.name { return Self.systemAudio }
        let matches = (isLoopback ? outputs : inputs).filter { $0.name == name }
        // A remembered name that is missing or ambiguous never falls back to an unrelated index.
        return matches.count == 1 ? matches.first : nil
    }

    func displayName(_ device: Device) -> String {
        let peers = inputs.filter { $0.name == device.name }
        guard peers.count > 1, let ordinal = peers.firstIndex(of: device) else { return device.name }
        return "\(device.name) (\(ordinal + 1))"
    }

    func refresh(fresh: Bool = false) async {
        refreshGeneration += 1
        let generation = refreshGeneration
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = httpPort
        components.path = "/devices.json"
        if fresh { components.queryItems = [URLQueryItem(name: "fresh", value: "1")] }
        guard let url = components.url else { return }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            let (data, response) = try await URLSession.shared.data(for: request)
            guard generation == refreshGeneration, (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            inputs = payload.devices.filter { !($0.loopback ?? false) }.map {
                Device(index: $0.index, name: $0.name, isLoopback: false,
                       isDefault: $0.isDefaultInput ?? false, endpointID: $0.endpointID)
            }
            // ScreenCaptureKit captions the Mac as a whole, not a particular output device.
            outputs = [Self.systemAudio]
            lastRefreshWasStale = payload.stale ?? false
        } catch {
            if generation == refreshGeneration { lastRefreshWasStale = true }
        }
    }

    private struct Payload: Decodable {
        let devices: [Entry]
        let stale: Bool?
        struct Entry: Decodable {
            let index: Int
            let name: String
            let loopback: Bool?
            let isDefaultInput: Bool?
            let isDefaultOutput: Bool?
            let endpointID: String?
            enum CodingKeys: String, CodingKey {
                case index, name, loopback
                case isDefaultInput = "is_default_input"
                case isDefaultOutput = "is_default_output"
                case endpointID = "endpoint_id"
            }
        }
    }
}
