// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Testing
import UIKit
@testable import Glimmer

@MainActor
struct LauncherGalleryTests {
    @Test func gridsFillAvailableColumnsAndAdaptToLargerText() {
        #expect(LauncherGrid.columns(width: 800, minimum: 220, count: 2) == 2)
        #expect(LauncherGrid.columns(width: 800, minimum: 220, count: 7) == 3)
        #expect(LauncherGrid.columns(width: 550, minimum: 350, count: 2) == 1)
        #expect(LauncherGrid.columns(width: 0, minimum: 220, count: 0) == 1)
        #expect(LauncherGrid.coverHeight(availableHeight: 320) == 160)
        #expect(LauncherGrid.coverHeight(availableHeight: 800) == 240)
    }

    @Test func backgroundDeadlineAndOldExpirationCannotStopReturnedStream() {
        var now: TimeInterval = 0
        var expirations: [@MainActor @Sendable () -> Void] = []
        var ended = 0
        var stopped = 0
        let grace = StreamBackgroundGrace(calls: .init(begin: { expire in
            expirations.append(expire)
            return .init(rawValue: expirations.count)
        }, end: { _ in ended += 1 }, now: { now }))
        grace.prepare { stopped += 1 }
        grace.leave { stopped += 1 }
        now = 5
        #expect(grace.returned())
        grace.prepare { stopped += 1 }
        expirations[0]()
        #expect(stopped == 0 && ended == 1)
        grace.leave { stopped += 1 }
        now = 21
        #expect(!grace.returned())
        #expect(ended == 2)
        grace.finish()
        #expect(ended == 2)
    }

    @Test func systemExpirationEndsLeaseOnce() {
        var expiration: (@MainActor @Sendable () -> Void)?
        var ended = 0
        var stopped = 0
        let grace = StreamBackgroundGrace(calls: .init(begin: { expiration = $0; return .init(rawValue: 1) },
                                                       end: { _ in ended += 1 }))
        grace.prepare { stopped += 1 }
        grace.leave { stopped += 1 }
        expiration?()
        expiration?()
        #expect(stopped == 1 && ended == 1)
    }
}
