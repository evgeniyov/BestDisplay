import ColorSync
import CoreGraphics
import Darwin

enum DisplayConnection {
    typealias Configure = @convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> CGError
    private static let configure = loadSymbol(
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL),
        "SLSConfigureDisplayEnabled",
        as: Configure.self
    )

    static var isAvailable: Bool { configure != nil }

    @MainActor
    static func setEnabled(_ enabled: Bool, display: CGDirectDisplayID, identity: String) throws {
        guard let configure else { throw DisplayFailure("Программное подключение недоступно в этой версии macOS.") }
        if let liveIdentity = displayIdentity(display), liveIdentity != identity {
            throw DisplayFailure("Идентификатор дисплея изменился.")
        }
        try configureDisplays { configuration in
            try checkDisplayError(configure(configuration, display, enabled))
        }
    }
}
