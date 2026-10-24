// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import SwiftUI

struct ControllerBodyShape: Shape {
    let family: ControllerDiagramFamily

    func path(in rect: CGRect) -> Path {
        let outline: Path
        switch family {
        case .dualSense, .dualSenseEdge: outline = Self.dualSense
        case .dualShock: outline = Self.dualShock
        case .xbox, .xboxElite: outline = Self.xbox
        case .backbone, .backbonePlayStation: outline = Self.backbone
        case .generic: outline = Self.generic
        }
        return outline.applying(.init(scaleX: rect.width / 480, y: rect.height / 330))
            .applying(.init(translationX: rect.minX, y: rect.minY))
    }

    // Original curves use a common front projection; dimensions set the overall proportions, not traced vertices.
    private static var dualSense: Path {
        Path { path in
            path.move(to: CGPoint(x: 240, y: 49))
            path.addCurve(to: CGPoint(x: 363, y: 53), control1: CGPoint(x: 292, y: 47), control2: CGPoint(x: 329, y: 48))
            path.addCurve(to: CGPoint(x: 413, y: 79), control1: CGPoint(x: 387, y: 56), control2: CGPoint(x: 405, y: 61))
            path.addCurve(to: CGPoint(x: 457, y: 244), control1: CGPoint(x: 433, y: 123), control2: CGPoint(x: 454, y: 190))
            path.addCurve(to: CGPoint(x: 431, y: 310), control1: CGPoint(x: 460, y: 278), control2: CGPoint(x: 453, y: 307))
            path.addCurve(to: CGPoint(x: 397, y: 286), control1: CGPoint(x: 412, y: 313), control2: CGPoint(x: 405, y: 306))
            path.addCurve(to: CGPoint(x: 350, y: 219), control1: CGPoint(x: 384, y: 252), control2: CGPoint(x: 372, y: 221))
            path.addCurve(to: CGPoint(x: 240, y: 219), control1: CGPoint(x: 316, y: 217), control2: CGPoint(x: 270, y: 219))
            path.addCurve(to: CGPoint(x: 130, y: 219), control1: CGPoint(x: 210, y: 219), control2: CGPoint(x: 164, y: 217))
            path.addCurve(to: CGPoint(x: 83, y: 286), control1: CGPoint(x: 108, y: 221), control2: CGPoint(x: 96, y: 252))
            path.addCurve(to: CGPoint(x: 49, y: 310), control1: CGPoint(x: 75, y: 306), control2: CGPoint(x: 68, y: 313))
            path.addCurve(to: CGPoint(x: 23, y: 244), control1: CGPoint(x: 27, y: 307), control2: CGPoint(x: 20, y: 278))
            path.addCurve(to: CGPoint(x: 67, y: 79), control1: CGPoint(x: 26, y: 190), control2: CGPoint(x: 47, y: 123))
            path.addCurve(to: CGPoint(x: 117, y: 53), control1: CGPoint(x: 75, y: 61), control2: CGPoint(x: 93, y: 56))
            path.addCurve(to: CGPoint(x: 240, y: 49), control1: CGPoint(x: 151, y: 48), control2: CGPoint(x: 188, y: 47))
            path.closeSubpath()
        }
    }

