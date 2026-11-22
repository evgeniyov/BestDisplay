import AppKit

enum ProfileCommand {
    static let scheme = ProfileURL.scheme

    static func readName(from url: URL) -> String? { ProfileURL.readName(from: url) }

    @MainActor
    static func run(_ arguments: [String]) -> Int32 {
        switch arguments.first {
        case "--report" where arguments.count == 1:
            let screens = displays()
            print(displayReport(screens))
            return screens.isEmpty ? 1 : 0
        case "--profiles" where arguments.count == 1:
            for profile in DisplayManager().profiles { print(profile.name) }
            return 0
        case "--preview-profile" where arguments.count == 2:
            let name = arguments[1]
            guard DisplayManager().profiles.contains(where: { $0.name == name }) else {
                FileHandle.standardError.write(Data("Профиль с таким названием не найден.\n".utf8))
                return 1
            }
            var components = URLComponents()
            components.scheme = scheme
            components.host = "profile"
            components.queryItems = [URLQueryItem(name: "name", value: name)]
            guard let url = components.url, NSWorkspace.shared.open(url) else { return 1 }
            return 0
        case "--help" where arguments.count == 1:
            print(usage)
            return 0
        default:
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            return 2
        }
    }

    private static let usage = """
    BestDisplay --report
    BestDisplay --profiles
    BestDisplay --preview-profile "Название профиля"
    """
}
