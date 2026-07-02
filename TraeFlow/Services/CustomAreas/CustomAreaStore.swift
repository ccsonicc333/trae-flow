import Combine
import Foundation
import SwiftUI

/// Spec: 自定义区域设置页面 —— 新建/编辑/删除/排序多个目录，并实时渲染每个目录的 HTML 预览
/// Spec: 紧凑态与展开态的选择已迁移到 LeftFeatureStore（left-features.json）
@MainActor
final class CustomAreaStore: ObservableObject {
    static let shared = CustomAreaStore()

    /// 持久化文件位于 `~/Library/Application Support/trae-flow/custom-areas.json`
    private static var persistenceURL: URL {
        BridgeRuntimePaths.runtimeDirectoryURL
            .appendingPathComponent("custom-areas.json")
    }

    @Published private(set) var areas: [CustomArea] = []

    private let defaults: UserDefaults

    private enum Keys {
        static let areasVersion = "customAreasVersion"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
        // 注意：内置预设注入不再在 init 中执行，以避免在 LeftFeatureStore 初始化期间
        // 副作用地追加 LeftFeature 后被 migrateFromLegacy() 覆盖。
        // 调用方应在 LeftFeatureStore 初始化完成后显式调用 bootstrapBuiltInAreasIfNeeded()。
    }

    // MARK: - Loading & Persistence

    private func load() {
        let url = Self.persistenceURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([CustomArea].self, from: data) else {
            // 首次启动时由 bootstrapBuiltInAreasIfNeeded 填充
            areas = []
            return
        }
        areas = decoded.sorted { $0.sortOrder > $1.sortOrder }
    }

