import UIKit
import Flutter
import GoLunaSea

@main
@objc class AppDelegate: FlutterAppDelegate {
    private var tailscale: LunaseaTailscale?
    private var proxyPort: Int?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        guard let controller = window?.rootViewController as? FlutterViewController else {
            return super.application(application, didFinishLaunchingWithOptions: launchOptions)
        }

        let tailscaleChannel = FlutterMethodChannel(
            name: "com.lunasea.tailscale/method",
            binaryMessenger: controller.binaryMessenger
        )

        tailscaleChannel.setMethodCallHandler { [weak self] (call, result) in
            self?.handleMethodCall(call: call, result: result)
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    private func handleMethodCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "start":
            handleStart(call: call, result: result)
        case "stop":
            handleStop(result: result)
        case "ensure":
            handleEnsure(result: result)
        case "isRunning":
            handleIsRunning(result: result)
        case "getPort":
            handleGetPort(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func handleStart(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let authKey = args["authKey"] as? String else {
            result(FlutterError(
                code: "INVALID_ARGUMENT",
                message: "Missing authKey argument",
                details: nil
            ))
            return
        }

        guard let stateDir = stateDirectory() else {
            result(FlutterError(
                code: "STATE_DIR_ERROR",
                message: "Failed to create state directory",
                details: nil
            ))
            return
        }

        // Stop existing instance if running
        if tailscale?.isRunning() == true {
            tailscale?.stopProxy()
        }

        // Create new Tailscale instance
        let instance = LunaseaNewTailscale(stateDir, authKey)
        tailscale = instance

        // StartProxy blocks until the node is authenticated (up to ~45s) —
        // keep it off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var port: Int = 0
                try instance?.startProxy(&port)
                DispatchQueue.main.async {
                    self.proxyPort = port
                    result(port)
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "START_FAILED",
                        message: error.localizedDescription,
                        details: nil
                    ))
                }
            }
        }
    }

    private func handleEnsure(result: @escaping FlutterResult) {
        guard let instance = tailscale, instance.isRunning() else {
            result(nil)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var port: Int = 0
                try instance.ensureProxy(&port)
                DispatchQueue.main.async {
                    self.proxyPort = port
                    result(port)
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "ENSURE_FAILED",
                        message: error.localizedDescription,
                        details: nil
                    ))
                }
            }
        }
    }

    private func handleStop(result: @escaping FlutterResult) {
        tailscale?.stopProxy()
        tailscale = nil
        proxyPort = nil
        result(nil)
    }

    private func handleIsRunning(result: @escaping FlutterResult) {
        result(tailscale?.isRunning() ?? false)
    }

    private func handleGetPort(result: @escaping FlutterResult) {
        if let port = proxyPort, tailscale?.isRunning() == true {
            result(port)
        } else {
            result(nil)
        }
    }

    private func stateDirectory() -> String? {
        guard let appSupportDir = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }

        let stateDir = appSupportDir.appendingPathComponent("tailscale")
        try? FileManager.default.createDirectory(
            at: stateDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return stateDir.path
    }
}
