import UIKit
import Flutter
import AVFoundation
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate {
    static let appGroupId = "group.com.stephenspeicher.tailarr"
    private static let pushChannelName = "com.stephenspeicher.tailarr/push"
    private static let voiceAudioChannelName = "com.stephenspeicher.tailarr/voice_audio"

    /// Pending Dart request awaiting the APNs token callback.
    private var pushTokenResult: FlutterResult?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        if let controller = window?.rootViewController as? FlutterViewController {
            registerPushChannel(messenger: controller.binaryMessenger, mainEngine: true)
            registerVoiceAudioChannel(messenger: controller.binaryMessenger)
        }

        // ntfy background refresh (BGAppRefreshTask). The identifier must
        // match LunaNtfy.BACKGROUND_TASK_ID and Info.plist's
        // BGTaskSchedulerPermittedIdentifiers.
        WorkmanagerPlugin.setPluginRegistrantCallback { registry in
            GeneratedPluginRegistrant.register(with: registry)
            // The background isolate needs the App Group path too (its
            // shared-state file lives there); APNs registration itself is
            // main-engine only.
            if let registrar = registry.registrar(forPlugin: "TailarrPushChannel") {
                AppDelegate.sharedInstance?.registerPushChannel(
                    messenger: registrar.messenger(), mainEngine: false)
            }
        }
        WorkmanagerPlugin.registerPeriodicTask(
            withIdentifier: "com.stephenspeicher.tailarr.ntfy-refresh",
            frequency: NSNumber(value: 15 * 60)
        )

        AppDelegate.sharedInstance = self
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    private static weak var sharedInstance: AppDelegate?

    private func registerPushChannel(messenger: FlutterBinaryMessenger, mainEngine: Bool) {
        let channel = FlutterMethodChannel(
            name: AppDelegate.pushChannelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            switch call.method {
            case "getAppGroupPath":
                result(FileManager.default
                    .containerURL(forSecurityApplicationGroupIdentifier: AppDelegate.appGroupId)?
                    .path)
            case "getPushEnvironment":
                result(AppDelegate.pushEnvironment())
            case "requestPushToken":
                guard mainEngine, let self = self else {
                    result(FlutterError(
                        code: "UNAVAILABLE",
                        message: "APNs registration is main-engine only",
                        details: nil))
                    return
                }
                self.pushTokenResult = result
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    /// Read-only probe of the shared `AVAudioSession`, used by the voice lane
    /// immediately BEFORE it starts the flutter_sound stream player.
    ///
    /// Build 11.0.0 (48) crashed with `EXC_CRASH (SIGABRT)` inside
    /// `-[AVAudioEngine connect:to:format:]` reached from `startPlayerFromStream`.
    /// `connect` raises an Objective-C exception on an invalid format — most
    /// often a `sampleRate` of 0, which is what the session reports while it is
    /// not active. An ObjC exception is NOT catchable from Dart, so Dart has to
    /// be able to look before it leaps. This channel is that look.
    ///
    /// Strictly read-only: it mutates nothing about the session.
    private func registerVoiceAudioChannel(messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: AppDelegate.voiceAudioChannelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "probeSession":
                let session = AVAudioSession.sharedInstance()
                result([
                    "sampleRate": session.sampleRate,
                    "ioBufferDuration": session.ioBufferDuration,
                    "outputChannels": session.outputNumberOfChannels,
                    "inputChannels": session.inputNumberOfChannels,
                    "category": session.category.rawValue,
                    "mode": session.mode.rawValue,
                    "route": session.currentRoute.outputs
                        .map { $0.portType.rawValue }
                        .joined(separator: "+"),
                ])
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    /// Which APNs environment this binary's tokens belong to. Decided by
    /// the aps-environment entitlement in the embedded provisioning
    /// profile — NOT the Dart build mode: a release-mode build signed with
    /// a development profile still gets sandbox tokens. App Store builds
    /// carry no embedded profile → production.
    private static func pushEnvironment() -> String {
        guard
            let path = Bundle.main.path(
                forResource: "embedded", ofType: "mobileprovision"),
            let raw = try? String(contentsOfFile: path, encoding: .isoLatin1),
            let keyRange = raw.range(of: "<key>aps-environment</key>")
        else { return "production" }
        let tail = raw[keyRange.upperBound...].prefix(120)
        return tail.contains("development") ? "development" : "production"
    }

    override func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        pushTokenResult?(hex)
        pushTokenResult = nil
        super.application(
            application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
    }

    override func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        pushTokenResult?(FlutterError(
            code: "APNS_REGISTRATION_FAILED",
            message: error.localizedDescription,
            details: nil))
        pushTokenResult = nil
        super.application(
            application, didFailToRegisterForRemoteNotificationsWithError: error)
    }
}
