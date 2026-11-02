#if os(iOS)
import StoreKit
import UIKit

enum RefundShim {
    /// Apple's own refund sheet: Apple decides, not the app. Returns the action reported to the team:
    /// "claimed" (request submitted), "dismissed" (the user cancelled) or "failed".
    @MainActor static func begin(transactionID: UInt64, in scene: UIWindowScene) async -> String {
        switch try? await Transaction.beginRefundRequest(for: transactionID, in: scene) {
        case .success?: return "claimed"
        case .userCancelled?: return "dismissed"
        default: return "failed"
        }
    }
}
#endif
