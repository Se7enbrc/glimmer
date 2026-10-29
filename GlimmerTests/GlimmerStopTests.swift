// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

@testable import GlimmerEngine
import Foundation
import Testing
@testable import Glimmer

@Suite(.serialized)
struct GlimmerStopTests {
    private let settings = IsolatedDefaults()

    private let app = LibraryApp(id: 7, name: "Steam", hdr: false, hidden: false)

    private func pc(id: String = "pc-id", name: String = "Den PC") -> Glimmer.Host {
        Host(id: id, name: name, customName: nil, localAddress: "192.0.2.10", manualAddress: "den.local",
             apps: [app], lastConnected: nil, serverCertPEM: nil, appVersion: nil, macAddress: nil)
    }

    @Test func stopParsesWithAnOptionalPCAndJSON() throws {
        for arguments in [[], ["Den PC"]] {
            #expect(try GlimmerCLI.parse(["stop"] + arguments + ["--json"])
                == .init(verb: .stop, arguments: arguments, flags: ["--json"]))
        }
        #expect(throws: GlimmerCLI.UsageError.self) { try GlimmerCLI.parse(["stop", "Den", "Other"]) }
        #expect(throws: GlimmerCLI.UsageError.self) { try GlimmerCLI.parse(["stop", "--force"]) }
        for (text, arguments) in [("glimmer://stop", [String]()),
                                  ("glimmer://stop?pc=Den%20PC", ["Den PC"])] {
            #expect(GlimmerCLI.parseURL(try #require(URL(string: text))) == .init(verb: .stop, arguments: arguments))
        }
    }

    @Test(arguments: ["glimmer://stop?app=Steam", "glimmer://stop?pc=Den&force=1",
                      "glimmer://stop?pc=Den&pc=Other", "glimmer://stop?pc=", "glimmer://stop?pc",
                      "glimmer://stop?pc=%20", "glimmer://stop?pc=Den%0A", "glimmer://stop/path",
                      "glimmer://stop#fragment", "glimmer://user@stop", "glimmer://stop:42"])
    func malformedStopURLsAreIgnored(_ text: String) throws {
        #expect(GlimmerCLI.parseURL(try #require(URL(string: text))) == nil)
    }

    @MainActor @Test func stopRequestsAreHandledOnceWithoutRequiringAPairedPC() {
        var handled = Set<String>()
        let request = [CommandChannel.Key.id: "stop", CommandChannel.Key.verb: "stop"]
        #expect(CommandChannel.decide(request, handled: &handled, hosts: [], streamingFrom: nil)
            == .stopStreaming(nil))
        #expect(CommandChannel.decide(request, handled: &handled, hosts: [], streamingFrom: nil) == nil)
    }

    @MainActor @Test func absentAppReturnsFiveWithoutSendingOrOpeningAnything() async throws {
        let terminal = CapturedTerminal()
        let command = try GlimmerCLI.parse(["stop", "Den PC", "--json"])
        let result = await CLITerminal.$write.withValue(terminal.write) {
            await GlimmerCLI.stop(command, appIsRunning: { false }, send: { _ in
                Issue.record("An absent app must not receive a stop request")
                return nil
            })
        }
        #expect(result == 5)
        #expect(terminal.out == "{\"result\":\"noActiveStream\",\"stopped\":false,\"version\":1}\n")
        #expect(terminal.err.isEmpty)
    }

    @MainActor @Test func cliResultsKeepTheVersionedJSONAndExitContract() async throws {
        for (event, code) in [("stopped", Int32(0)), ("noActiveStream", 5), ("pcMismatch", 1), ("unknown", 1)] {
            for json in [false, true] {
                let terminal = CapturedTerminal()
                let command = try GlimmerCLI.parse(["stop", "Den PC"] + (json ? ["--json"] : []))
                let result = await CLITerminal.$write.withValue(terminal.write) {
                    await GlimmerCLI.stop(command, appIsRunning: { true }, send: { request in
                        #expect(request == [CommandChannel.Key.verb: "stop", CommandChannel.Key.pc: "Den PC"])
                        return [CommandChannel.Key.event: event]
                    })
                }
                #expect(result == code)
                if code == 1 {
                    #expect(terminal.out.isEmpty && !terminal.err.isEmpty)
                } else if json {
                    let object = try #require(JSONSerialization.jsonObject(with: Data(terminal.out.utf8))
                        as? [String: Any])
                    #expect(object["version"] as? Int == 1)
                    #expect(object["result"] as? String == event)
                    #expect(object["stopped"] as? Bool == (code == 0))
                    #expect(terminal.err.isEmpty && terminal.out.hasSuffix("\n"))
                } else {
                    #expect(terminal.out == (code == 0 ? "Stream stopped.\n" : "No active stream.\n"))
                }
            }
        }
        let terminal = CapturedTerminal()
        let result = await CLITerminal.$write.withValue(terminal.write) {
            await GlimmerCLI.stop(.init(verb: .stop, flags: ["--json"]),
                                  appIsRunning: { true }, send: { _ in nil })
        }
        #expect(result == 1 && terminal.out.isEmpty && !terminal.err.isEmpty)
    }

    @MainActor @Test func urlMismatchAndIdleNeverStopOrAskForConfirmation() async throws {
        let model = AppModel(defaults: settings.defaults)
        model.nativeSession = StreamSession(hostDisposition: .cancelOwnedHostSession, backend: InputRecordingBackend())
        model.lastLaunchAttempt = (app, pc())
        var reply: [String: String]?
        model.postCommandReply = { reply = $0 }
        let mismatch = try #require(URL(string: "glimmer://stop?pc=Other"))
        model.handleCommandURL(mismatch)
        #expect(await AppModel.poll(slices: 100, every: .milliseconds(10)) { reply != nil })
        #expect(reply?[CommandChannel.Key.event] == "pcMismatch")
        #expect(!model.menuStopInProgress)
        model.nativeSession = nil
        reply = nil
        model.handleCommandURL(try #require(URL(string: "glimmer://stop")))
        #expect(await AppModel.poll(slices: 100, every: .milliseconds(10)) { reply != nil })
        #expect(reply?[CommandChannel.Key.event] == "noActiveStream")
        #expect(!model.menuStopInProgress)
    }

    @MainActor @Test(arguments: ["menu", "url", "cli", "intent"])
    func everyStopUsesTheMenuTeardownAndCancelsThePC(_ route: String) async throws {
        let model = AppModel(defaults: settings.defaults)
        let sunshine = FakeSunshine.scripted(["cancel": [SessionFlow.cancelled]])
        let session = StreamSession(hostDisposition: .cancelOwnedHostSession, backend: InputRecordingBackend())
        let server = SessionFlow.pairedPC()
        await session.prepareLaunchFlow(server: server)
        await session.prepareStopCommandTest(network: sunshine.client(server))
        model.nativeSession = session
        model.lastLaunchAttempt = (app, pc())
        model.isStreaming = true
        // A different launcher selection must not redirect or veto stopping the current stream.
        model.selectedHost = pc(id: "other", name: "Other PC")
        model.hosts = [model.selectedHost].compactMap { $0 }
        var reply: [String: String]?
        model.postCommandReply = { reply = $0 }
        switch route {
        case "menu": await model.stopStreamFromMenu()?.value
        case "url":
            model.handleCommandURL(try #require(URL(string: "glimmer://stop?pc=den%20pc")), confirm: { _ in true })
            #expect(await AppModel.poll(slices: 200, every: .milliseconds(10)) { reply != nil })
            #expect(reply?[CommandChannel.Key.event] == "stopped")
        case "cli":
            let terminal = CapturedTerminal()
            let result = await CLITerminal.$write.withValue(terminal.write) {
                await GlimmerCLI.stop(.init(verb: .stop), appIsRunning: { true }, send: { request in
                    var info = request
                    info[CommandChannel.Key.id] = UUID().uuidString
                    model.handleCommand(info)
                    _ = await AppModel.poll(slices: 200, every: .milliseconds(10)) { reply != nil }
                    return reply
                })
            }
            #expect(result == 0)
        default: try await StopStreamingIntent.stop(model: model)
        }
        #expect(model.menuStopInProgress)
        #expect(await session.stopCause == .userStopped)
        #expect(sunshine.paths == ["cancel"])
        #expect(await model.stopActiveStream(source: "a repeated request") == .noActiveStream)
        #expect(sunshine.paths == ["cancel"])
    }

    @MainActor @Test func externalStopCannotEndTheSessionWithoutConfirmation() async throws {
        let model = AppModel(defaults: settings.defaults)
        let session = StreamSession(hostDisposition: .cancelOwnedHostSession, backend: InputRecordingBackend())
        model.nativeSession = session
        model.lastLaunchAttempt = (app, pc())
        var confirmations = 0
        model.handleCommand([CommandChannel.Key.id: UUID().uuidString, CommandChannel.Key.verb: "stop"],
                            fromURL: true, confirmExternal: { _ in confirmations += 1; return false })
        #expect(confirmations == 1)
        #expect(!model.menuStopInProgress)
        model.nativeSession = nil
    }

    @MainActor @Test func externalStopApprovalCannotFollowAReplacementSession() throws {
        let model = AppModel(defaults: settings.defaults)
        model.nativeSession = StreamSession(hostDisposition: .cancelOwnedHostSession, backend: InputRecordingBackend())
        model.lastLaunchAttempt = (app, pc())
        let replacement = StreamSession(hostDisposition: .cancelOwnedHostSession, backend: InputRecordingBackend())
        model.handleCommandURL(try #require(URL(string: "glimmer://stop")), confirm: { _ in
            model.nativeSession = replacement
            return true
        })
        #expect(model.nativeSession === replacement)
        #expect(!model.menuStopInProgress)
    }

    @MainActor @Test func externalLaunchRequiresConfirmation() throws {
        let model = AppModel(defaults: settings.defaults)
        model.hosts = [pc()]
        var confirmations = 0
        model.handleCommandURL(try #require(URL(string: "glimmer://stream?pc=pc-id&app=Steam")), confirm: { prompt in
            confirmations += 1
            #expect(prompt.action == .stream)
            return false
        })
        #expect(confirmations == 1)
        #expect(model.pendingCommandStream == nil && model.nativeSession == nil)
    }

    @MainActor @Test func matchingUsesTheActivePCsNamesIDsAndAddresses() async {
        for name in ["den pc", "PC-ID", "192.0.2.10", "DEN.LOCAL"] {
            let model = AppModel(defaults: settings.defaults)
            model.nativeSession = StreamSession(hostDisposition: .cancelOwnedHostSession, backend: InputRecordingBackend())
            model.lastLaunchAttempt = (app, pc())
            #expect(await model.stopActiveStream(matching: name, source: "a test") == .stopped)
            #expect(model.menuStopInProgress)
        }
        await #expect(throws: PCIntentError.failed("No active stream.")) {
            try await StopStreamingIntent.stop(model: AppModel(defaults: settings.defaults))
        }
    }
}

private extension StreamSession {
    func prepareStopCommandTest(network: NetworkClient) {
        isStreaming = true
        ownsHostSession = true
        self.network = network
    }
}
