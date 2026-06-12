import DataStore
import Testing

@Suite("DataStore container lifecycle")
struct ContainerTests {
    @Test("In-memory container initialises successfully")
    func inMemoryInit() async throws {
        let store = try DataStore(storage: .inMemory)
        // If we got here, init succeeded — verify a round-trip works.
        let id = try await store.createMeeting(title: "Init check")
        try await store.read { store in
            let fetched = try store.meeting(id: id)
            #expect(fetched != nil)
            #expect(fetched?.title == "Init check")
        }
    }

    @Test("Two in-memory stores operate independently")
    func multipleContainersIndependent() async throws {
        let storeA = try DataStore(storage: .inMemory)
        let storeB = try DataStore(storage: .inMemory)

        let idA = try await storeA.createMeeting(title: "Only in A")

        // storeB should not see storeA's meeting
        #expect(try await storeB.meetingExists(id: idA) == false)

        // storeA should still see its own meeting
        try await storeA.read { store in
            let fetchedFromA = try store.meeting(id: idA)
            #expect(fetchedFromA != nil)
            #expect(fetchedFromA?.title == "Only in A")
        }
    }

    @Test("CloudKit-off configuration does not throw")
    func cloudKitOff() async throws {
        // cloudKit defaults to false; explicit false should also work.
        let store = try DataStore(storage: .inMemory, cloudKit: false)
        let id = try await store.createMeeting(title: "CK off")
        #expect(try await store.meetingExists(id: id))
    }
}
