// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFAudio
import Foundation

extension IOSAudioSession {
    enum Event: Sendable {
        case route
        case interruption(began: Bool, shouldResume: Bool)
        case servicesLost
        case servicesReset

        init?(_ notification: Notification) {
            switch notification.name {
            case AVAudioSession.routeChangeNotification: self = .route
            case AVAudioSession.interruptionNotification:
                guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return nil }
                let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                self = .interruption(began: type == .began,
                                     shouldResume: AVAudioSession.InterruptionOptions(rawValue: options)
                                        .contains(.shouldResume))
            case AVAudioSession.mediaServicesWereLostNotification: self = .servicesLost
            case AVAudioSession.mediaServicesWereResetNotification: self = .servicesReset
            default: return nil
            }
        }
    }

    func installRouteListener(queue: DispatchQueue, id: String, changed: @escaping @Sendable (UInt64) -> Void) {
        lock.withLock {
            wantsPlayback = true
            routeID = id
            routeListener = Listener(queue: queue, changed: changed)
            observeIfNeeded()
        }
    }

    func removeRouteListener(id: String) {
        lock.withLock {
            guard routeID == id else { return }
            routeID = nil
            generation &+= 1
            routeListener = nil
            wantsPlayback = false
            if leases == 0, active { deactivate() }
            removeObserversIfUnused()
        }
    }

    func installDeviceListeners(queue: DispatchQueue, changed: @escaping @Sendable (UInt64) -> Void) {
        lock.withLock {
            deviceListener = Listener(queue: queue, changed: changed)
            observeIfNeeded()
        }
    }

    func removeDeviceListeners() {
        lock.withLock {
            deviceListener = nil
            removeObserversIfUnused()
        }
    }

    private func observeIfNeeded() {
        guard tokens.isEmpty else { return }
        observerGeneration &+= 1
        let installed = observerGeneration
        let names = [AVAudioSession.routeChangeNotification, AVAudioSession.interruptionNotification,
                     AVAudioSession.mediaServicesWereLostNotification,
                     AVAudioSession.mediaServicesWereResetNotification]
        tokens = names.map { name in
            notifications.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                guard let self, let event = Event(notification) else { return }
                let changedAt = DispatchTime.now().uptimeNanoseconds
                self.events.async { [weak self] in self?.receive(event, installed: installed, at: changedAt) }
            }
        }
    }

    private func removeObserversIfUnused() {
        guard routeListener == nil, deviceListener == nil else { return }
        observerGeneration &+= 1
        for token in tokens { notifications.removeObserver(token) }
        tokens.removeAll()
        interrupted = false
        servicesLost = false
    }

    private func receive(_ event: Event, installed: UInt64, at changedAt: UInt64) {
        let listener: Listener? = lock.withLock {
            guard installed == observerGeneration, !tokens.isEmpty else { return nil }
            switch event {
            case .interruption(let began, let shouldResume):
                interrupted = began || !shouldResume
                if began { active = false }
            case .servicesLost:
                servicesLost = true
                active = false
            case .servicesReset:
                servicesLost = false
                active = false
                configured = false
            case .route: break
            }
            generation &+= 1
            if case .route = event { return routeListener ?? deviceListener }
            return deviceListener ?? routeListener
        }
        guard let listener else { return }
        listener.queue.async { listener.changed(changedAt) }
    }
}