    private static var dualShock: Path {
        Path { path in
            path.move(to: CGPoint(x: 240, y: 63))
            path.addCurve(to: CGPoint(x: 322, y: 68), control1: CGPoint(x: 276, y: 63), control2: CGPoint(x: 299, y: 64))
            path.addCurve(to: CGPoint(x: 403, y: 69), control1: CGPoint(x: 346, y: 51), control2: CGPoint(x: 381, y: 52))
            path.addCurve(to: CGPoint(x: 434, y: 141), control1: CGPoint(x: 424, y: 85), control2: CGPoint(x: 428, y: 108))
            path.addCurve(to: CGPoint(x: 450, y: 270), control1: CGPoint(x: 442, y: 179), control2: CGPoint(x: 455, y: 231))
            path.addCurve(to: CGPoint(x: 417, y: 306), control1: CGPoint(x: 448, y: 293), control2: CGPoint(x: 438, y: 310))
            path.addCurve(to: CGPoint(x: 362, y: 235), control1: CGPoint(x: 392, y: 302), control2: CGPoint(x: 378, y: 266))
            path.addCurve(to: CGPoint(x: 329, y: 238), control1: CGPoint(x: 350, y: 217), control2: CGPoint(x: 344, y: 228))
            path.addCurve(to: CGPoint(x: 263, y: 225), control1: CGPoint(x: 296, y: 255), control2: CGPoint(x: 282, y: 225))
            path.addCurve(to: CGPoint(x: 240, y: 225), control1: CGPoint(x: 254, y: 225), control2: CGPoint(x: 248, y: 225))
            path.addCurve(to: CGPoint(x: 217, y: 225), control1: CGPoint(x: 232, y: 225), control2: CGPoint(x: 226, y: 225))
            path.addCurve(to: CGPoint(x: 151, y: 238), control1: CGPoint(x: 198, y: 225), control2: CGPoint(x: 184, y: 255))
            path.addCurve(to: CGPoint(x: 118, y: 235), control1: CGPoint(x: 136, y: 228), control2: CGPoint(x: 130, y: 217))
            path.addCurve(to: CGPoint(x: 63, y: 306), control1: CGPoint(x: 102, y: 266), control2: CGPoint(x: 88, y: 302))
            path.addCurve(to: CGPoint(x: 30, y: 270), control1: CGPoint(x: 42, y: 310), control2: CGPoint(x: 32, y: 293))
            path.addCurve(to: CGPoint(x: 46, y: 141), control1: CGPoint(x: 25, y: 231), control2: CGPoint(x: 38, y: 179))
            path.addCurve(to: CGPoint(x: 77, y: 69), control1: CGPoint(x: 52, y: 108), control2: CGPoint(x: 56, y: 85))
            path.addCurve(to: CGPoint(x: 158, y: 68), control1: CGPoint(x: 99, y: 52), control2: CGPoint(x: 134, y: 51))
            path.addCurve(to: CGPoint(x: 240, y: 63), control1: CGPoint(x: 181, y: 64), control2: CGPoint(x: 204, y: 63))
            path.closeSubpath()
        }
    }

    private static var xbox: Path {
        Path { path in
            path.move(to: CGPoint(x: 240, y: 52))
            path.addCurve(to: CGPoint(x: 347, y: 49), control1: CGPoint(x: 297, y: 52), control2: CGPoint(x: 322, y: 45))
            path.addCurve(to: CGPoint(x: 421, y: 108), control1: CGPoint(x: 382, y: 53), control2: CGPoint(x: 406, y: 72))
            path.addCurve(to: CGPoint(x: 457, y: 253), control1: CGPoint(x: 437, y: 144), control2: CGPoint(x: 452, y: 203))
            path.addCurve(to: CGPoint(x: 432, y: 309), control1: CGPoint(x: 462, y: 282), control2: CGPoint(x: 451, y: 305))
            path.addCurve(to: CGPoint(x: 362, y: 251), control1: CGPoint(x: 411, y: 311), control2: CGPoint(x: 382, y: 279))
            path.addCurve(to: CGPoint(x: 331, y: 229), control1: CGPoint(x: 352, y: 237), control2: CGPoint(x: 344, y: 229))
            path.addCurve(to: CGPoint(x: 240, y: 231), control1: CGPoint(x: 298, y: 232), control2: CGPoint(x: 267, y: 231))
            path.addCurve(to: CGPoint(x: 149, y: 229), control1: CGPoint(x: 213, y: 231), control2: CGPoint(x: 182, y: 232))
            path.addCurve(to: CGPoint(x: 118, y: 251), control1: CGPoint(x: 136, y: 229), control2: CGPoint(x: 128, y: 237))
            path.addCurve(to: CGPoint(x: 48, y: 309), control1: CGPoint(x: 98, y: 279), control2: CGPoint(x: 69, y: 311))
            path.addCurve(to: CGPoint(x: 23, y: 253), control1: CGPoint(x: 29, y: 305), control2: CGPoint(x: 18, y: 282))
            path.addCurve(to: CGPoint(x: 59, y: 108), control1: CGPoint(x: 28, y: 203), control2: CGPoint(x: 43, y: 144))
            path.addCurve(to: CGPoint(x: 133, y: 49), control1: CGPoint(x: 74, y: 72), control2: CGPoint(x: 98, y: 53))
            path.addCurve(to: CGPoint(x: 240, y: 52), control1: CGPoint(x: 158, y: 45), control2: CGPoint(x: 183, y: 52))
            path.closeSubpath()
        }
    }

