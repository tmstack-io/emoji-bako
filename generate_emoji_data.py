#!/usr/bin/env python3
"""
Unicode emoji-test.txt から emoji-data.json を生成するスクリプト

各絵文字エントリは {"char": <絵文字>, "name": <英語ラベル>} オブジェクトとして
出力され、検索機能のラベルとして利用される。

使い方:
    python3 generate_emoji_data.py

最新の絵文字に更新する手順:
    1. https://unicode.org/Public/emoji/ から最新バージョンを確認
    2. 下のEMOJI_VERSION を更新
    3. このスクリプトを実行
    4. Xcodeでリビルド
"""

import re
import json
import urllib.request
from collections import OrderedDict
from pathlib import Path

# 絵文字バージョン（更新時にここを変更）
EMOJI_VERSION = "15.1"

# スキントーン修飾子のコードポイント
SKIN_TONE_MODIFIERS = {'1F3FB', '1F3FC', '1F3FD', '1F3FE', '1F3FF'}

# emoji-test.txt の行フォーマット例:
#   1F600 ; fully-qualified     # 😀 E1.0 grinning face
# `# <絵文字> E<バージョン> <ラベル>` の構造から絵文字とラベルを抽出する。
EMOJI_LINE_RE = re.compile(r'#\s*(\S+)\s+E\d+(?:\.\d+)?\s+(.+?)\s*$')
# フォールバック: バージョン表記が無い等の異形に備え、最低限「絵文字」だけは取る。
EMOJI_FALLBACK_RE = re.compile(r'#\s*(\S+)')

def download_emoji_test():
    """Unicode公式からemoji-test.txtをダウンロード"""
    url = f"https://unicode.org/Public/emoji/{EMOJI_VERSION}/emoji-test.txt"
    print(f"Downloading {url}...")
    
    try:
        with urllib.request.urlopen(url) as response:
            return response.read().decode('utf-8')
    except Exception as e:
        print(f"Error downloading: {e}")
        return None

def has_skin_tone(codepoints_str):
    """スキントーン修飾子が含まれているかチェック"""
    codepoints = codepoints_str.strip().split()
    return any(cp in SKIN_TONE_MODIFIERS for cp in codepoints)

def parse_emoji_test(content):
    """emoji-test.txtをパースしてカテゴリ別絵文字を抽出"""
    categories = OrderedDict()
    current_group = None
    
    # グループ名をアプリ用にマッピング
    group_mapping = {
        "Smileys & Emotion": ("smileys", "Smileys", "face.smiling"),
        "People & Body": ("people", "People", "person"),
        "Animals & Nature": ("animals", "Animals & Nature", "hare"),
        "Food & Drink": ("food", "Food & Drink", "fork.knife"),
        "Travel & Places": ("travel", "Travel", "car"),
        "Activities": ("activities", "Activities", "sportscourt"),
        "Objects": ("objects", "Objects", "desktopcomputer"),
        "Symbols": ("symbols", "Symbols", "heart"),
        "Flags": ("flags", "Flags", "flag"),
        "Component": None,  # スキップ
    }
    
    for line in content.split('\n'):
        line = line.strip()
        
        # グループ行
        if line.startswith('# group:'):
            group_name = line.replace('# group:', '').strip()
            if group_name in group_mapping and group_mapping[group_name]:
                current_group = group_mapping[group_name]
                if current_group[0] not in categories:
                    categories[current_group[0]] = {
                        'id': current_group[0],
                        'name': current_group[1],
                        'icon': current_group[2],
                        'emojis': []
                    }
            else:
                current_group = None
            continue
        
        # 空行やコメント行をスキップ
        if not line or line.startswith('#'):
            continue
        
        # fully-qualified の絵文字のみ取得
        if '; fully-qualified' not in line:
            continue
        
        if current_group is None:
            continue
        
        # コードポイント部分を取得
        codepoints_str = line.split(';')[0].strip()
        
        # スキントーンが含まれている場合はスキップ
        if has_skin_tone(codepoints_str):
            continue
        
        # 絵文字とラベルを抽出（`# 😀 E1.0 grinning face` 形式から両方を取る）
        match = EMOJI_LINE_RE.search(line)
        if match:
            emoji = match.group(1)
            name = match.group(2).strip()
        else:
            # フォールバック: ラベル抽出失敗時は絵文字だけ取り、name は空文字
            fallback = EMOJI_FALLBACK_RE.search(line)
            if not fallback:
                continue
            emoji = fallback.group(1)
            name = ''

        categories[current_group[0]]['emojis'].append({
            'char': emoji,
            'name': name,
        })

    return list(categories.values())

def main():
    # スクリプトのディレクトリを取得
    script_dir = Path(__file__).parent
    output_path = script_dir / "EmojiPicker" / "emoji-data.json"
    
    # emoji-test.txt をダウンロード
    content = download_emoji_test()
    if content is None:
        print("Failed to download emoji-test.txt")
        return 1
    
    # パース
    print("Parsing emoji data...")
    categories = parse_emoji_test(content)
    
    # JSON出力
    output = {
        "version": EMOJI_VERSION,
        "categories": categories
    }
    
    with open(output_path, 'w', encoding='utf-8') as f:
        json.dump(output, f, ensure_ascii=False, indent=2)
    
    # 統計を出力
    total = sum(len(c['emojis']) for c in categories)
    labeled = sum(1 for c in categories for e in c['emojis'] if e.get('name'))
    print(f"\n✅ Generated {output_path}")
    print(f"   Unicode Emoji Version: {EMOJI_VERSION}")
    print(f"   Total categories: {len(categories)}")
    print(f"   Total emojis: {total}")
    if total:
        print(f"   With name label: {labeled} ({labeled * 100 / total:.1f}%)")
    print()
    for cat in categories:
        print(f"   - {cat['name']}: {len(cat['emojis'])} emojis")
    
    print("\n次のステップ: Xcodeでアプリをリビルドしてください")
    return 0

if __name__ == '__main__':
    exit(main())
