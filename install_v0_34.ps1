param(
  [string]$ProjectPath = "C:\Users\gosho\AndroidStudioProjects\catch_app"
)

$ErrorActionPreference = "Stop"
$SourcePath = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not (Test-Path (Join-Path $ProjectPath "pubspec.yaml"))) {
  throw "Flutter project not found: $ProjectPath"
}

$BackupPath = Join-Path $ProjectPath ("catch_backup_v0_34_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
New-Item -ItemType Directory -Path $BackupPath | Out-Null

# Backup current source/config
$backupFiles = @(
  "lib\main.dart",
  "lib\cloud_sync.dart",
  "pubspec.yaml",
  "android\app\build.gradle.kts",
  "android\app\src\main\AndroidManifest.xml",
  "android\app\src\main\kotlin\com\example\catch_app\MainActivity.kt",
  "android\app\src\main\kotlin\com\example\catch_app\TeamsCaptureService.kt"
)
foreach ($rel in $backupFiles) {
  $src = Join-Path $ProjectPath $rel
  if (Test-Path $src) {
    $safeName = ($rel -replace '[\\/:*?"<>|]', '_')
    Copy-Item $src (Join-Path $BackupPath $safeName) -Force
  }
}

# Backup current launcher icons
$iconBackup = Join-Path $BackupPath "launcher_icons"
New-Item -ItemType Directory -Path $iconBackup -Force | Out-Null
Get-ChildItem (Join-Path $ProjectPath "android\app\src\main\res") -Directory -Filter "mipmap-*" -ErrorAction SilentlyContinue | ForEach-Object {
  $icon = Join-Path $_.FullName "ic_launcher.png"
  if (Test-Path $icon) {
    Copy-Item $icon (Join-Path $iconBackup ($_.Name + "_ic_launcher.png")) -Force
  }
}

# Replace Catch source files
$replaceFiles = @(
  "lib\main.dart",
  "lib\cloud_sync.dart",
  "pubspec.yaml",
  "android\app\build.gradle.kts",
  "android\app\src\main\AndroidManifest.xml",
  "android\app\src\main\kotlin\com\example\catch_app\MainActivity.kt",
  "android\app\src\main\kotlin\com\example\catch_app\TeamsCaptureService.kt"
)
foreach ($rel in $replaceFiles) {
  $src = Join-Path $SourcePath $rel
  $dst = Join-Path $ProjectPath $rel
  if (Test-Path $src) {
    $parent = Split-Path -Parent $dst
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Copy-Item $src $dst -Force
  }
}

# Replace only the APP launcher icon. Bottom navigation/tab icons are in Dart and are not changed here.
$resSource = Join-Path $SourcePath "android\app\src\main\res"
$resTarget = Join-Path $ProjectPath "android\app\src\main\res"
$mipmapFolders = @("mipmap-mdpi", "mipmap-hdpi", "mipmap-xhdpi", "mipmap-xxhdpi", "mipmap-xxxhdpi")
foreach ($folder in $mipmapFolders) {
  $srcIcon = Join-Path (Join-Path $resSource $folder) "ic_launcher.png"
  $dstFolder = Join-Path $resTarget $folder
  if (Test-Path $srcIcon) {
    New-Item -ItemType Directory -Path $dstFolder -Force | Out-Null
    Copy-Item $srcIcon (Join-Path $dstFolder "ic_launcher.png") -Force
  }
}

# Keep the full-resolution source icon in the project too.
$assetSrc = Join-Path $SourcePath "assets\catch_app_icon.png"
if (Test-Path $assetSrc) {
  $assetDstDir = Join-Path $ProjectPath "assets"
  New-Item -ItemType Directory -Path $assetDstDir -Force | Out-Null
  Copy-Item $assetSrc (Join-Path $assetDstDir "catch_app_icon.png") -Force
}

Set-Location $ProjectPath
flutter clean
flutter pub get

Write-Host ""
Write-Host "Catch v0.34 install complete." -ForegroundColor Green
Write-Host "- Calendar + magnifying-glass APP icon installed" -ForegroundColor Green
Write-Host "- Bottom task/calendar/watch tab icons were NOT changed" -ForegroundColor Green
Write-Host "- Calendar weather: current-location forecast with no API key" -ForegroundColor Green
Write-Host "- Weather uses structured forecast data; Japan cross-checks Best Match + JMA model" -ForegroundColor Green
Write-Host "- Dates keep monitoring until confirmed; prices compare sites; general watches use web search" -ForegroundColor Green
Write-Host "Backup: $BackupPath"
Write-Host "Now select the Android emulator/device and run the app again."
