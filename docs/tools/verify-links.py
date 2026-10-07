"""校验 Markdown 里引用的本地文件（图片/文档）都存在。

只检查相对路径，忽略 http(s) 链接、锚点链接和代码块里的内容。
覆盖 README.md、NOTICE.md、docs/*.md。
"""
import os
import re
import sys

# Windows 控制台默认可能是 GBK，打印 ✓ / 中文会抛 UnicodeEncodeError。
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

# [text](target) 与 ![alt](target)
LINK_RE = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
# ``` 围栏代码块
FENCE_RE = re.compile(r"^```")


def markdown_files() -> list:
    files = []
    for name in ("README.md", "NOTICE.md"):
        p = os.path.join(ROOT, name)
        if os.path.exists(p):
            files.append(p)
    docs = os.path.join(ROOT, "docs")
    if os.path.isdir(docs):
        for f in sorted(os.listdir(docs)):
            if f.endswith(".md"):
                files.append(os.path.join(docs, f))
    return files


def strip_code_blocks(text: str) -> str:
    out, in_fence = [], False
    for line in text.splitlines():
        if FENCE_RE.match(line.strip()):
            in_fence = not in_fence
            continue
        if not in_fence:
            out.append(line)
    return "\n".join(out)


def main() -> int:
    problems = []
    checked = 0

    for md in markdown_files():
        with open(md, encoding="utf-8") as fh:
            text = strip_code_blocks(fh.read())
        base = os.path.dirname(md)

        for target in LINK_RE.findall(text):
            target = target.strip()
            if not target or target.startswith("#"):
                continue
            if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*://", target):
                continue          # 外链
            if target.startswith("mailto:"):
                continue

            path_part = target.split("#", 1)[0]
            if not path_part:
                continue
            checked += 1
            resolved = os.path.normpath(os.path.join(base, path_part.replace("/", os.sep)))
            if not os.path.exists(resolved):
                problems.append(f"{os.path.relpath(md, ROOT)} -> {target}  (不存在)")

    print(f"检查了 {checked} 个本地链接")
    if problems:
        print("\n断链:")
        for p in problems:
            print("  x " + p)
        return 1
    print("全部有效 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
