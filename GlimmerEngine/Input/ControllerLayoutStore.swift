// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

public actor ControllerLayoutStore {
    public static let maximumBytes = 4 * 1024 * 1024
    private let url: URL

    public init(url: URL) { self.url = url }

    public func load() throws -> ControllerLayoutLibrary {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.maximumBytes else { throw ControllerLayoutError.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maximumBytes else { throw ControllerLayoutError.tooLarge }
        let library = try JSONDecoder().decode(ControllerLayoutLibrary.self, from: data)
        try library.validate()
        return library
    }

    public func save(_ library: ControllerLayoutLibrary) throws {
        try library.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(library)
        guard data.count <= Self.maximumBytes else { throw ControllerLayoutError.tooLarge }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
}
