param(
  [string]$ProjectPath = "C:\Users\gosho\AndroidStudioProjects\catch_app"
)

$ErrorActionPreference = "Stop"

$flutterCandidates = @(
  "C:\Users\gosho\Downloads\develop\flutter\bin\flutter.bat",
  (Join-Path $env:USERPROFILE "Downloads\develop\flutter\bin\flutter.bat")
)

$flutter = $null
foreach ($candidate in $flutterCandidates) {
  if (Test-Path $candidate) {
    $flutter = $candidate
    break
  }
}

if (-not $flutter) {
  $cmd = Get-Command flutter -ErrorAction SilentlyContinue
  if ($cmd) { $flutter = $cmd.Source }
}

if (-not $flutter) {
  throw "Flutter が見つかりません。Flutter の場所を確認してください。"
}

if (-not (Test-Path (Join-Path $ProjectPath "pubspec.yaml"))) {
  throw "Catch プロジェクトが見つかりません: $ProjectPath"
}

Set-Location $ProjectPath

Write-Host "=== Catch Android APK build ===" -ForegroundColor Cyan
& $flutter clean
& $flutter pub get
& $flutter build apk --release

$apk = Join-Path $ProjectPath "build\app\outputs\flutter-apk\app-release.apk"
if (-not (Test-Path $apk)) {
  throw "APK の生成に失敗しました。"
}

$out = Join-Path $env:USERPROFILE "Downloads\Catch.apk"
Copy-Item $apk $out -Force

Write-Host ""
Write-Host "完成: $out" -ForegroundColor Green
Write-Host "Android に Catch.apk を送って開けばインストールできます。" -ForegroundColor Green
