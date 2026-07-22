//
//  LunaGateTests.swift
//
//  Pins the pure halves of the Luna power gate (LunaPower.swift): MAC
//  normalization (the match key - zeroed/malformed MACs must fail CLOSED)
//  and the calver minimum check (2026.7.0 lacks `devices --json` and must
//  fail the gate; 2026.7.1+ passes).
//

import Testing
@testable import Glimmer

struct LunaGateTests {

    @Test func macNormalizationCanonicalizes() {
        #expect(LunaPower.normalizeMac("AA:BB:CC:DD:EE:FF") == "aa:bb:cc:dd:ee:ff")
        #expect(LunaPower.normalizeMac("aa-bb-cc-dd-ee-ff") == "aa:bb:cc:dd:ee:ff")
        // Single-digit octets pad to two so both sides compare equal.
        #expect(LunaPower.normalizeMac("A:B:C:D:E:F") == "0a:0b:0c:0d:0e:0f")
        #expect(LunaPower.normalizeMac("0A:0B:0C:0D:0E:0F") == "0a:0b:0c:0d:0e:0f")
    }

    @Test func macNormalizationFailsClosed() {
        // The Sunshine zeroed-MAC quirk: no match, no controls.
        #expect(LunaPower.normalizeMac("00:00:00:00:00:00") == nil)
        #expect(LunaPower.normalizeMac("0:0:0:0:0:0") == nil)
        #expect(LunaPower.normalizeMac(nil) == nil)
        #expect(LunaPower.normalizeMac("") == nil)
        #expect(LunaPower.normalizeMac("not-a-mac") == nil)
        #expect(LunaPower.normalizeMac("aa:bb:cc:dd:ee") == nil)        // 5 octets
        #expect(LunaPower.normalizeMac("aa:bb:cc:dd:ee:ff:11") == nil)  // 7 octets
        #expect(LunaPower.normalizeMac("gg:bb:cc:dd:ee:ff") == nil)     // non-hex
    }

    @Test func calverMinimumGates() {
        let minimum = [2026, 7, 1]
        #expect(LunaPower.calverAtLeast(LunaPower.calver("2026.7.1"), minimum))
        #expect(LunaPower.calverAtLeast(LunaPower.calver("2026.7.2"), minimum))
        #expect(LunaPower.calverAtLeast(LunaPower.calver("2026.8.0"), minimum))
        #expect(LunaPower.calverAtLeast(LunaPower.calver("2027.1.0"), minimum))
        // 2026.7.0 (no devices --json) and garbage both fail.
        #expect(!LunaPower.calverAtLeast(LunaPower.calver("2026.7.0"), minimum))
        #expect(!LunaPower.calverAtLeast(LunaPower.calver("2026.6.9"), minimum))
        #expect(!LunaPower.calverAtLeast(LunaPower.calver("luna 1.0"), minimum))
        #expect(!LunaPower.calverAtLeast(LunaPower.calver(""), minimum))
    }
}
