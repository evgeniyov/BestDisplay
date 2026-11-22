import Foundation

/// Parsing of `bestdisplay://profile?name=…` links.
enum ProfileURL {
    static let scheme = "bestdisplay"

    static func readName(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == scheme, components.host == "profile",
              components.path.isEmpty, components.user == nil, components.password == nil,
              components.port == nil, components.fragment == nil,
              let items = components.queryItems, items.count == 1, let item = items.first,
              item.name == "name", let name = item.value, (1...80).contains(name.count) else { return nil }
        return name
    }
}
