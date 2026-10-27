import SwiftUI

enum Theme {
    static let paper = Color(red: 0.965, green: 0.957, blue: 0.937)
    static let ink = Color(red: 0.16, green: 0.18, blue: 0.15)
    static let accent = Color(red: 0.77, green: 0.35, blue: 0.22)
    static let sage = Color(red: 0.89, green: 0.92, blue: 0.85)
    static let muted = Color(red: 0.52, green: 0.56, blue: 0.48)
}

func clock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    return "\(Int(seconds) / 60):\(String(format: "%02d", Int(seconds) % 60))"
}
