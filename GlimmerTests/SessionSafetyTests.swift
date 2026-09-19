import Foundation
import Testing
@testable import Glimmer

struct SessionSafetyTests {
    @Test func hdrSnapshotsNeverMixBlobs() async {
        let store = HDRMetadataStore()
        await withTaskGroup(of: Void.self) { group in
            for value in UInt8(1)...UInt8(4) {
                group.addTask {
                    let metadata = HDRMetadata(mdcv: Data([value]), contentLightLevel: Data([value]))
                    for _ in 0..<1_000 {
                        store.publish(metadata)
                        let snapshot = store.snapshot
                        #expect(snapshot.mdcv == snapshot.contentLightLevel)
                        store.publish(.empty)
                    }
                }
            }
        }
    }

    @Test func hdrMetadataChangesIncludeEitherBlobAndReset() {
        let store = HDRMetadataStore()
        let first = HDRMetadata(mdcv: Data([1]), contentLightLevel: Data([2]))
        store.publish(first)
        #expect(store.snapshot == first)
        store.publish(HDRMetadata(mdcv: first.mdcv, contentLightLevel: Data([3])))
        #expect(store.snapshot != first)
        store.publish(HDRMetadata(mdcv: Data([4]), contentLightLevel: first.contentLightLevel))
        #expect(store.snapshot != first)
        store.publish(.empty)
        #expect(store.snapshot == .empty)
    }

    @Test func abandonedLaunchCannotContinue() {
        for cancelled in [false, true] {
            for streaming in [false, true] {
                for stopping in [false, true] {
                    #expect(StreamAttempt.shouldContinue(
                        cancelled: cancelled, streaming: streaming, stopping: stopping)
                        == (!cancelled && streaming && !stopping))
                }
            }
        }
    }

    @Test func cancellationAfterSuspensionPreventsHostMutation() async {
        let request = SafetyTestGate()
        let entered = SafetyTestGate()
        let mutation = SafetyTestCounter()
        let task = Task {
            await entered.open()
            await request.wait()
            guard StreamAttempt.shouldContinue(
                cancelled: Task.isCancelled, streaming: true, stopping: false) else {
                throw CancellationError()
            }
            await mutation.increment()
        }
        await entered.wait()
        task.cancel()
        await request.open()
        do {
            try await task.value
            Issue.record("Cancelled launch continued")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(await mutation.value == 0)
    }

    @Test func cancelledTransportCannotSendAfterHandshake() throws {
        let lifetime = ControlTransport.RequestLifetime(timeout: 10)
        try lifetime.check()
        lifetime.cancel()
        #expect(throws: CancellationError.self) { try lifetime.check() }
    }

    @Test func quitWaitsForOverlappingStop() async {
        let teardown = SharedTeardown()
        let entered = SafetyTestGate()
        let release = SafetyTestGate()
        let completed = SafetyTestCounter()
        let first = Task {
            await teardown.run {
                await entered.open()
                await release.wait()
                await completed.increment()
            }
        }
        await entered.wait()
        let quit = Task {
            await TerminationGate.runBounded(seconds: 2) {
                await teardown.run { Issue.record("Teardown ran twice") }
            }
        }
        #expect(await completed.value == 0)
        await release.open()
        #expect(await quit.value)
        await first.value
        #expect(await completed.value == 1)
    }

    @Test func quitBoundDoesNotTreatRunningTeardownAsFinished() async {
        let teardown = SharedTeardown()
        let entered = SafetyTestGate()
        let release = SafetyTestGate()
        let first = Task {
            await teardown.run {
                await entered.open()
                await release.wait()
            }
        }
        await entered.wait()
        let finished = await TerminationGate.runBounded(seconds: 0.02) {
            await teardown.run { Issue.record("Teardown ran twice") }
        }
        #expect(!finished)
        await release.open()
        await first.value
    }

    @Test func deadlineBoundsUncooperativeRequestAndPreventsNextLeg() async {
        let release = SafetyTestGate()
        let unwound = SafetyTestGate()
        let entered = SafetyTestGate()
        let mutations = SafetyTestCounter()
        let start = Date()
        do {
            try await StreamAttempt.run(until: start.addingTimeInterval(0.02)) {
                await entered.open()
                await release.wait()
                defer { Task { await unwound.open() } }
                try Task.checkCancellation()
                await mutations.increment()
            }
            Issue.record("Request outlived its deadline")
        } catch {
            #expect(Date().timeIntervalSince(start) < 1)
        }
        await release.open()
        if await entered.isOpen { await unwound.wait() }
        #expect(await mutations.value == 0)
    }

    @Test func expiredDeadlineDoesNotStartAnotherRequest() async {
        let requests = SafetyTestCounter()
        do {
            try await StreamAttempt.run(until: Date().addingTimeInterval(-1)) {
                await requests.increment()
            }
            Issue.record("Expired attempt started")
        } catch {
            #expect(await requests.value == 0)
        }
    }

    @Test func occupiedHostsNeedExplicitAuthorizationUnlessOwned() {
        #expect(StreamAttempt.requiresTakeover(occupied: true, owner: nil, client: "ours", authorized: false))
        #expect(StreamAttempt.requiresTakeover(occupied: true, owner: "other", client: "ours", authorized: false))
        #expect(!StreamAttempt.requiresTakeover(occupied: true, owner: "ours", client: "ours", authorized: false))
        #expect(!StreamAttempt.requiresTakeover(occupied: true, owner: nil, client: "ours", authorized: true))
        #expect(!StreamAttempt.requiresTakeover(occupied: false, owner: nil, client: "ours", authorized: false))
        #expect(StreamAttempt.requiresTakeover(occupied: true, owner: "", client: "", authorized: false))
    }

    @Test func pairingResultsRequireCurrentAttemptAndHost() {
        let first = PairingAttempt(address: "first.local")
        let second = PairingAttempt(address: "second.local")
        let retry = PairingAttempt(address: "first.local")
        #expect(first.accepts(first, address: "first.local", cancelled: false))
        #expect(!first.accepts(second, address: "second.local", cancelled: false))
        #expect(!first.accepts(retry, address: "first.local", cancelled: false))
        #expect(!first.accepts(nil, address: "first.local", cancelled: false))
        #expect(!first.accepts(first, address: "second.local", cancelled: false))
        #expect(!first.accepts(first, address: "first.local", cancelled: true))
    }
}

private actor SafetyTestGate {
    private(set) var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private actor SafetyTestCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
