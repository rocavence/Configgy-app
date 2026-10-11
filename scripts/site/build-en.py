#!/usr/bin/env python3
"""從 docs/index.html（中文）產生 docs/en/index.html（英文靜態頁），讓搜尋引擎與 LLM 不跑 JavaScript 也讀得到英文。

文字取自頁面裡的 I18N.en（用 node 讀出），套進每個 data-i 元素；head 的標題、描述、canonical、og 換成英文。
改完 docs/index.html 的文案就重跑：python3 scripts/site/build-en.py
"""

import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "docs/index.html"
OUT = ROOT / "docs/en/index.html"
SITE = "https://configgy.rocavence.com"

TITLE = "Configgy — back up and restore your Mac's config files across Macs"
DESC = ("Configgy is a free, open-source macOS menu bar app that keeps Zen Browser, Claude Code and any folder you pick "
        "as versioned zip snapshots in Dropbox, iCloud Drive or Google Drive. Preview before restoring, roll back, "
        "set up a new Mac in one go. Never copies passwords or keys.")
SHORT = "Zen Browser, Claude Code and any folder: versioned snapshots, preview before restore, one click on a new Mac. Never copies passwords or keys."
KEYWORDS = ("Configgy, macOS config backup, dotfiles backup, Zen Browser backup, Claude Code backup, restore Mac settings, "
            "new Mac setup, menu bar app, Dropbox, iCloud Drive, Homebrew cask")

# 頁面上的截圖換成英文介面，alt 也換成英文
IMAGES = {
    ('/shots/main-dark.png', 'Configgy 主視窗（深色）：最上面一句話告訴你設定都已備份，下面列出每個項目上次備份的時間'):
        ('/readme-shots/en-main-dark.png', "Configgy's main window (dark): one line says your settings are backed up; below, when each item was last backed up"),
    ('/shots/main-light.png', 'Configgy 主視窗（淺色）'):
        ('/readme-shots/en-main-light.png', "Configgy's main window (light)"),
    ('/shots/main-dark.png', '主視窗：最上面一句話說明設定是否都已備份，下面列出每個項目上次備份的時間與可還原的份數'):
        ('/readme-shots/en-main-dark.png', 'Main window: one line says whether everything is backed up; below, when each item was last backed up and how many backups can be restored'),
    ('/shots/restore-light.png', '還原預覽：列出會被取代與新增的每個檔案，確認後才還原'):
        ('/readme-shots/en-restore-light.png', 'Restore preview: every file that will be replaced or added, restored only after you confirm'),
    ('/shots/exclusions-dark.png', '設定的排除頁：一律不備份的檔案，以及每個項目實際複製的內容'):
        ('/readme-shots/en-exclusions-dark.png', 'Exclusions in Settings: files that are never backed up, and what each item actually copies'),
    ('/shots/onboarding-light.png', '第一次使用導覽：選備份資料夾、選要保護的項目'):
        ('/readme-shots/en-onboarding-light.png', 'First-run setup: choose a backup folder and the items to protect'),
}


def i18n_en(html: str) -> dict:
    start = html.index("const I18N = {")
    end = html.index("\n};", start) + 3
    js = html[start:end] + "\nprocess.stdout.write(JSON.stringify(I18N.en));"
    return json.loads(subprocess.run(["node", "-e", js], capture_output=True, text=True, check=True).stdout)


def replace_inner(html: str, key: str, value: str) -> str:
    """Replaces the contents of every element carrying data-i="key"."""
    pos = 0
    attr = f'data-i="{key}"'
    while (i := html.find(attr, pos)) != -1:
        tag_start = html.rfind("<", 0, i)
        name = re.match(r"<(\w+)", html[tag_start:]).group(1)
        open_end = html.index(">", i) + 1
        depth, j = 1, open_end
        pattern = re.compile(rf"<(/?){name}\b[^>]*>")
        while depth:
            m = pattern.search(html, j)
            depth += -1 if m.group(1) else 1
            j = m.end()
        close_start = j - len(f"</{name}>")
        html = html[:open_end] + value + html[close_start:]
        pos = open_end + len(value)
    return html


def sub1(html: str, old: str, new: str) -> str:
    assert old in html, f"找不到：{old[:60]}"
    return html.replace(old, new, 1)


def main() -> None:
    html = SRC.read_text()
    en = i18n_en(html)
    for key, value in en.items():
        if f'data-i="{key}"' in html:
            html = replace_inner(html, key, value)

    html = sub1(html, '<html lang="zh-Hant">', '<html lang="en">')
    html = re.sub(r"<title>.*?</title>", f"<title>{TITLE}</title>", html, count=1)
    html = re.sub(r'<meta name="description" content="[^"]*">', f'<meta name="description" content="{DESC}">', html, count=1)
    html = re.sub(r'<meta name="keywords" content="[^"]*">',
                  f'<meta name="keywords" content="{KEYWORDS}">', html, count=1)
    html = sub1(html, f'<link rel="canonical" href="{SITE}/">', f'<link rel="canonical" href="{SITE}/en/">')
    html = sub1(html, f'<meta property="og:url" content="{SITE}/">', f'<meta property="og:url" content="{SITE}/en/">')
    html = re.sub(r'<meta property="og:title" content="[^"]*">', f'<meta property="og:title" content="{TITLE}">', html, count=1)
    html = re.sub(r'<meta property="og:description" content="[^"]*">', f'<meta property="og:description" content="{SHORT}">', html, count=1)
    html = re.sub(r'<meta property="og:image:alt" content="[^"]*">', f'<meta property="og:image:alt" content="{TITLE}">', html, count=1)
    html = sub1(html, f'<meta property="og:image" content="{SITE}/og.png">', f'<meta property="og:image" content="{SITE}/og-en.png">')
    html = sub1(html, '<meta property="og:locale" content="zh_TW">\n<meta property="og:locale:alternate" content="en_US">',
                '<meta property="og:locale" content="en_US">\n<meta property="og:locale:alternate" content="zh_TW">')
    html = re.sub(r'<meta name="twitter:title" content="[^"]*">', f'<meta name="twitter:title" content="{TITLE}">', html, count=1)
    html = re.sub(r'<meta name="twitter:description" content="[^"]*">', f'<meta name="twitter:description" content="{SHORT}">', html, count=1)
    html = sub1(html, f'<meta name="twitter:image" content="{SITE}/og.png">', f'<meta name="twitter:image" content="{SITE}/og-en.png">')
    for (src, alt), (en_src, en_alt) in IMAGES.items():
        html = sub1(html, f'src="{src}" alt="{alt}"', f'src="{en_src}" alt="{en_alt}"')
    html = html.replace('<button data-lang="zh" class="on">中</button>', '<button data-lang="zh">中</button>')
    html = html.replace('<button data-lang="en">EN</button>', '<button data-lang="en" class="on">EN</button>')
    html = sub1(html, "<!DOCTYPE html>\n", "<!DOCTYPE html>\n<!-- 由 scripts/site/build-en.py 從 docs/index.html 產生，不要直接改 -->\n")

    left = re.findall(r"[一-鿿]+", re.sub(r"const I18N = \{.*?\n\};", "", html, flags=re.S))
    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text(html)
    print(f"寫入 {OUT.relative_to(ROOT)}；I18N 以外還有中文：{sorted(set(left))[:20]}")


if __name__ == "__main__":
    main()
