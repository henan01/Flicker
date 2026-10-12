//
//  SharedStore.swift
//  Flicker
//
//  Shared between the container app and the Finder Sync extension.
//  Reads/writes the configured AppEntry list via a fixed file path.
//

import Foundation
import os

/// 配置读写。App 与扩展共享同一套 JSON。
///
/// 共享目录选在 **Finder Sync 扩展自己的 Container** 内：
/// `~/Library/Containers/com.wangyanan.flicker.extension/Data/Library/Application Support/Flicker/`
///
/// 这样：
/// - 扩展沙盒内始终可读可写，不依赖 temporary-exception / 写死用户名
/// - 主 App（未沙盒）直接写入该目录，设置保存后下次右键即可生效，无需重启 Finder
///
/// 仍会从旧路径 `~/Library/Application Support/Flicker/` 做一次性迁移。
enum SharedStore {
    static let configFileName = "app_entries.json"
    static let menuSettingsFileName = "menu_settings.json"
    static let newFileSettingsFileName = "new_file_settings.json"
    static let appSupportSubdir = "Flicker"
    static let extensionBundleID = "com.wangyanan.flicker.extension"
    private static let logger = Logger(subsystem: "com.wangyanan.flicker", category: "SharedStore")
    // Migration is idempotent (compares mtimes); flag only avoids repeat work in-process.
    nonisolated(unsafe) private static var didMigrateLegacy = false

    /// 真实用户主目录（不受沙盒容器重定向影响）。
    private static var realHomeDirectory: URL? {
        guard let pw = getpwuid(getuid()) else { return nil }
        return URL(fileURLWithFileSystemRepresentation: pw.pointee.pw_dir, isDirectory: true, relativeTo: nil)
    }

    private static func ensureDirectory(_ dir: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// 旧版共享目录（主 App 曾写入这里；扩展沙盒读不到）。
    private static var legacySharedDirectoryURL: URL? {
        guard let home = realHomeDirectory else { return nil }
        return home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(appSupportSubdir, isDirectory: true)
    }

    /// 扩展 Container 内的 Application Support/Flicker。
    private static var extensionContainerSharedDirectoryURL: URL? {
        // 扩展进程内：标准 API 已指向自己的 Container。
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
           appSupport.path.contains("/Containers/\(extensionBundleID)/") {
            let dir = appSupport.appendingPathComponent(appSupportSubdir, isDirectory: true)
            ensureDirectory(dir)
            return dir
        }

        // 主 App 或其他非沙盒进程：按约定路径写入扩展 Container。
        guard let home = realHomeDirectory else { return nil }
        let dir = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent(extensionBundleID, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(appSupportSubdir, isDirectory: true)
        ensureDirectory(dir)
        return dir
    }

    /// 把旧 Application Support 配置迁到扩展 Container（只尝试一次/进程）。
    private static func migrateLegacyIfNeeded(to directory: URL) {
        guard !didMigrateLegacy else { return }
        didMigrateLegacy = true
        guard let legacy = legacySharedDirectoryURL else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path) else { return }

        let names = [configFileName, menuSettingsFileName, newFileSettingsFileName]
        for name in names {
            let src = legacy.appendingPathComponent(name, isDirectory: false)
            let dst = directory.appendingPathComponent(name, isDirectory: false)
            guard fm.fileExists(atPath: src.path) else { continue }
            // 目标已有更新文件则不覆盖。
            if fm.fileExists(atPath: dst.path),
               let srcDate = (try? src.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               let dstDate = (try? dst.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               dstDate >= srcDate {
                continue
            }
            do {
                if fm.fileExists(atPath: dst.path) {
                    try fm.removeItem(at: dst)
                }
                try fm.copyItem(at: src, to: dst)
                logger.info("migrated \(name, privacy: .public) to extension container")
            } catch {
                logger.error("migrate \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 共享目录 URL（扩展 Container 内，双方均可访问）。
    static var sharedDirectoryURL: URL? {
        guard let dir = extensionContainerSharedDirectoryURL else { return nil }
        migrateLegacyIfNeeded(to: dir)
        return dir
    }

    /// 共享配置文件 URL。
    static var configFileURL: URL? {
        sharedDirectoryURL?.appendingPathComponent(configFileName, isDirectory: false)
    }

    /// 菜单设置文件 URL。
    static var menuSettingsFileURL: URL? {
        sharedDirectoryURL?.appendingPathComponent(menuSettingsFileName, isDirectory: false)
    }

    /// 新建文件设置文件 URL。
    static var newFileSettingsFileURL: URL? {
        sharedDirectoryURL?.appendingPathComponent(newFileSettingsFileName, isDirectory: false)
    }

    /// 读取应用列表。
    static func loadEntries() -> [AppEntry] {
        guard let url = configFileURL,
              let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try JSONDecoder().decode([AppEntry].self, from: data)
        } catch {
            logger.error("loadEntries decode failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// 写入应用列表。
    @discardableResult
    static func saveEntries(_ entries: [AppEntry]) -> Bool {
        guard let url = configFileURL else { return false }
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: .atomic)
            // 同步一份到旧路径，方便用户备份/查看。
            mirrorToLegacy(data: data, fileName: configFileName)
            return true
        } catch {
            logger.error("saveEntries failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Menu Settings

    /// 读取菜单设置。文件不存在时返回默认值。
    static func loadMenuSettings() -> MenuSettings {
        guard let url = menuSettingsFileURL,
              let data = try? Data(contentsOf: url) else { return .defaults }
        do {
            return try JSONDecoder().decode(MenuSettings.self, from: data)
        } catch {
            logger.error("loadMenuSettings decode failed: \(error.localizedDescription, privacy: .public)")
            return .defaults
        }
    }

    /// 写入菜单设置。
    @discardableResult
    static func saveMenuSettings(_ settings: MenuSettings) -> Bool {
        guard let url = menuSettingsFileURL else { return false }
        do {
            let data = try JSONEncoder().encode(settings)
            try data.write(to: url, options: .atomic)
            mirrorToLegacy(data: data, fileName: menuSettingsFileName)
            return true
        } catch {
            logger.error("saveMenuSettings failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - New File Settings

    /// 读取新建文件设置。文件不存在时返回默认值。
    static func loadNewFileSettings() -> NewFileSettings {
        guard let url = newFileSettingsFileURL,
              let data = try? Data(contentsOf: url) else { return .defaults }
        do {
            return try JSONDecoder().decode(NewFileSettings.self, from: data)
        } catch {
            logger.error("loadNewFileSettings decode failed: \(error.localizedDescription, privacy: .public)")
            return .defaults
        }
    }

    /// 写入新建文件设置。
    @discardableResult
    static func saveNewFileSettings(_ settings: NewFileSettings) -> Bool {
        guard let url = newFileSettingsFileURL else { return false }
        do {
            let data = try JSONEncoder().encode(settings)
            try data.write(to: url, options: .atomic)
            mirrorToLegacy(data: data, fileName: newFileSettingsFileName)
            return true
        } catch {
            logger.error("saveNewFileSettings failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// 主 App 保存时顺便写回旧路径，避免外部工具/用户仍只看 Application Support。
    private static func mirrorToLegacy(data: Data, fileName: String) {
        guard let legacyDir = legacySharedDirectoryURL else { return }
        ensureDirectory(legacyDir)
        let url = legacyDir.appendingPathComponent(fileName, isDirectory: false)
        try? data.write(to: url, options: .atomic)
    }
}
