import UIKit

// AppDelegate.swift
// RTMPCameraApp 入口 - 注意: main.swift 定义了 UIApplicationMain, 此处不能用 @main

class RTMPAppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {

        window = UIWindow(frame: UIScreen.main.bounds)
        let navController = UINavigationController(
            rootViewController: MainViewController()
        )
        navController.navigationBar.prefersLargeTitles = true
        window?.rootViewController = navController
        window?.makeKeyAndVisible()

        return true
    }
}
