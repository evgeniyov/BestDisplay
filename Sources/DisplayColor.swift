@preconcurrency import ColorSync
import CoreGraphics
import Foundation

extension DisplayColor {
    static func read(_ display: CGDirectDisplayID) -> DisplayColor? {
        guard let deviceClass = kColorSyncDisplayDeviceClass?.takeUnretainedValue(),
              let uuid = displayUUID(display),
              let info = ColorSyncDeviceCopyDeviceInfo(deviceClass, uuid)?
                .takeRetainedValue() as? [String: Any] else { return nil }
        guard let customKey = kColorSyncCustomProfiles?.takeUnretainedValue(),
              let defaultKey = kColorSyncDeviceDefaultProfileID?.takeUnretainedValue(),
              let factoryKey = kColorSyncFactoryProfiles?.takeUnretainedValue() else { return nil }
        let profiles = info[customKey as String] as? [String: Any] ?? [:]
        let key = defaultKey as String
        let factory = info[factoryKey as String] as? [String: Any]
        let factoryDefault = factory?[key] as? String
        let url = profiles[key] as? URL ?? factoryDefault.flatMap { profiles[$0] as? URL }
        return DisplayColor(customProfile: url)
    }

    var title: String { customProfile?.deletingPathExtension().lastPathComponent ?? "Заводской профиль" }

    func validate() throws {
        guard let url = customProfile else { return }
        let problem = DisplayFailure("Не удалось открыть «\(url.lastPathComponent)» как цветовой профиль RGB для дисплея.")
        guard url.isFileURL, let reader = try? FileHandle(forReadingFrom: url) else { throw problem }
        defer { try? reader.close() }
        guard let header = try? reader.read(upToCount: 128), header.count == 128,
              header[12..<16].elementsEqual("mntr".utf8), header[16..<20].elementsEqual("RGB ".utf8),
              header[36..<40].elementsEqual("acsp".utf8),
              ColorSyncProfileCreateWithURL(url as CFURL, nil)?.takeRetainedValue() != nil else { throw problem }
    }

    func apply(to display: Display) throws {
        try validate()
        guard CGDisplayIsOnline(display.id) != 0,
              displayIdentity(display.id) == display.identity,
              let uuid = displayUUID(display.id) else {
            throw DisplayFailure("Дисплей «\(display.title)» отключён.")
        }
        guard let deviceClass = kColorSyncDisplayDeviceClass?.takeUnretainedValue(),
              let defaultKey = kColorSyncDeviceDefaultProfileID?.takeUnretainedValue() else {
            throw DisplayFailure("ColorSync недоступен.")
        }
        let value: Any = if let customProfile { customProfile as CFURL } else { NSNull() }
        let profiles = [defaultKey as String: value]
        guard ColorSyncDeviceSetCustomProfiles(deviceClass, uuid, profiles as CFDictionary),
              Self.read(display.id) == self else {
            throw DisplayFailure("macOS не подтвердила цветовой профиль дисплея «\(display.title)».")
        }
    }
}
