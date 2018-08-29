//
//  LoginProcess.swift
//
//  Copyright (c) 2016-present, LINE Corporation. All rights reserved.
//
//  You are hereby granted a non-exclusive, worldwide, royalty-free license to use,
//  copy and distribute this software in source code or binary form for use
//  in connection with the web services and APIs provided by LINE Corporation.
//
//  As with any software that integrates with the LINE Corporation platform, your use of this software
//  is subject to the LINE Developers Agreement [http://terms2.line.me/LINE_Developers_Agreement].
//  This copyright notice shall be included in all copies or substantial portions of the software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
//  INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
//  IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
//  DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//

import Foundation
import UIKit
import SafariServices

/// Represents a login process initialized by a `LoginManager`. Normally, a process contains multiple login flows,
/// which will run serially. If a previous flow succeeded in auth the user, later flows will not be executed.
public class LoginProcess {
    
    enum BotPrompt: String {
        case normal
        case aggressive
    }
    
    struct FlowParameters {
        let channelID: String
        let universalLinkURL: URL?
        let scopes: Set<LoginPermission>
        let otp: OneTimePassword
        let processID: String
        let nonce: String?
        let botPrompt: BotPrompt?
    }
    
    /// Observes application switching to foreground.
    /// - Note:
    /// If the app switching happens during login process, we want to
    /// inspect the event of switched back from another app (Safari or LINE or any other)
    /// If the framework container app has not been started up by an `open(url:)`, we think current
    /// login process fails and we need to call the completion closuer with a `.userCancelled` error.
    class AppSwitchingObserver {
        // A token holds current observing. It will be released and trigger remove observer
        // when this `AppSwitchingObserver` gets released.
        var token: NotificationToken?
        
        // Controls whether we really need the trigger. By setting this to `false`, `onTrigger` will not be
        // called even a `.UIApplicationDidBecomeActive` event received.
        var valid: Bool = true
        
        let onTrigger = Delegate<(), Void>()
        
        init() { }
        
        func startObserving() {
            token = NotificationCenter.default
                .addObserver(forName: .UIApplicationDidBecomeActive, object: nil, queue: nil)
            {
                [weak self] _ in
                guard let `self` = self else { return }
                guard self.valid else { return }
                self.onTrigger.call()
            }
        }
    }
    
    let configuration: LoginConfiguration
    let scopes: Set<LoginPermission>
    let options: LoginManagerOptions
    
    // Flows of login process. A flow will be `nil` until it is running, so we could tell which one should take
    // responsibility to handle a url callback response.
    
    // LINE Client app auth flow captured by LINE universal link.
    var appUniversalLinkFlow: AppUniversalLinkFlow?
    // LINE Client app auth flow by LINE customize URL scheme.
    var appAuthSchemeFlow: AppAuthSchemeFlow?
    // Web login flow with Safari View Controller or Mobile Safari
    var webLoginFlow: WebLoginFlow? {
        didSet {
            // Dismiss safari view controller (if exists) when reset web login flow.
            if webLoginFlow == nil {
                oldValue?.dismiss()
            }
        }
    }
    
    // When we leave current app, we need to set the switching observer
    // to intercept cancel event (switching back but without a token url response)
    var appSwitchingObserver: AppSwitchingObserver?
    
    weak var presentingViewController: UIViewController?
    
    /// A UUID string of current process. Used to verify with server `state` response.
    let processID: String
    
    /// A string used to prevent replay attacks. This value is returned in an ID token.
    let tokenIDNonce: String?
    
    var otp: OneTimePassword!
    
    let onSucceed = Delegate<(token: AccessToken, response: LoginProcessURLResponse), Void>()
    let onFail = Delegate<Error, Void>()
    
    init(
        configuration: LoginConfiguration,
        scopes: Set<LoginPermission>,
        options: LoginManagerOptions,
        viewController: UIViewController?)
    {
        self.configuration = configuration
        self.processID = UUID().uuidString
        self.scopes = scopes
        self.options = options
        self.presentingViewController = viewController
        
        if scopes.contains(.openID) {
            tokenIDNonce = UUID().uuidString
        } else {
            tokenIDNonce = nil
        }
    }
    
