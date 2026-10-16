#!/usr/bin/env python3
"""
EmojiBako用のアプリアイコンを生成
"""

from PIL import Image, ImageDraw
import subprocess
import os

def create_gradient_background(size):
    """グラデーション背景を作成"""
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    
    # グラデーション背景（紫→ピンク）
    for y in range(size):
        ratio = y / size
        r = int(147 + (236 - 147) * ratio)
        g = int(112 + (72 - 112) * ratio)
        b = int(219 + (153 - 219) * ratio)
        draw.line([(0, y), (size, y)], fill=(r, g, b, 255))
    
    # 角丸マスクを適用
    radius = int(size * 0.22)
    mask = Image.new('L', (size, size), 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.rounded_rectangle([0, 0, size-1, size-1], radius=radius, fill=255)
    img.putalpha(mask)
    
    return img

def create_icon_with_emoji(size, output_path, base_emoji_path):
    """アイコンを生成"""
    # 背景を作成
    bg = create_gradient_background(size)
    
    # 絵文字画像をリサイズして合成
    if os.path.exists(base_emoji_path):
        emoji_img = Image.open(base_emoji_path).convert('RGBA')
        
        # アスペクト比を維持してリサイズ
        emoji_size = int(size * 0.65)
        
        # 元画像の幅と高さを取得
        orig_width, orig_height = emoji_img.size
        
        # アスペクト比を維持して正方形に収める
        if orig_width > orig_height:
            new_width = emoji_size
            new_height = int(emoji_size * orig_height / orig_width)
        else:
            new_height = emoji_size
            new_width = int(emoji_size * orig_width / orig_height)
        
        emoji_img = emoji_img.resize((new_width, new_height), Image.Resampling.LANCZOS)
        
        # 中央に配置
        x = (size - new_width) // 2
        y = (size - new_height) // 2
        
        bg.paste(emoji_img, (x, y), emoji_img)
    
    bg.save(output_path)

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    output_dir = os.path.join(script_dir, "EmojiBako", "Assets.xcassets", "AppIcon.appiconset")
    
    # 絵文字画像を作成（正方形キャンバスに描画）
    emoji_png = os.path.join(script_dir, "emoji_temp.png")
    
    # AppleScriptで絵文字を正方形画像として保存
    applescript = '''
    use framework "AppKit"
    
    set emojiString to "😊"
    set fontSize to 480
    set canvasSize to 512
    
    set theFont to current application's NSFont's fontWithName:"AppleColorEmoji" |size|:fontSize
    set attribs to current application's NSDictionary's dictionaryWithObject:theFont forKey:(current application's NSFontAttributeName)
    set attString to current application's NSAttributedString's alloc()'s initWithString:emojiString attributes:attribs
    
    -- 正方形のキャンバスを作成
    set theImage to current application's NSImage's alloc()'s initWithSize:{canvasSize, canvasSize}
    theImage's lockFocus()
    
    -- 絵文字のサイズを取得
    set stringSize to attString's |size|()
    set stringWidth to stringSize's width
    set stringHeight to stringSize's height
    
    -- 中央に描画
    set xPos to (canvasSize - stringWidth) / 2
    set yPos to (canvasSize - stringHeight) / 2
    attString's drawAtPoint:{xPos, yPos}
    
    theImage's unlockFocus()
    
    set tiffData to theImage's TIFFRepresentation()
    set bitmapRep to current application's NSBitmapImageRep's imageRepWithData:tiffData
    set pngData to bitmapRep's representationUsingType:(current application's NSBitmapImageFileTypePNG) |properties|:(missing value)
    
    set savePath to "''' + emoji_png + '''"
    pngData's writeToFile:savePath atomically:true
    '''
    
    # AppleScriptを実行
    result = subprocess.run(['osascript', '-e', applescript], capture_output=True, text=True)
    if result.returncode != 0:
        print(f"AppleScript error: {result.stderr}")
        return 1
    
    if not os.path.exists(emoji_png):
        print("Failed to create emoji image")
        return 1
    
    print("Created base emoji image")
    
    # macOS用のアイコンサイズ
    sizes = [16, 32, 64, 128, 256, 512, 1024]
    icons = []
    
    for size in sizes:
        # 1x
        filename = f"icon_{size}x{size}.png"
        filepath = os.path.join(output_dir, filename)
        create_icon_with_emoji(size, filepath, emoji_png)
        icons.append({
            "filename": filename,
            "idiom": "mac",
            "scale": "1x",
            "size": f"{size}x{size}"
        })
        print(f"Generated {filename}")
        
        # 2x (512以下のみ)
        if size <= 512:
            filename_2x = f"icon_{size}x{size}@2x.png"
            filepath_2x = os.path.join(output_dir, filename_2x)
            create_icon_with_emoji(size * 2, filepath_2x, emoji_png)
            icons.append({
                "filename": filename_2x,
                "idiom": "mac",
                "scale": "2x",
                "size": f"{size}x{size}"
            })
            print(f"Generated {filename_2x}")
    
    # 一時ファイルを削除
    os.remove(emoji_png)
    
    # Contents.json を生成
    contents = {
        "images": icons,
        "info": {
            "author": "xcode",
            "version": 1
        }
    }
    
    import json
    with open(os.path.join(output_dir, "Contents.json"), 'w') as f:
        json.dump(contents, f, indent=2)
    
    print(f"\n✅ App icons generated in {output_dir}")
    print("次のステップ: Xcodeでリビルド")

if __name__ == '__main__':
    main()
