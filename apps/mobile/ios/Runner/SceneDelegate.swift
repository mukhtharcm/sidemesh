import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    registerLiveActivityBridge()
    registerPushBridge()
  }

  private func registerLiveActivityBridge() {
    DispatchQueue.main.async { [weak self] in
      guard
        let controller = self?.window?.rootViewController as? FlutterViewController
      else {
        return
      }
      SidemeshLiveActivityBridge.shared.attach(to: controller.binaryMessenger)
    }
  }

  private func registerPushBridge() {
    DispatchQueue.main.async { [weak self] in
      guard
        let controller = self?.window?.rootViewController as? FlutterViewController
      else {
        return
      }
      SidemeshPushBridge.shared.attach(to: controller.binaryMessenger)
    }
  }
}
