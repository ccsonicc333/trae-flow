import Foundation

/// 矿石电台支持的音乐平台（Spec: mineradio-bridge-compat-layer）
/// 三平台 cookie 共存于 WKHTTPCookieStore（不同 domain），互不干扰。
enum MusicPlatform: String, Codable, CaseIterable, Sendable, Identifiable {
    case netease
    case qq
    case kugou

    /// Identifiable —— 用于 SwiftUI `.sheet(item:)` / `.confirmationDialog(presenting:)`
    var id: String { rawValue }

    /// 平台登录页 URL
    var loginURL: URL {
        switch self {
        case .netease:
            return URL(string: "https://music.163.com/#/login")!
        case .qq:
            return URL(string: "https://y.qq.com/portal/profile.html")!
        case .kugou:
            return URL(string: "https://www.kugou.com/vip/loginsuccess/")!
        }
    }

    /// 登录成功后写入 WKHTTPCookieStore 的关键 cookie 名称
    /// 检测到任一即视为已登录
    var loginCookieKeys: [String] {
        switch self {
        case .netease:
            return ["MUSIC_U", "MUSIC_A", "__csrf"]
        case .qq:
            return ["qm_keyst", "qqmusic_key", "music_key"]
        case .kugou:
            return ["userid", "token", "KugooID"]
        }
    }

    /// 平台显示名称
    var displayName: String {
        switch self {
        case .netease:
            return "网易云"
        case .qq:
            return "QQ音乐"
        case .kugou:
            return "酷狗"
        }
    }

    /// Bridge API 路径前缀（router.js 中各平台登录状态查询路径）
    var loginStatusPath: String {
        switch self {
        case .netease:
            return "/api/login/status"
        case .qq:
            return "/api/qq/login/status"
        case .kugou:
            return "/api/kg/login/status"
        }
    }
}

/// 平台登录状态
enum MineradioLoginState: Equatable, Sendable {
    case unknown
    case loggedIn(nickname: String)
    case loggedOut

    var isLoggedIn: Bool {
        if case .loggedIn = self { return true }
        return false
    }
}