    private func persist() {
        let url = Self.persistenceURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(areas)
            try data.write(to: url, options: [.atomic])
        } catch {
            // 持久化失败不应阻塞 UI；下次启动会重新尝试
        }
    }

    // MARK: - Built-in Areas Bootstrap

    /// Spec: 首次启动时确保运行时目录就绪，并注入默认自定义功能预设。
    /// 当前仅保留「TRAE Flow 演示」一个预设，以 isBuiltIn=false 写入，用户可自行删除。
    ///
    /// 注意：此方法不再在 `init` 中自动调用。必须在 `LeftFeatureStore` 初始化完成后显式调用，
    /// 否则 `seedDefaultCustomArea` 中 `appendCustomAreaFeature(areaID:isEnabled:)` 追加的
    /// LeftFeature（如 demo 默认不启用）会被 `migrateFromLegacy()` 覆盖。
    func bootstrapBuiltInAreasIfNeeded() {
        BridgeRuntimePaths.prepareRuntimeDirectory()
        bootstrapDefaultCustomAreasIfNeeded()
    }

    /// Spec: 首次启动注入一个默认自定义功能预设（用户可删除）
    /// 用 UserDefaults flag 保证仅执行一次；老用户已存在则跳过。
    private func bootstrapDefaultCustomAreasIfNeeded() {
        let defaultsKey = "traeFlowDefaultCustomAreasSeeded"
        guard !defaults.bool(forKey: defaultsKey) else { return }
        defaults.set(true, forKey: defaultsKey)

        // 预设 1：TRAE Flow 演示页（图标文字「演示」，允许外部接口）
        // Spec: demo-preset-default-disabled —— 演示页默认不启用，避免打扰新用户
        // Spec: upgrade-demo-html-to-four-blocks —— 使用四个真实交互区块 HTML（testHTMLContent）
        _ = seedDefaultCustomArea(
            directoryName: "trae-flow-demo",
            name: "TRAE Flow 演示",
            iconName: "text:演示",
            allowsNetworkAccess: true,
            htmlContent: Self.testHTMLContent,
            defaultEnabled: false
        )
    }

    /// 写入默认预设目录与 index.html，并添加 area 记录（isBuiltIn=false，用户可删除）。
    /// 若同名目录已存在则跳过写入；若已存在同名 area 则跳过添加。
    /// `defaultEnabled` 控制对应 LeftFeature 的初始启用状态（默认 true；
    /// 「TRAE Flow 演示」预设传 false 使其默认不启用，避免打扰新用户）。
    @discardableResult
    private func seedDefaultCustomArea(
        directoryName: String,
        name: String,
        iconName: String?,
        allowsNetworkAccess: Bool,
        htmlContent: String,
        defaultEnabled: Bool = true
    ) -> CustomArea? {
        let dirURL = BridgeRuntimePaths.customAreasDirectoryURL
            .appendingPathComponent(directoryName, isDirectory: true)
        let htmlURL = dirURL.appendingPathComponent("index.html")

        // 若 HTML 不存在则写入
        if !FileManager.default.fileExists(atPath: htmlURL.path) {
            do {
                try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                try htmlContent.data(using: .utf8)?.write(to: htmlURL, options: [.atomic])
            } catch {
                return nil
            }
        }

        // 若已存在同路径 area 则跳过
        if areas.contains(where: { $0.directoryURL.path == dirURL.path }) {
            return nil
        }

        let sortOrder = (areas.map(\.sortOrder).max() ?? 100) + 1
        let area = CustomArea(
            name: name,
            directoryPath: dirURL.path,
            entryPointRelativePath: "index.html",
            autoDetectEntryPoint: false,
            defaultVariant: .trae,
            isBuiltIn: false,
            sortOrder: sortOrder,
            iconName: iconName,
            allowsNetworkAccess: allowsNetworkAccess
        )
        areas.append(area)
        persist()
        LeftFeatureStore.shared.appendCustomAreaFeature(areaID: area.id, isEnabled: defaultEnabled)
        return area
    }

    // MARK: - Default Custom Area HTML Contents

    /// 默认预设 1 的旧版 TRAE Flow 演示页 —— 三个真实交互区块（Flow 岛提示 / 外部接口 / localStorage 持久化）。
    /// 当前内置预设已改用 `testHTMLContent`（四个真实交互区块，含系统数据监控），
    /// 本常量保留以兼容可能引用它的其他代码。
    private static let defaultDemoHTMLContent = """
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>TRAE Flow 演示</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: -apple-system, "PingFang SC", sans-serif;
    background: transparent;
    color: #fff;
    padding: 20px;
    min-height: 100vh;
  }
  .header {
    margin-bottom: 16px;
    padding-bottom: 12px;
    border-bottom: 1px solid rgba(255,255,255,0.08);
  }
  .header h1 { font-size: 17px; font-weight: 600; }
  .header p { font-size: 12px; color: rgba(255,255,255,0.55); margin-top: 4px; line-height: 1.5; }
  .card {
    background: rgba(255,255,255,0.06);
    border: 1px solid rgba(255,255,255,0.1);
    border-radius: 14px;
    padding: 16px 18px;
    margin-bottom: 14px;
  }
  .card-title { font-size: 14px; font-weight: 600; margin-bottom: 4px; }
  .card-desc { font-size: 11px; color: rgba(255,255,255,0.5); margin-bottom: 10px; line-height: 1.45; }
  .btn-row { display: flex; flex-wrap: wrap; gap: 8px; }
  button {
    height: 32px;
    padding: 0 14px;
    line-height: 32px;
    border: 1px solid rgba(255,255,255,0.18);
    border-radius: 8px;
    background: rgba(255,255,255,0.08);
    color: #fff;
    font-size: 12px;
    cursor: pointer;
    transition: background 0.15s, transform 0.05s, box-shadow 0.15s, border-color 0.15s;
  }
  button:hover { background: rgba(255,255,255,0.16); box-shadow: 0 2px 8px rgba(0,0,0,0.25); }
  button:active { transform: scale(0.97); }
  button.primary { background: rgba(0,122,255,0.32); border-color: rgba(0,122,255,0.55); }
  button.primary:hover { background: rgba(0,122,255,0.48); }
  button.danger { background: rgba(255,69,58,0.25); border-color: rgba(255,69,58,0.5); }
  button.danger:hover { background: rgba(255,69,58,0.4); }
  button.success { background: rgba(48,209,63,0.32); border-color: rgba(48,209,63,0.55); }
  button.success:hover { background: rgba(48,209,63,0.48); }
  .out {
    margin-top: 10px;
    padding: 10px;
    background: rgba(0,0,0,0.25);
    border: 1px solid rgba(255,255,255,0.08);
    border-radius: 8px;
    font-family: "SF Mono", ui-monospace, monospace;
    font-size: 11px;
    color: rgba(255,255,255,0.85);
    white-space: pre-wrap;
    word-break: break-all;
    min-height: 40px;
  }
  .out.error { border-color: rgba(255,159,10,0.5); }
  .out.success { border-color: rgba(48,209,63,0.5); }
  .out.with-icon { display: flex; align-items: center; gap: 8px; }
  .count {
    font-size: 22px;
    font-weight: 700;
    color: #fff;
    margin: 0 12px;
    min-width: 32px;
    text-align: center;
  }
  .count-row { display: flex; align-items: center; }
  .count-meta { margin-top: 8px; font-size: 10px; color: rgba(255,255,255,0.45); }
  code {
    background: rgba(255,255,255,0.1);
    padding: 1px 5px;
    border-radius: 4px;
    font-size: 10px;
  }
  .muted { color: rgba(255,255,255,0.45); }
  .spinner {
    display: inline-block;
    width: 12px;
    height: 12px;
    border: 2px solid rgba(255,255,255,0.25);
    border-top-color: rgba(255,255,255,0.85);
    border-radius: 50%;
    animation: spin 0.7s linear infinite;
    flex-shrink: 0;
  }
  @keyframes spin { to { transform: rotate(360deg); } }
</style>
</head>
<body>
  <div class="header">
    <h1>TRAE Flow 演示页</h1>
    <p>三个真实交互区块：Flow 岛提示、外部接口请求、本地计数器持久化。</p>
  </div>

  <div class="card">
    <div class="card-title">推送提示到 Flow 岛</div>
    <div class="card-desc">调用 <code>traeFlowHint.postMessage</code> 向紧凑态 Flow 岛推送限时提示；点击后按钮短暂变绿作为成功反馈。</div>
    <div class="btn-row">
      <button class="primary" onclick="sendHint(this, '默认提示 5 秒')">默认 5 秒</button>
      <button onclick="sendHint(this, '自定义 3 秒', 3000)">自定义 3 秒</button>
      <button class="danger" onclick="clearHint(this)">清除提示</button>
    </div>
  </div>

  <div class="card">
    <div class="card-title">调用外部接口</div>
    <div class="card-desc">fetch 公开 API <code>https://api.github.com/repos/apple/swift</code> 并渲染返回 JSON 片段；5 秒超时，加载中显示 spinner。</div>
    <div class="btn-row">
      <button class="primary" onclick="fetchGitHub()">请求 GitHub API</button>
      <button onclick="clearFetch()">清空结果</button>
    </div>
    <div id="fetchOut" class="out muted">点击按钮发起请求。若未开启外部接口将显示提示。</div>
  </div>

  <div class="card">
    <div class="card-title">localStorage 持久化计数器</div>
    <div class="card-desc">读写 <code>localStorage.traeFlowDemoCount</code>，点击 +/- 修改；连续点击会合并写入，刷新页面后保留。</div>
    <div class="count-row">
      <button onclick="changeCount(-1)">-1</button>
      <div id="countView" class="count">0</div>
      <button class="primary" onclick="changeCount(1)">+1</button>
      <button class="danger" onclick="resetCount()" style="margin-left:8px;">重置</button>
    </div>
    <div id="countMeta" class="count-meta">尚未修改</div>
  </div>

<script>
  function flashSuccess(btn) {
    if (!btn) return;
    btn.classList.add("success");
    setTimeout(function () { btn.classList.remove("success"); }, 800);
  }
  function sendHint(btn, text, duration) {
    var body = duration != null
      ? { text: text, duration: duration }
      : { text: text };
    try {
      window.webkit.messageHandlers.traeFlowHint.postMessage(body);
      flashSuccess(btn);
    } catch (e) {
      document.title = "bridge-error: " + e.message;
    }
  }
  function clearHint(btn) {
    try {
      window.webkit.messageHandlers.traeFlowHint.postMessage({ action: "clear" });
      flashSuccess(btn);
    } catch (e) {}
  }
  function fetchWithTimeout(url, ms) {
    return Promise.race([
      fetch(url),
      new Promise(function (_, reject) {
        setTimeout(function () { reject(new Error("请求超时 (" + ms + "ms)")); }, ms);
      })
    ]);
  }
  function fetchGitHub() {
    var out = document.getElementById("fetchOut");
    out.className = "out with-icon muted";
    out.innerHTML = '<span class="spinner"></span><span>请求中…</span>';
    fetchWithTimeout("https://api.github.com/repos/apple/swift", 5000)
      .then(function (r) {
        if (!r.ok) throw new Error("HTTP " + r.status);
        return r.json();
      })
      .then(function (data) {
        var slice = {
          name: data.name,
          full_name: data.full_name,
          stargazers_count: data.stargazers_count,
          open_issues_count: data.open_issues_count,
          description: data.description
        };
        out.className = "out success";
        out.textContent = JSON.stringify(slice, null, 2);
        setTimeout(function () { out.classList.remove("success"); }, 1500);
      })
      .catch(function (err) {
        out.className = "out error";
        out.textContent = "请求失败：" + err.message + "\\n（未开启外部接口？请在设置中开启）";
      });
  }
  function clearFetch() {
    var out = document.getElementById("fetchOut");
    out.className = "out muted";
    out.textContent = "已清空。";
  }
  var COUNT_KEY = "traeFlowDemoCount";
  var COUNT_META_KEY = "traeFlowDemoCountUpdatedAt";
  var writeTimer = null;
  function readCount() {
    var raw = localStorage.getItem(COUNT_KEY);
    var n = parseInt(raw, 10);
    return isNaN(n) ? 0 : n;
  }
  function renderCount(n) {
    document.getElementById("countView").textContent = String(n);
  }
  function renderCountMeta(ts) {
    var meta = document.getElementById("countMeta");
    if (!ts) { meta.textContent = "尚未修改"; return; }
    var d = new Date(ts);
    var hh = String(d.getHours()).padStart(2, "0");
    var mm = String(d.getMinutes()).padStart(2, "0");
    var ss = String(d.getSeconds()).padStart(2, "0");
    meta.textContent = "上次更新：" + hh + ":" + mm + ":" + ss;
  }
  function scheduleWrite(n, ts) {
    if (writeTimer) clearTimeout(writeTimer);
    writeTimer = setTimeout(function () {
      localStorage.setItem(COUNT_KEY, String(n));
      localStorage.setItem(COUNT_META_KEY, String(ts));
      writeTimer = null;
    }, 300);
  }
  function changeCount(delta) {
    var n = readCount() + delta;
    var now = Date.now();
    renderCount(n);
    renderCountMeta(now);
    scheduleWrite(n, now);
  }
  function resetCount() {
    var now = Date.now();
    renderCount(0);
    renderCountMeta(now);
    scheduleWrite(0, now);
  }
  (function init() {
    renderCount(readCount());
    var ts = parseInt(localStorage.getItem(COUNT_META_KEY), 10);
    renderCountMeta(isNaN(ts) ? 0 : ts);
  })();
</script>
</body>
</html>
"""

    // MARK: - Test HTML Area

    /// Spec: 仅用于内部测试（设置页已移除入口）。
    /// 在 `~/Library/Application Support/trae-flow/custom-areas/trae-flow-test/` 下写入
    /// `index.html`，包含触发提示的按钮（默认 5 秒、自定义 3 秒、清除提示）。
    /// 若同名目录已存在则跳过创建，仅返回已有 area。
    @discardableResult
    func addTestHTMLArea() -> CustomArea? {
        let testDirName = "trae-flow-test"
        let testDirURL = BridgeRuntimePaths.customAreasDirectoryURL
            .appendingPathComponent(testDirName, isDirectory: true)

        // 若已存在同名 area 则直接返回
        if let existing = areas.first(where: { $0.directoryURL.path == testDirURL.path }) {
            return existing
        }

        // 创建目录并写入测试 HTML
        do {
            try FileManager.default.createDirectory(at: testDirURL, withIntermediateDirectories: true)
            let htmlURL = testDirURL.appendingPathComponent("index.html")
            try Self.testHTMLContent.data(using: .utf8)?.write(to: htmlURL, options: [.atomic])
        } catch {
            return nil
        }

        let sortOrder = (areas.map(\.sortOrder).max() ?? 100) + 1
        let area = CustomArea(
            name: "测试 HTML",
            directoryPath: testDirURL.path,
            entryPointRelativePath: "index.html",
            autoDetectEntryPoint: false,
            defaultVariant: .trae,
            isBuiltIn: false,
            sortOrder: sortOrder,
            iconName: nil,
            allowsNetworkAccess: false
        )
        areas.append(area)
        persist()
        LeftFeatureStore.shared.appendCustomAreaFeature(areaID: area.id)
        return area
    }

    /// 测试 HTML 内容 —— 演示四个真实交互区块（Flow 岛提示 / 外部接口 / localStorage 持久化 / 系统数据监控）。
    /// 深色圆角卡片风格，与 Flow 岛视觉一致。包含 loading spinner、5 秒超时、
    /// 计数器防抖、错误态橙边、成功态绿边、按钮成功反馈、系统指标进度条等交互打磨。
    private static let testHTMLContent = """
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>TRAE Flow 演示</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: -apple-system, "PingFang SC", sans-serif;
    background: transparent;
    color: #fff;
    padding: 20px;
    min-height: 100vh;
  }
  .header {
    margin-bottom: 16px;
    padding-bottom: 12px;
    border-bottom: 1px solid rgba(255,255,255,0.08);
  }
  .header h1 { font-size: 17px; font-weight: 600; }
  .header p { font-size: 12px; color: rgba(255,255,255,0.55); margin-top: 4px; line-height: 1.5; }
  .card {
    background: rgba(255,255,255,0.06);
    border: 1px solid rgba(255,255,255,0.1);
    border-radius: 14px;
    padding: 16px 18px;
    margin-bottom: 14px;
  }
  .card-title { font-size: 14px; font-weight: 600; margin-bottom: 4px; }
  .card-desc { font-size: 11px; color: rgba(255,255,255,0.5); margin-bottom: 10px; line-height: 1.45; }
  .btn-row { display: flex; flex-wrap: wrap; gap: 8px; }
  button {
    height: 32px;
    padding: 0 14px;
    line-height: 32px;
    border: 1px solid rgba(255,255,255,0.18);
    border-radius: 8px;
    background: rgba(255,255,255,0.08);
    color: #fff;
    font-size: 12px;
    cursor: pointer;
    transition: background 0.15s, transform 0.05s, box-shadow 0.15s, border-color 0.15s;
  }
  button:hover { background: rgba(255,255,255,0.16); box-shadow: 0 2px 8px rgba(0,0,0,0.25); }
  button:active { transform: scale(0.97); }
  button.primary { background: rgba(0,122,255,0.32); border-color: rgba(0,122,255,0.55); }
  button.primary:hover { background: rgba(0,122,255,0.48); }
  button.danger { background: rgba(255,69,58,0.25); border-color: rgba(255,69,58,0.5); }
  button.danger:hover { background: rgba(255,69,58,0.4); }
  button.success { background: rgba(48,209,63,0.32); border-color: rgba(48,209,63,0.55); }
  button.success:hover { background: rgba(48,209,63,0.48); }
  .out {
    margin-top: 10px;
    padding: 10px;
    background: rgba(0,0,0,0.25);
    border: 1px solid rgba(255,255,255,0.08);
    border-radius: 8px;
    font-family: "SF Mono", ui-monospace, monospace;
    font-size: 11px;
    color: rgba(255,255,255,0.85);
    white-space: pre-wrap;
    word-break: break-all;
    min-height: 40px;
  }
  .out.error { border-color: rgba(255,159,10,0.5); }
  .out.success { border-color: rgba(48,209,63,0.5); }
  .out.with-icon { display: flex; align-items: center; gap: 8px; }
  .count {
    font-size: 22px;
    font-weight: 700;
    color: #fff;
    margin: 0 12px;
    min-width: 32px;
    text-align: center;
  }
  .count-row { display: flex; align-items: center; }
  .count-meta { margin-top: 8px; font-size: 10px; color: rgba(255,255,255,0.45); }
  code {
    background: rgba(255,255,255,0.1);
    padding: 1px 5px;
    border-radius: 4px;
    font-size: 10px;
  }
  .muted { color: rgba(255,255,255,0.45); }
  .spinner {
    display: inline-block;
    width: 12px;
    height: 12px;
    border: 2px solid rgba(255,255,255,0.25);
    border-top-color: rgba(255,255,255,0.85);
    border-radius: 50%;
    animation: spin 0.7s linear infinite;
    flex-shrink: 0;
  }
  @keyframes spin { to { transform: rotate(360deg); } }

  /* ===== 区块 4: 系统数据监控 ===== */
  .metric { display: flex; flex-direction: column; gap: 5px; margin-bottom: 10px; }
  .metric:last-child { margin-bottom: 0; }
  .metric-label {
    font-size: 11px; color: rgba(255,255,255,0.5);
    text-transform: uppercase; letter-spacing: 0.5px;
    display: flex; justify-content: space-between; align-items: baseline;
  }
  .metric-label .val { font-size: 13px; font-weight: 600; color: #fff; text-transform: none; letter-spacing: 0; }
  .metric-bar {
    height: 4px; background: rgba(255,255,255,0.08);
    border-radius: 2px; overflow: hidden;
  }
  .metric-fill { height: 100%; border-radius: 2px; transition: width 0.4s ease; }
  .metric-fill.cpu { background: linear-gradient(90deg, #ff6b6b, #ff8e53); }
  .metric-fill.mem { background: linear-gradient(90deg, #4dd0e1, #26c6da); }
  .metric-sub { font-size: 10px; color: rgba(255,255,255,0.35); margin-top: 2px; }
  .metric-pending { opacity: 0.4; }
</style>
</head>
<body>
  <div class="header">
    <h1>TRAE Flow 演示页</h1>
    <p>四个真实交互区块：Flow 岛提示、外部接口请求、本地计数器持久化、系统数据监控。</p>
  </div>

  <!-- 区块 1: 推送提示到 Flow 岛 -->
  <div class="card">
    <div class="card-title">推送提示到 Flow 岛</div>
    <div class="card-desc">调用 <code>traeFlowHint.postMessage</code> 向紧凑态 Flow 岛推送限时提示；点击后按钮短暂变绿作为成功反馈。</div>
    <div class="btn-row">
      <button class="primary" onclick="sendHint(this, '默认提示 5 秒')">默认 5 秒</button>
      <button onclick="sendHint(this, '自定义 3 秒', 3000)">自定义 3 秒</button>
      <button class="danger" onclick="clearHint(this)">清除提示</button>
    </div>
  </div>

  <!-- 区块 2: 调用外部接口 -->
  <div class="card">
    <div class="card-title">调用外部接口</div>
    <div class="card-desc">fetch 公开 API <code>https://api.github.com/repos/apple/swift</code> 并渲染返回 JSON 片段；5 秒超时，加载中显示 spinner。</div>
    <div class="btn-row">
      <button class="primary" onclick="fetchGitHub()">请求 GitHub API</button>
      <button onclick="clearFetch()">清空结果</button>
    </div>
    <div id="fetchOut" class="out muted">点击按钮发起请求。若未开启外部接口将显示提示。</div>
  </div>

  <!-- 区块 3: localStorage 持久化计数器 -->
  <div class="card">
    <div class="card-title">localStorage 持久化计数器</div>
    <div class="card-desc">读写 <code>localStorage.traeFlowDemoCount</code>，点击 +/- 修改；连续点击会合并写入，刷新页面后保留。</div>
    <div class="count-row">
      <button onclick="changeCount(-1)">-1</button>
      <div id="countView" class="count">0</div>
      <button class="primary" onclick="changeCount(1)">+1</button>
      <button class="danger" onclick="resetCount()" style="margin-left:8px;">重置</button>
    </div>
    <div id="countMeta" class="count-meta">尚未修改</div>
  </div>

  <!-- 区块 4: 系统数据监控 -->
  <div class="card">
    <div class="card-title">系统数据监控</div>
    <div class="card-desc">通过 <code>traeFlowMetrics</code> JS Bridge 每 2 秒获取真实系统指标：CPU 使用率、内存、负载均值、逻辑核心数。</div>
    <div class="metric">
      <div class="metric-label"><span>CPU</span><span class="val" id="cpuValue">--</span></div>
      <div class="metric-bar"><div class="metric-fill cpu" id="cpuBar" style="width:0%"></div></div>
    </div>
    <div class="metric">
      <div class="metric-label"><span>内存</span><span class="val" id="memValue">--</span></div>
      <div class="metric-bar"><div class="metric-fill mem" id="memBar" style="width:0%"></div></div>
      <div class="metric-sub" id="memDetail"></div>
    </div>
    <div class="metric">
      <div class="metric-label"><span>负载</span><span class="val metric-pending" id="loadValue">等待数据...</span></div>
    </div>
  </div>

<script>
  // ===== 区块 1: Flow 岛提示 =====
  // 调用后给按钮临时加 .success 类 800ms 作为成功反馈
  function flashSuccess(btn) {
    if (!btn) return;
    btn.classList.add("success");
    setTimeout(function () { btn.classList.remove("success"); }, 800);
  }
  function sendHint(btn, text, duration) {
    var body = duration != null
      ? { text: text, duration: duration }
      : { text: text };
    try {
      window.webkit.messageHandlers.traeFlowHint.postMessage(body);
      flashSuccess(btn);
    } catch (e) {
      document.title = "bridge-error: " + e.message;
    }
  }
  function clearHint(btn) {
    try {
      window.webkit.messageHandlers.traeFlowHint.postMessage({ action: "clear" });
      flashSuccess(btn);
    } catch (e) {}
  }

  // ===== 区块 2: 外部接口 =====
  // 用 Promise.race 实现 5 秒超时
  function fetchWithTimeout(url, ms) {
    return Promise.race([
      fetch(url),
      new Promise(function (_, reject) {
        setTimeout(function () { reject(new Error("请求超时 (" + ms + "ms)")); }, ms);
      })
    ]);
  }
  function fetchGitHub() {
    var out = document.getElementById("fetchOut");
    out.className = "out with-icon muted";
    out.innerHTML = '<span class="spinner"></span><span>请求中…</span>';
    fetchWithTimeout("https://api.github.com/repos/apple/swift", 5000)
      .then(function (r) {
        if (!r.ok) throw new Error("HTTP " + r.status);
        return r.json();
      })
      .then(function (data) {
        var slice = {
          name: data.name,
          full_name: data.full_name,
          stargazers_count: data.stargazers_count,
          open_issues_count: data.open_issues_count,
          description: data.description
        };
        out.className = "out success";
        out.textContent = JSON.stringify(slice, null, 2);
        // 1.5 秒后移除成功边框
        setTimeout(function () { out.classList.remove("success"); }, 1500);
      })
      .catch(function (err) {
        out.className = "out error";
        out.textContent = "请求失败：" + err.message + "\\n（未开启外部接口？请在设置中开启）";
      });
  }
  function clearFetch() {
    var out = document.getElementById("fetchOut");
    out.className = "out muted";
    out.textContent = "已清空。";
  }

  // ===== 区块 3: localStorage 计数器 =====
  // 防抖：UI 立即更新，localStorage 写入合并到 300ms 内
  var COUNT_KEY = "traeFlowDemoCount";
  var COUNT_META_KEY = "traeFlowDemoCountUpdatedAt";
  var writeTimer = null;
  function readCount() {
    var raw = localStorage.getItem(COUNT_KEY);
    var n = parseInt(raw, 10);
    return isNaN(n) ? 0 : n;
  }
  function renderCount(n) {
    document.getElementById("countView").textContent = String(n);
  }
  function renderCountMeta(ts) {
    var meta = document.getElementById("countMeta");
    if (!ts) { meta.textContent = "尚未修改"; return; }
    var d = new Date(ts);
    var hh = String(d.getHours()).padStart(2, "0");
    var mm = String(d.getMinutes()).padStart(2, "0");
    var ss = String(d.getSeconds()).padStart(2, "0");
    meta.textContent = "上次更新：" + hh + ":" + mm + ":" + ss;
  }
  function scheduleWrite(n, ts) {
    if (writeTimer) clearTimeout(writeTimer);
    writeTimer = setTimeout(function () {
      localStorage.setItem(COUNT_KEY, String(n));
      localStorage.setItem(COUNT_META_KEY, String(ts));
      writeTimer = null;
    }, 300);
  }
  function changeCount(delta) {
    var n = readCount() + delta;
    var now = Date.now();
    renderCount(n);
    renderCountMeta(now);
    scheduleWrite(n, now);
  }
  function resetCount() {
    var now = Date.now();
    renderCount(0);
    renderCountMeta(now);
    scheduleWrite(0, now);
  }
  // 初始化渲染
  (function init() {
    renderCount(readCount());
    var ts = parseInt(localStorage.getItem(COUNT_META_KEY), 10);
    renderCountMeta(isNaN(ts) ? 0 : ts);
  })();

  // ===== 区块 4: 系统数据监控 =====
  // 通过 traeFlowMetrics bridge 每 2 秒获取真实系统指标
  function formatBytes(bytes) {
    if (bytes >= 1073741824) return (bytes / 1073741824).toFixed(1) + ' GB';
    return (bytes / 1048576).toFixed(0) + ' MB';
  }
  window.receiveMetrics = function(data) {
    var cpu = Math.min(100, Math.max(0, data.cpu || 0));
    document.getElementById('cpuValue').textContent = cpu.toFixed(1) + '%';
    document.getElementById('cpuBar').style.width = cpu + '%';

    var mem = Math.min(100, Math.max(0, data.memoryPercent || 0));
    document.getElementById('memValue').textContent = mem.toFixed(1) + '%';
    document.getElementById('memBar').style.width = mem + '%';
    document.getElementById('memDetail').textContent =
      formatBytes(data.memoryUsed || 0) + ' / ' + formatBytes(data.memoryTotal || 0);

    document.getElementById('loadValue').classList.remove('metric-pending');
    var cores = data.cores || 0;
    document.getElementById('loadValue').textContent =
      (data.loadOne || 0).toFixed(2) + ' / ' + (data.loadFive || 0).toFixed(2) + ' / ' + (data.loadFifteen || 0).toFixed(2) +
      (cores > 0 ? '  (' + cores + ' cores)' : '');
  };
  function requestMetrics() {
    try {
      window.webkit.messageHandlers.traeFlowMetrics.postMessage({});
    } catch (e) {
      document.getElementById('loadValue').textContent = 'Bridge 未就绪';
    }
  }
  requestMetrics();
  setInterval(requestMetrics, 2000);
</script>
</body>
</html>
"""

    // MARK: - Mutation API

    /// Spec: 用户新建目录 —— 提示选择本地文件夹作为项目目录，命名、选择默认变体
    /// 新增 `iconName` / `allowsNetworkAccess` 参数（默认 nil / false），向后兼容老调用
    @discardableResult
    func addArea(
        name: String,
        directoryURL: URL,
        entryPointRelativePath: String = "index.html",
        defaultVariant: TraeVariant = .traeWorkCN,
        autoDetectEntryPoint: Bool = true,
        iconName: String? = nil,
        allowsNetworkAccess: Bool = false
    ) -> CustomArea {
        let sortOrder = (areas.map(\.sortOrder).max() ?? 100) + 1
        let area = CustomArea(
            name: name,
            directoryPath: directoryURL.path,
            entryPointRelativePath: entryPointRelativePath,
            autoDetectEntryPoint: autoDetectEntryPoint,
            defaultVariant: defaultVariant,
            isBuiltIn: false,
            sortOrder: sortOrder,
            iconName: iconName,
            allowsNetworkAccess: allowsNetworkAccess
        )
        areas.append(area)
        persist()
        // 联动 LeftFeatureStore 为新目录创建对应功能项
        LeftFeatureStore.shared.appendCustomAreaFeature(areaID: area.id)
        return area
    }

    /// Spec: 按功能名称在 `custom-areas/<sanitized-name>/` 下自动生成目录与 `index.html`。
    /// 若目录已存在则追加短随机后缀避免覆盖；写入失败返回 nil。
    @discardableResult
    func addAreaWithAutoGeneratedDirectory(
        name: String,
        iconName: String?,
        allowsNetworkAccess: Bool,
        defaultVariant: TraeVariant = .traeWorkCN
    ) -> CustomArea? {
        let sanitizedName = sanitizeDirectoryName(name)
        let dirURL = BridgeRuntimePaths.customAreasDirectoryURL
            .appendingPathComponent(sanitizedName, isDirectory: true)
        // 若目录已存在，追加短随机后缀避免覆盖
        var finalURL = dirURL
        if FileManager.default.fileExists(atPath: finalURL.path) {
            let suffix = String(UUID().uuidString.prefix(6))
            finalURL = BridgeRuntimePaths.customAreasDirectoryURL
                .appendingPathComponent("\(sanitizedName)-\(suffix)", isDirectory: true)
        }
        do {
            try FileManager.default.createDirectory(at: finalURL, withIntermediateDirectories: true)
            let htmlURL = finalURL.appendingPathComponent("index.html")
            try Self.testHTMLContent.data(using: .utf8)?.write(to: htmlURL, options: [.atomic])
        } catch {
            return nil
        }
        let sortOrder = (areas.map(\.sortOrder).max() ?? 100) + 1
        let area = CustomArea(
            name: name,
            directoryPath: finalURL.path,
            entryPointRelativePath: "index.html",
            autoDetectEntryPoint: false,
            defaultVariant: defaultVariant,
            isBuiltIn: false,
            sortOrder: sortOrder,
            iconName: iconName,
            allowsNetworkAccess: allowsNetworkAccess
        )
        areas.append(area)
        persist()
        LeftFeatureStore.shared.appendCustomAreaFeature(areaID: area.id)
        return area
    }

    /// 将功能名 sanitize 为安全目录名（保留中文、字母、数字，将文件系统非法字符替换为连字符）。
    private func sanitizeDirectoryName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "area" }
        // 替换文件系统非法字符 / \ : * ? " < > | 为连字符
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return trimmed.components(separatedBy: illegal).joined(separator: "-")
    }

    /// Spec: 用户编辑目录条目（重命名、更换入口、改默认变体等）
    func updateArea(_ updated: CustomArea) {
        guard let index = areas.firstIndex(where: { $0.id == updated.id }) else { return }
        var copy = updated
        copy.updatedAt = Date()
        areas[index] = copy
        persist()
    }

    /// Spec: 用户删除目录 —— 仅移除引用，不删除用户原始文件夹
    /// 内置目录被删除时同样只移除引用
    /// 选择状态的清理由 LeftFeatureStore.removeCustomAreaFeature 联动处理
    func removeArea(id: String) {
        // 先联动 LeftFeatureStore 移除对应功能并清理选择状态，避免 UI 短暂不一致
        LeftFeatureStore.shared.removeCustomAreaFeature(areaID: id)
        areas.removeAll { $0.id == id }
        persist()
    }

    /// Spec: 排序
    func moveArea(from source: IndexSet, to destination: Int) {
        areas.move(fromOffsets: source, toOffset: destination)
        // 根据新位置反向更新 sortOrder
        for (index, _) in areas.enumerated().reversed() {
            areas[index].sortOrder = areas.count - index
        }
        persist()
    }

    /// Spec: 用户手动指定入口 HTML 文件后，应用锁定使用该文件作为渲染源，
    /// 不再随文件变化自动切换
    func lockEntryPoint(areaID: String, entryPointRelativePath: String) {
        guard let index = areas.firstIndex(where: { $0.id == areaID }) else { return }
        var copy = areas[index]
        copy.entryPointRelativePath = entryPointRelativePath
        copy.autoDetectEntryPoint = false
        copy.updatedAt = Date()
        areas[index] = copy
        persist()
    }

    /// Spec: 自动检测入口 HTML 文件创建/修改并刷新
    /// 由 CustomAreaWatcher 调用
    func refreshEntryPointIfNeeded(areaID: String) {
        guard let index = areas.firstIndex(where: { $0.id == areaID }) else { return }
        var copy = areas[index]
        guard copy.autoDetectEntryPoint else { return }
        // 检测目录中是否新增了 index.html 或用户配置的入口
        let dir = copy.directoryURL
        let candidate = dir.appendingPathComponent("index.html")
        if FileManager.default.fileExists(atPath: candidate.path),
           candidate.path != copy.entryPointURL.path {
            copy.entryPointRelativePath = "index.html"
            copy.updatedAt = Date()
            areas[index] = copy
            persist()
        }
    }
}
