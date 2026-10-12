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

    /// 启动时：迁移配置 + 注册/启用本包内的扩展。
    static func prepareOnLaunch() {
        // 触发旧 Application Support → 扩展 Container 的迁移。
        _ = SharedStore.sharedDirectoryURL
        reregisterEmbeddedExtension()
    }

    /// 重新向 pluginkit 注册本包扩展并设为启用。
    @discardableResult
    static func reregisterEmbeddedExtension() -> Bool {
        guard let url = embeddedExtensionURL, FileManager.default.fileExists(atPath: url.path) else {
            logger.error("embedded FlickerExtension.appex not found")
            return false
        }
        let path = url.path
        // 先添加（幂等），再用户选举为 use。
        let addOK = runPluginKit(arguments: ["-a", path])
        let useOK = runPluginKit(arguments: ["-e", "use", "-i", extensionBundleID])
        logger.info("reregister appex add=\(addOK, privacy: .public) use=\(useOK, privacy: .public) path=\(path, privacy: .public)")
        return addOK && useOK
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
