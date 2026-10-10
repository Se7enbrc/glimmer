// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  AudioCushionMemoryTests.swift
//
//  The cushion's per-host memory (age lerp, link-class clamp, weld repair), the loss floor an
//  under-run teaches and the quiet-window decay, all on known inputs with no real clock.
//

import Foundation
import Testing
@testable import Glimmer

struct AudioCushionMemoryTests {

    private func store(link: String, target: Double, floor: Double = 0, savedOffset: Double = 100) -> String {
        let key = AudioDecoder.cushionMemoryKey(host: "test-\(UUID().uuidString)", link: link)
        let record: [String: Any] = ["target_ms": target, "floor_ms": floor,
                                     "saved_at": Date().timeIntervalSinceReferenceDate + savedOffset]
        UserDefaults.standard.set(record, forKey: key)
        return key
    }

    private func read(_ key: String) -> (targetMs: Double, floorMs: Double)? {
        defer { UserDefaults.standard.removeObject(forKey: key) }
        return AudioDecoder.readCushionMemory(key: key)
    }

    // MARK: - Caps and keys

    @Test func linkClassPicksItsCushionCap() {
        #expect(AudioDecoder.cushionMaxMs(forLink: "wired") == 150)
        #expect(AudioDecoder.cushionMaxMs(forLink: "wifi") == 200)
        #expect(AudioDecoder.cushionMaxMs(forLink: "tunnel") == 300)
        #expect(AudioDecoder.cushionMaxMs(forLink: "unknown") == 300)
        #expect(AudioDecoder.cushionMemoryKey(host: "den", link: "wifi") == "audioCushionMemory.den|wifi")
    }

    // MARK: - Reading a record

    @Test func freshRecordReadsBackUnchanged() throws {
        let record = try #require(read(store(link: "wired", target: 90, floor: 40)))
        #expect(record.targetMs == 90)
        #expect(record.floorMs == 40)
    }

    @Test func persistedRecordRoundTripsThroughTheStore() throws {
        let key = AudioDecoder.cushionMemoryKey(host: "test-\(UUID().uuidString)", link: "wifi")
        defer { UserDefaults.standard.removeObject(forKey: key) }
        AudioDecoder.persistCushionMemory(key: key, targetMs: 100, floorMs: 50)
        let record = try #require(AudioDecoder.readCushionMemory(key: key))
        #expect(abs(record.targetMs - 100) < 0.01)
        #expect(abs(record.floorMs - 50) < 0.01)
    }

    @Test func oneHalfLifeOldRecordLerpsHalfwayToBase() throws {
        let age = -AudioDecoder.cushionMemoryAgeHalfLifeSeconds
        let record = try #require(read(store(link: "wifi", target: 90, floor: 40, savedOffset: age)))
        #expect(abs(record.targetMs - 60) < 0.05)
        #expect(abs(record.floorMs - 20) < 0.05)
    }

    @Test func targetIsClampedToItsOwnLinkClassAndToTheBase() throws {
        #expect(try #require(read(store(link: "wired", target: 400))).targetMs == 150)
        #expect(try #require(read(store(link: "wifi", target: 400))).targetMs == 200)
        #expect(try #require(read(store(link: "tunnel", target: 400))).targetMs == 300)
        #expect(try #require(read(store(link: "unknown", target: 400))).targetMs == 300)
        #expect(try #require(read(store(link: "wifi", target: 5))).targetMs == AudioDecoder.playoutCushionBaseMs)
    }

    @Test func weldedOrInvertedFloorsDropToBase() throws {
        let welded = try #require(read(store(link: "wifi", target: 190, floor: 180)))
        #expect(welded.floorMs == AudioDecoder.playoutCushionBaseMs)
        let inverted = try #require(read(store(link: "wired", target: 60, floor: 60)))
        #expect(inverted.floorMs == AudioDecoder.playoutCushionBaseMs)
        let healthy = try #require(read(store(link: "wifi", target: 120, floor: 100)))
        #expect(healthy.floorMs == 100)
    }

    @Test func missingOrNonFiniteRecordsReadAsNothing() {
        #expect(read("audioCushionMemory.absent-\(UUID().uuidString)|wifi") == nil)
        #expect(read(store(link: "wifi", target: .infinity)) == nil)
        #expect(read(store(link: "wifi", target: .nan)) == nil)
    }

    // MARK: - Learning the floor

    @Test func underrunsPullTheFloorTowardTheFailedTargetAndCapIt() {
        let decoder = AudioDecoder()
        decoder.effectiveCushionMaxMs = 200
        decoder.cushionSeedKey = "audioCushionMemory.h|wifi"
        let first = decoder.cushionNoteUnderrunLocked(now: 1_000, failedTargetMs: 80)
        #expect(decoder.learnedFloorMs == 80)
        #expect(first.key == "audioCushionMemory.h|wifi")
        #expect(first.floorMs == 80)
        #expect(first.targetMs == AudioDecoder.playoutCushionBaseMs)
        _ = decoder.cushionNoteUnderrunLocked(now: 2_000, failedTargetMs: 100)
        #expect(decoder.learnedFloorMs == 90)
        _ = decoder.cushionNoteUnderrunLocked(now: 3_000, failedTargetMs: 900)
        #expect(decoder.learnedFloorMs == 200)
        #expect(decoder.cushionHadUnderrun)
    }

