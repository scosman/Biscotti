import DataStore
import Testing

@Suite("DataStore container lifecycle")
struct ContainerTests {
    @Test("In-memory container initialises successfully")
    func inMemoryInit() async throws {
        let store = try DataStore(storage: .inMemory)
        // If we got here, init succeeded — verify a round-trip works.
        let id = try await store.createMeeting(title: "Init check")
        let fetched = try await store.meeting(id: id)
        #expect(fetched != nil)
        #expect(fetched?.title == "Init check")
    }

    @Test("Two in-memory stores operate independently")
    func multipleContainersIndependent() async throws {
        let storeA = try DataStore(storage: .inMemory)
        let storeB = try DataStore(storage: .inMemory)

        let idA = try await storeA.createMeeting(title: "Only in A")

        // storeB should not see storeA's meeting
        let fetchedFromB = try await storeB.meeting(id: idA)
        #expect(fetchedFromB == nil)

        // storeA should still see its own meeting
        let fetchedFromA = try await storeA.meeting(id: idA)
        #expect(fetchedFromA != nil)
        #expect(fetchedFromA?.title == "Only in A")
    }

    @Test("CloudKit-off configuration does not throw")
    func cloudKitOff() async throws {
        // cloudKit defaults to false; explicit false should also work.
        let store = try DataStore(storage: .inMemory, cloudKit: false)
        let id = try await store.createMeeting(title: "CK off")
        #expect(try await store.meeting(id: id) != nil)
    }
}
