/// A named, ordered list of test steps that a human walks through in the manual test app.
public struct TestScript: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let steps: [TestStep]

    public init(id: String, title: String, steps: [TestStep]) {
        self.id = id
        self.title = title
        self.steps = steps
    }
}
