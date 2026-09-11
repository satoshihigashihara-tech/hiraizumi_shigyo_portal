# 平泉町志業支援施設 利用申請ポータル

キャンプ利用と地域活動利用の申請、審査、部屋割り、納付、入退去を一つの流れで扱う試作版です。Next.js App Router、Supabase Auth／Database／Storage、Vercelを使用します。

## ローカル起動

```bash
npm install
npm run dev
```

ブラウザで[http://localhost:3000](http://localhost:3000)を開きます。`.env.local`には次の変数名を設定し、値はGit、文書、画面、ログへ記載しません。

```text
NEXT_PUBLIC_SUPABASE_URL
NEXT_PUBLIC_SUPABASE_ANON_KEY
SUPABASE_SECRET_KEY
```

## 確認コマンド

```bash
npm test
npm run lint -- --ignore-pattern '.claude/**'
npm run build -- --webpack
```

DBの全回帰は、ローカル専用PostgreSQL実行環境がある端末で実行します。

```bash
node scripts/test-community-applications-db.mjs
```

## 本番SQLの扱い

- `supabase/migrations/`：本番用。番号順に適用し、SQL Editorで**保存する**。
- `supabase/tests/`：架空データと末尾`ROLLBACK`による検証用。SQL Editorへ**保存しない**。
- 同じ番号の本番SQLを成功後に再実行しない。
- Authの秘密鍵、定期実行用秘密値、実在利用者情報をリポジトリへ入れない。

利用終了後のアカウント初期化は、SQL027、Edge Function、Vault設定の3段階です。Vaultを設定するまでは実際の自動削除を開始しません。詳細は[アカウント初期化の本番設定](docs/account-cleanup-setup.md)を参照してください。

## 受入確認とデモ

- [MVP総合受入チェックリスト](docs/mvp-acceptance.md)
- [5役割の発表デモ手順](docs/demo-runbook.md)
- [障害時の緊急対応](docs/incident-runbook.md)
- [要件定義](docs/requirements.md)
- [画面・URL設計](docs/routes.md)
- [データベース設計](docs/database.md)

試作版を本運用へ移す前に、制度、料金、電子申請の効力、記録保存期間、同意書様式を町へ確認する必要があります。
