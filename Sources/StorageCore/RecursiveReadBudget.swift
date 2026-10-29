import Foundation

/// One process-wide budget for recursive metadata walks. Interactive directory
/// listings are shallow and do not queue behind a complete disk enumeration.
public actor RecursiveReadBudget {
    public static let shared = RecursiveReadBudget()
    private var available = 2
    private var waiting: [CheckedContinuation<Void, Never>] = []
    public init() {}
    public func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    public func release() {
        if waiting.isEmpty { available += 1 }
        else { waiting.removeFirst().resume() }
    }
}
