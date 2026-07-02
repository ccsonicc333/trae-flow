import AppKit
import Foundation

/// 通过 AppleScript 查询/控制具体播放器。
///
/// 支持的播放器：Apple Music (`com.apple.Music`)、Spotify (`com.spotify.client`)、
/// 网易云音乐 (`com.netease.163music`)、QQ音乐 (`com.tencent.QQMusic`)。
///
/// AppleScript 受系统「辅助功能/自动化」权限控制，首次运行时会弹出授权提示。
/// 未授权时返回 nil。由于查询的是具体应用，无需 MediaRemote 的系统级权限。
///
/// 调试：打开 Console.app，过滤 `AppleScriptPlayerSource`，可看到每个播放器的
/// 查询结果、错误码和错误信息。
@MainActor
final class AppleScriptPlayerSource: PlayerSource {
    var name: String { "AppleScript" }

    /// 轮询式数据源，流式回调保持 nil
    var onNowPlayingUpdate: ((NowPlayingInfo) -> Void)?

    /// 播放器配置：bundle ID 候选列表 + 是否支持标准 `current track` 术语
    private struct PlayerConfig {
        let displayName: String
        let bundleIDCandidates: [String]
        /// 是否使用标准 `current track` / `player state` 术语（Apple Music / Spotify）
        let usesStandardDictionary: Bool
        /// 非标准播放器中获取标题的 AppleScript 表达式（若 usesStandardDictionary 为 false）
        let titleExpression: String?
    }

    /// 按优先级排序的播放器配置
    private static let playerConfigs: [PlayerConfig] = [
        PlayerConfig(displayName: "Spotify",
                     bundleIDCandidates: ["com.spotify.client"],
                     usesStandardDictionary: true,
                     titleExpression: nil),
        PlayerConfig(displayName: "Apple Music",
                     bundleIDCandidates: ["com.apple.Music", "com.apple.iTunes"],
                     usesStandardDictionary: true,
                     titleExpression: nil),
        PlayerConfig(displayName: "网易云音乐",
                     bundleIDCandidates: [
                         "com.netease.163music",      // Mac App Store / 官网旧版
                         "com.netease.163music.mac",  // 官网新版常见
                         "163Music",                  // 纯 bundle name
                         "com.netease.cloudmusic"     // 其他可能
                     ],
                     usesStandardDictionary: false,
                     titleExpression: "name of current track"),
        PlayerConfig(displayName: "QQ音乐",
                     bundleIDCandidates: [
                         "com.tencent.QQMusic",        // 旧版
                         "com.tencent.QQMusicMac",     // Mac 版常见
                         "QQMusicMac",                 // 纯 bundle name
                         "com.tencent.qqmusicmac"      // 小写变体
                     ],
                     usesStandardDictionary: false,
                     titleExpression: "name of current track")
    ]

    /// 缓存每个配置实际找到的运行中 bundle ID
    private var resolvedBundleIDs: [String: String] = [:]

    /// 记录最近一次查询到正在播放的播放器，下次优先查询
    private var lastPlayingConfigDisplayName: String?

    func fetchNowPlaying(completion: @escaping (NowPlayingInfo?) -> Void) {
        // 1. 如果上次查询到正在播放的播放器，优先查询它
        if let lastName = lastPlayingConfigDisplayName,
           let config = Self.playerConfigs.first(where: { $0.displayName == lastName }),
           let info = fetch(from: config) {
            completion(info)
            return
        }

        // 2. 遍历所有配置，找第一个正在播放的
        for config in Self.playerConfigs {
            if let info = fetch(from: config) {
                lastPlayingConfigDisplayName = config.displayName
                completion(info)
                return
            }
        }

        // 3. 都没有
        lastPlayingConfigDisplayName = nil
        completion(nil)
    }

    private func fetch(from config: PlayerConfig) -> NowPlayingInfo? {
        // 解析实际 bundle ID（候选列表中第一个运行中的）
        let bundleID: String
        if let cached = resolvedBundleIDs[config.displayName],
           NSRunningApplication.runningApplications(withBundleIdentifier: cached).contains(where: { !$0.isTerminated }) {
            bundleID = cached
        } else {
            guard let found = config.bundleIDCandidates.first(where: {
                NSRunningApplication.runningApplications(withBundleIdentifier: $0).contains { !$0.isTerminated }
            }) else {
                return nil
            }
            resolvedBundleIDs[config.displayName] = found
            bundleID = found
        }

        // 构造脚本
        let script: String
        if config.usesStandardDictionary {
            script = standardScript(bundleID: bundleID)
        } else {
            script = fallbackScript(bundleID: bundleID, titleExpression: config.titleExpression ?? "name of current track")
        }

        var errorInfo: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            NSLog("[AppleScriptPlayerSource] \(config.displayName)(\(bundleID)) NSAppleScript 创建失败")
            return nil
        }
        let result = appleScript.executeAndReturnError(&errorInfo)
        NSLog("[AppleScriptPlayerSource] \(config.displayName) 生成脚本: \(script)")

