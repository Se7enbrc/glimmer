enum AWDLStreamLease {
    static func refreshIfNeeded(isEnabled: () -> Bool, refresh: () -> Void) {
        if !isEnabled() { refresh() }
    }

    static func releaseIfHeartbeatExists(hasHeartbeat: () -> Bool, release: () -> Void) {
        guard hasHeartbeat() else { return }
        release()
    }
}
