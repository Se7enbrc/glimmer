// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import PackageDescription

let package = Package(
    name: "Glimmer",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: [.library(name: "GlimmerEngine", targets: ["GlimmerEngine"])],
    targets: [
        .target(name: "GlimmerEngine", path: "GlimmerEngine"),
        .testTarget(name: "EnginePackageTests", dependencies: ["GlimmerEngine"], path: "EnginePackageTests")
    ],
    swiftLanguageModes: [.v6]
)
