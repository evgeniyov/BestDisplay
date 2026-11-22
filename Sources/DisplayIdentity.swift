import ColorSync
import CoreGraphics
import Foundation

func displayUUID(_ id: CGDirectDisplayID) -> CFUUID? {
    CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
}

func legacyDisplayIdentity(_ id: CGDirectDisplayID) -> String? {
    displayUUID(id).map { CFUUIDCreateString(nil, $0) as String }
}

struct DisplayHardwareFingerprint: Equatable {
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32

    func identity(among peers: @autoclosure () -> [Self], uuid: @autoclosure () -> String?) -> String? {
        guard vendor != 0, serial != 0, !peers().contains(self) else { return uuid() }
        return "hw-\(vendor)-\(model)-\(serial)"
    }

    fileprivate init(display id: CGDirectDisplayID) {
        self.init(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id))
    }

    init(vendor: UInt32, model: UInt32, serial: UInt32) {
        self.vendor = vendor
        self.model = model
        self.serial = serial
    }
}

func displayIdentity(_ id: CGDirectDisplayID, among onlineIDs: [CGDirectDisplayID]? = nil) -> String? {
    DisplayHardwareFingerprint(display: id).identity(
        among: (onlineIDs ?? onlineDisplayIDs()).filter { $0 != id }.map(DisplayHardwareFingerprint.init(display:)),
        uuid: legacyDisplayIdentity(id)
    )
}

func onlineDisplayIDs() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
    return Array(ids.prefix(Int(count)))
}
