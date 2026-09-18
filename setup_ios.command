#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "=== Catch iPhone setup ==="
if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter が見つかりません。Mac に Flutter をインストールしてから再実行してください。"
  exit 1
fi

flutter create --platforms=ios .

PLIST="ios/Runner/Info.plist"
if [ -f "$PLIST" ]; then
python3 - <<'PY'
from pathlib import Path
p = Path("ios/Runner/Info.plist")
s = p.read_text()
photo_key = "<key>NSPhotoLibraryUsageDescription</key>"
if photo_key not in s:
    s = s.replace(
        "</dict>",
        "  <key>NSPhotoLibraryUsageDescription</key>\n"
        "  <string>スクリーンショットから課題名・予定・日時を読み取るために写真へのアクセスを使用します。</string>\n"
        "</dict>",
        1,
    )
location_key = "<key>NSLocationWhenInUseUsageDescription</key>"
if location_key not in s:
    s = s.replace(
        "</dict>",
        "  <key>NSLocationWhenInUseUsageDescription</key>\n"
        "  <string>現在地付近の天気予報をカレンダーに表示するため、アプリ使用中のみ位置情報を使用します。</string>\n"
        "</dict>",
        1,
    )
if "<key>CFBundleDisplayName</key>" in s:
    import re
    s = re.sub(
        r"<key>CFBundleDisplayName</key>\s*<string>.*?</string>",
        "<key>CFBundleDisplayName</key>\n\t<string>Catch</string>",
        s,
        count=1,
        flags=re.S,
    )
p.write_text(s)
PY
fi

# ML Kit recent iOS packages require a modern iOS deployment target.
PODFILE="ios/Podfile"
if [ -f "$PODFILE" ]; then
  python3 - <<'PY'
from pathlib import Path
p = Path("ios/Podfile")
s = p.read_text()
lines = s.splitlines()
out = []
found = False
for line in lines:
    if line.strip().startswith("platform :ios"):
        out.append("platform :ios, '15.5'")
        found = True
    else:
        out.append(line)
if not found:
    out.insert(0, "platform :ios, '15.5'")
p.write_text("\n".join(out) + "\n")
PY
fi


# Catch only needs foreground location. Tell geolocator_apple not to request
# "Always" location permission.
if [ -f "$PODFILE" ]; then
  python3 - <<'PY'
from pathlib import Path
p = Path("ios/Podfile")
s = p.read_text()
needle = "flutter_additional_ios_build_settings(target)"
replacement = """flutter_additional_ios_build_settings(target)
    if target.name == 'geolocator_apple'
      target.build_configurations.each do |config|
        config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= ['$(inherited)']
        config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] << 'BYPASS_PERMISSION_LOCATION_ALWAYS=1'
      end
    end"""
if "BYPASS_PERMISSION_LOCATION_ALWAYS=1" not in s and needle in s:
    s = s.replace(needle, replacement, 1)
p.write_text(s)
PY
fi

flutter pub get
cd ios
pod install || pod install --repo-update
cd ..

echo
echo "完了。Xcode で ios/Runner.xcworkspace を開き、Signing & Capabilities で自分のTeamを選択してください。"
