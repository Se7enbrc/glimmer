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
        case .backbone: outline = Self.backbone
        case .generic: outline = Self.generic
        }
        return outline.applying(.init(scaleX: rect.width / 480, y: rect.height / 330))
            .applying(.init(translationX: rect.minX, y: rect.minY))
    }

    // Original curves use a common front projection; dimensions set the overall proportions, not traced vertices.
    private static var dualSense: Path {
        Path { path in
            path.move(to: CGPoint(x: 240, y: 40))
            path.addCurve(to: CGPoint(x: 354, y: 42), control1: CGPoint(x: 278, y: 38), control2: CGPoint(x: 327, y: 36))
            path.addCurve(to: CGPoint(x: 413, y: 73), control1: CGPoint(x: 382, y: 44), control2: CGPoint(x: 401, y: 52))
            path.addCurve(to: CGPoint(x: 442, y: 151), control1: CGPoint(x: 433, y: 102), control2: CGPoint(x: 434, y: 119))
            path.addCurve(to: CGPoint(x: 460, y: 284), control1: CGPoint(x: 453, y: 194), control2: CGPoint(x: 461, y: 254))
            path.addCurve(to: CGPoint(x: 438, y: 316), control1: CGPoint(x: 460, y: 308), control2: CGPoint(x: 454, y: 319))
            path.addCurve(to: CGPoint(x: 397, y: 292), control1: CGPoint(x: 424, y: 315), control2: CGPoint(x: 410, y: 308))
            path.addCurve(to: CGPoint(x: 351, y: 231), control1: CGPoint(x: 381, y: 273), control2: CGPoint(x: 370, y: 241))
            path.addCurve(to: CGPoint(x: 310, y: 238), control1: CGPoint(x: 338, y: 225), control2: CGPoint(x: 325, y: 236))
            path.addCurve(to: CGPoint(x: 170, y: 238), control1: CGPoint(x: 274, y: 247), control2: CGPoint(x: 206, y: 247))
            path.addCurve(to: CGPoint(x: 129, y: 231), control1: CGPoint(x: 155, y: 236), control2: CGPoint(x: 142, y: 225))
            path.addCurve(to: CGPoint(x: 83, y: 292), control1: CGPoint(x: 110, y: 241), control2: CGPoint(x: 99, y: 273))
            path.addCurve(to: CGPoint(x: 42, y: 316), control1: CGPoint(x: 70, y: 308), control2: CGPoint(x: 56, y: 315))
            path.addCurve(to: CGPoint(x: 20, y: 284), control1: CGPoint(x: 26, y: 319), control2: CGPoint(x: 20, y: 308))
            path.addCurve(to: CGPoint(x: 38, y: 151), control1: CGPoint(x: 19, y: 254), control2: CGPoint(x: 27, y: 194))
            path.addCurve(to: CGPoint(x: 67, y: 73), control1: CGPoint(x: 46, y: 119), control2: CGPoint(x: 47, y: 102))
            path.addCurve(to: CGPoint(x: 126, y: 42), control1: CGPoint(x: 79, y: 52), control2: CGPoint(x: 98, y: 44))
            path.addCurve(to: CGPoint(x: 240, y: 40), control1: CGPoint(x: 153, y: 36), control2: CGPoint(x: 202, y: 38))
            path.closeSubpath()
        }
    }

    private static var dualShock: Path {
        Path { path in
            path.move(to: CGPoint(x: 157, y: 65))
            path.addCurve(to: CGPoint(x: 323, y: 65), control1: CGPoint(x: 193, y: 55), control2: CGPoint(x: 287, y: 55))
            path.addCurve(to: CGPoint(x: 412, y: 67), control1: CGPoint(x: 347, y: 47), control2: CGPoint(x: 389, y: 48))
            path.addCurve(to: CGPoint(x: 443, y: 138), control1: CGPoint(x: 439, y: 88), control2: CGPoint(x: 445, y: 111))
            path.addCurve(to: CGPoint(x: 459, y: 260), control1: CGPoint(x: 446, y: 178), control2: CGPoint(x: 461, y: 230))
            path.addCurve(to: CGPoint(x: 424, y: 299), control1: CGPoint(x: 458, y: 286), control2: CGPoint(x: 447, y: 304))
            path.addCurve(to: CGPoint(x: 385, y: 276), control1: CGPoint(x: 407, y: 297), control2: CGPoint(x: 395, y: 289))
            path.addLine(to: CGPoint(x: 347, y: 234))
            path.addCurve(to: CGPoint(x: 282, y: 242), control1: CGPoint(x: 329, y: 254), control2: CGPoint(x: 302, y: 252))
            path.addCurve(to: CGPoint(x: 198, y: 242), control1: CGPoint(x: 257, y: 225), control2: CGPoint(x: 223, y: 225))
            path.addCurve(to: CGPoint(x: 133, y: 234), control1: CGPoint(x: 178, y: 252), control2: CGPoint(x: 151, y: 254))
            path.addLine(to: CGPoint(x: 95, y: 276))
            path.addCurve(to: CGPoint(x: 56, y: 299), control1: CGPoint(x: 85, y: 289), control2: CGPoint(x: 73, y: 297))
            path.addCurve(to: CGPoint(x: 21, y: 260), control1: CGPoint(x: 33, y: 304), control2: CGPoint(x: 22, y: 286))
            path.addCurve(to: CGPoint(x: 37, y: 138), control1: CGPoint(x: 19, y: 230), control2: CGPoint(x: 34, y: 178))
            path.addCurve(to: CGPoint(x: 68, y: 67), control1: CGPoint(x: 35, y: 111), control2: CGPoint(x: 41, y: 88))
            path.addCurve(to: CGPoint(x: 157, y: 65), control1: CGPoint(x: 91, y: 48), control2: CGPoint(x: 133, y: 47))
            path.closeSubpath()
        }
    }

    private static var xbox: Path {
        Path { path in
            path.move(to: CGPoint(x: 130, y: 40))
            path.addCurve(to: CGPoint(x: 350, y: 40), control1: CGPoint(x: 203, y: 30), control2: CGPoint(x: 277, y: 30))
            path.addCurve(to: CGPoint(x: 411, y: 74), control1: CGPoint(x: 376, y: 41), control2: CGPoint(x: 399, y: 52))
            path.addCurve(to: CGPoint(x: 440, y: 168), control1: CGPoint(x: 425, y: 103), control2: CGPoint(x: 435, y: 137))
            path.addCurve(to: CGPoint(x: 456, y: 275), control1: CGPoint(x: 449, y: 209), control2: CGPoint(x: 456, y: 251))
            path.addCurve(to: CGPoint(x: 430, y: 312), control1: CGPoint(x: 456, y: 298), control2: CGPoint(x: 449, y: 313))
            path.addCurve(to: CGPoint(x: 394, y: 291), control1: CGPoint(x: 416, y: 311), control2: CGPoint(x: 403, y: 302))
            path.addCurve(to: CGPoint(x: 350, y: 230), control1: CGPoint(x: 377, y: 269), control2: CGPoint(x: 364, y: 236))
            path.addCurve(to: CGPoint(x: 130, y: 230), control1: CGPoint(x: 304, y: 247), control2: CGPoint(x: 176, y: 247))
            path.addCurve(to: CGPoint(x: 86, y: 291), control1: CGPoint(x: 116, y: 236), control2: CGPoint(x: 103, y: 269))
            path.addCurve(to: CGPoint(x: 50, y: 312), control1: CGPoint(x: 77, y: 302), control2: CGPoint(x: 64, y: 311))
            path.addCurve(to: CGPoint(x: 24, y: 275), control1: CGPoint(x: 31, y: 313), control2: CGPoint(x: 24, y: 298))
            path.addCurve(to: CGPoint(x: 40, y: 168), control1: CGPoint(x: 24, y: 251), control2: CGPoint(x: 31, y: 209))
            path.addCurve(to: CGPoint(x: 69, y: 74), control1: CGPoint(x: 45, y: 137), control2: CGPoint(x: 55, y: 103))
            path.addCurve(to: CGPoint(x: 130, y: 40), control1: CGPoint(x: 81, y: 52), control2: CGPoint(x: 104, y: 41))
            path.closeSubpath()
        }
    }

    private static var backbone: Path {
        var path = Path()
        let left = Path { path in
            path.move(to: CGPoint(x: 92, y: 77))
            path.addCurve(to: CGPoint(x: 43, y: 76), control1: CGPoint(x: 76, y: 69), control2: CGPoint(x: 59, y: 70))
            path.addCurve(to: CGPoint(x: 12, y: 119), control1: CGPoint(x: 23, y: 82), control2: CGPoint(x: 12, y: 99))
            path.addLine(to: CGPoint(x: 12, y: 202))
            path.addCurve(to: CGPoint(x: 48, y: 237), control1: CGPoint(x: 12, y: 222), control2: CGPoint(x: 26, y: 237))
            path.addCurve(to: CGPoint(x: 94, y: 222), control1: CGPoint(x: 70, y: 239), control2: CGPoint(x: 85, y: 235))
            path.addCurve(to: CGPoint(x: 92, y: 77), control1: CGPoint(x: 101, y: 195), control2: CGPoint(x: 96, y: 106))
            path.closeSubpath()
        }
        path.addPath(left)
        path.addPath(left.applying(.init(a: -1, b: 0, c: 0, d: 1, tx: 480, ty: 0)))
        return path
    }

    private static var generic: Path {
        Path { path in
            path.move(to: CGPoint(x: 103, y: 63))
            path.addQuadCurve(to: CGPoint(x: 377, y: 63), control: CGPoint(x: 240, y: 43))
            path.addCurve(to: CGPoint(x: 429, y: 117), control1: CGPoint(x: 410, y: 64), control2: CGPoint(x: 425, y: 84))
            path.addLine(to: CGPoint(x: 450, y: 257))
            path.addCurve(to: CGPoint(x: 405, y: 294), control1: CGPoint(x: 460, y: 299), control2: CGPoint(x: 428, y: 308))
            path.addLine(to: CGPoint(x: 346, y: 239))
            path.addQuadCurve(to: CGPoint(x: 134, y: 239), control: CGPoint(x: 240, y: 263))
            path.addLine(to: CGPoint(x: 75, y: 294))
            path.addCurve(to: CGPoint(x: 30, y: 257), control1: CGPoint(x: 52, y: 308), control2: CGPoint(x: 20, y: 299))
            path.addLine(to: CGPoint(x: 51, y: 117))
            path.addCurve(to: CGPoint(x: 103, y: 63), control1: CGPoint(x: 55, y: 84), control2: CGPoint(x: 70, y: 64))
            path.closeSubpath()
        }
    }
}
