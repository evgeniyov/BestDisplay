import CoreGraphics
import Foundation

func profileURLTests() {
    func name(_ text: String) -> String? { URL(string: text).flatMap(ProfileURL.readName) }
    check(name("bestdisplay://profile?name=Desk%20%2B%20HP") == "Desk + HP", "valid profile URL")
    check(name("bestdisplay://profile?name=") == nil, "empty name rejected")
    check(name("https://profile?name=x") == nil, "wrong scheme rejected")
    check(name("bestdisplay://other?name=x") == nil, "wrong host rejected")
    check(name("bestdisplay://profile/extra?name=x") == nil, "path rejected")
    check(name("bestdisplay://profile?name=x&extra=1") == nil, "extra query item rejected")
    check(name("bestdisplay://profile?name=x#frag") == nil, "fragment rejected")
    check(name("bestdisplay://profile?name=\(String(repeating: "a", count: 81))") == nil, "name over 80 chars rejected")
}

func hardwareOptionsTests() {
    let caps = "(prot(monitor)type(lcd)vcp(10 12 60(0F 11 12 0F) D6(01 04 05)))"
    check(HardwareOptions.codes(.input, in: caps) == [0x0f, 0x11, 0x12], "input codes parsed and deduplicated")
    check(HardwareOptions.codes(.power, in: caps) == [1, 4, 5], "power codes parsed")
    check(HardwareOptions.codes(.input, in: "vcp(10 12)") == [], "missing feature yields no codes")
    check(HardwareOptions.inputLabel(0x11) == "HDMI 1", "known input label")
    check(HardwareOptions.inputLabel(0x99) == "Вход 0x99", "unknown input label")
    let options = HardwareOptions(inputs: [.init(id: 0x11, name: "HDMI 1")], powerModes: [],
                                  currentInput: nil, currentPower: nil)
    check(options.supports(0x11, for: .input), "supported input accepted")
    check(!options.supports(0x12, for: .input), "unsupported input rejected")
    check(!options.supports(1, for: .power), "power with no modes rejected")
}

func placementTests() {
    let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let other = CGRect(x: 0, y: 0, width: 1280, height: 720)
    check(Placement.left.origin(for: other, relativeTo: primary) == CGPoint(x: -1280, y: 0), "left placement")
    check(Placement.right.origin(for: other, relativeTo: primary) == CGPoint(x: 1920, y: 0), "right placement")
    check(Placement.above.origin(for: other, relativeTo: primary) == CGPoint(x: 0, y: -720), "above placement")
    check(Placement.below.origin(for: other, relativeTo: primary) == CGPoint(x: 0, y: 1080), "below placement")
}

func cecTests() {
    let listing = """
    found devices: 2
    device: 1
    com port: /dev/cu.usbmodem1101
    device: 2
    com port: /dev/other
    """
    check(CECClient.parseAdapters(listing) == ["/dev/cu.usbmodem1101"], "only /dev/cu. and /dev/tty. ports kept")
    check(CECClient.parseAdapters("found devices: none") == [], "no adapters")
    check((try? CECClient.parsePowerStatus("power status: on")) == "Телевизор включён", "power on")
    check((try? CECClient.parsePowerStatus("POWER STATUS: standby\n")) == "Телевизор в режиме ожидания", "power standby")
    check((try? CECClient.parsePowerStatus("power status: unknown")) == nil, "unknown power status throws")
    check((try? CECClient.parsePowerStatus("no answer")) == nil, "missing power line throws")
}
