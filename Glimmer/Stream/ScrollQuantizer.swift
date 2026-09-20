//
//  ScrollQuantizer.swift
//
//  Windows reads the wheel in notches of 120 and many games treat less as
//  nothing; precise devices arrive in 40-100 unit slices. Sum, send notches.
//

import Foundation

struct ScrollQuantizer {
    static let notch = 120

    private var vertical = 0
    private var horizontal = 0

    /// Units to send now: whole notches of the running total, same sign.
    mutating func consumeVertical(_ units: Int) -> Int {
        Self.consume(units, residual: &vertical)
    }

    mutating func consumeHorizontal(_ units: Int) -> Int {
        Self.consume(units, residual: &horizontal)
    }

    /// A finished gesture never banks into the next one.
    mutating func reset() {
        vertical = 0
        horizontal = 0
    }

    private static func consume(_ units: Int, residual: inout Int) -> Int {
        // A direction change drops what the other direction had banked.
        if units != 0, residual != 0, (units < 0) != (residual < 0) { residual = 0 }
        residual += units
        let notches = residual / notch
        residual -= notches * notch
        return notches * notch
    }
}