    func start() {
        let otpRequest = PostOTPRequest(channelID: configuration.channelID)
        Session.shared.send(otpRequest) { result in
            switch result {
            case .success(let otp):
                self.otp = otp
                let parameters = FlowParameters(
                    channelID: self.configuration.channelID,
                    universalLinkURL: self.configuration.universalLinkURL,
                    scopes: self.scopes,
                    otp: otp,
                    processID: self.processID,
                    nonce: self.tokenIDNonce,
                    botPrompt: self.options.botPrompt)
                if self.options.contains(.onlyWebLogin) {
                    self.startWebLoginFlow(parameters)
                } else {
                    self.startAppUniversalLinkFlow(parameters)
                }
            case .failure(let error):
                self.invokeFailure(error: error)
            }
        }
    }
    
    /// Stops this login process. The login process will fail with a `.forceStopped` error.
    public func stop() {
        invokeFailure(error: LineSDKError.authorizeFailed(reason: .forceStopped))
    }
    
    // App switching observer should only work when external app switching happens during login process.
    // That means, we should not call this when login with SFSafariViewController.
    private func setupAppSwitchingObserver() {
        let observer = AppSwitchingObserver()
        observer.onTrigger.delegate(on: self) { (self, _) in
            // This trigger will be called during `UIApplicationDidBecomeActive` event.
            // There is some (UI or main thread) bugs on earlier iOS system that users cannot pop up an alert
            // at this time. So we wait for a while before report the cancel event to framework users.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.invokeFailure(error: LineSDKError.authorizeFailed(reason: .userCancelled))
            }
        }
        appSwitchingObserver = observer
        
        observer.startObserving()
    }
    
    private func startAppUniversalLinkFlow(_ parameters: FlowParameters) {
        let appUniversalLinkFlow = AppUniversalLinkFlow(parameter: parameters)
        appUniversalLinkFlow.onNext.delegate(on: self) { [unowned appUniversalLinkFlow] (self, started) in
            // Can handle app universal link flow. Store the flow for later resuming use.
            if started {
                self.setupAppSwitchingObserver()
                self.appUniversalLinkFlow = appUniversalLinkFlow
            } else {
                // LINE universal link handling failed for some reason. Fallback to LINE v2 auth
                if self.canUseLineAuthV2 {
                    self.startAppAuthSchemeFlow(parameters)
                } else {
                    // No lineauth2 scheme supported. Make user to choose
                    // install/upgrade LINE, or continue login with web.
                    // TODO: We need localize these text.
                    let mainActionTitle = self.canUseLineAuthV1 ? "Upgrade" : "Install"
                    
                    let actions: [UIAlertAction] = [
                        .init(title: mainActionTitle, style: .default) { _ in
                            UIApplication.shared.openLINEInAppStore()
                            self.setupAppSwitchingObserver()
                        },
                        .init(title: "Continue Login", style: .default) { _ in
                            self.startWebLoginFlow(parameters)
                        }
                    ]
                    let showed = UIAlertController.presentAlert(
                        in: self.presentingViewController,
                        title: "Earlier LINE app detected",
                        message: "You are using an earlier LINE app which does not support login with LINE client.",
                        actions: actions)
                    if !showed {
                        self.startWebLoginFlow(parameters)
                    }
                }
            }
        }
        
        appUniversalLinkFlow.start()
    }
    
    private func startAppAuthSchemeFlow(_ parameters: FlowParameters) {
        let appAuthSchemeFlow = AppAuthSchemeFlow(parameter: parameters)
        appAuthSchemeFlow.onNext.delegate(on: self) { [unowned appAuthSchemeFlow] (self, started) in
            if started {
                self.setupAppSwitchingObserver()
                self.appAuthSchemeFlow = appAuthSchemeFlow
            } else {
                self.startWebLoginFlow(parameters)
            }
        }
        
        appAuthSchemeFlow.start()
    }
    
    private func startWebLoginFlow(_ parameters: FlowParameters) {
        let webLoginFlow = WebLoginFlow(parameter: parameters)
        webLoginFlow.onNext.delegate(on: self) { [unowned webLoginFlow] (self, result) in
            switch result {
            case .safariViewController:
                self.webLoginFlow = webLoginFlow
            case .externalSafari:
                self.setupAppSwitchingObserver()
                self.webLoginFlow = webLoginFlow
            case .error(let error):
                // Starting login flow failed. There is no more
                // fallback methods or cannot find correct view controller.
                // This should normally not happen, but in case we throw an error out.
                self.invokeFailure(error: error)
            }
        }
        webLoginFlow.onCancel.delegate(on: self) { (self, _) in
            self.invokeFailure(error: LineSDKError.authorizeFailed(reason: .userCancelled))
        }
        
        webLoginFlow.start(in: presentingViewController)
    }
    
    func resumeOpenURL(url: URL, sourceApplication: String?) -> Bool {
        guard configuration.isValidUniversalLinkURL(url: url) ||
              configuration.isValidCustomizeURL(url: url) else
        {
            invokeFailure(error: LineSDKError.authorizeFailed(reason: .callbackURLSchemeNotMatching))
            return false
        }
        
        guard let sourceApp = sourceApplication, configuration.isValidSourceApplication(appID: sourceApp) else {
            invokeFailure(error: LineSDKError.authorizeFailed(reason: .invalidSourceApplication))
            return false
        }
        
        // It is the callback url we could handle, so the app switching observer should be invalidated.
        appSwitchingObserver?.valid = false
        
        do {
            let response = try LoginProcessURLResponse(from: url, validatingWith: processID)
            let tokenExchangeRequest = PostExchangeTokenRequest(
                channelID: configuration.channelID,
                code: response.requestToken,
                otpValue: otp.otp,
                redirectURI: Constant.thirdPartyAppReturnURL)
            Session.shared.send(tokenExchangeRequest) { tokenResult in
                switch tokenResult {
                case .success(let token): self.invokeSuccess(result: token, response: response)
                case .failure(let error): self.invokeFailure(error: error)
                }
            }
        } catch {
            invokeFailure(error: error)
        }
        
        return true
    }
    
    private var canUseLineAuthV1: Bool {
        return UIApplication.shared.canOpenURL(Constant.lineAppAuthURLv1)
    }
    
    private var canUseLineAuthV2: Bool {
        return UIApplication.shared.canOpenURL(Constant.lineAppAuthURLv2)
    }
    
    private func resetFlows() {
        appUniversalLinkFlow = nil
        appAuthSchemeFlow = nil
        webLoginFlow = nil
    }
    
    private func invokeSuccess(result: AccessToken, response: LoginProcessURLResponse) {
        resetFlows()
        onSucceed.call((result, response))
    }
    
    private func invokeFailure(error: Error) {
        resetFlows()
        onFail.call(error)
    }
}

