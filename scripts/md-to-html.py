#!/usr/bin/env python3
"""把 trae-flow体验用例.md 转成单文件 HTML,内嵌压缩后的 base64 图片。

样式优化版本:
- 卡片化用例(TC/VC/PC)
- 步骤/预期分栏视觉层级
- 有序列表 + 表格支持
- 代码块语言标签
- 图片居中带说明
"""
import base64
import re
import subprocess
import sys
import tempfile
from pathlib import Path

DOC = Path("/Users/telking/web/ccc/trae-flow/docs/trae-flow体验用例.md")
OUT_HTML = Path("/Users/telking/web/ccc/trae-flow/docs/trae-flow体验用例.html")

# 匹配 markdown 图片语法 ![alt](docs/images/xxx.png)
# group(1) = alt, group(2) = 相对路径
IMG_PATTERN = re.compile(r'!\[([^\]]*)\]\((docs/images/[^)]+)\)')

PROJECT_ROOT = Path("/Users/telking/web/ccc/trae-flow")

IMAGE_META = {
    0: ("Gatekeeper 拦截解决方法", "图 1：Gatekeeper 拦截时在「隐私与安全性」点击「仍要打开」", "70%"),
    1: ("启用 TRAE Hooks 设置界面", "图 2：在「设置 > Hooks」中勾选对应变体的「启用 Hook」", "80%"),
    2: ("双变体并发任务列表", "图 3：展开态右侧列出各变体待处理任务数与跳回按钮", "90%"),
    3: ("宠物 Detach 到桌面", "图 4：宠物拖拽到桌面后以独立浮窗显示，滚轮可缩放", "80%"),
}

def compress_image_file(img_path: Path, idx: int) -> str:
    """读取图片文件 -> sips 压缩到 600px + JPEG q85 -> base64 编码"""
    img_data = img_path.read_bytes()
    with tempfile.TemporaryDirectory() as td:
        src = Path(td) / f"src_{idx}.png"
        dst = Path(td) / f"dst_{idx}.jpg"
        src.write_bytes(img_data)
        result = subprocess.run(
            ["sips", "-Z", "600", "-s", "format", "jpeg",
             "-s", "formatOptions", "85", str(src), "--out", str(dst)],
            capture_output=True, text=True
        )
        if result.returncode != 0:
            print(f"  [警告] 图片 {idx} 压缩失败,使用原图: {result.stderr}", file=sys.stderr)
            return base64.b64encode(img_data).decode("ascii")
        compressed = dst.read_bytes()
        print(f"  图片 {idx} ({img_path.name}): {len(img_data)//1024}KB -> {len(compressed)//1024}KB (JPEG)")
        return base64.b64encode(compressed).decode("ascii")


def md_to_html(md_text: str) -> str:
    """markdown -> HTML 转换(覆盖本文档语法 + 表格 + 有序列表)"""
    lines = md_text.split("\n")
    html_parts = []
    in_code = False
    code_lang = ""
    in_ul = False
    in_ol = False
    in_table = False
    table_rows = []

    def close_lists():
        nonlocal in_ul, in_ol
        if in_ul: html_parts.append("</ul>"); in_ul = False
        if in_ol: html_parts.append("</ol>"); in_ol = False

    def close_table():
        nonlocal in_table, table_rows
        if in_table and table_rows:
            html_parts.append(render_table(table_rows))
            table_rows = []
            in_table = False

    def escape(t):
        return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

    for line in lines:
        # 代码块(允许行首缩进,列表内嵌代码块场景)
        m = re.match(r"^\s*```(\w*)", line)
        if m:
            if in_code:
                html_parts.append("</code></pre>")
                in_code = False
            else:
                close_lists()
                close_table()
                code_lang = m.group(1)
                label = f'<div class="code-lang">{escape(code_lang)}</div>' if code_lang else ""
                html_parts.append(f'<pre>{label}<code>')
                in_code = True
            continue
        if in_code:
            # 代码块内的行:去掉统一缩进后 escape,不做 markdown 解析
            stripped = line[2:] if line.startswith("  ") else line
            html_parts.append(escape(stripped) if stripped else "")
            continue

        # 空行
        if not line.strip():
            close_lists()
            close_table()
            html_parts.append("")
            continue

        # 表格行 (| xxx | yyy |)
        if line.strip().startswith("|") and line.strip().endswith("|"):
            close_lists()
            # 跳过分隔行 |---|---|
            if not re.match(r"^\|[\s\-:|]+\|$", line.strip()):
                cells = [c.strip() for c in line.strip().strip("|").split("|")]
                table_rows.append(cells)
                in_table = True
            continue
        else:
            close_table()

        # 标题
        if line.startswith("######"):
            close_lists()
            html_parts.append(f"<h6>{inline(line[6:].strip())}</h6>")
        elif line.startswith("#####"):
            close_lists()
            html_parts.append(f"<h5>{inline(line[5:].strip())}</h5>")
        elif line.startswith("####"):
            close_lists()
            html_parts.append(f"<h4>{inline(line[4:].strip())}</h4>")
        elif line.startswith("###"):
            close_lists()
            html_parts.append(f"<h3>{inline(line[3:].strip())}</h3>")
        elif line.startswith("##"):
            close_lists()
            html_parts.append(f"<h2>{inline(line[2:].strip())}</h2>")
        elif line.startswith("#"):
            close_lists()
            html_parts.append(f"<h1>{inline(line[1:].strip())}</h1>")
        elif line.strip() in ("***", "---"):
            close_lists()
            html_parts.append("<hr>")
        elif re.match(r"^\d+\.\s", line):
            # 有序列表
            if in_ul: html_parts.append("</ul>"); in_ul = False
            if not in_ol:
                html_parts.append("<ol>")
                in_ol = True
            stripped = re.sub(r"^\d+\.\s", "", line).rstrip()
            html_parts.append(f"<li>{inline(stripped)}</li>")
        elif line.startswith("- ") or line.startswith("  - "):
            if in_ol: html_parts.append("</ol>"); in_ol = False
            if not in_ul:
                html_parts.append("<ul>")
                in_ul = True
            stripped = line.lstrip("- ").rstrip()
            html_parts.append(f"<li>{inline(stripped)}</li>")
        elif "<img" in line:
            close_lists()
            html_parts.append(line)
        else:
            close_lists()
            html_parts.append(f"<p>{inline(line.strip())}</p>")

    close_lists()
    close_table()
    if in_code: html_parts.append("</code></pre>")
    return "\n".join(html_parts)


