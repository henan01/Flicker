//
//  FinderExtensionRegistrar.swift
//  Flicker
//
//  确保本 App 内嵌的 Finder Sync 扩展被系统识别并启用。
//  多次本地/CI 构建会在 /tmp 等路径留下副本，pkd 可能优先加载旧副本导致菜单消失。
//

import Foundation
import os

enum FinderExtensionRegistrar {
    private static let logger = Logger(subsystem: "com.wangyanan.flicker", category: "ExtensionRegistrar")
    static let extensionBundleID = "com.wangyanan.flicker.extension"

    /// 当前运行中的 App 内嵌 appex 路径。
    static var embeddedExtensionURL: URL? {
        Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("FlickerExtension.appex", isDirectory: true)
    }

    private static let keyLastRegisteredPath = "lastRegisteredExtensionAppPath"
    private static let keyLastRegisteredVersion = "lastRegisteredExtensionAppVersion"

    /// 启动时检测：如果是初次运行、覆盖重装或升级，自动执行全量修复与访达刷新，实现开箱即用零操作！
    static func prepareOnLaunch() {
        SharedStore.ensureInitialConfigsExist()

        let currentPath = Bundle.main.bundlePath
        let currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        let defaults = UserDefaults.standard

        let lastPath = defaults.string(forKey: keyLastRegisteredPath)
        let lastVersion = defaults.string(forKey: keyLastRegisteredVersion)

        let isFreshInstallOrUpdate = (lastPath != currentPath || lastVersion != currentVersion)

        if isFreshInstallOrUpdate {
            logger.info("Fresh install or update detected. Performing automatic extension repair and Finder refresh...")
            performFullRepair(restartFinderOnSuccess: true)
            defaults.set(currentPath, forKey: keyLastRegisteredPath)
            defaults.set(currentVersion, forKey: keyLastRegisteredVersion)
        } else {
            // 普通启动：确保 pluginkit 处于激活状态，不中断常驻进程
            ensurePluginKitActive()
        }
    }

    /// 当前应用是否处于 App Translocation 隔离环境下运行。
    static var isAppTranslocated: Bool {
        Bundle.main.bundlePath.contains("/AppTranslocation/")
    }

    /// 重新向 pluginkit 注册本包扩展并设为启用。
    @discardableResult
    static func reregisterEmbeddedExtension() -> Bool {
        performFullRepair(restartFinderOnSuccess: false)
    }

    /// 执行全套重注册修复（包含选举清理、LaunchServices 登记与可选的访达重启）。
    @discardableResult
    static func performFullRepair(restartFinderOnSuccess: Bool = true) -> Bool {
        guard let url = embeddedExtensionURL, FileManager.default.fileExists(atPath: url.path) else {
            logger.error("embedded FlickerExtension.appex not found")
            return false
        }
        let path = url.path

        // 1. 先清除历史选举冲突
        _ = runPluginKit(arguments: ["-e", "ignore", "-i", extensionBundleID])
        // 2. 添加本包扩展
        let addOK = runPluginKit(arguments: ["-a", path])
        // 3. 用户选举启用
        let useOK = runPluginKit(arguments: ["-e", "use", "-i", extensionBundleID])
        // 4. 同步登记到 LaunchServices
        _ = runLsregister(arguments: ["-f", "-R", "-trusted", path])

        logger.info("performFullRepair appex add=\(addOK, privacy: .public) use=\(useOK, privacy: .public) path=\(path, privacy: .public)")

        // 5. 杀掉旧扩展常驻进程并重启 Finder，确保系统彻底重新加载新插件
        if addOK && useOK {
            reloadExtensionProcess()
            if restartFinderOnSuccess {
                restartFinder()
            }
        }

        return addOK && useOK
    }

    /// 幂等确保扩展处于 pluginkit 选举状态（不杀进程、不重启 Finder）
    private static func ensurePluginKitActive() {
        guard let url = embeddedExtensionURL, FileManager.default.fileExists(atPath: url.path) else { return }
        _ = runPluginKit(arguments: ["-a", url.path])
        _ = runPluginKit(arguments: ["-e", "use", "-i", extensionBundleID])
    }

    /// 重启 Finder（用于用户点击修复时确保访达重新载入扩展）
    static func restartFinder() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Finder"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// 终止当前驻留的 FlickerExtension 扩展进程（系统会在下次右键时自动拉起最新进程）。
    static func reloadExtensionProcess() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["FlickerExtension"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private static func runLsregister(arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func runPluginKit(arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            logger.error("pluginkit \(arguments.joined(separator: " "), privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
