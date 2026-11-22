@preconcurrency import ColorSync
import CoreGraphics
import Foundation

struct Calibration: Equatable {
    var contrast = 1.0
    var gamma = 1.0
    var red = 1.0
    var green = 1.0
    var blue = 1.0

    func apply(to tables: TransferTables) -> TransferTables {
        let channels = zip(tables.channels, [red, green, blue]).map { channel, gain in
            channel.map { sample -> Float in
                let centered: Double = Double(sample) - 0.5
                let adjusted: Double = centered * contrast + 0.5
                let value = min(1.0, max(0.0, adjusted))
                let corrected: Double = pow(value, 1.0 / gamma) * gain
                return Float(min(1.0, max(0.0, corrected)))
            }
        }
        return TransferTables(channels: channels)
    }

    func writeProfile(for display: Display, to url: URL) throws {
        guard CGDisplayIsOnline(display.id) != 0, displayIdentity(display.id) == display.identity,
              let profile = ColorSyncProfileCreateWithDisplayID(display.id)?.takeRetainedValue(),
              let copy = ColorSyncProfileCreateMutableCopy(profile)?.takeRetainedValue() else {
            throw DisplayFailure("Не удалось открыть действующий ICC-профиль дисплея.")
        }
        let entries = 256
        var count = 0
        let previous = ColorSyncProfileCreateDisplayTransferTablesFromVCGT(profile, &count)?.takeRetainedValue()
        let baseline = TransferTables(profileData: previous as Data?, samples: count, outputSamples: entries)
        var tag = Data("vcgt".utf8)
        tag.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        for value in [3, entries, 2] { tag.appendBigEndian(UInt16(value)) }
        for channel in apply(to: baseline).channels {
            for sample in channel { tag.appendBigEndian(UInt16((Double(sample) * 65_535).rounded())) }
        }
        ColorSyncProfileSetTag(copy, "vcgt" as CFString, tag as CFData)
        var verifiedCount = 0
        guard let data = ColorSyncProfileCopyData(copy, nil)?.takeRetainedValue(),
              let verified = ColorSyncProfileCreate(data, nil)?.takeRetainedValue(),
              ColorSyncProfileCreateDisplayTransferTablesFromVCGT(verified, &verifiedCount) != nil,
              verifiedCount == entries else {
            throw DisplayFailure("ColorSync не подтвердил таблицу калибровки ICC.")
        }
        try (data as Data).write(to: url, options: .atomic)
    }
}

struct TransferTables {
    let channels: [[Float]]

    init(channels: [[Float]]) { self.channels = channels }

    init(profileData: Data?, samples: Int, outputSamples: Int) {
        let ramp = (0..<outputSamples).map { Float($0) / Float(outputSamples - 1) }
        guard let profileData, samples > 1,
              profileData.count / (3 * MemoryLayout<Float>.size) == samples else {
            channels = Array(repeating: ramp, count: 3)
            return
        }
        channels = profileData.withUnsafeBytes { bytes in
            (0..<3).map { channel in
                let base = channel * samples
                return ramp.map { value in
                    let index = min(samples - 2, Int(value * Float(samples - 1)))
                    let weight = value * Float(samples - 1) - Float(index)
                    let a = bytes.loadUnaligned(fromByteOffset: (base + index) * MemoryLayout<Float>.size, as: Float.self)
                    let b = bytes.loadUnaligned(fromByteOffset: (base + index + 1) * MemoryLayout<Float>.size, as: Float.self)
                    let result = a + (b - a) * weight
                    return result.isFinite ? result : value
                }
            }
        }
    }

    static func read(_ id: CGDirectDisplayID) throws -> Self {
        let capacity = CGDisplayGammaTableCapacity(id)
        guard capacity > 1, capacity <= 65_536 else {
            throw DisplayFailure("Дисплей не предоставляет цветовую таблицу рабочего стола.")
        }
        var red = [Float](repeating: 0, count: Int(capacity))
        var green = red
        var blue = red
        var count: UInt32 = 0
        try checkDisplayError(CGGetDisplayTransferByTable(id, capacity, &red, &green, &blue, &count))
        guard count > 1, count <= capacity else { throw DisplayFailure("Не удалось прочитать таблицу цветов.") }
        return Self(channels: [red, green, blue].map { Array($0.prefix(Int(count))) })
    }

    func write(_ id: CGDirectDisplayID) throws {
        try checkDisplayError(CGSetDisplayTransferByTable(id, UInt32(channels[0].count), channels[0], channels[1], channels[2]))
    }

    func matches(_ other: Self) -> Bool {
        zip(channels, other.channels).allSatisfy { actual, expected in
            actual.count == expected.count && zip(actual, expected).allSatisfy { abs($0 - $1) < 0.003 }
        }
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}
