# Mineradio Bridge

Chrome / Edge 扩展，为 [Mineradio 网页版](../docs/WEB.md) 提供本地音乐 API 代理。

## 安装

1. 生成图标（首次）：`node web/scripts/generate-icons.js`
2. Chrome / Edge → 扩展管理 → 开发者模式 → **加载已解压的扩展程序**
3. 选择本目录 **`web/extension/`**（或同步后的仓库根目录 **`extension/`**）

同步到根目录 `extension/`：

```powershell
node web/scripts/generate-icons.js
node web/scripts/sync-extension.mjs
```

## 使用前

在浏览器中登录：

- [music.163.com](https://music.163.com)（网易云）
- [y.qq.com](https://y.qq.com)（QQ 音乐，可选）

然后打开 Mineradio 网页版。扩展 content script 会通过 `postMessage` 与页面通信。

## 开发

- `background.js` — Service Worker 入口
- `content-bridge.js` — 页面 ↔ 扩展桥接
- `api/router.js` — `/api/*` 路由表
- `api/netease.js` / `api/qq.js` — 音乐源实现

修改后于扩展管理页点击「重新加载」。

## 权限说明

| 权限 | 用途 |
| --- | --- |
| `cookies` | 读取用户已在 music.163.com / y.qq.com 的登录 Cookie |
| `host_permissions` | 向音乐平台 API 发起 fetch |
| `storage` | 缓存 beatmap 等轻量数据 |

Cookie 不会离开本机，也不会发送到 Mineradio 服务器。
