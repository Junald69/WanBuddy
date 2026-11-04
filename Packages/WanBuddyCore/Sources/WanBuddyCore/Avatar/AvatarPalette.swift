public enum AvatarPalette {
    /// Pastel fills from the v0.1 prototype. The color is chosen from the id, so no database column is required.
    public static let hexColors: [String] = [
        "F6E2D5",
        "F7E9BB",
        "DAEADF",
        "E1E6F4",
        "F8E8EE",
        "F3D9CA",
    ]

    public static func index(for id: String) -> Int {
        var hash = 0
        for byte in id.utf8 {
            hash = (hash &* 31) &+ Int(byte)
        }
        let count = hexColors.count
        let remainder = hash % count
        if remainder >= 0 {
            return remainder
        }
        return remainder + count
    }

    public static func hex(for id: String) -> String {
        hexColors[index(for: id)]
    }
}
