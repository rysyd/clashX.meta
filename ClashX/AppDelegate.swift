//
//  AppDelegate.swift
//  ClashX
//
//  Created by CYC on 2018/6/10.
//  Copyright © 2018年 yichengchen. All rights reserved.
//

import Alamofire
import Cocoa
import LetsMove
import RxCocoa
import RxSwift
import SwiftyJSON
import Yams
import PromiseKit

private let statusItemLengthWithSpeed: CGFloat = 72

private let MetaCoreMd5 = "WOSHIZIDONGSHENGCHENGDEA"

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!

    @IBOutlet var statusMenu: NSMenu!
    @IBOutlet var proxySettingMenuItem: NSMenuItem!
    @IBOutlet var autoStartMenuItem: NSMenuItem!

    @IBOutlet var proxyModeGlobalMenuItem: NSMenuItem!
    @IBOutlet var proxyModeDirectMenuItem: NSMenuItem!
    @IBOutlet var proxyModeRuleMenuItem: NSMenuItem!
    @IBOutlet var allowFromLanMenuItem: NSMenuItem!

    @IBOutlet var proxyModeMenuItem: NSMenuItem!
    @IBOutlet var showNetSpeedIndicatorMenuItem: NSMenuItem!
    @IBOutlet var dashboardMenuItem: NSMenuItem!
    @IBOutlet var separatorLineTop: NSMenuItem!
    @IBOutlet var sepatatorLineEndProxySelect: NSMenuItem!
    @IBOutlet var configSeparatorLine: NSMenuItem!
    @IBOutlet var logLevelMenuItem: NSMenuItem!
    @IBOutlet var httpPortMenuItem: NSMenuItem!
    @IBOutlet var socksPortMenuItem: NSMenuItem!
    @IBOutlet var apiPortMenuItem: NSMenuItem!
    @IBOutlet var ipMenuItem: NSMenuItem!
    @IBOutlet var remoteConfigAutoupdateMenuItem: NSMenuItem!
    @IBOutlet var showProxyGroupCurrentMenuItem: NSMenuItem!
    @IBOutlet var copyExportCommandMenuItem: NSMenuItem!
    @IBOutlet var copyExportCommandExternalMenuItem: NSMenuItem!
    @IBOutlet var experimentalMenu: NSMenu!
    @IBOutlet var externalControlSeparator: NSMenuItem!

    @IBOutlet var tunModeMenuItem: NSMenuItem!

    @IBOutlet var hideUnselecableMenuItem: NSMenuItem!
    @IBOutlet var proxyProvidersMenu: NSMenu!
    @IBOutlet var ruleProvidersMenu: NSMenu!
    @IBOutlet var proxyProvidersMenuItem: NSMenuItem!
    @IBOutlet var ruleProvidersMenuItem: NSMenuItem!
    @IBOutlet var snifferMenuItem: NSMenuItem!
    @IBOutlet var flushFakeipCacheMenuItem: NSMenuItem!

    @IBOutlet var useAlphaMetaMenuItem: NSMenuItem!
    @IBOutlet var alphaMetaVersionMenuItem: NSMenuItem!
    @IBOutlet var updateAlphaMetaMenuItem: NSMenuItem!

    var disposeBag = DisposeBag()
    var statusItemView: StatusItemView!
    var isSpeedTesting = false

    var runAfterConfigReload: (() -> Void)?

    var dashboardWindowController: ClashWebViewWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        // crash recorder
        failLaunchProtect()
        NSAppleEventManager.shared()
            .setEventHandler(self,
                             andSelector: #selector(handleURL(event:reply:)),
                             forEventClass: AEEventClass(kInternetEventClass),
                             andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.log("applicationDidFinishLaunching")
        Logger.log("Appversion: \(AppVersionUtil.currentVersion) \(AppVersionUtil.currentBuild)")
        ProcessInfo.processInfo.disableSuddenTermination()
        // setup menu item first
        statusItem = NSStatusBar.system.statusItem(withLength: statusItemLengthWithSpeed)
        statusItemView = StatusItemView.create(statusItem: statusItem)
        statusItemView.frame = CGRect(x: 0, y: 0, width: statusItemLengthWithSpeed, height: 22)
        statusMenu.delegate = self
        registCrashLogger()
        DispatchQueue.main.async {
            self.postFinishLaunching()
        }
    }

    func postFinishLaunching() {
        defer {
            statusItem.menu = statusMenu
        }
        setupStatusMenuItemData()
        AppVersionUtil.showUpgradeAlert()
        ICloudManager.shared.setup()
        setupExperimentalMenuItem()

        // install proxy helper
        _ = ClashResourceManager.check()
        PrivilegedHelperManager.shared.checkInstall()
        ConfigFileManager.copySampleConfigIfNeed()

        PFMoveToApplicationsFolderIfNecessary()

        // claer not existed selected model
        removeUnExistProxyGroups()
        setupData()
        runAfterConfigReload = { [weak self] in
            self?.selectAllowLanWithMenory()
        }

        updateLoggingLevel()

        // start watch config file change
        ConfigManager.watchCurrentConfigFile()

        RemoteConfigManager.shared.autoUpdateCheck()

        setupNetworkNotifier()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let group = DispatchGroup()
        var shouldWait = false

        PrivilegedHelperManager.shared.helper()?.stopMeta()

        if ConfigManager.shared.proxyPortAutoSet && !ConfigManager.shared.isProxySetByOtherVariable.value || NetworkChangeNotifier.isCurrentSystemSetToClash(looser: true) ||
            NetworkChangeNotifier.hasInterfaceProxySetToClash() {
            Logger.log("ClashX quit need clean proxy setting")
            shouldWait = true
            group.enter()

            SystemProxyManager.shared.disableProxy(forceDisable: ConfigManager.shared.isProxySetByOtherVariable.value) {
                group.leave()
            }
        }

        if !shouldWait {
            Logger.log("ClashX quit without clean waiting")
            return .terminateNow
        }

        if statusItem != nil, statusItem.menu != nil {
            statusItem.menu = nil
        }
        disposeBag = DisposeBag()

        DispatchQueue.global(qos: .default).async {
            let res = group.wait(timeout: .now() + 5)
            switch res {
            case .success:
                Logger.log("ClashX quit after clean up finish")
                DispatchQueue.main.asyncAfter(deadline: .now()+0.2) {
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
                DispatchQueue.global().asyncAfter(deadline: .now()+1) {
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            case .timedOut:
                Logger.log("ClashX quit after clean up timeout")
                DispatchQueue.main.async {
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
                DispatchQueue.global().asyncAfter(deadline: .now()+1) {
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            }
        }

        Logger.log("ClashX quit wait for clean up")
        return .terminateLater
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        UserDefaults.standard.set(0, forKey: "launch_fail_times")
        Logger.log("ClashX will terminate")
        if NetworkChangeNotifier.isCurrentSystemSetToClash(looser: true) ||
            NetworkChangeNotifier.hasInterfaceProxySetToClash() {
            Logger.log("Need Reset Proxy Setting again", level: .error)
            SystemProxyManager.shared.disableProxy()
        }
    }

    func setupStatusMenuItemData() {
        ConfigManager.shared
            .showNetSpeedIndicatorObservable
            .bind { [weak self] show in
                guard let self = self else { return }
                self.showNetSpeedIndicatorMenuItem.state = (show ?? true) ? .on : .off
                let statusItemLength: CGFloat = (show ?? true) ? statusItemLengthWithSpeed : 25
                self.statusItem.length = statusItemLength
                self.statusItemView.frame.size.width = statusItemLength
                self.statusItemView.showSpeedContainer(show: show ?? true)
            }.disposed(by: disposeBag)

        statusItemView.updateViewStatus(enableProxy: ConfigManager.shared.proxyPortAutoSet)

        LaunchAtLogin.shared
            .isEnableVirable
            .asObservable()
            .subscribe(onNext: { [weak self] enable in
                guard let self = self else { return }
                self.autoStartMenuItem.state = enable ? .on : .off
            }).disposed(by: disposeBag)

        remoteConfigAutoupdateMenuItem.state = RemoteConfigManager.autoUpdateEnable ? .on : .off

        hideUnselecableMenuItem.state = .init(rawValue: MenuItemFactory.hideUnselectable)
        useAlphaMetaMenuItem.state = MenuItemFactory.useAlphaCore ? .on : .off
    }

    func setupData() {
        ConfigManager.shared
            .showNetSpeedIndicatorObservable.skip(1)
            .bind {
                _ in
                ApiRequest.shared.resetTrafficStreamApi()
            }.disposed(by: disposeBag)

        Observable
            .merge([ConfigManager.shared.proxyPortAutoSetObservable,
                    ConfigManager.shared.isProxySetByOtherVariable.asObservable()])
            .map { _ -> NSControl.StateValue in
                if ConfigManager.shared.isProxySetByOtherVariable.value && ConfigManager.shared.proxyPortAutoSet {
                    return .mixed
                }
                return ConfigManager.shared.proxyPortAutoSet ? .on : .off
            }.distinctUntilChanged()
            .bind { [weak self] status in
                guard let self = self else { return }
                self.proxySettingMenuItem.state = status
            }.disposed(by: disposeBag)

        Observable
            .merge([ConfigManager.shared.proxyPortAutoSetObservable,
                    ConfigManager.shared.isTunModeVariable.asObservable(),
                    ConfigManager.shared.isProxySetByOtherVariable.asObservable()])
            .map { _ -> Bool in
                var status = NSControl.StateValue.mixed
                if ConfigManager.shared.isProxySetByOtherVariable.value && ConfigManager.shared.proxyPortAutoSet {

                } else {
                    status = ConfigManager.shared.proxyPortAutoSet ? .on : .off
                }
                return status == .on || ConfigManager.shared.isTunModeVariable.value
            }.distinctUntilChanged()
            .bind { [weak self] enable in
                guard let self = self else { return }
                self.statusItemView.updateViewStatus(enableProxy: enable)
            }.disposed(by: disposeBag)

        let configObservable = ConfigManager.shared
            .currentConfigVariable
            .asObservable()
        Observable.zip(configObservable, configObservable.skip(1))
            .filter { _, new in return new != nil }
            .bind { [weak self] old, config in
                guard let self = self, let config = config else { return }
                self.proxyModeDirectMenuItem.state = .off
                self.proxyModeGlobalMenuItem.state = .off
                self.proxyModeRuleMenuItem.state = .off

                switch config.mode {
                case .direct: self.proxyModeDirectMenuItem.state = .on
                case .global: self.proxyModeGlobalMenuItem.state = .on
                case .rule: self.proxyModeRuleMenuItem.state = .on
                }
                self.allowFromLanMenuItem.state = config.allowLan ? .on : .off

                self.proxyModeMenuItem.title = "\(NSLocalizedString("Proxy Mode", comment: "")) (\(config.mode.name))"

                if old?.usedHttpPort != config.usedHttpPort || old?.usedSocksPort != config.usedSocksPort {
                    Logger.log("port config updated,new: \(config.usedHttpPort),\(config.usedSocksPort)")
                    if ConfigManager.shared.proxyPortAutoSet {
                        SystemProxyManager.shared.enableProxy(port: config.usedHttpPort, socksPort: config.usedSocksPort)
                    }
                }

                self.httpPortMenuItem.title = "Http Port: \(config.usedHttpPort)"
                self.socksPortMenuItem.title = "Socks Port: \(config.usedSocksPort)"
                self.apiPortMenuItem.title = "Api Port: \(ConfigManager.shared.apiPort)"
                self.ipMenuItem.title = "IP: \(NetworkChangeNotifier.getPrimaryIPAddress() ?? "")"

                if RemoteControlManager.selectConfig == nil {
                    ClashStatusTool.checkPortConfig(cfg: config)
                }

                self.snifferMenuItem.state = config.sniffing ? .on : .off
                self.tunModeMenuItem.state = config.tun.enable ? .on : .off
                ConfigManager.shared.isTunModeVariable.accept(config.tun.enable)
            }.disposed(by: disposeBag)

        if !PrivilegedHelperManager.shared.isHelperCheckFinished.value {
            proxySettingMenuItem.target = nil
            PrivilegedHelperManager.shared.isHelperCheckFinished
                .filter({$0})
                .take(1)
                .observe(on: MainScheduler.instance)
                .subscribe { [weak self] _ in
                    guard let self = self else { return }
                    self.proxySettingMenuItem.target = self
                }.disposed(by: disposeBag)
        }

        // start proxy
        if !PrivilegedHelperManager.shared.isHelperCheckFinished.value {
            PrivilegedHelperManager.shared.isHelperCheckFinished
                .filter({$0})
                .take(1)
                .observe(on: MainScheduler.instance)
                .bind(onNext: { _ in
                    self.initMetaCore()
                    self.startProxy()
                }).disposed(by: disposeBag)
        } else {
            initMetaCore()
            startProxy()
        }
    }

    func setupSystemData() {
        if !PrivilegedHelperManager.shared.isHelperCheckFinished.value &&
            ConfigManager.shared.proxyPortAutoSet {
            PrivilegedHelperManager.shared.isHelperCheckFinished
                .filter({$0})
                .take(1)
                .take(while: {_ in ConfigManager.shared.proxyPortAutoSet})
                .observe(on: MainScheduler.instance)
                .bind(onNext: { _ in
                    SystemProxyManager.shared.enableProxy()
                }).disposed(by: disposeBag)
        } else if ConfigManager.shared.proxyPortAutoSet {
            SystemProxyManager.shared.enableProxy()
        }
    }

    func setupNetworkNotifier() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            NetworkChangeNotifier.start()
        }

        NotificationCenter
            .default
            .rx
            .notification(.systemNetworkStatusDidChange)
            .observe(on: MainScheduler.instance)
            .delay(.milliseconds(200), scheduler: MainScheduler.instance)
            .bind { _ in
                guard NetworkChangeNotifier.getPrimaryInterface() != nil else { return }
                let proxySetted = NetworkChangeNotifier.isCurrentSystemSetToClash()
                ConfigManager.shared.isProxySetByOtherVariable.accept(!proxySetted)
                if !proxySetted && ConfigManager.shared.proxyPortAutoSet {
                    let proxiesSetting = NetworkChangeNotifier.getRawProxySetting()
                    Logger.log("Proxy changed by other process!, current:\(proxiesSetting), is Interface Set: \(NetworkChangeNotifier.hasInterfaceProxySetToClash())", level: .warning)
                }
            }.disposed(by: disposeBag)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(resetProxySettingOnWakeupFromSleep),
            name: NSWorkspace.didWakeNotification, object: nil
        )

        NotificationCenter
            .default
            .rx
            .notification(.systemNetworkStatusIPUpdate).map({ _ in
                NetworkChangeNotifier.getPrimaryIPAddress(allowIPV6: false)
            })
            .startWith(NetworkChangeNotifier.getPrimaryIPAddress(allowIPV6: false))
            .distinctUntilChanged()
            .skip(1)
            .filter { $0 != nil }
            .observe(on: MainScheduler.instance)
            .debounce(.seconds(5), scheduler: MainScheduler.instance).bind { [weak self] _ in
                self?.healthCheckOnNetworkChange()
            }.disposed(by: disposeBag)

        ConfigManager.shared
            .isProxySetByOtherVariable
            .asObservable()
            .filter { _ in ConfigManager.shared.proxyPortAutoSet }
            .distinctUntilChanged()
            .filter { $0 }.bind { _ in
                let rawProxy = NetworkChangeNotifier.getRawProxySetting()
                Logger.log("proxy changed to no clashX setting: \(rawProxy)", level: .warning)
                NSUserNotificationCenter.default.postProxyChangeByOtherAppNotice()
            }.disposed(by: disposeBag)

        NotificationCenter
            .default
            .rx
            .notification(.systemNetworkStatusIPUpdate).map({ _ in
                NetworkChangeNotifier.getPrimaryIPAddress(allowIPV6: false)
            }).bind { [weak self] _ in
                if RemoteControlManager.selectConfig != nil {
                    self?.resetStreamApi()
                }
            }.disposed(by: disposeBag)
    }

    func updateProxyList(withMenus menus: [NSMenuItem]) {
        let startIndex = statusMenu.items.firstIndex(of: separatorLineTop)! + 1
        let endIndex = statusMenu.items.firstIndex(of: sepatatorLineEndProxySelect)!
        sepatatorLineEndProxySelect.isHidden = menus.count == 0
        for _ in 0..<endIndex - startIndex {
            statusMenu.removeItem(at: startIndex)
        }
        for each in menus {
            statusMenu.insertItem(each, at: startIndex)
        }
    }

    func updateConfigFiles() {
        guard let menu = configSeparatorLine.menu else { return }
        MenuItemFactory.generateSwitchConfigMenuItems {
            items in
            let lineIndex = menu.items.firstIndex(of: self.configSeparatorLine)!
            for _ in 0..<lineIndex {
                menu.removeItem(at: 0)
            }
            for item in items.reversed() {
                menu.insertItem(item, at: 0)
            }
        }
    }

    func updateLoggingLevel() {
        ApiRequest.updateLogLevel(level: ConfigManager.selectLoggingApiLevel)
        for item in logLevelMenuItem.submenu?.items ?? [] {
            item.state = item.title.lowercased() == ConfigManager.selectLoggingApiLevel.rawValue ? .on : .off
        }
        NotificationCenter.default.post(name: .reloadDashboard, object: nil)
    }

    func initMetaCore() {
        Logger.log("initClashCore")

        let corePath: String = {
            if let path = Paths.alphaCorePath()?.path,
               let v = testMetaCore(path) {
                updateAlphaVersion(v.version)
                if MenuItemFactory.useAlphaCore {
                    return path
                }
            } else {
                updateAlphaVersion(nil)
            }

            if Paths.defaultCorePath() == nil {
                if let p = Paths.defaultCoreGzPath(),
                   let data = try? Data(contentsOf: .init(fileURLWithPath: p)).gunzipped(),
                   var path = Bundle.main.resourcePath {
                    path += "/\(kDefauleMetaCoreName)"
                    do {
                        try data.write(to: URL(fileURLWithPath: path))
                    } catch let error {
                        Logger.log("\(error)", level: .error)
                        return "ERROR"
                    }
                } else {
                    return "ERROR"
                }
            }

            if let path = Paths.defaultCorePath(),
               testMetaCore(path) != nil,
               validateDefaultCore() {
                return path
            } else {
                return "ERROR"
            }
        }()

        if corePath == "ERROR" {
            let alert = NSAlert()
            alert.messageText = "Failure to verify the internal Meta Core.\nDo NOT replace core file in the resources folder."
            alert.alertStyle = .warning
            alert.addButton(withTitle: NSLocalizedString("Quit", comment: ""))
            alert.runModal()

            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        } else {
            RemoteConfigManager.shared.verifyConfigTask.setLaunchPath(corePath)
            PrivilegedHelperManager.shared.helper()?.initMetaCore(withPath: corePath)
            Logger.log("initClashCore finish")
        }
    }

    func testMetaCore(_ path: String) -> (version: String, date: Date?)? {
        guard FileManager.default.fileExists(atPath: path),
              chmodX(path) else {
            return nil
        }

        let proc = Process()
        proc.executableURL = .init(fileURLWithPath: path)
        proc.arguments = ["-v"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        do {
            try proc.run()
        } catch let error {
            Logger.log(error.localizedDescription)
            return nil
        }
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        guard proc.terminationStatus == 0,
              let out = String(data: data, encoding: .utf8) else {
            return nil
        }

        let outs = out.replacingOccurrences(of: "\n", with: "").split(separator: " ").map(String.init)

        guard outs.count == 13,
              outs[0] == "Clash",
              outs[1] == "Meta",
              outs[3] == "darwin" else {
            return nil
        }

        let version = outs[2]

        let dateString = [outs[7], outs[8], outs[9], outs[10], outs[12]].joined(separator: "-")
        let f = DateFormatter()
        f.dateFormat = "E-MMM-d-HH:mm:ss-yyyy"
        f.timeZone = .init(abbreviation: outs[11])
        let date = f.date(from: dateString)

        return (version: version, date: date)
    }

    func validateDefaultCore() -> Bool {
        guard let path = Paths.defaultCorePath() else { return false }
        #if DEBUG
            return true
        #endif
        let proc = Process()
        proc.executableURL = .init(fileURLWithPath: "/sbin/md5")
        proc.arguments = ["-q", path]
        let pipe = Pipe()
        proc.standardOutput = pipe

        try? proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard proc.terminationStatus == 0,
              let out = String(data: data, encoding: .utf8) else {
            return false
        }

        let md5 = out.replacingOccurrences(of: "\n", with: "")
        return md5 == MetaCoreMd5
    }

    func chmodX(_ path: String) -> Bool {
        let proc = Process()
        proc.executableURL = .init(fileURLWithPath: "/bin/chmod")
        proc.arguments = ["+x", path]
        do {
            try proc.run()
        } catch let error {
            Logger.log("chmod +x failed. \(error.localizedDescription)")
            return false
        }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    func syncConfig(completeHandler: (() -> Void)? = nil) {
        ApiRequest.requestConfig { config in
            ConfigManager.shared.currentConfig = config
            completeHandler?()
        }
    }

    func resetStreamApi() {
        ApiRequest.shared.delegate = self
        ApiRequest.shared.resetStreamApis()
    }

    func updateConfig(configName: String? = nil, showNotification: Bool = true, completeHandler: ((ErrorString?) -> Void)? = nil) {
        startProxy()
        guard ConfigManager.shared.isRunning else { return }

        let config = configName ?? ConfigManager.selectConfigName

        ClashProxy.cleanCache()

        ApiRequest.requestConfigUpdate(configName: config) {
            [weak self] err in
            guard let self = self else { return }

            defer {
                completeHandler?(err)
            }

            if let error = err {
                NSUserNotificationCenter.default
                    .postNotificationAlert(title: NSLocalizedString("Reload Config Fail", comment: ""),
                          info: error)
            } else {
                self.syncConfig()
                self.resetStreamApi()
                self.runAfterConfigReload?()
                self.runAfterConfigReload = nil
                if showNotification {
                    NSUserNotificationCenter.default
                        .post(title: NSLocalizedString("Reload Config Succeed", comment: ""),
                              info: NSLocalizedString("Success", comment: ""))
                }

                if let newConfigName = configName {
                    ConfigManager.selectConfigName = newConfigName
                }
                self.selectProxyGroupWithMemory()
                self.selectOutBoundModeWithMenory()
                MenuItemFactory.recreateProxyMenuItems()
                NotificationCenter.default.post(name: .reloadDashboard, object: nil)
            }
        }
    }

    func setupExperimentalMenuItem() {
        ConnectionManager.addCloseOptionMenuItem(&experimentalMenu)
//        ClashResourceManager.addUpdateMMDBMenuItem(&experimentalMenu)
        SystemProxyManager.shared.addDisableRestoreProxyMenuItem(&experimentalMenu)
        MenuItemFactory.addExperimentalMenuItem(&experimentalMenu)
        if WebPortalManager.hasWebProtal {
            WebPortalManager.shared.addWebProtalMenuItem(&statusMenu)
        }
        ICloudManager.shared.addEnableMenuItem(&experimentalMenu)
//        AutoUpgardeManager.shared.setup()
//        AutoUpgardeManager.shared.addChanelMenuItem(&experimentalMenu)
        updateExperimentalFeatureStatus()
        RemoteControlManager.setupMenuItem(separator: externalControlSeparator)
    }

    func updateExperimentalFeatureStatus() {
        showProxyGroupCurrentMenuItem.state = ConfigManager.shared.disableShowCurrentProxyInMenu ? .off : .on
    }

    @objc func resetProxySettingOnWakeupFromSleep() {
        guard !ConfigManager.shared.isProxySetByOtherVariable.value,
            ConfigManager.shared.proxyPortAutoSet else { return }
        guard NetworkChangeNotifier.getPrimaryInterface() != nil else { return }
        if !NetworkChangeNotifier.isCurrentSystemSetToClash() {
            let rawProxy = NetworkChangeNotifier.getRawProxySetting()
            Logger.log("Resting proxy setting, current:\(rawProxy)", level: .warning)
            SystemProxyManager.shared.disableProxy()
            SystemProxyManager.shared.enableProxy()
        }

        if RemoteControlManager.selectConfig != nil {
            resetStreamApi()
        }
    }

    @objc func healthCheckOnNetworkChange() {
        ApiRequest.getMergedProxyData {
            proxyResp in
            guard let proxyResp = proxyResp else {return}

            var providers = Set<ClashProxyName>()

            let groups = proxyResp.proxyGroups.filter({$0.type.isAutoGroup})
            for group in groups {
                group.all?.compactMap {
                    proxyResp.proxiesMap[$0]?.enclosingProvider?.name
                }.forEach {
                    providers.insert($0)
                }
            }

            for group in groups {
                Logger.log("Start auto health check for group \(group.name)")
                ApiRequest.healthCheck(proxy: group.name)
            }

            for provider in providers {
                Logger.log("Start auto health check for provider \(provider)")
                ApiRequest.healthCheck(proxy: provider)
            }
        }
    }
}

// MARK: Meta Core

extension AppDelegate {

    enum StartMetaError: Error {
        case configMissing
        case remoteConfigMissing
        case startMetaFailed(String)
        case helperNotFound
        case pushConfigFailed(String)
    }

    struct StartProxyResp: Codable {
        let externalController: String
        let secret: String
        let log: String?
    }

    func startProxy() {
        if ConfigManager.shared.isRunning { return }

        Logger.log("Trying start meta core")

        prepareConfigFile().then {
            self.generateInitConfig()
        }.then {
            self.startMeta($0)
        }.get { res in
            if let log = res.log {
                Logger.log("""
\n########  Clash Meta Start Log  #########
\(log)
########  END  #########
""", level: .info)
            }

            let port = res.externalController.components(separatedBy: ":").last ?? "9090"
            ConfigManager.shared.apiPort = port
            ConfigManager.shared.apiSecret = res.secret
            ConfigManager.shared.isRunning = true
            self.proxyModeMenuItem.isEnabled = true
            self.dashboardMenuItem.isEnabled = true
        }.then { _ in
            self.pushInitConfig()
        }.done {
            Logger.log("Init config file success.")
        }.catch { error in
            ConfigManager.shared.isRunning = false
            self.proxyModeMenuItem.isEnabled = false
            Logger.log("\(error)", level: .error)

            let unc = NSUserNotificationCenter.default

            switch error {
            case StartMetaError.configMissing:
                unc.postConfigErrorNotice(msg: "Can't find config.")
            case StartMetaError.remoteConfigMissing:
                unc.postConfigErrorNotice(msg: "Can't find remote config.")
            case StartMetaError.helperNotFound:
                unc.postMetaErrorNotice(msg: "Can't connect to helper.")
            case StartMetaError.startMetaFailed(let s):
                unc.postMetaErrorNotice(msg: s)
            case StartMetaError.pushConfigFailed(let s):
                unc.postConfigErrorNotice(msg: s)
            default:
                unc.postMetaErrorNotice(msg: "Unknown Error.")
            }
        }
    }

    func prepareConfigFile() -> Promise<()> {
        .init { resolver in
            let configName = ConfigManager.selectConfigName
            ApiRequest.findConfigPath(configName: configName) { path in
                guard let path = path else {
                    resolver.reject(StartMetaError.configMissing)
                    return
                }
                if !FileManager.default.fileExists(atPath: path) {
                    Logger.log("\(configName) not exists")
                    if let config = RemoteConfigManager.shared.configs.first(where: { $0.name == configName }) {
                        Logger.log("Try to download remote config \(configName)")
                        RemoteConfigManager.updateConfig(config: config) {
                            if let error = $0 {
                                Logger.log("Download remote config failed, \(error)")
                                resolver.reject(StartMetaError.remoteConfigMissing)
                            } else {
                                Logger.log("Download remote config success")
                                resolver.fulfill_()
                            }
                        }
                    } else {
                        if configName != "config" {
                            ConfigManager.selectConfigName = "config"
                        }

                        Logger.log("Try to copy default config")
                        ICloudManager.shared.setup()
                        ConfigFileManager.copySampleConfigIfNeed()
                        resolver.fulfill_()
                    }
                } else {
                    resolver.fulfill_()
                }
            }
        }
    }

    func generateInitConfig() -> Promise<ClashMetaConfig.Config> {
        Promise { resolver in
            ClashMetaConfig.generateInitConfig {
                var config = $0
                PrivilegedHelperManager.shared.helper {
                    resolver.reject(StartMetaError.helperNotFound)
                }?.getUsedPorts {
                    config.updatePorts($0 ?? "")
                    resolver.fulfill(config)
                }
            }
        }
    }

    func startMeta(_ config: ClashMetaConfig.Config) -> Promise<StartProxyResp> {
        .init { resolver in
            PrivilegedHelperManager.shared.helper {
                resolver.reject(StartMetaError.helperNotFound)
            }?.startMeta(withConfPath: kConfigFolderPath,
                         confFilePath: config.path) {
                if let string = $0 {
                    guard let jsonData = string.data(using: .utf8),
                          let res = try? JSONDecoder().decode(StartProxyResp.self, from: jsonData) else {
                        resolver.reject(StartMetaError.startMetaFailed(string))
                        return
                    }

                    resolver.fulfill(res)
                } else {
                    resolver.reject(StartMetaError.startMetaFailed($0 ?? "unknown error"))
                }
            }
        }
    }

    func pushInitConfig() -> Promise<()> {
        .init { resolver in
            ClashProxy.cleanCache()
            let configName = ConfigManager.selectConfigName
            Logger.log("Push init config file: \(configName)")
            ApiRequest.requestConfigUpdate(configName: configName) { err in
                if let error = err {
                    resolver.reject(StartMetaError.pushConfigFailed(error))
                } else {
                    self.syncConfig()
                    self.resetStreamApi()
                    self.runAfterConfigReload?()
                    self.runAfterConfigReload = nil
                    self.selectProxyGroupWithMemory()
                    MenuItemFactory.recreateProxyMenuItems()
                    NotificationCenter.default.post(name: .reloadDashboard, object: nil)
                    resolver.fulfill_()
                }
            }
        }
    }
}

// MARK: Main actions

extension AppDelegate {
    @IBAction func actionDashboard(_ sender: NSMenuItem) {
        if dashboardWindowController == nil {
            dashboardWindowController = ClashWebViewWindowController.create()
            dashboardWindowController?.onWindowClose = {
                [weak self] in
                self?.dashboardWindowController = nil
            }
        }
        dashboardWindowController?.showWindow(sender)
    }

    @IBAction func actionAllowFromLan(_ sender: NSMenuItem) {
        ApiRequest.updateAllowLan(allow: !ConfigManager.allowConnectFromLan) {
            [weak self] in
            guard let self = self else { return }
            self.syncConfig()
            ConfigManager.allowConnectFromLan = !ConfigManager.allowConnectFromLan
        }
    }

    @IBAction func actionStartAtLogin(_ sender: NSMenuItem) {
        LaunchAtLogin.shared.isEnabled = !LaunchAtLogin.shared.isEnabled
    }

    @IBAction func actionSwitchProxyMode(_ sender: NSMenuItem) {
        let mode: ClashProxyMode
        switch sender {
        case proxyModeGlobalMenuItem:
            mode = .global
        case proxyModeDirectMenuItem:
            mode = .direct
        case proxyModeRuleMenuItem:
            mode = .rule
        default:
            return
        }
        let config = ConfigManager.shared.currentConfig?.copy()
        config?.mode = mode
        ApiRequest.updateOutBoundMode(mode: mode) { _ in
            ConfigManager.shared.currentConfig = config
            ConfigManager.selectOutBoundMode = mode
            MenuItemFactory.recreateProxyMenuItems()
        }
    }

    @IBAction func actionShowNetSpeedIndicator(_ sender: NSMenuItem) {
        ConfigManager.shared.showNetSpeedIndicator = !(sender.state == .on)
    }

    @IBAction func actionSetSystemProxy(_ sender: Any) {
        var canSaveProxy = true
        if ConfigManager.shared.isProxySetByOtherVariable.value {
            // should reset proxy to clashx
            ConfigManager.shared.isProxySetByOtherVariable.accept(false)
            ConfigManager.shared.proxyPortAutoSet = true
            // clear then reset.
            canSaveProxy = false
            SystemProxyManager.shared.disableProxy(port: 0, socksPort: 0, forceDisable: true)
        } else {
            ConfigManager.shared.proxyPortAutoSet = !ConfigManager.shared.proxyPortAutoSet
        }

        if ConfigManager.shared.proxyPortAutoSet {
            if canSaveProxy {
                SystemProxyManager.shared.saveProxy()
            }
            SystemProxyManager.shared.enableProxy()
        } else {
            SystemProxyManager.shared.disableProxy()
        }
    }

    @IBAction func actionCopyExportCommand(_ sender: NSMenuItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let port = ConfigManager.shared.currentConfig?.usedHttpPort ?? 0
        let socksport = ConfigManager.shared.currentConfig?.usedSocksPort ?? 0
        let localhost = "127.0.0.1"
        let isLocalhostCopy = sender == copyExportCommandMenuItem
        let ip = isLocalhostCopy ? localhost :
            NetworkChangeNotifier.getPrimaryIPAddress() ?? localhost
        pasteboard.setString("export https_proxy=http://\(ip):\(port) http_proxy=http://\(ip):\(port) all_proxy=socks5://\(ip):\(socksport)", forType: .string)
    }

    @IBAction func actionSpeedTest(_ sender: Any) {
        if isSpeedTesting {
            NSUserNotificationCenter.default.postSpeedTestingNotice()
            return
        }
        NSUserNotificationCenter.default.postSpeedTestBeginNotice()

        isSpeedTesting = true

        ApiRequest.getMergedProxyData { [weak self] resp in
            let group = DispatchGroup()

            for (name, _) in resp?.enclosingProviderResp?.providers ?? [:] {
                group.enter()
                ApiRequest.healthCheck(proxy: name) {
                    group.leave()
                }
            }

            for p in resp?.proxiesMap["GLOBAL"]?.all ?? [] {
                group.enter()
                ApiRequest.getProxyDelay(proxyName: p) { _ in
                    group.leave()
                }
            }
            group.notify(queue: DispatchQueue.main) {
                NSUserNotificationCenter.default.postSpeedTestFinishNotice()
                self?.isSpeedTesting = false
            }
        }
    }

    @IBAction func actionQuit(_ sender: Any) {
        NSApplication.shared.terminate(self)
    }
}

// MARK: Streaming Info

extension AppDelegate: ApiRequestStreamDelegate {
    func didUpdateTraffic(up: Int, down: Int) {
        statusItemView.updateSpeedLabel(up: up, down: down)
    }

    func didGetLog(log: String, level: String) {
        Logger.log(log, level: ClashLogLevel(rawValue: level) ?? .unknow)
    }
}

// MARK: Help actions

extension AppDelegate {
    @IBAction func actionShowLog(_ sender: Any) {
        NSWorkspace.shared.openFile(Logger.shared.logFilePath())
    }
}

// MARK: Config actions

extension AppDelegate {
    @IBAction func openConfigFolder(_ sender: Any) {
        if ICloudManager.shared.isICloudEnable() {
            ICloudManager.shared.getUrl {
                url in
                if let url = url {
                    NSWorkspace.shared.open(url)
                }
            }
        } else {
            NSWorkspace.shared.openFile(kConfigFolderPath)
        }
    }

    @IBAction func actionUpdateConfig(_ sender: AnyObject) {
        updateConfig()
    }

    @IBAction func actionSetLogLevel(_ sender: NSMenuItem) {
        let level = ClashLogLevel(rawValue: sender.title.lowercased()) ?? .unknow
        ConfigManager.selectLoggingApiLevel = level
        updateLoggingLevel()
        resetStreamApi()
    }

    @IBAction func actionAutoUpdateRemoteConfig(_ sender: Any) {
        RemoteConfigManager.autoUpdateEnable = !RemoteConfigManager.autoUpdateEnable
        remoteConfigAutoupdateMenuItem.state = RemoteConfigManager.autoUpdateEnable ? .on : .off
    }

    @IBAction func actionUpdateRemoteConfig(_ sender: Any) {
        RemoteConfigManager.shared.updateCheck(ignoreTimeLimit: true, showNotification: true)
    }

    @IBAction func actionSetUpdateInterval(_ sender: Any) {
        RemoteConfigManager.showAdd()
    }

    @IBAction func actionUpdateProxyGroupMenu(_ sender: Any) {
        ConfigManager.shared.disableShowCurrentProxyInMenu = !ConfigManager.shared.disableShowCurrentProxyInMenu
        updateExperimentalFeatureStatus()
        MenuItemFactory.recreateProxyMenuItems()
    }

    @IBAction func actionSetBenchmarkUrl(_ sender: Any) {
        let alert = NSAlert()
        let textfiled = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 20))
        textfiled.stringValue = ConfigManager.shared.benchMarkUrl
        alert.messageText = NSLocalizedString("Benchmark", comment: "")
        alert.accessoryView = textfiled
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))

        if alert.runModal() == .alertFirstButtonReturn {
            if textfiled.stringValue.isUrlVaild() {
                ConfigManager.shared.benchMarkUrl = textfiled.stringValue
            } else {
                let err = NSAlert()
                err.messageText = NSLocalizedString("URL is not valid", comment: "")
                err.runModal()
            }
        }
    }
}

