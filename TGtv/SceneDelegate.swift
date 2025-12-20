import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        DebugLogger.shared.log("SceneDelegate: scene willConnectTo")
        guard let windowScene = (scene as? UIWindowScene) else { return }

        let appDelegate = UIApplication.shared.delegate as! AppDelegate
        
        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = .black
        
        // Присваиваем окно в AppDelegate для совместимости
        appDelegate.window = window
        self.window = window
        
        // Ожидаем, пока AppDelegate создаст навигационный контроллер, если он еще не готов
        if let nav = appDelegate.navigationController {
            window.rootViewController = nav
        } else {
            // Фолбэк на случай, если AppDelegate еще не успел создать контроллер
            let placeholderNav = UINavigationController()
            appDelegate.navigationController = placeholderNav
            window.rootViewController = placeholderNav
        }
        
        window.makeKeyAndVisible()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
    }

    func sceneWillResignActive(_ scene: UIScene) {
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
    }
}


