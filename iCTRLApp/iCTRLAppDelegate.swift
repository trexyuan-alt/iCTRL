import UIKit

final class iCTRLAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        EndpointOraclePublisher.shared.start()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        EndpointOraclePublisher.shared.refreshIfNeeded(reason: "active")
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        EndpointOraclePublisher.shared.updateAPNSToken(deviceToken)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        ictrlLog("APNs registration unavailable: \(error.localizedDescription)")
        EndpointOraclePublisher.shared.registerBackend(apnsToken: nil, completion: nil)
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard EndpointOraclePublisher.isEndpointRefreshPush(userInfo) else {
            completionHandler(.noData)
            return
        }
        EndpointOraclePublisher.shared.refreshAndPublish(reason: "silent_push") { ok in
            completionHandler(ok ? .newData : .failed)
        }
    }
}
