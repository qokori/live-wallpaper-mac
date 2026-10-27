/// Why a screen's video is paused. Declaration order is priority: the first reason is the one shown in the menu.
public enum PauseReason: String, CaseIterable, Sendable {
    case userPaused
    case systemSleep
    case screensAsleep
    case screenLocked
    case sessionInactive
    case lowPowerMode
    case onBattery
    case occluded
}

/// Machine-wide state that can pause every screen at once.
public struct SystemConditions: Equatable, Sendable {
    public var userPaused: Bool
    public var systemSleeping: Bool
    public var screensAsleep: Bool
    public var screenLocked: Bool
    public var sessionActive: Bool
    public var lowPowerMode: Bool
    public var onBattery: Bool
    public var pauseOnBattery: Bool

    public init(
        userPaused: Bool = false,
        systemSleeping: Bool = false,
        screensAsleep: Bool = false,
        screenLocked: Bool = false,
        sessionActive: Bool = true,
        lowPowerMode: Bool = false,
        onBattery: Bool = false,
        pauseOnBattery: Bool = false
    ) {
        self.userPaused = userPaused
        self.systemSleeping = systemSleeping
        self.screensAsleep = screensAsleep
        self.screenLocked = screenLocked
        self.sessionActive = sessionActive
        self.lowPowerMode = lowPowerMode
        self.onBattery = onBattery
        self.pauseOnBattery = pauseOnBattery
    }
}

public enum PausePolicy {
    /// Every reason that applies to one screen, in priority order. Empty means the video plays.
    /// `screenVisible` is the window's occlusion state: false when a fullscreen app or other windows cover it.
    public static func reasons(_ conditions: SystemConditions, screenVisible: Bool) -> [PauseReason] {
        var reasons: [PauseReason] = []
        if conditions.userPaused { reasons.append(.userPaused) }
        if conditions.systemSleeping { reasons.append(.systemSleep) }
        if conditions.screensAsleep { reasons.append(.screensAsleep) }
        if conditions.screenLocked { reasons.append(.screenLocked) }
        if !conditions.sessionActive { reasons.append(.sessionInactive) }
        if conditions.lowPowerMode { reasons.append(.lowPowerMode) }
        if conditions.onBattery && conditions.pauseOnBattery { reasons.append(.onBattery) }
        if !screenVisible { reasons.append(.occluded) }
        return reasons
    }

    public static func shouldPlay(_ conditions: SystemConditions, screenVisible: Bool) -> Bool {
        reasons(conditions, screenVisible: screenVisible).isEmpty
    }
}

extension PausePolicy {
    /// Pause reasons for every screen at once. `visible` is each window's occlusion state: false while a fullscreen
    /// app, another Space, Mission Control or the lock screen covers it, so only that screen pauses.
    /// `ignoreOcclusion` keeps covered screens playing (measurements only).
    public static func plan(
        _ conditions: SystemConditions, visible: [String: Bool], ignoreOcclusion: Bool = false
    ) -> [String: [PauseReason]] {
        visible.mapValues { reasons(conditions, screenVisible: ignoreOcclusion || $0) }
    }
}
