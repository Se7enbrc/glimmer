// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

#if TOUCH_INPUT_EVIDENCE
import Darwin
import GlimmerEngine
import OSLog
import Testing
import UIKit
@testable import Glimmer

@Suite(.serialized)
@MainActor
struct TouchIdleEvidenceTests {
    @Test(arguments: [false, true], [UIUserInterfaceStyle.light, .dark])
    func visibleAndHeldControlsDoNotScheduleRecurringWork(movingVideo: Bool, style: UIUserInterfaceStyle) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = style
        let owner = TouchIdleHost()
        window.rootViewController = owner
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        owner.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
        let deadline = ContinuousClock.now + .seconds(5)
        while !scene.effectiveGeometry.interfaceOrientation.isLandscape, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(scene.effectiveGeometry.interfaceOrientation.isLandscape)
        owner.view.layoutIfNeeded()
        let video = TouchEvidenceVideo()
        video.surface.frame = owner.view.bounds
        owner.view.addSubview(video.surface)
        if movingVideo { video.start() }
        defer { video.stop() }
        let connection = StreamConnection(video: ConnectionTestVideoSink()) { _, _ in }
        var submissions = 0
        let capture = TouchGamepadCapture(calls: .init(register: connection.input.registerController,
            unregister: connection.input.unregisterController, submit: { _, _, _ in submissions += 1 }))
        #expect(capture.attach())
        capture.setEnabled(true)
        let overlay = MeasuredTouchView(frame: owner.view.bounds)
        owner.view.addSubview(overlay)
        overlay.configure(capture: capture, layout: TouchLayout(),
                          area: owner.view.bounds.inset(by: owner.view.safeAreaInsets))
        let axis = try #require(overlay.controls[.leftStick] as? TouchAxisControl)
        let signposter = OSSignposter(subsystem: "io.ugfugl.Glimmer", category: "Touch evidence")
        var lines = ["state,seconds,root_layouts,root_draws,submissions,user_cpu_s,system_cpu_s,video_frames"]
        for state in ["hidden", "minimum", "maximum", "held", "moving"] {
            var layout = TouchLayout()
            layout.opacity = state == "minimum" ? 0.1 : 0.6
            overlay.configure(capture: capture, layout: layout,
                              area: owner.view.bounds.inset(by: owner.view.safeAreaInsets))
            overlay.isHidden = state == "hidden"
            let contact = state == "held" || state == "moving" ? capture.begin(.leftStick) : nil
            if let contact {
                capture.update(contact, value: CGPoint(x: 0.5, y: 0), at: ProcessInfo.processInfo.systemUptime)
            }
            axis.display(contact == nil ? .zero : CGPoint(x: 0.5, y: 0))
            overlay.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            let startLayouts = overlay.layouts
            let startDraws = overlay.draws
            let startSubmissions = submissions
            let startVideo = video.submitted
            let start = ProcessInfo.processInfo.systemUptime
            let cpu = usage()
            let interval = signposter.beginInterval("Touch idle", "\(state), video: \(movingVideo)")
            if state == "moving", let contact {
                for index in 0..<480 {
                    capture.update(contact, value: CGPoint(x: index.isMultiple(of: 2) ? 0.5 : -0.5, y: 0),
                                   at: ProcessInfo.processInfo.systemUptime)
                    axis.display(CGPoint(x: index.isMultiple(of: 2) ? 0.5 : -0.5, y: 0))
                    try await Task.sleep(for: .milliseconds(16))
                }
            } else { try await Task.sleep(for: .seconds(8)) }
            let endCPU = usage()
            signposter.endInterval("Touch idle", interval)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let layouts = overlay.layouts - startLayouts
            let draws = overlay.draws - startDraws
            let sent = submissions - startSubmissions
            if state != "moving" { #expect(layouts == 0 && draws == 0 && sent == 0) }
            lines.append("\(state),\(elapsed),\(layouts),\(draws),\(sent),\(endCPU.0 - cpu.0),\(endCPU.1 - cpu.1),"
                + "\(video.submitted - startVideo)")
            if let contact { capture.end(contact, at: ProcessInfo.processInfo.systemUptime) }
        }
        let name = "touch-idle-\(style == .dark ? "dark" : "light")-\(movingVideo ? "video" : "static").csv"
        Attachment.record(Array((lines.joined(separator: "\n") + "\n").utf8), named: name)
        capture.detach()
        await connection.stop()
    }

    private func usage() -> (Double, Double) {
        var value = rusage()
        _ = getrusage(RUSAGE_SELF, &value)
        return (Double(value.ru_utime.tv_sec) + Double(value.ru_utime.tv_usec) / 1e6,
                Double(value.ru_stime.tv_sec) + Double(value.ru_stime.tv_usec) / 1e6)
    }
}

@MainActor
private final class MeasuredTouchView: TouchGamepadView {
    var layouts = 0
    var draws = 0
    override func layoutSubviews() { super.layoutSubviews(); layouts += 1 }
    override func draw(_ rect: CGRect) { super.draw(rect); draws += 1 }
}

@MainActor
private final class TouchIdleHost: UIViewController {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
}
#endif
