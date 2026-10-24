// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

@testable import GlimmerEngine
import Foundation
import Testing
@testable import Glimmer

struct GlimmerAutomationTests {
    private let settings = IsolatedDefaults()

    private let app = LibraryApp(id: 7, name: "Hades II", hdr: true, hidden: false)

    private func pc(manual: String? = "Den.local:47989") -> Glimmer.Host {
        Host(id: "pc-id", name: "Den PC", customName: nil, localAddress: "192.0.2.99", manualAddress: manual,
             apps: [app], lastConnected: nil, serverCertPEM: nil, appVersion: nil, macAddress: nil)
    }

    private func object(_ json: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    @Test func urlsDecodeNamesOnceAndNeverCreateFlags() throws {
        let url = try #require(URL(string: "glimmer://stream?pc=Den%20PC&app=Hades%20II"))
        #expect(GlimmerCLI.parseURL(url) == .init(verb: .stream, arguments: ["Den PC", "Hades II"]))
        let literal = try #require(URL(string: "glimmer://stream?pc=Den%2520PC&app=A%2BB%26C"))
        #expect(GlimmerCLI.parseURL(literal)?.arguments == ["Den%20PC", "A+B&C"])
        for verb in ["wake", "quit", "stream"] {
            let url = try #require(URL(string: "glimmer://\(verb)?pc=%5B2001%3Adb8%3A%3A1%5D"))
            let command = try #require(GlimmerCLI.parseURL(url))
            #expect(command.verb.rawValue == verb)
            #expect(command.arguments == ["[2001:db8::1]"])
            #expect(command.flags.isEmpty && command.pin == nil)
        }
    }

    @Test(arguments: [
        "glimmer://pair?pc=Den", "glimmer://unknown?pc=Den", "https://stream?pc=Den",
        "glimmer://stream", "glimmer://stream?pc=", "glimmer://stream?pc=%20",
        "glimmer://stream?pc", "glimmer://stream?pc=Den&pc=Other", "glimmer://stream?pc=Den&app=",
        "glimmer://stream?pc=Den&app=A&app=B", "glimmer://stream?pc=Den&force=1",
        "glimmer://quit?pc=Den&app=A", "glimmer://quit?pc=Den&--force",
        "glimmer://user@stream?pc=Den", "glimmer://stream:42?pc=Den", "glimmer://stream/path?pc=Den",
        "glimmer://stream?pc=Den#fragment", "glimmer://stream?pc=Den%0A", "glimmer://stream?PC=Den"
    ])
    func malformedURLsAreIgnored(_ text: String) throws {
        let url = try #require(URL(string: text))
        #expect(GlimmerCLI.parseURL(url) == nil)
    }

    @MainActor @Test func urlsDispatchThroughTheCommandChannel() throws {
        let model = AppModel(defaults: settings.defaults)
        model.hosts = [pc()]
        var handled = Set<String>()
        for verb in ["stream", "wake", "quit"] {
            let url = try #require(URL(string: "glimmer://\(verb)?pc=den%20pc"))
            var request: [String: String]?
            model.handleCommandURL(url, dispatch: { request = $0 })
            let info = try #require(request)
            #expect(info[CommandChannel.Key.host] == "pc-id")
            #expect(info[CommandChannel.Key.takeover] == nil)
            let decision = CommandChannel.decide(info, handled: &handled, hosts: model.hosts, streamingFrom: "pc-id")
            switch verb {
            case "wake": #expect(decision == .wake(pc()))
            case "quit": #expect(decision == .stop)
            default:
                #expect(decision == .rejected(CommandChannel.alreadyStreaming))
                var fresh = Set<String>()
                #expect(CommandChannel.decide(info, handled: &fresh, hosts: model.hosts, streamingFrom: nil)
                    == .stream(app, on: pc(), takeover: false))
            }
        }
    }