def render_table(rows: list) -> str:
    """渲染 markdown 表格为 HTML"""
    if not rows:
        return ""
    header = rows[0]
    body = rows[1:] if len(rows) > 1 else []
    th = "".join(f"<th>{inline(c)}</th>" for c in header)
    trs = "".join(
        "<tr>" + "".join(f"<td>{inline(c)}</td>" for c in row) + "</tr>"
        for row in body
    )
    return f'<div class="table-wrap"><table><thead><tr>{th}</tr></thead><tbody>{trs}</tbody></table></div>'


def inline(text: str) -> str:
    """处理行内格式"""
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<!\*)\*([^*]+)\*(?!\*)", r"<em>\1</em>", text)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2" target="_blank" rel="noopener noreferrer">\1</a>', text)
    return text


def main():
    text = DOC.read_text(encoding="utf-8")

    # 提取 markdown 中的相对路径图片
    images = list(IMG_PATTERN.finditer(text))
    print(f"找到 {len(images)} 张图片,开始压缩...")

    compressed_uris = []
    for idx, m in enumerate(images):
        alt = m.group(1)
        rel_path = m.group(2)
        img_path = PROJECT_ROOT / rel_path
        print(f"压缩图片 {idx}: {rel_path}")
        if not img_path.exists():
            print(f"  [错误] 图片文件不存在: {img_path}", file=sys.stderr)
            compressed_uris.append("")
            continue
        compressed_b64 = compress_image_file(img_path, idx)
        compressed_uris.append(f"data:image/jpeg;base64,{compressed_b64}")

    # 替换图片为带说明的 <figure>
    for idx, m in enumerate(reversed(images)):
        actual_idx = len(images) - 1 - idx
        alt = m.group(1)
        _, caption, width = IMAGE_META[actual_idx]
        img_html = (
            f'\n<figure class="img-figure">'
            f'<img src="{compressed_uris[actual_idx]}" alt="{alt}" '
            f'style="max-width:{width};width:100%;height:auto;" />'
            f'<figcaption>{caption}</figcaption>'
            f'</figure>\n'
        )
        text = text[:m.start()] + img_html + text[m.end():]

    # 转 HTML
    print("转换 markdown -> HTML...")
    body_html = md_to_html(text)

    html = f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>TRAE FLOW 体验用例</title>
