import Foundation
import os

struct HDRMetadata: Equatable, Sendable {
    let mdcv: Data?
    let contentLightLevel: Data?

    static let empty = HDRMetadata(mdcv: nil, contentLightLevel: nil)
}

final class HDRMetadataStore: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: HDRMetadata.empty)

    var snapshot: HDRMetadata {
        storage.withLock { $0 }
    }

    func publish(_ metadata: HDRMetadata) {
        storage.withLock { $0 = metadata }
    }
}