    @MainActor @Test func unknownTargetsDoNotDispatchOrChangeSelection() throws {
        let model = AppModel(defaults: settings.defaults)
        model.hosts = [pc()]
        var calls = 0
        for text in ["glimmer://stream?pc=Missing", "glimmer://stream?pc=Den%20PC&app=Missing",
                     "glimmer://pair?pc=Den%20PC"] {
            model.handleCommandURL(try #require(URL(string: text)), dispatch: { _ in calls += 1 })
        }
        #expect(calls == 0)
        #expect(model.selectedHost == nil)
    }

    @MainActor @Test func aURLForTheCurrentStreamBringsItForwardWithoutRelaunching() throws {
        let model = AppModel(defaults: settings.defaults)
        model.hosts = [pc()]
        model.isStreaming = true
        model.lastLaunchAttempt = (app, pc())
        var resumes = 0
        var dispatches = 0
        for suffix in ["", "&app=Hades%20II"] {
            model.handleCommandURL(try #require(URL(string: "glimmer://stream?pc=Den%20PC\(suffix)")),
                                   dispatch: { _ in dispatches += 1 }, resume: { resumes += 1 })
        }
        #expect(resumes == 2 && dispatches == 0)
    }

    @MainActor @Test func quitRequiresTheAppConfirmationEvenWithoutAStatusReading() {
        let model = AppModel(defaults: settings.defaults)
        var confirmations = 0
        model.hosts = [pc()]
        let request = [CommandChannel.Key.id: UUID().uuidString, CommandChannel.Key.verb: "quit",
                       CommandChannel.Key.host: "pc-id", CommandChannel.Key.takeover: "1"]
        model.handleCommand(request, fromURL: true) { app, host in
            confirmations += 1
            #expect(app.name == "the running app")
            #expect(host.id == "pc-id")
        }
        #expect(confirmations == 1)
    }

    @MainActor @Test func quitConfirmationUsesOnlyFreshMatchingPCOrOwnLiveApp() {
        let model = AppModel(defaults: settings.defaults)
        let host = pc()
        var targets: [String] = []
        for (id, date, expected) in [(host.id, Date(), "Hades II"),
                                     ("other", Date(), "the running app"),
                                     (host.id, Date.distantPast, "the running app")] {
            model.hostLiveStatus = .init(hostID: id, state: .streamingApp(name: app.name), capturedAt: date)
            model.confirmURLQuit(on: host) { target, pc in
                targets.append(target.name)
                #expect(target.name == expected && pc.id == host.id)
            }
        }
        model.isStreaming = true
        model.lastLaunchAttempt = (app, host)
        model.confirmURLQuit(on: host) { target, _ in #expect(target == app) }
        #expect(targets == ["Hades II", "the running app", "the running app"])
    }

    @MainActor @Test func nonJSONStatusReportsLiveIdleMalformedAndRejectedReplies() async throws {
        let command = try GlimmerCLI.parse(["status"])
        for (json, expected, code) in [("{\"live\":true}", "Streaming.\n", Int32(0)),
                                        ("{\"live\":false}", "Not streaming.\n", Int32(0)),
                                        ("invalid", "", Int32(1))] {
            let terminal = CapturedTerminal()
            let result = await CLITerminal.$write.withValue(terminal.write) {
                await GlimmerCLI.status(command, appIsRunning: { true }, send: { _ in
                    [CommandChannel.Key.event: CommandChannel.Event.accepted, CommandChannel.Key.detail: json]
                })
            }
            #expect(result == code && terminal.out == expected)
            #expect(terminal.err == (code == 0 ? "" : "Couldn't read the stream status. Try again.\n"))
        }
        let terminal = CapturedTerminal()
        let result = await CLITerminal.$write.withValue(terminal.write) {
            await GlimmerCLI.status(command, appIsRunning: { true }, send: { _ in
                [CommandChannel.Key.event: CommandChannel.Event.accepted]
            })
        }
        #expect(result == 1 && terminal.out.isEmpty)
        #expect(terminal.err == "Glimmer didn't answer. Try again.\n")
        let model = AppModel(defaults: settings.defaults)
        let idle = try object(await model.commandStatusJSON())
        #expect(idle["live"] as? Bool == false && idle["pc"] is NSNull)
    }

    @MainActor @Test func appStatusReadsTheCurrentSessionAndRejectsSnapshotsAfterTeardown() async throws {
        let model = AppModel(defaults: settings.defaults)
        let session = StreamSession(hostDisposition: .cancelOwnedHostSession, backend: InputRecordingBackend())
        model.nativeSession = session
        model.lastLaunchAttempt = (app, pc())
        model.isStreaming = true
        model.streamPhase = .streaming
        model.nativeHDRActive = true
        var snapshot = StreamStatsSnapshot()
        snapshot.configuredFps = 120
        snapshot.videoCodec = "HEVC"
        snapshot.negotiatedBitrateMbps = 50
        let live = try object(await model.commandStatusJSON { current in
            #expect(current === session)
            return (snapshot, false, (2560, 1440))
        })
        #expect(live["live"] as? Bool == true && live["hdr"] as? Bool == true)
        #expect(live["resolution"] as? [String: Int] == ["width": 2560, "height": 1440])
        #expect(live["fps"] as? Double == 120 && live["bitrateMbps"] as? Double == 50)
        model.isReconnecting = true
        let reconnecting = try object(await model.commandStatusJSON { _ in nil })
        #expect(reconnecting["live"] as? Bool == false && reconnecting["hdr"] is NSNull)
        #expect((reconnecting["app"] as? [String: Any])?["name"] as? String == app.name)
        let retired = try object(await model.commandStatusJSON { _ in
            model.nativeSession = nil
            return (snapshot, false, (2560, 1440))
        })
        #expect(retired["live"] as? Bool == false && retired["pc"] is NSNull)
    }

    @Test func jsonFlagsAndStatusArityAreStrict() throws {
        #expect(try GlimmerCLI.parse(["list", "--json"]).flags == ["--json"])
        #expect(try GlimmerCLI.parse(["list", "Den PC", "--json"]).arguments == ["Den PC"])
        #expect(try GlimmerCLI.parse(["status", "--json"]).verb == .status)
        #expect(throws: GlimmerCLI.UsageError.self) { try GlimmerCLI.parse(["status", "Den PC"]) }
        #expect(throws: GlimmerCLI.UsageError.self) { try GlimmerCLI.parse(["list", "--csv", "--json"]) }
    }

    @Test func pcJSONUsesOnlyTheManualAddressAndStableStates() throws {
        for (state, expected) in [(HostLiveStatus.State.idle, "ready"), (.asleep, "asleep"),
                                  (.certMismatch, "reachable"), (.unknown, "unknown"),
                                  (.streamingApp(name: app.name), "reachable"),
                                  (.streamingUnknownApp(id: 99), "reachable")] {
            let live = HostLiveStatus(hostID: "pc-id", state: state, capturedAt: Date())
            let row = CommandJSON.pc(pc(), live: live, paired: true, defaultID: "pc-id")
            let json = try object(CommandJSON.encode(["pcs": [row]]))
            #expect(json["version"] as? Int == 1)
            #expect(row["address"] as? String == "Den.local:47989")
            #expect(row["state"] as? String == expected)
            #expect(row["paired"] as? Bool == (state != .certMismatch))
            #expect(row["default"] as? Bool == true)
            if case .streamingApp = state {
                #expect((row["runningApp"] as? [String: Any])?["id"] as? Int == 7)
            }
            if case .streamingUnknownApp = state {
                let running = try #require(row["runningApp"] as? [String: Any])
                #expect(running["id"] as? Int == 99 && running["name"] is NSNull)
            }
        }
        let row = CommandJSON.pc(pc(manual: nil), live: nil, paired: false, defaultID: nil)
        #expect(row["address"] is NSNull)
        #expect(row["runningApp"] is NSNull)
        #expect(row["paired"] as? Bool == false && row["default"] as? Bool == false)
        #expect(try CommandJSON.encode(["pcs": []]) == #"{"pcs":[],"version":1}"#)
    }

    @Test func pcJSONPreservesTheReportedIDWhenAppNamesMatch() {
        let host = Host(id: "pc-id", name: "Den", customName: nil, localAddress: nil, manualAddress: nil,
                        apps: [app, LibraryApp(id: 8, name: app.name, hdr: false, hidden: false)],
                        lastConnected: nil, serverCertPEM: nil, appVersion: nil, macAddress: nil)
        let live = HostLiveStatus(hostID: host.id, state: .streamingApp(name: app.name),
                                  capturedAt: Date(), runningAppID: 8)
        let row = CommandJSON.pc(host, live: live, paired: true, defaultID: nil)
        #expect((row["runningApp"] as? [String: Any])?["id"] as? Int == 8)
    }

    @Test func appJSONIncludesHiddenAppsAndEscapesNames() throws {
        let apps = [HostApp(id: 7, name: "Game, \"two\"\n雪", hdrCapable: true, hidden: true)]
        let json = try object(CommandJSON.apps(apps, runningID: 7))
        #expect(json["version"] as? Int == 1)
        let rows = try #require(json["apps"] as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows[0]["name"] as? String == apps[0].name)
        #expect(rows[0]["id"] as? Int == 7)
        #expect(rows[0]["hdr"] as? Bool == true)
        #expect(rows[0]["hidden"] as? Bool == true)
        #expect(rows[0]["running"] as? Bool == true)
        #expect(try CommandJSON.apps([], runningID: 0) == #"{"apps":[],"version":1}"#)
    }

    @Test func statusJSONHasTypedValuesAndExplicitUnknowns() throws {
        let idle = try object(CommandJSON.status(live: false))
        #expect(idle["version"] as? Int == 1 && idle["live"] as? Bool == false)
        for key in ["pc", "app", "resolution", "fps", "hdr", "codec", "bitrateMbps"] {
            #expect(idle[key] is NSNull)
        }
        var snapshot = StreamStatsSnapshot()
        snapshot.configuredFps = 120
        snapshot.videoCodec = "HEVC"
        snapshot.negotiatedBitrateMbps = 82.5
        let live = try object(CommandJSON.status(live: true, pc: pc(), app: app,
                                                resolution: (2560, 1440), hdr: true, snapshot: snapshot))
        #expect(live["live"] as? Bool == true)
        #expect((live["pc"] as? [String: String])?["id"] == "pc-id")
        #expect((live["app"] as? [String: Any])?["id"] as? Int == 7)
        #expect(live["resolution"] as? [String: Int] == ["width": 2560, "height": 1440])
        #expect(live["fps"] as? Double == 120 && live["bitrateMbps"] as? Double == 82.5)
        #expect(live["hdr"] as? Bool == true && live["codec"] as? String == "HEVC")
        snapshot.configuredFps = .nan
        snapshot.negotiatedBitrateMbps = .infinity
        let unknown = try object(CommandJSON.status(live: true, resolution: (0, 0), snapshot: snapshot))
        #expect(unknown["fps"] is NSNull && unknown["bitrateMbps"] is NSNull)
        #expect(unknown["resolution"] is NSNull)
    }

    @MainActor @Test func statusAsksTheAppWithoutRequiringAPCOrOpeningIt() async throws {
        let terminal = CapturedTerminal()
        let command = try GlimmerCLI.parse(["status", "--json"])
        let json = try CommandJSON.status(live: false)
        let status = await CLITerminal.$write.withValue(terminal.write) {
            await GlimmerCLI.status(command, appIsRunning: { true }, send: { request in
                var handled = Set<String>()
                var info = request
                info[CommandChannel.Key.id] = "status-test"
                #expect(CommandChannel.decide(info, handled: &handled, hosts: [], streamingFrom: nil) == .status)
                #expect(handled.isEmpty)
                return [CommandChannel.Key.event: CommandChannel.Event.accepted, CommandChannel.Key.detail: json]
            })
        }
        #expect(status == 0 && terminal.out == json + "\n" && terminal.err.isEmpty)
        let absent = await CLITerminal.$write.withValue(terminal.write) {
            await GlimmerCLI.status(command, appIsRunning: { false }, send: { _ in
                Issue.record("An absent app must not receive a status request")
                return nil
            })
        }
        #expect(absent == 0)
        let failed = await CLITerminal.$write.withValue(terminal.write) {
            await GlimmerCLI.status(command, appIsRunning: { true }, send: { _ in nil })
        }
        #expect(failed == 1)
    }
}