        if let error = errorInfo {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            let message = error[NSAppleScript.errorMessage] as? String ?? "unknown"
            if code == -1743 {
                NSLog("[AppleScriptPlayerSource] \(config.displayName)(\(bundleID)) 自动化权限被拒绝 (-1743)")
            } else {
                NSLog("[AppleScriptPlayerSource] \(config.displayName)(\(bundleID)) AppleScript 错误 [\(code)]: \(message)")
            }
            return nil
        }

        let text = result.stringValue ?? ""
        let parts = text.components(separatedBy: "\n")
        NSLog("[AppleScriptPlayerSource] \(config.displayName)(\(bundleID)) 返回: \(text.prefix(200))")

        guard parts.count >= 6,
              !parts[0].isEmpty,
              parts[5] == "playing" || parts[5] == "paused" else {
            // 播放器运行但不在播放状态，或返回格式不符
            return nil
        }

        let isPlaying = (parts[5] == "playing")
        guard isPlaying else { return nil }

        return NowPlayingInfo(
            title: parts[0],
            artist: parts[1].isEmpty ? nil : parts[1],
            album: parts[2].isEmpty ? nil : parts[2],
            artwork: nil,
            duration: TimeInterval(parts[3]) ?? 0,
            elapsed: TimeInterval(parts[4]) ?? 0,
            isPlaying: isPlaying,
            source: config.displayName,
            receivedAt: Date()
        )
    }

    /// Apple Music / Spotify 标准脚本
    private func standardScript(bundleID: String) -> String {
        // `linefeed` 是 AppleScript 全局常量，不能在 `tell application` 块内解析为目标应用术语，
        // 因此放在块外先赋值给 `nl`。
        """
        set nl to linefeed
        tell application id "\(bundleID)"
            if player state is playing then
                return (name of current track) & nl & (artist of current track) & nl & (album of current track) & nl & (duration of current track) & nl & (player position) & nl & "playing"
            else if player state is paused then
                return (name of current track) & nl & (artist of current track) & nl & (album of current track) & nl & (duration of current track) & nl & (player position) & nl & "paused"
            end if
        end tell
        return ""
        """
    }

    /// 网易云/QQ音乐等非标准字典的保守脚本：尝试 `name of current track` 和 `player state`
    private func fallbackScript(bundleID: String, titleExpression: String) -> String {
        """
        set nl to linefeed
        tell application id "\(bundleID)"
            try
                set ps to player state
                set tn to \(titleExpression)
                if ps is playing then
                    return tn & nl & "" & nl & "" & nl & "0" & nl & "0" & nl & "playing"
                else if ps is paused then
                    return tn & nl & "" & nl & "" & nl & "0" & nl & "0" & nl & "paused"
                end if
            on error errMsg number errNum
                return "ERROR:" & errNum & ":" & errMsg
            end try
        end tell
        return ""
        """
    }

    func sendCommand(_ command: PlayerCommand) -> Bool {
        guard let configName = lastPlayingConfigDisplayName,
              let config = Self.playerConfigs.first(where: { $0.displayName == configName }),
              let bundleID = resolvedBundleIDs[config.displayName] else {
            // 找不到最后播放的播放器时，尝试第一个运行中的可控制播放器
            for cfg in Self.playerConfigs where cfg.usesStandardDictionary {
                if let bid = cfg.bundleIDCandidates.first(where: {
                    NSRunningApplication.runningApplications(withBundleIdentifier: $0).contains { !$0.isTerminated }
                }) {
                    return sendCommand(command, bundleID: bid, config: cfg)
                }
            }
            return false
        }
        return sendCommand(command, bundleID: bundleID, config: config)
    }

    private func sendCommand(_ command: PlayerCommand, bundleID: String, config: PlayerConfig) -> Bool {
        let script: String
        if config.usesStandardDictionary {
            switch command {
            case .play:
                script = "tell application id \"\(bundleID)\" to play"
            case .pause:
                script = "tell application id \"\(bundleID)\" to pause"
            case .togglePlayPause:
                script = "tell application id \"\(bundleID)\" to playpause"
            case .nextTrack:
                script = "tell application id \"\(bundleID)\" to next track"
            case .previousTrack:
                script = "tell application id \"\(bundleID)\" to previous track"
            case .seek(let position):
                script = "tell application id \"\(bundleID)\" to set player position to \(position)"
            }
        } else {
            // 网易云/QQ音乐控制命令通常也支持 play/pause/next track/previous track
            let verb: String
            switch command {
            case .play: verb = "play"
            case .pause: verb = "pause"
            case .togglePlayPause: verb = "playpause"
            case .nextTrack: verb = "next track"
            case .previousTrack: verb = "previous track"
            case .seek:
                // 非标准字典播放器暂不支持精确 seek
                return false
            }
            script = """
            tell application id "\(bundleID)"
                try
                    \(verb)
                on error
                    return "ERROR"
                end try
            end tell
            """
        }

        var errorInfo: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else { return false }
        appleScript.executeAndReturnError(&errorInfo)
        if let error = errorInfo {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            NSLog("[AppleScriptPlayerSource] 控制命令 \(command) 发送到 \(config.displayName) 失败 [\(code)]")
        }
        return errorInfo == nil
    }
}
