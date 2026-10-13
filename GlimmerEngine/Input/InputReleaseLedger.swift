// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

@usableFromInline package struct InputReleaseLedger {

    @inlinable package init(
        held: Set<Release> = [],
        pending: [Release] = [],
        keyReleaseModifiers: [VKScanCode: Int8] = [:],
        controllerRemovals: Set<UInt8> = [],
        flushCount: Int = 0,
        reconciledCount: Int = 0,
        lastNoticeTime: TimeInterval = 0
    ) {
        self.held = held
        self.pending = pending
        self.keyReleaseModifiers = keyReleaseModifiers
        self.controllerRemovals = controllerRemovals
        self.flushCount = flushCount
        self.reconciledCount = reconciledCount
        self.lastNoticeTime = lastNoticeTime
    }

    @usableFromInline package enum Release: Hashable {
        case key(VKScanCode)
        case mouse(Int32)
        case controller(UInt8)
    }

    @usableFromInline package var held: Set<Release> = []
    @usableFromInline package var pending: [Release] = []
    @usableFromInline package var keyReleaseModifiers: [VKScanCode: Int8] = [:]
    @usableFromInline package var controllerRemovals: Set<UInt8> = []
    @usableFromInline package var flushCount = 0
    @usableFromInline package var reconciledCount = 0
    @usableFromInline package var lastNoticeTime: TimeInterval = 0
    // Accepted releases may still be unacknowledged when a connection closes.
    @usableFromInline internal var connectionInputs: [Release] = []

    @inlinable package mutating func hold(_ input: Release) {
        held.insert(input)
        remember(input)
    }

    @inlinable package mutating func remember(_ input: Release) {
        if !connectionInputs.contains(input) { connectionInputs.append(input) }
    }

    @inlinable package mutating func release(_ input: Release, modifiers: Int8 = 0) {
        guard held.contains(input), !pending.contains(input) else { return }
        pending.append(input)
        if case .key(let key) = input { keyReleaseModifiers[key] = modifiers }
    }

    @inlinable package mutating func releaseAll(connectionLost: Bool = false) {
        if connectionLost {
            held.formUnion(connectionInputs)
            keyReleaseModifiers.removeAll()
        }
        for input in connectionInputs { release(input) }
        if connectionLost {
            // A replacement announces pads before its live-state resync, never an old neutral frame.
            held = held.filter { if case .controller = $0 { return false }; return true }
            pending.removeAll { if case .controller = $0 { return true }; return false }
            controllerRemovals.removeAll()
            connectionInputs.removeAll()
        }
    }

    @inlinable package mutating func releaseKeyboardAndMouse(preservingMouse: Set<Int32> = []) {
        for input in connectionInputs {
            if case .controller = input { continue }
            if case .mouse(let button) = input, preservingMouse.contains(button) { continue }
            release(input)
        }
    }

    @inlinable package mutating func accepted(_ input: Release) {
        held.remove(input)
        if case .key(let key) = input { keyReleaseModifiers[key] = nil }
        if case .controller(let slot) = input { controllerRemovals.remove(slot) }
        pending.removeAll { $0 == input }
    }
}