    private static var backbone: Path {
        let left = Path { path in
            path.move(to: CGPoint(x: 96, y: 76))
            path.addCurve(to: CGPoint(x: 29, y: 91), control1: CGPoint(x: 68, y: 73), control2: CGPoint(x: 43, y: 77))
            path.addCurve(to: CGPoint(x: 13, y: 201), control1: CGPoint(x: 17, y: 112), control2: CGPoint(x: 15, y: 166))
            path.addCurve(to: CGPoint(x: 45, y: 270), control1: CGPoint(x: 9, y: 244), control2: CGPoint(x: 20, y: 269))
            path.addCurve(to: CGPoint(x: 96, y: 241), control1: CGPoint(x: 73, y: 274), control2: CGPoint(x: 94, y: 267))
            path.addCurve(to: CGPoint(x: 94, y: 203), control1: CGPoint(x: 98, y: 226), control2: CGPoint(x: 93, y: 217))
            path.addLine(to: CGPoint(x: 96, y: 76))
            path.closeSubpath()
        }
        var path = left
        path.addPath(left.applying(.init(a: -1, b: 0, c: 0, d: 1, tx: 480, ty: 0)))
        return path
    }

    private static var generic: Path {
        Path { path in
            path.move(to: CGPoint(x: 240, y: 57))
            path.addCurve(to: CGPoint(x: 370, y: 62), control1: CGPoint(x: 292, y: 57), control2: CGPoint(x: 338, y: 55))
            path.addCurve(to: CGPoint(x: 429, y: 119), control1: CGPoint(x: 400, y: 69), control2: CGPoint(x: 420, y: 88))
            path.addCurve(to: CGPoint(x: 449, y: 264), control1: CGPoint(x: 442, y: 161), control2: CGPoint(x: 451, y: 225))
            path.addCurve(to: CGPoint(x: 410, y: 296), control1: CGPoint(x: 449, y: 291), control2: CGPoint(x: 431, y: 304))
            path.addCurve(to: CGPoint(x: 346, y: 235), control1: CGPoint(x: 386, y: 286), control2: CGPoint(x: 368, y: 253))
            path.addCurve(to: CGPoint(x: 240, y: 236), control1: CGPoint(x: 318, y: 230), control2: CGPoint(x: 276, y: 236))
            path.addCurve(to: CGPoint(x: 134, y: 235), control1: CGPoint(x: 204, y: 236), control2: CGPoint(x: 162, y: 230))
            path.addCurve(to: CGPoint(x: 70, y: 296), control1: CGPoint(x: 112, y: 253), control2: CGPoint(x: 94, y: 286))
            path.addCurve(to: CGPoint(x: 31, y: 264), control1: CGPoint(x: 49, y: 304), control2: CGPoint(x: 31, y: 291))
            path.addCurve(to: CGPoint(x: 51, y: 119), control1: CGPoint(x: 29, y: 225), control2: CGPoint(x: 38, y: 161))
            path.addCurve(to: CGPoint(x: 110, y: 62), control1: CGPoint(x: 60, y: 88), control2: CGPoint(x: 80, y: 69))
            path.addCurve(to: CGPoint(x: 240, y: 57), control1: CGPoint(x: 142, y: 55), control2: CGPoint(x: 188, y: 57))
            path.closeSubpath()
        }
    }
}