class AppUniversalLinkFlow {
    
    let url: URL
    let onNext = Delegate<Bool, Void>()
    
    init(parameter: LoginProcess.FlowParameters) {
        let universalURLBase = URL(string: Constant.lineWebAuthUniversalURL)!
        url = universalURLBase.appendedLoginQuery(parameter)
    }
    
    func start() {
        if #available(iOS 10.0, *) {
            UIApplication.shared.open(url, options: [UIApplicationOpenURLOptionUniversalLinksOnly: true]) {
                opened in
                self.onNext.call(opened)
            }
        } else {
            self.onNext.call(false)
        }
    }
}

class AppAuthSchemeFlow {
    
    let url: URL
    let onNext = Delegate<Bool, Void>()
    
    init(parameter: LoginProcess.FlowParameters) {
        url = Constant.lineAppAuthURLv2.appendedURLSchemeQuery(parameter)
    }
    
    func start() {
        if #available(iOS 10.0, *) {
            UIApplication.shared.open(url, options: [:]) {
                opened in
                self.onNext.call(opened)
            }
        } else {
            let opened = UIApplication.shared.openURL(url)
            self.onNext.call(opened)
        }
    }
}

class WebLoginFlow: NSObject {
    
    enum Next {
        case safariViewController
        case externalSafari
        case error(Error)
    }
    
    let url: URL
    let onNext = Delegate<Next, Void>()
    let onCancel = Delegate<(), Void>()
    
    weak var safariViewController: UIViewController?
    
    init(parameter: LoginProcess.FlowParameters) {
        let webLoginURLBase = URL(string: Constant.lineWebAuthURL)!
         url = webLoginURLBase.appendedLoginQuery(parameter)
    }
    
