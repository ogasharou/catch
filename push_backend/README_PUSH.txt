Catch v0.42 無料iPhone通知

必要:
- CatchをiPhoneのホーム画面に追加して使う
- Cloudflare無料アカウント
- PCにNode.js

セットアップ:
1. push_backend フォルダで setup_free_push.ps1 を実行
2. 途中で表示される D1 database_id を wrangler.jsonc に貼る
3. 最後に表示される https://～.workers.dev をコピー
4. iPhoneのCatch → 設定 → 通知 → 通知サーバー設定 に貼る
5. 「iPhone通知を有効にする」を押して許可
6. 「テスト通知を送る」で確認

通知時刻:
Catchの各タスク/予定に設定されている「事前通知」を使います。
例: 締切 18:00 + 30分前 → 17:30ごろ通知。
無料Workerは5分ごとに確認するため、最大で数分程度遅れる場合があります。

注意:
Safariの普通のタブではなく、ホーム画面に追加したCatchから通知許可してください。
