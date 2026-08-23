import Foundation

/// The list of things that can be captured, fetched from the backend's own HTTP endpoint.
///
/// Deliberately not enumerated natively, for now. The backend already serves `/devices.json`,
/// already narrows the list to devices that are actually present, and already marks the
/// system default. Reimplementing that in Swift would mean two enumerations that can disagree
/// about which microphone is which, and the index the user picks is passed straight back to
/// the backend, so the two must agree by construction rather than by care.
///
/// It becomes native when the engine does. At that point this type keeps its shape and
/// changes its source, which is why the view talks to this rather than to a URL.
@MainActor
final class DeviceCatalog: ObservableObject {

    struct Device: Identifiable, Equatable {
        let index: Int
        let name: String
        let isLoopback: Bool
        let isDefault: Bool

        var id: String { "\(isLoopback ? "out" : "in")-\(index)" }
    }

    @Published private(set) var inputs: [Device] = []
    /// Output endpoints, so what is being played can be captioned too. Kept apart from the
    /// microphones rather than mixed into one flat list: they are very different things and a
    /// picker that blends them invites capturing the wrong one silently.
    @Published private(set) var outputs: [Device] = []
    @Published private(set) var selectedName: String?
    @Published private(set) var lastRefreshWasStale = false

    private var httpPort: Int = 8765

    func configure(httpPort: Int) {
        self.httpPort = httpPort
    }

    func select(_ device: Device) {
        selectedName = device.name
    }

    /// `fresh` re-enumerates in a child process on the backend side. Without it the backend
    /// serves what the audio layer cached at startup, which is right at startup and wrong
    /// every time afterwards.
    func refresh(fresh: Bool = false) async {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = httpPort
        components.path = "/devices.json"
        if fresh {
            components.queryItems = [URLQueryItem(name: "fresh", value: "1")]
        }
        guard let url = components.url else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let payload = try JSONDecoder().decode(Payload.self, from: data)

            inputs = payload.devices
                .filter { !($0.loopback ?? false) }
                .map { Device(index: $0.index, name: $0.name,
                              isLoopback: false, isDefault: $0.isDefaultInput ?? false) }
            outputs = payload.devices
                .filter { $0.loopback ?? false }
                .map { Device(index: $0.index, name: $0.name,
                              isLoopback: true, isDefault: $0.isDefaultOutput ?? false) }
            lastRefreshWasStale = payload.stale ?? false
        } catch {
            // A picker that fails to refresh should keep showing what it had. An empty list
            // is worse than a slightly stale one, because it offers no way to choose at all.
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

            enum CodingKeys: String, CodingKey {
                case index, name, loopback
                case isDefaultInput = "is_default_input"
                case isDefaultOutput = "is_default_output"
            }
        }
    }
}