    @Test func startupGateStopsBootRampDrainsFromTeachingTheFloor() {
        let decoder = AudioDecoder()
        decoder.floorLearnGateUntilNanos = 10_000
        _ = decoder.cushionNoteUnderrunLocked(now: 5_000, failedTargetMs: 120)
        #expect(decoder.learnedFloorMs == 0)
        #expect(decoder.lastUnderrunNanos == 0)
        #expect(decoder.floorQuietSinceNanos == 5_000)
        _ = decoder.cushionNoteUnderrunLocked(now: 10_000, failedTargetMs: 120)
        #expect(decoder.learnedFloorMs == 120)
    }

    @Test func recentFailureHoldsOneStepAboveTheFailedTargetUntilItExpires() {
        let decoder = AudioDecoder()
        #expect(decoder.recentFailureFloorMs(now: 500) == 0)
        _ = decoder.cushionNoteUnderrunLocked(now: 1_000, failedTargetMs: 80)
        let hold = AudioDecoder.recentFailureHoldNanos
        #expect(decoder.recentFailureFloorMs(now: 1_000 + hold - 1) == 80 + AudioDecoder.playoutCushionStepMs)
        #expect(decoder.recentFailureFloorMs(now: 1_000 + hold) == 0)
    }

    // MARK: - Quiet-window decay

    private func quietDecoder(target: Double, minFill: Double = 100) -> AudioDecoder {
        let decoder = AudioDecoder()
        decoder.playoutTargetMs = target
        decoder.quietWindowMinFillMs = minFill
        return decoder
    }

    @Test func cleanQuietWindowStepsTheTargetDownOneStep() throws {
        let decoder = quietDecoder(target: 80)
        let now = AudioDecoder.playoutDecayQuietNanos
        let write = try #require(decoder.cushionQuietAdjustLocked(now: now))
        #expect(decoder.playoutTargetMs == 80 - AudioDecoder.playoutCushionStepMs)
        #expect(write.targetMs == 70)
        #expect(decoder.quietSinceNanos == now)
        #expect(decoder.cushionQuietAdjustLocked(now: now + 1) == nil)
    }

    @Test func nearMissWindowKeepsDepthAndRestartsTheWindow() {
        let decoder = quietDecoder(target: 80, minFill: 5)
        let now = AudioDecoder.playoutDecayQuietNanos
        #expect(decoder.cushionQuietAdjustLocked(now: now) == nil)
        #expect(decoder.playoutTargetMs == 80)
        #expect(decoder.quietSinceNanos == now)
        #expect(decoder.quietWindowMinFillMs == .infinity)
    }

    @Test func recentFailureBlocksAStepBackIntoTheFailedLevel() {
        let decoder = quietDecoder(target: 90)
        _ = decoder.cushionNoteUnderrunLocked(now: 1, failedTargetMs: 80)
        decoder.quietWindowMinFillMs = 100
        decoder.quietSinceNanos = 0
        #expect(decoder.cushionQuietAdjustLocked(now: AudioDecoder.playoutDecayQuietNanos) == nil)
        #expect(decoder.playoutTargetMs == 90)
    }

    @Test func floorDecaysOneStepOnItsOwnSlowClock() throws {
        let decoder = quietDecoder(target: 80)
        decoder.learnedFloorMs = 50
        let now = AudioDecoder.cushionFloorDecayQuietNanos
        decoder.quietSinceNanos = now
        let write = try #require(decoder.cushionQuietAdjustLocked(now: now))
        #expect(decoder.learnedFloorMs == 40)
        #expect(write.floorMs == 40)
        #expect(decoder.playoutTargetMs == 80)
        #expect(decoder.floorQuietSinceNanos == now)
    }

    @Test func floorBlocksTheStepUnlessTheResamplerCarriesTheSkew() throws {
        let decoder = quietDecoder(target: 80)
        decoder.learnedFloorMs = 70
        decoder.floorQuietSinceNanos = AudioDecoder.playoutDecayQuietNanos
        let now = AudioDecoder.playoutDecayQuietNanos
        #expect(decoder.cushionQuietAdjustLocked(now: now) == nil)
        #expect(decoder.playoutTargetMs == 80)
        decoder.resamplerSkewConverged = true
        decoder.cushionLinkClass = "wired"
        _ = try #require(decoder.cushionQuietAdjustLocked(now: now))
        #expect(decoder.playoutTargetMs == 70)
        #expect(decoder.learnedFloorMs == 60)
    }
}
