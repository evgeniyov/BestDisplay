import Foundation

func parses(_ text: String) -> CubeLUT? { try? CubeLUT(contents: text) }

func cubeLUTTests() {

    let identity2 = """
    TITLE "id"
    # comment
    LUT_3D_SIZE 2
    DOMAIN_MIN 0 0 0
    DOMAIN_MAX 1 1 1
    0 0 0
    1 0 0
    0 1 0
    1 1 0
    0 0 1
    1 0 1
    0 1 1
    1 1 1
    """
    check(parses(identity2)?.size == 2, "valid 2x2x2 cube parses")
    check(parses(identity2)?.data.count == 8 * 4 * MemoryLayout<Float>.size, "RGBA float data size")
    check(parses("LUT_3D_SIZE 2\n0 0 0\n") == nil, "too few samples rejected")
    check(parses("LUT_3D_SIZE 1\n0 0 0\n") == nil, "size below 2 rejected")
    check(parses("LUT_3D_SIZE 65\n") == nil, "size above 64 rejected")
    check(parses("0 0 0\n") == nil, "sample before size rejected")
    check(parses("LUT_3D_SIZE 2\nDOMAIN_MAX 2 2 2\n") == nil, "non-unit domain rejected")
    check(parses(identity2 + "\n1 1 1\n") == nil, "extra sample rejected")
    check(parses(identity2.replacingOccurrences(of: "1 1 1\n", with: "nan 1 1\n")) == nil, "NaN rejected")
}
