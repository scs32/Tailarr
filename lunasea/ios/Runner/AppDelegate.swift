import UIKit
import Flutter
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate {
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        // ntfy background refresh (BGAppRefreshTask). The identifier must
        // match LunaNtfy.BACKGROUND_TASK_ID and Info.plist's
        // BGTaskSchedulerPermittedIdentifiers.
        WorkmanagerPlugin.setPluginRegistrantCallback { registry in
            GeneratedPluginRegistrant.register(with: registry)
        }
        WorkmanagerPlugin.registerPeriodicTask(
            withIdentifier: "com.stephenspeicher.tailarr.ntfy-refresh",
            frequency: NSNumber(value: 15 * 60)
        )

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}
