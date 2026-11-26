/// Holds every arrival until as many have come as it waits for.
actor Barrier {
    private let count: Int
    private let gate = Gate()
    private var arrivals = 0

    init(count: Int) {
        self.count = count
    }

    func arrive() async {
        arrivals += 1
        if arrivals == count { await gate.open() }
        await gate.wait()
    }
}
