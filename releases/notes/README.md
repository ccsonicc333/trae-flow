# Release Notes

Create one Markdown file per version:

- `releases/notes/1.2.3.md`
- `releases/notes/1.2.4.md`

The app shows these notes in the in-app update popup and the release script publishes them as `TraeFlow-<version>.md`.
When `scripts/create-release.sh` creates or updates a GitHub Release, it also uses `releases/notes/<version>.md` as the release body when that file exists.

Recommended template:

```md
# TRAE FLOW 1.2.3

## 亮点

- 优化更新体验
- 提升稳定性

## 修复

- 修复某些场景下的闪退问题
- 修复设置页中的显示问题

## 说明

- 说明这一版的范围、限制或兼容性注意事项

## 关联 PR

- `#123` Example teammate PR reference
```

Notes:

- Prefer `##` headings if you want separate collapsible sections in the popup.
- Default to `亮点` / `修复` / `说明`; add `关联 PR` when useful.
- Plain Markdown without headings still works and will be shown as a single section.
- Bullet and numbered lists are rendered as single-column rows in the popup, so concise one-line items read best.
- Use the app version from `CFBundleShortVersionString`.
- If a release includes merged teammate PRs, keep the PR references in the release note file so the published GitHub Release body and in-app notes preserve that attribution trail.