// MARK: Meta Menu

extension AppDelegate {
    @IBAction func tunMode(_ sender: NSMenuItem) {
        let nc = NSUserNotificationCenter.default
        guard let config = ApiRequest.shared.currentConfigContent else {
            nc.post(title: "Tun Mode", info: "Not found current config.")
            return
        }

        sender.isEnabled = false
        ApiRequest.requestConfig {
            guard let path = ClashMetaConfig.updateConfigTun(config, enable: !$0.tun.enable) else {
                sender.isEnabled = true
                nc.post(title: "Tun Mode", info: "Decode current config failed.")
                return
            }

            ApiRequest.requestConfigUpdate(configPath: path) { err in
                if let error = err {
                    nc.postNotificationAlert(title: NSLocalizedString("Reload Config Fail", comment: ""),
                              info: error)
                } else {
                    self.syncConfig()
                    self.resetStreamApi()
                    self.selectProxyGroupWithMemory()
                    self.selectOutBoundModeWithMenory()
                    MenuItemFactory.recreateProxyMenuItems()
                    NotificationCenter.default.post(name: .reloadDashboard, object: nil)
                }
                sender.isEnabled = true
            }
        }
    }

    @IBAction func hideUnselectable(_ sender: NSMenuItem) {
        var newState = NSControl.StateValue.off
        switch sender.state {
        case .off:
            newState = .mixed
        case .mixed:
            newState = .on
        case .on:
            newState = .off
        default:
            return
        }

        sender.state = newState
        MenuItemFactory.hideUnselectable = newState.rawValue
    }

