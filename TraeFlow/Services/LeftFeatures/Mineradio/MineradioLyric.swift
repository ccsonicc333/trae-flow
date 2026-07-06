import Foundation

/// Spec: mineradio-bridge-compat-layer — Mineradio 歌词数据模型与 LRC 解析器。
///
/// 由 `MineradioBridgeCoordinator` 在收到播放状态后调用 `/api/lyric` 获取 LRC 文本，
/// 解析为按时间排序的行数组，再根据 `elapsed` 定位当前行显示到 Flow 岛紧凑态。

/// 单行歌词：时间戳 + 文本
struct MineradioLyricLine: Identifiable, Equatable {
    /// 行起始时间（秒）
    let time: TimeInterval
    /// 歌词文本
    let text: String

    var id: Double { time }
}

/// 播放状态：由注入脚本 post 的播放信息
struct MineradioPlaybackState: Equatable {
    var elapsed: TimeInterval
    var duration: TimeInterval
    var isPlaying: Bool
    /// 当前歌曲 ID（网易云 netease id；其他平台暂不支持歌词）
    var songId: String?
    /// 播放平台标识："netease" / "qq" / "kugou"
    var provider: String?
    /// 歌曲标题（best-effort 从 DOM 提取）
    var title: String?
    /// 艺术家（best-effort 从 DOM 提取）
    var artist: String?
    /// 专辑封面 URL（best-effort 从 DOM img src 提取）
    var coverURL: String?
}

/// LRC 解析器：将 `[mm:ss.xx]text` 格式的 LRC 文本解析为按时间排序的行数组
enum MineradioLyricParser {
    /// 解析 LRC 文本
    /// - 支持 `[mm:ss.xx]`、`[mm:ss.xxx]`、`[mm:ss]` 三种精度
    /// - 一行可含多个时间戳（如 `[00:01.00][00:15.00]歌词`），每个时间戳生成一行
    /// - 无时间戳的行被忽略
    static func parse(_ lrc: String) -> [MineradioLyricLine] {
        guard !lrc.isEmpty else { return [] }
        var lines: [MineradioLyricLine] = []
        // 正则：[mm:ss(.xx)?]  捕获组 1=分 2=秒 3=小数部分（可选）
        let pattern = #"\[(\d{1,2}):(\d{1,2})(?:\.(\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        for rawLine in lrc.components(separatedBy: .newlines) {
            let nsLine = rawLine as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)
            let matches = regex.matches(in: rawLine, range: fullRange)
            if matches.isEmpty { continue }

            // 取最后一个时间戳后的文本作为歌词内容
            guard let lastMatch = matches.last else { continue }
            let textStart = lastMatch.range.location + lastMatch.range.length
            let text = textStart < nsLine.length
                ? nsLine.substring(from: textStart).trimmingCharacters(in: .whitespaces)
                : ""

            for match in matches {
                let mm = Int(nsLine.substring(with: match.range(at: 1))) ?? 0
                let ss = Int(nsLine.substring(with: match.range(at: 2))) ?? 0
                let msStr: String
                if match.range(at: 3).location == NSNotFound {
                    msStr = ""
                } else {
                    msStr = nsLine.substring(with: match.range(at: 3))
                }
                let ms = normalizeMilliseconds(msStr)
                let time = TimeInterval(mm * 60 + ss) + ms / 1000.0
                lines.append(MineradioLyricLine(time: time, text: text))
            }
        }

        lines.sort { $0.time < $1.time }
        return lines
    }

    /// 将 1/2/3 位小数归一化为毫秒整数值
    private static func normalizeMilliseconds(_ s: String) -> Double {
        guard let n = Int(s), !s.isEmpty else { return 0 }
        switch s.count {
        case 1: return Double(n) * 100
        case 2: return Double(n) * 10
        case 3: return Double(n)
        default: return Double(n)
        }
    }

    /// 根据 elapsed 时间找到当前应显示的歌词行（二分查找）
    /// - 返回最后一个 `time <= elapsed` 的行；若 elapsed 早于首行则返回 nil
    static func currentLine(in lines: [MineradioLyricLine], at elapsed: TimeInterval) -> MineradioLyricLine? {
        guard !lines.isEmpty else { return nil }
        if elapsed < lines[0].time { return nil }
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].time <= elapsed { lo = mid } else { hi = mid - 1 }
        }
        return lines[lo]
    }

    /// Spec: 计算当前行的演唱进度 0...1，用于紧凑态 karaoke 高亮动画。
    /// - `line`: 当前行（`currentLine` 的返回值）
    /// - `lines`: 完整歌词行数组（用于找下一行时间戳）
    /// - `elapsed`: 当前播放时间
    /// - 返回值：`(elapsed - line.time) / (nextLine.time - line.time)`，clamp 到 0...1
    ///   最后一行（无下一行）按固定 4 秒线性推进；超过下一行时间返回 1
    static func lineProgress(line: MineradioLyricLine, in lines: [MineradioLyricLine], at elapsed: TimeInterval) -> Double {
        guard let idx = lines.firstIndex(where: { $0.time == line.time && $0.text == line.text }) else { return 0 }
        let lineStart = line.time
        let lineEnd: TimeInterval
        if idx + 1 < lines.count {
            lineEnd = lines[idx + 1].time
        } else {
            // 最后一行：无下一行时间戳，假定 4 秒线性推进
            lineEnd = lineStart + 4
        }
        guard lineEnd > lineStart else { return 0 }
        let raw = (elapsed - lineStart) / (lineEnd - lineStart)
        return min(max(raw, 0), 1)
    }
}
