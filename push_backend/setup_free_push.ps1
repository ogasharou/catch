$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== Catch 無料iPhone通知セットアップ ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Cloudflareの無料アカウントを使います。Apple Developer登録は不要です。"
Write-Host ""

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Write-Host "Node.js が必要です。Node.js を入れてからもう一度実行してください。" -ForegroundColor Red
  exit 1
}

npm install

Write-Host ""
Write-Host "1) Cloudflareへログインします。ブラウザが開いたら許可してください。" -ForegroundColor Yellow
npx wrangler login

Write-Host ""
Write-Host "2) D1データベースを作成します。" -ForegroundColor Yellow
Write-Host "   すでに catch-push-db がある場合、作成エラーは無視して次へ進んでください。"
try {
  npx wrangler d1 create catch-push-db
} catch {}

Write-Host ""
Write-Host "IMPORTANT:" -ForegroundColor Yellow
Write-Host "上に表示された database_id を push_backend\wrangler.jsonc の"
Write-Host 'PUT_YOUR_D1_DATABASE_ID_HERE に貼り付けてください。'
Write-Host ""
Read-Host "貼り付けたら Enter"

Write-Host ""
Write-Host "3) DBテーブルを作ります。" -ForegroundColor Yellow
npx wrangler d1 execute catch-push-db --remote --file=./schema.sql

Write-Host ""
Write-Host "4) VAPIDキーを生成します。" -ForegroundColor Yellow
$keysOutput = node .\generate-vapid.mjs
$keysOutput | Write-Host

$pubLine = $keysOutput | Where-Object { $_ -like "VAPID_PUBLIC_KEY=*" } | Select-Object -First 1
$privLine = $keysOutput | Where-Object { $_ -like "VAPID_PRIVATE_KEY=*" } | Select-Object -First 1
$pub = $pubLine.Substring("VAPID_PUBLIC_KEY=".Length)
$priv = $privLine.Substring("VAPID_PRIVATE_KEY=".Length)

Write-Host ""
Write-Host "5) 秘密鍵をCloudflareへ保存します。" -ForegroundColor Yellow
$pub | npx wrangler secret put VAPID_PUBLIC_KEY
$priv | npx wrangler secret put VAPID_PRIVATE_KEY
"https://ogasharou.github.io/catch/" | npx wrangler secret put VAPID_SUBJECT

Write-Host ""
Write-Host "6) Workerを公開します。" -ForegroundColor Yellow
npx wrangler deploy

Write-Host ""
Write-Host "=== 完了 ===" -ForegroundColor Green
Write-Host "最後に表示された https://...workers.dev のURLをコピーして、"
Write-Host "Catch > 設定 > 通知サーバー設定 に貼り付けてください。"
Write-Host "その後『iPhone通知を有効にする』→『テスト通知を送る』です。"