    @IBAction func checkForUpdate(_ sender: NSMenuItem) {
        let unc = NSUserNotificationCenter.default
        AF.request("https://api.github.com/repos/MetaCubeX/ClashX.Meta/releases/latest").responseString {
            guard $0.error == nil,
                  let data = $0.data,
                  let tagName = try? JSON(data: data)["tag_name"].string else {
                unc.postUpdateNotice(msg: "Some thing failed.")
                return
            }

            if tagName != AppVersionUtil.currentVersion {
                let alert = NSAlert()
                alert.messageText = "Open github release page to download \(tagName)"
                alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
                alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(.init(string: "https://github.com/MetaCubeX/ClashX.Meta/releases/latest")!)
                }
            } else {
                unc.postUpdateNotice(msg: "No new release found.")
            }
        }
    }

    @IBAction func updateGEO(_ sender: NSMenuItem) {
        ApiRequest.updateGEO { _ in
            NSUserNotificationCenter.default.post(title: "Updating GEO Databases...", info: "Good luck to you  🙃")
        }
    }

    @IBAction func flushFakeipCache(_ sender: NSMenuItem) {
        ApiRequest.flushFakeipCache {
            NSUserNotificationCenter.default.post(title: "Flush fake-ip cache", info: $0 ? "Success" : "Failed")
        }
    }

    @IBAction func updateSniffing(_ sender: NSMenuItem) {
        let enable = sender.state != .on
        ApiRequest.updateSniffing(enable: enable) {
            sender.state = enable ? .on : .off
        }
    }

    @IBAction func useAlphaMeta(_ sender: NSMenuItem) {
        if UserDefaults.standard.object(forKey: "useAlphaCore") as? Bool == nil {
            let alert = NSAlert()
            alert.messageText = """
If you don't know what you're doing, never turn this switch on.
如果你不知道你在做什么, 请绝对不要打开这个开关.
Running Meta Core without any authentication under sudo privileges can have devastating consequences.
在sudo 权限下运行未经验证的 Meta 核心, 可能造成严重后果.
"""
            alert.alertStyle = .warning
            alert.addButton(withTitle: NSLocalizedString("Continue", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            if alert.runModal() != .alertFirstButtonReturn {
                return
            }
        }

        let use = sender.state != .on
        MenuItemFactory.useAlphaCore = use
        sender.state = use ? .on : .off
    }

    @IBAction func showAlphaInFinder(_ sender: NSMenuItem) {
        guard let u = Paths.alphaCorePath(),
              FileManager.default.fileExists(atPath: u.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([u])
    }

    @IBAction func updateAlphaMeta(_ sender: NSMenuItem) {
        guard let helperURL = Paths.alphaCorePath() else {
            return
        }
        sender.isEnabled = false
        struct ReleasesResp: Decodable {
            let assets: [Asset]
            struct Asset: Decodable {
                let name: String
                let downloadUrl: String
                let contentType: String
                let state: String

                enum CodingKeys: String, CodingKey {
                    case name,
                         state,
                         downloadUrl = "browser_download_url",
                         contentType = "content_type"
                }
            }
        }

        func GetMachineHardwareName() -> String? {
            var sysInfo = utsname()
            let retVal = uname(&sysInfo)

            guard retVal == EXIT_SUCCESS else { return nil }

            return String(cString: &sysInfo.machine.0, encoding: .utf8)
        }

        let assetName: String? = {
            switch GetMachineHardwareName() {
            case "x86_64":
                return "darwin-amd64"
            case "arm64":
                return "darwin-arm64"
            default:
                return nil
            }
        }()
        let fm = FileManager.default

        func dlResult(_ info: String) {
            sender.isEnabled = true
            NSUserNotificationCenter.default.post(title: "Clash Meta Core", info: info)
        }

        AF.request("https://api.github.com/repos/MetaCubeX/Clash.Meta/releases/tags/Prerelease-Alpha").responseDecodable(of: ReleasesResp.self) {
            guard let assets = $0.value?.assets,
                  let assetName = assetName,
                  let asset = assets.first(where: {
                      $0.name.contains(assetName) &&
                      $0.state == "uploaded" &&
                      $0.contentType == "application/gzip"
                  }) else {
                dlResult("Decode alpha release info failed")
                return
            }

            if let v = self.testMetaCore(helperURL.path),
               asset.name.contains(v.version) {
                dlResult("Not found update")
                return
            }

            self.updateAlphaVersion(nil)
            try? fm.removeItem(at: helperURL)

            AF.download(asset.downloadUrl).response {
                guard let gzPath = $0.fileURL?.path,
                      let contentData = fm.contents(atPath: gzPath)
                else {
                    dlResult("Download file failed")
                    return
                }
                do {
                    try fm.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
                    try contentData.gunzipped().write(to: helperURL)
                    guard let version = self.testMetaCore(helperURL.path)?.version else {
                        dlResult("Test downloaded file failed")
                        return
                    }
                    self.updateAlphaVersion(version)
                    dlResult("Version: \(version)")
                } catch let error {
                    dlResult("Something error \(error.localizedDescription)")
                }
            }
        }
    }

    func updateAlphaVersion(_ version: String?) {
        let enable = version != nil
        useAlphaMetaMenuItem.isEnabled = enable
        alphaMetaVersionMenuItem.isEnabled = enable
        if let v = version {
            let info = "Version: \(v)"
            alphaMetaVersionMenuItem.title = info
            updateAlphaMetaMenuItem.title = "Update Meta core"
        } else {
            alphaMetaVersionMenuItem.title = "Version: none"
            updateAlphaMetaMenuItem.title = "Download Meta core"
        }
    }
}

// MARK: crash hanlder

extension AppDelegate {
    func registCrashLogger() {
        /*
        #if DEBUG
            return
        #else
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                AppCenter.start(withAppSecret: "dce6e9a3-b6e3-4fd2-9f2d-35c767a99663", services: [
                    Analytics.self
                ])
            }

        #endif
         */
    }

    func failLaunchProtect() {
        #if DEBUG
            return
        #else
            UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": true])
            let x = UserDefaults.standard
            var launch_fail_times: Int = 0
            if let xx = x.object(forKey: "launch_fail_times") as? Int { launch_fail_times = xx }
            launch_fail_times += 1
            x.set(launch_fail_times, forKey: "launch_fail_times")
            if launch_fail_times > 3 {
                // 发生连续崩溃
                ConfigFileManager.backupAndRemoveConfigFile()
                try? FileManager.default.removeItem(atPath: kConfigFolderPath + "Country.mmdb")
                if let domain = Bundle.main.bundleIdentifier {
                    UserDefaults.standard.removePersistentDomain(forName: domain)
                    UserDefaults.standard.synchronize()
                }
                NSUserNotificationCenter.default.post(title: "Fail on launch protect", info: "You origin Config has been renamed", notiOnly: false)
            }
            DispatchQueue.global().asyncAfter(deadline: DispatchTime.now() + Double(Int64(5 * Double(NSEC_PER_SEC))) / Double(NSEC_PER_SEC), execute: {
                x.set(0, forKey: "launch_fail_times")
            })
        #endif
    }
}

// MARK: Memory

extension AppDelegate {
    func selectProxyGroupWithMemory() {
        let copy = [SavedProxyModel](ConfigManager.selectedProxyRecords)
        for item in copy {
            guard item.config == ConfigManager.selectConfigName else { continue }
            Logger.log("Auto selecting \(item.group) \(item.selected)", level: .debug)
            ApiRequest.updateProxyGroup(group: item.group, selectProxy: item.selected) { success in
                if !success {
                    ConfigManager.selectedProxyRecords.removeAll { model -> Bool in
                        return model.key == item.key
                    }
                }
            }
        }
    }

    func removeUnExistProxyGroups() {
        let action: (([String]) -> Void) = { list in
            let unexists = ConfigManager.selectedProxyRecords.filter {
                !list.contains($0.config)
            }
            ConfigManager.selectedProxyRecords.removeAll {
                unexists.contains($0)
            }
        }

        if ICloudManager.shared.isICloudEnable() {
            ICloudManager.shared.getConfigFilesList { list in
                action(list)
            }
        } else {
            let list = ConfigManager.getConfigFilesList()
            action(list)
        }
    }

    func selectOutBoundModeWithMenory() {
        ApiRequest.updateOutBoundMode(mode: ConfigManager.selectOutBoundMode) {
            [weak self] _ in
            ConnectionManager.closeAllConnection()
            self?.syncConfig()
        }
    }

    func selectAllowLanWithMenory() {
        ApiRequest.updateAllowLan(allow: ConfigManager.allowConnectFromLan) {
            [weak self] in
            self?.syncConfig()
        }
    }

    func hasMenuSelected() -> Bool {
        if #available(macOS 11, *) {
            return statusMenu.items.contains { $0.state == .on }
        } else {
            return true
        }
    }
}

// MARK: NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        MenuItemFactory.refreshExistingMenuItems()
        updateConfigFiles()
        syncConfig()
        NotificationCenter.default.post(name: .proxyMeneViewShowLeftPadding,
                                        object: nil,
                                        userInfo: ["show": hasMenuSelected()])
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        menu.items.forEach {
            ($0.view as? ProxyGroupMenuHighlightDelegate)?.highlight(item: item)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        menu.items.forEach {
            ($0.view as? ProxyGroupMenuHighlightDelegate)?.highlight(item: nil)
        }
    }
}

// MARK: URL Scheme

extension AppDelegate {
    @objc func handleURL(event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let url = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else {
            return
        }

        guard let components = URLComponents(string: url),
              let scheme = components.scheme,
              scheme.hasPrefix("clash"),
              let host = components.host
        else { return }

        if host == "install-config" {
            guard let url = components.queryItems?.first(where: { item in
                item.name == "url"
            })?.value else { return }

            var userInfo = ["url": url]
            if let name = components.queryItems?.first(where: { item in
                item.name == "name"
            })?.value {
                userInfo["name"] = name
            }

            remoteConfigAutoupdateMenuItem.menu?.performActionForItem(at: 0)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NotificationCenter.default.post(name: Notification.Name(rawValue: "didGetUrl"), object: nil, userInfo: userInfo)
            }
        } else if host == "update-config" {
          updateConfig()
        }
    }
}
