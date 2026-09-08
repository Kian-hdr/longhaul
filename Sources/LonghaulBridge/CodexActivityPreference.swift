import Foundation
import LonghaulCore

/// Hooks remain the normal integration. Native lifecycle observation covers
/// existing unreported turns and provisional Stop continuations without making
/// two active jobs out of the same turn.
public enum CodexActivityPreference {
    public static func useActivity(hook: JobEvent?, hookIsFresh: Bool, nativeIsTerminal: Bool = false, hookOwnerMatches: Bool = true) -> Bool {
        if nativeIsTerminal || !hookOwnerMatches { return true }
        guard let hook else { return true }
        if hook.phase.isTerminal {
            return hook.phase == .completed && hook.continuableHookStop != nil
        }
        return !hookIsFresh
    }
}