<style>
  :root {{
    --primary: #0A84FF;
    --primary-light: #e8f2ff;
    --bg: #fafbfc;
    --card-bg: #ffffff;
    --border: #e5e7eb;
    --text: #1f2937;
    --text-light: #6b7280;
    --code-bg: #1e1e2e;
    --success: #10b981;
    --warning: #f59e0b;
  }}
  * {{ box-sizing: border-box; }}
  body {{
    font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", Arial, sans-serif;
    max-width: 880px;
    margin: 0 auto;
    padding: 48px 24px 80px;
    color: var(--text);
    line-height: 1.7;
    background: var(--bg);
    -webkit-font-smoothing: antialiased;
  }}
  /* 顶部标题 */
  h1 {{
    font-size: 2em;
    font-weight: 700;
    color: var(--text);
    border-bottom: 3px solid var(--primary);
    padding-bottom: 12px;
    margin-bottom: 8px;
  }}
  h1 + p {{ margin-top: 0; }}
  h2 {{
    font-size: 1.5em;
    font-weight: 600;
    color: var(--text);
    margin-top: 3em;
    margin-bottom: 1em;
    padding-bottom: 8px;
    border-bottom: 2px solid var(--border);
    position: relative;
  }}
  h2::before {{
    content: "";
    display: inline-block;
    width: 4px;
    height: 1em;
    background: var(--primary);
    margin-right: 10px;
    vertical-align: -2px;
    border-radius: 2px;
  }}
  h3 {{
    font-size: 1.2em;
    font-weight: 600;
    color: var(--text);
    margin-top: 2em;
    margin-bottom: 0.8em;
    padding: 6px 12px;
    background: var(--primary-light);
    border-left: 3px solid var(--primary);
    border-radius: 0 6px 6px 0;
  }}
  h4, h5, h6 {{ font-weight: 600; margin-top: 1.5em; }}
  p {{ margin: 0.6em 0; }}
  /* 行内代码 */
  code {{
    background: #f3f4f6;
    color: #d6336c;
    padding: 2px 6px;
    border-radius: 4px;
    font-family: "SF Mono", "JetBrains Mono", Menlo, monospace;
    font-size: 0.88em;
    font-weight: 500;
  }}
  /* 代码块 */
  pre {{
    background: var(--code-bg);
    color: #cdd6f4;
    padding: 16px 20px;
    border-radius: 10px;
    overflow-x: auto;
    margin: 1em 0;
    position: relative;
    font-size: 0.9em;
    line-height: 1.5;
  }}
  pre code {{
    background: transparent;
    color: inherit;
    padding: 0;
    font-weight: normal;
  }}
  .code-lang {{
    position: absolute;
    top: 6px;
    right: 12px;
    font-size: 0.75em;
    color: #6c7086;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    font-family: "SF Mono", Menlo, monospace;
  }}
  /* 列表 */
  ul, ol {{ padding-left: 28px; margin: 0.8em 0; }}
  li {{ margin: 4px 0; }}
  ul li::marker {{ color: var(--primary); }}
  ol li::marker {{ color: var(--primary); font-weight: 600; }}
  /* 链接 */
  a {{ color: var(--primary); text-decoration: none; }}
  a:hover {{ text-decoration: underline; }}
  /* 分隔线 */
  hr {{
    border: none;
    height: 1px;
    background: linear-gradient(to right, transparent, var(--border), transparent);
    margin: 3em 0;
  }}
  /* 引用块 */
  blockquote {{
    border-left: 4px solid var(--primary);
    margin: 1em 0;
    padding: 12px 20px;
    background: var(--primary-light);
    color: var(--text);
    border-radius: 0 8px 8px 0;
    font-style: normal;
  }}
  blockquote p {{ margin: 0.3em 0; }}
  /* 图片 */
  .img-figure {{
    margin: 24px 0;
    text-align: center;
  }}
  .img-figure img {{
    border: 1px solid var(--border);
    border-radius: 10px;
    box-shadow: 0 4px 12px rgba(0,0,0,0.06);
    display: block;
    margin: 0 auto;
  }}
  .img-figure figcaption {{
    margin-top: 10px;
    color: var(--text-light);
    font-size: 0.88em;
    font-style: normal;
  }}
  /* 表格 */
  .table-wrap {{
    overflow-x: auto;
    margin: 1.5em 0;
    border-radius: 8px;
    border: 1px solid var(--border);
  }}
  table {{
    border-collapse: collapse;
    width: 100%;
    background: var(--card-bg);
    font-size: 0.92em;
  }}
  th, td {{
    padding: 10px 16px;
    text-align: left;
    border-bottom: 1px solid var(--border);
  }}
  th {{
    background: #f9fafb;
    font-weight: 600;
    color: var(--text);
    border-bottom: 2px solid var(--border);
  }}
  tr:last-child td {{ border-bottom: none; }}
  tr:hover td {{ background: #f9fafb; }}
  td code {{ font-size: 0.85em; }}
  /* 强调 */
  strong {{ color: var(--text); font-weight: 600; }}
  em {{ color: var(--text-light); }}
  /* 预期段落视觉强化 */
  p > strong:first-child {{
    color: var(--primary);
  }}
</style>
</head>
<body>
{body_html}
</body>
</html>"""

    OUT_HTML.write_text(html, encoding="utf-8")
    size_mb = OUT_HTML.stat().st_size / 1024 / 1024
    print(f"\n生成 HTML: {OUT_HTML}")
    print(f"文件大小: {size_mb:.2f} MB")

if __name__ == "__main__":
    main()
