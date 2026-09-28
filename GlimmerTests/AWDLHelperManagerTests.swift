import Foundation
import Synchronization
import Testing
@testable import Glimmer

private final class HelperTestProxy: NSObject, Glimmer.GlimmerHelperProtocol {
    func setAWDLDown(_ down: Bool, reason: String, reply: @escaping @Sendable (Bool) -> Void) { reply(true) }
    func currentStatus(reply: @escaping (Bool, Date?) -> Void) { reply(false, nil) }
    func ping(reply: @escaping (String) -> Void) { reply("test") }
    func reSuppressCount(reply: @escaping (UInt64) -> Void) { reply(0) }
}

struct HelperClientTests {
    @Test func errorsRetainConnectionAndStaleInvalidationsCannotDropReplacement() async throws {
        let identities = Mutex<[ObjectIdentifier]>([])
        let fail = Mutex(false)
        let invalidated = DispatchSemaphore(value: 0)
        let client = HelperClient(makeConnection: {
            let connection = NSXPCConnection(machServiceName: glimmerHelperMachServiceName, options: .privileged)
            identities.withLock { $0.append(ObjectIdentifier(connection)) }
            return connection
        }, makeProxy: { connection, error in
            #expect(connection.interruptionHandler == nil)
            let original = connection.invalidationHandler
            connection.invalidationHandler = {
                invalidated.signal()
                original?()
            }
            if fail.withLock({ $0 }) {
                error(CancellationError())
                // A late reply after a transport failure must not resume twice.
            }
            return HelperTestProxy()
        })
        #expect(await client.setAWDLDown(true, reason: "test"))
        let first = try #require(identities.withLock { $0.first })
        fail.withLock { $0 = true }
        #expect(!(await client.setAWDLDown(false, reason: "test")))
        #expect(await client.currentStatus() == nil)
        #expect(await client.reSuppressCount() == nil)
        #expect(identities.withLock { $0.count } == 1)
        await client.drop(first)
        #expect(await invalidated.waitAsync(for: .seconds(10)) == .success)
        fail.withLock { $0 = false }
        #expect(await client.reSuppressCount() == 0)
        #expect(identities.withLock { $0.count } == 2)
        await client.drop(first)
        #expect(await client.reSuppressCount() == 0)
        #expect(identities.withLock { $0.count } == 2)
        await client.invalidate()
    }
}
