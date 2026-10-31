#if os(iOS)
import StoreKit
import UIKit

enum SKStoreReviewControllerShim {
    @MainActor static func request(in scene: UIWindowScene) {
        if #available(iOS 18.0, *) { AppStore.requestReview(in: scene) } else { SKStoreReviewController.requestReview(in: scene) }
    }
}

enum RefundShim {
    /// Apple's own refund sheet: Apple decides, not the app.
    @MainActor static func begin(transactionID: UInt64, in scene: UIWindowScene) async -> Bool {
        (try? await Transaction.beginRefundRequest(for: transactionID, in: scene)) == .success
    }
}
#endif
