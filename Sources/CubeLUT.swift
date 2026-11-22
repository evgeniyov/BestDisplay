import Foundation

struct CubeLUT: Sendable {
    let size: Int
    let data: Data

    init(contents: String) throws {
        var size = 0
        var samples: [Float] = []
        for original in contents.split(whereSeparator: \.isNewline) {
            let line = original.prefix { $0 != "#" }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let key = fields.first else { continue }

            switch key {
            case "TITLE":
                continue
            case "LUT_3D_SIZE":
                guard size == 0, fields.count == 2, let parsed = Int(fields[1]), (2...64).contains(parsed) else {
                    throw DisplayFailure("Размер LUT должен быть от 2 до 64.")
                }
                size = parsed
                samples.reserveCapacity(size * size * size * 4)
            case "DOMAIN_MIN", "DOMAIN_MAX":
                let endpoint: Float = key == "DOMAIN_MIN" ? 0 : 1
                guard fields.count == 4, fields.dropFirst().allSatisfy({ Float($0) == endpoint }) else {
                    throw DisplayFailure("Поддерживаются LUT с диапазоном 0…1.")
                }
            default:
                let rgb = fields.compactMap { Float($0) }
                guard size > 0, fields.count == 3, rgb.count == 3, rgb.allSatisfy(\.isFinite),
                      samples.count < size * size * size * 4 else {
                    throw DisplayFailure("В файле ожидается таблица 3D LUT в формате .cube.")
                }
                samples += rgb
                samples.append(1)
            }
        }
        guard size > 0, samples.count == size * size * size * 4 else {
            throw DisplayFailure("Количество цветов не совпадает с размером 3D LUT.")
        }
        self.size = size
        data = samples.withUnsafeBytes { Data($0) }
    }
}
