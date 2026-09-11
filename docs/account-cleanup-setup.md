# アカウント初期化の本番設定

T22はDBのSQLだけでは認証アカウントを削除しない。`process-account-cleanup` Edge Functionを配置し、Function側とVault側に同じランダムな定期実行用秘密値を設定して初めて自動削除が動く。

## 安全な適用順

1. Edge Functionを`--no-verify-jwt`付きで配置する。Function自身が`x-cron-secret`を照合する。
2. Edge Functionの`ACCOUNT_CLEANUP_CRON_SECRET`を設定する。`SUPABASE_SERVICE_ROLE_KEY`はSupabaseの既定秘密値を使用し、ブラウザやGitへ渡さない。
3. 本番用`supabase/migrations/202609110027_account_cleanup.sql`をSQL Editorで**保存して**1回だけ実行する。この時点ではVaultの2項目がないため自動削除は動かない。
4. 対象条件と画面案内を確認した後、Vaultへ`account_cleanup_url`と`account_cleanup_cron_secret`を登録する。これが自動削除を有効にする最終操作である。

配置コマンド例（プロジェクトをリンク済みの端末で実行）:

```bash
npx supabase functions deploy process-account-cleanup --no-verify-jwt
npx supabase secrets set ACCOUNT_CLEANUP_CRON_SECRET='十分に長いランダム値'
```

Vaultへ登録するSQL例。秘密値はEdge Functionへ設定した値と同じものに置き換える。

```sql
select vault.create_secret(
  'https://PROJECT_REF.supabase.co/functions/v1/process-account-cleanup',
  'account_cleanup_url'
);
select vault.create_secret(
  '十分に長いランダム値',
  'account_cleanup_cron_secret'
);
```

本番確認では、`account_cleanup_jobs`の対象UUIDと状態だけを職員が確認する。メール、氏名、秘密値をログへ出さない。検証用`supabase/tests/account_cleanup.sql`は末尾ROLLBACKのためSQL Editorへ**保存しない**。
