/// True once.
actor FirstTime {
    private var hasBeen = false

    func isNow() -> Bool {
        defer { hasBeen = true }
        return hasBeen == false
    }
}