    func start(in viewController: UIViewController?) {
        if #available(iOS 9.0, *) {
            let safariViewController = SFSafariViewController(url: url)
            safariViewController.modalPresentationStyle = .overFullScreen
            safariViewController.modalTransitionStyle = .coverVertical
            safariViewController.delegate = self
            
            self.safariViewController = safariViewController
            
            guard let presenting = viewController ?? .topMost else {
                self.onNext.call(.error(LineSDKError.authorizeFailed(reason: .malformedHierarchy)))
                return
            }
            presenting.present(safariViewController, animated: true) {
                self.onNext.call(.safariViewController)
            }
        } else {
            if #available(iOS 10.0, *) {
                UIApplication.shared.open(url, options: [:]) { opened in
                    if opened {
                        self.onNext.call(.externalSafari)
                    } else {
                        self.onNext.call(.error(LineSDKError.authorizeFailed(reason: .exhaustedLoginFlow)))
                    }
                }
            } else {
                let opened = UIApplication.shared.openURL(url)
                if opened {
                    self.onNext.call(.externalSafari)
                } else {
                    self.onNext.call(.error(LineSDKError.authorizeFailed(reason: .exhaustedLoginFlow)))
                }
            }
        }
    }
    
    func dismiss() {
        self.safariViewController?.dismiss(animated: true)
    }
}

@available(iOS 9.0, *)
extension WebLoginFlow: SFSafariViewControllerDelegate {
    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        // This happens when user tap "Cancel" in the SFSafariViewController.
        onCancel.call()
    }
}

// Helpers for creating urls for login process
extension String {
    
    static func returnUri(_ parameter: LoginProcess.FlowParameters) -> String {
        var universalLinkQuery = ""
        if let url = parameter.universalLinkURL {
            universalLinkQuery = "&optional_redirect_uri=\(url.absoluteString)"
        }
        
        var nonceQuery = ""
        if let nonce = parameter.nonce {
            nonceQuery = "&nonce=\(nonce)"
        }
        
        var botPromptQuery = ""
        if let botPrompt = parameter.botPrompt {
            botPromptQuery = "&bot_prompt=\(botPrompt.rawValue)"
        }
        
        let result =
            "/oauth2/v2.1/authorize/consent?response_type=code&sdk_ver=\(Constant.SDKVersion)" +
            "&client_id=\(parameter.channelID)&scope=\((parameter.scopes.map { $0.rawValue }).joined(separator: " "))" +
            "&otpId=\(parameter.otp.otpId)&state=\(parameter.processID)&redirect_uri=\(Constant.thirdPartyAppReturnURL)" +
            universalLinkQuery + nonceQuery + botPromptQuery
        
        return result
    }
}

extension URL {
    func appendedLoginQuery(_ flowParameters: LoginProcess.FlowParameters) -> URL {
        let returnUri = String.returnUri(flowParameters)
        let parameters: [String: Any] = [
            "returnUri": returnUri,
            "loginChannelId": flowParameters.channelID
        ]
        let encoder = URLQueryEncoder(parameters: parameters, allowed: .urlHostAllowed)
        return encoder.encoded(for: self)
    }
    
    func appendedURLSchemeQuery(_ flowParameters: LoginProcess.FlowParameters) -> URL {
        let returnUri = String.returnUri(flowParameters)
        let loginUrl =
            "\(Constant.lineWebAuthUniversalURL)?returnUri=\(returnUri)&loginChannelId=\(flowParameters.channelID)"
        let parameters = [
            "loginUrl": "\(loginUrl)"
        ]
        let encoder = URLQueryEncoder(parameters: parameters, allowed: .urlHostAllowed)
        return encoder.encoded(for: self)
    }
}

extension UIWindow {
    static func findKeyWindow() -> UIWindow? {
        if let window = UIApplication.shared.keyWindow, window.windowLevel == UIWindowLevelNormal {
            // A key window of main app exists, go ahead and use it
            return window
        }
        
        // Otherwise, try to find a normal level window
        let window = UIApplication.shared.windows.first { $0.windowLevel == UIWindowLevelNormal }
        guard let result = window else {
            Log.print("Cannot find a valid UIWindow at normal level. Current windows: \(UIApplication.shared.windows)")
            return nil
        }
        return result
    }
}

extension UIViewController {
    static var topMost: UIViewController? {
        let keyWindow = UIWindow.findKeyWindow()
        if let window = keyWindow, !window.isKeyWindow {
            Log.print("Cannot find a key window. Making window \(window) to keyWindow. " +
                "This might be not what you want, please check your window hierarchy.")
            window.makeKey()
        }
        guard var topViewController = keyWindow?.rootViewController else {
            Log.print("Cannot find a root view controller in current window. " +
                "Please check your view controller hierarchy.")
            return nil
        }
        
        while let currentTop = topViewController.presentedViewController {
            topViewController = currentTop
        }
        
        return topViewController
    }
}
