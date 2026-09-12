# 共同開発のコーディングルール

## 1. 作業開始前

1. `main` で `git pull` し、`codex/` から始まる作業ブランチを作る。
2. [tasks.md](tasks.md) で担当と依存関係を確認する。
3. 同じファイルを2人で同時に変更しない。必要なら先に担当範囲を連絡する。
4. Next.jsのコードを書く前に、対象機能の `node_modules/next/dist/docs/` を確認する。

1つのPull Requestは、説明できる1つの目的に絞ります。Secret key、パスワード、実在人物の個人情報、`.env.local` をコミットしてはいけません。

## 2. 使用技術と配置

- JavaScriptを使用する。新たにTypeScriptへ混在させない。
- App Routerを使用し、画面は `app/` 配下へ置く。
- 更新処理は `app/actions/` のServer Actionへ置く。
- Supabaseクライアントは `utils/supabase/` の既存部品を再利用する。
- DB変更は `supabase/migrations/` に時系列の新しいSQLとして追加する。適用済みマイグレーションを後から書き換えない。
- 通常CSSと既存のCSS Modulesを使用する。別のUIライブラリは合意なしに追加しない。

## 3. 命名と画面契約

- React component：`PascalCase`
- 関数・変数：`camelCase`
- DBテーブル・列・RPC引数：`snake_case`
- URLは [routes.md](routes.md) を正とし、独自の遷移先を増やさない。
- フォームの `name`、Action名、成功時遷移、エラーコードを変更するときは、フロント担当へ同じPull Request内または引き渡し文書で伝える。

## 4. Server Actionと入力検証

- Server Actionは直接POSTされ得る公開入口として扱う。
- Action内で毎回ログインを確認し、職員操作は職員権限も確認する。
- ID、日付、文字列、列挙値、ファイル形式・容量をサーバー側で検証する。
- 所有者、現在状態、期限、定員、料金、採番はDBでも再検査する。
- ブラウザから `user_id`、職員フラグ、金額、申請状態を受け取ってそのまま保存しない。
- `redirect()` は例外を送出するため、`try/catch` の中で呼ばない。
- 更新後は必要な `revalidatePath()` を行ってから遷移する。
- エラー時は秘密情報やDB内部情報を画面へ返さず、安定したエラーコードを日本語表示へ変換する。

## 5. Supabaseと秘密情報

- ブラウザ・通常サーバー処理は利用者セッションとRLSを使う。
- Secret keyはStorage等の必要最小限に限り、`SUPABASE_SECRET_KEY` としてサーバーだけで読む。
- Secret keyを使う前に、利用者セッションで本人・状態・権限を確認する。
- Secret keyで行うDB更新には、DB側の再検査または同等の安全な境界を設ける。
- テーブルはRLSを有効にし、必要列・必要操作だけをgrantする。
- `security definer` 関数は `set search_path = ''`、入力検証、権限確認、明示的な実行権限を必須とする。
- Storageは非公開を基本とし、公開URLを保存しない。ダウンロードは短時間の署名付きURLを使う。
- Storageの管理テーブルを直接変更せず、Storage APIまたはDashboardを使う。

## 6. DB更新と同時実行

- 重要な複数更新はRPC内の1トランザクションで行う。
- ロック順は `facility_guard` → 対象申請・団体 → 関連行 → 受付番号カウンターを守る。
- PL/pgSQLで結果を使わないクエリは `PERFORM` を使う。値を取得する `SELECT` には `INTO` を付ける。
- 下書きでは受付番号・料金確定・定員枠確保をしない。
- 二重送信しても受付番号を重複発行しない。
- アプリ側の確認だけでDB制約・RLS・RPC検査を省略しない。

## 7. UI実装

- Server Componentを基本とし、入力中の条件分岐など必要な部分だけClient Componentにする。
- スマートフォンを先に確認し、PCでも崩れないようにする。
- `label`、キーボード操作、フォーカス、送信中表示、空状態、読み込み、エラー、404を用意する。
- 色だけで状態を区別せず、必ず文字でも表示する。
- 送信失敗時に利用者の入力を可能な限り保持する。
- 「申請済み」を「許可済み」と表示しない。申請・納付・滞在の状態を分ける。

## 8. 完了前の確認

最低限、次を実行します。

```bash
npm run lint
npm run build
```

変更内容に応じて、正常系だけでなく未ログイン、別利用者、職員以外、期限境界、重複送信、定員超過、無効なファイルも確認します。SQLはファイル作成だけで完了にせず、Supabaseへの適用結果を記録します。

Pull Requestには目的、主な変更、確認結果、未確認事項、フロント担当への影響を書きます。マージ後は `main` へ戻って `git pull` し、[tasks.md](tasks.md) の状態も更新します。

## A7の追加契約（2026年9月13日）

キャンプ申請PDFには第5節の署名URL方式を使わず、毎回認証するRoute Handlerからprivate/no-storeで配信する。Supabase管理権限はSupabase側の内部Functionに限定し、Vercelへ `SUPABASE_SECRET_KEY` / `SUPABASE_SERVICE_ROLE_KEY` を登録しない。通常サーバーからは利用者JWTを渡す。

保護者同意書アップロードは現在のMVP対象外・本番未対応。既存の実装済み記述は本番利用可能という意味ではない。A7で同意書機能やフォーマットを作成・有効化しない。

A7内部Functionは既存のDeno Edge Functionと同じ配置に置き、JavaScriptの `index.js` をentrypointとして明示する。A7の同梱PDF fixtureは配信・hashテスト専用で、日本語フォントや1ページ収容の実証には使わない。

### A4のキャンプ終了処理

新方式の対象者終了をlegacy無効化・旧審査RPCへ転送しない。対象者／camp／申請の期待版、理由、確認を専用RPCへ一括で渡し、Actionから表ごとの更新をしない。入退去の互換RPCはcampモードをDBで判定する。申請なしも期待状態なので、処理直前に最新申請IDを取得して期待値を置換しない。料金やPDFの後始末を同じActionから別処理で呼ばない。[A4接続契約](camp-roster-lifecycle.md)を参照。
