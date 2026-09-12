# A7 キャンプ申請PDFの保存・配信基盤

## 現在の状態と適用範囲

2026年9月13日、main `90695de`（PR #102・#103、SQL 032）を基準にA7をローカル実装。
SQL 033、Edge Function、Next.js配信経路は保存済み。本番SQL未適用、バケット未作成、Function未配備。
コードの配布状態はGitHubのA7 PRを正とする。本番SQL適用はメインチャットが別途実施する。

対象は `usage_type='camp'` かつ `room_assignment_mode='eligible_roster'` の使用許可申請書PDF。
正式な使用許可通知書・納付書の生成や電子交付を追加するものではない。
保護者同意書アップロードはMVP対象外・本番未対応。既存の同意書コード・バケットとは混用せず、Vercelへ `SUPABASE_SECRET_KEY` や `SUPABASE_SERVICE_ROLE_KEY` を登録しない。
地域活動個人・団体、legacy camp、料金・納付・stay・状態遷移は変更しない。

R0の不変文書版、R1の日本語フォント消失・最大入力時のページ超過、R2のConditional Goを前提とする。
A3の実配置・配置履歴・印字許可・施設枠を接続済み。SQL036でA8の版付き設定ゲートを実装したが、migrationはactive設定を作らないため、外部配備とdigest登録までは `private.camp_pdf_render_settings(uuid)` が必ず `pdf-prerequisites-unavailable` を返す。
従って通常の生成要求はDBで拒否され、実PDF生成・確認提出を有効化しない。
テストだけがA8設定関数を架空データ用に置き換え、rollbackまたは後片付けで元に戻す。A3の配置はテストでも実際の `save_camp_room_plan` で保存する。

## 保存・認可契約

- `camp_application_versions`: 申請・camp・対象者・所有者ID、連番、要求キー、入力版、配置版、JST申請日、入力snapshot、SHA-256、版付き変換contextを固定。結果は一度だけ登録。
- `camp_pdf_jobs`: 版と1対1。要求と同一トランザクションで作成。queued → running → succeeded。失敗・期限切れは failed / expired、清掃予約は cleaning → cleaned。
- 本文・hash・contextは不変。差替えは新しいversion ID。過去版・提出済みobjectを削除しない。
- 本人はactive・対象資格・本人結合・参加状態・期限・入力版・配置版・当日JST日付・render contextが有効な、最新の未提出ready版だけを取得できる。
- active職員はsubmittedの最新版・過去版を取得できる。過去版に現在の入力や部屋設定を反映しない。資格取消・申請終了で過去の職員向け履歴を消さない。
- 団体代表者・他利用者・匿名への取得は拒否。モードcookieやURLは認可根拠にしない。
- 正本の配信はNext.js → Edge Function → DB認可 → Storage取得 → byte hash検査 → DB再認可 → 応答。GET/HEAD共通。Rangeは単一範囲のみ。HEADはHTTP仕様に従いRangeを無視して本文を返さない。
- すべての正常・エラー応答にprivate/no-store。公開URL・署名URLへのリダイレクト、ETag/304による認可省略はない。
- テーブルの直接SELECT/INSERT/UPDATE/DELETEはanon/authenticated/service_roleともgrantしない。内部RPCだけservice_roleへgrant。
- StorageにA7専用のrestrictive policyを追加する。他バケットのpermissive policyが広くてもA7の直接一覧・取得・保存・変更・削除を許可しない。他バケットの条件は維持する。
- 管理権限自体はStorage RLSを迂回する。Functionは管理権限を使う前にも検証し、書込みは `upsert:false`。管理者による直接変更までWORMストレージ同様に防ぐ仕組みではない。

## SQL 033本番適用手順（メインチャット担当）

1. mainのA3 `202609130032_camp_room_plan_bulk_save.sql` が適用済みであることを確認する。A7の旧番号032は廃止したため適用しない。
2. mainの `supabase/migrations/202609130033_camp_pdf_versions.sql` をSQL Editorに保存し、ファイル全体を1回実行する。BEGIN〜COMMITを分割しない。migration管理を使う場合も同じファイルを032の後に適用する。既適用なら再実行しない。
3. 文書表・ジョブ表・RLS・Storageのrestrictive policy・A8の拒否関数を確認する。下記は読取だけの確認SQLで、既存の個人データを取得しない。
4. SQL 033だけではバケット・Functionを作成しない。A8ゲートや印字許可を手動で解除しない。テストSQL2本はSQL Editorへ保存・本番実行しない。

```sql
select to_regclass('public.camp_application_versions') as versions,
       to_regclass('public.camp_pdf_jobs') as jobs,
       to_regprocedure('private.camp_pdf_render_settings(uuid)') as a8_gate;
select relname, relrowsecurity
from pg_class where oid in ('public.camp_application_versions'::regclass,
                           'public.camp_pdf_jobs'::regclass);
select policyname, permissive, roles, cmd, qual, with_check
from pg_policies where schemaname='storage' and tablename='objects'
  and policyname='camp_pdf_objects_boundary';
select pg_get_functiondef('private.camp_pdf_render_settings(uuid)'::regprocedure);
```

期待値は表2つ・RLS両方true、A7 policyがRESTRICTIVEでanon/authenticatedのA7バケット操作を拒否し、A8関数は `pdf-prerequisites-unavailable` を送出する定義である。

## バケット設定（外部適用の承認後）

Supabase Storage APIまたはDashboardを使う。`storage.buckets` / `storage.objects` の行をSQLで直接変更しない。

| 項目 | 値 |
|---|---|
| バケットID | `camp-application-pdfs` |
| 公開 | false |
| MIME | `application/pdf` のみ |
| 最大サイズ | 3,145,728 bytes（3 MiB） |
| object path | `{version UUID}/{attempt UUID}.pdf` |
| 保存 | 上書き禁止 |

3 MiBはA7の配信容量上限。入力文字数・1ページ収容の保証とは別の制約。ブラウザや職員の任意PDFアップロード経路はない。
配信・worker・cleanupは毎回バケット設定を確認し、不一致なら処理を拒否する。
SQL 033の `camp_pdf_objects_boundary` restrictive policyが実Storageに存在することを確認する。
SQL 033をStorageなしのPostgresに適用しただけでは、このpolicyの実Storage検証を完了したことにならない。

## 実行環境・認証（外部配備の承認後）

| 場所 | 認証・設定 |
|---|---|
| Vercel | 既存 `NEXT_PUBLIC_SUPABASE_URL` と `NEXT_PUBLIC_SUPABASE_ANON_KEY`、利用者のセッションJWTのみ |
| `camp-pdf-delivery` | Supabase内の `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY`。JWTを `auth.getUser(token)` で検証し、そのIDだけを認可RPCへ渡す |
| `camp-pdf-worker` | 同上＋32文字以上の `CAMP_PDF_WORKER_SECRET`。`x-camp-pdf-worker-secret` を照合 |
| `camp-pdf-cleanup` | 同上＋別の32文字以上の `CAMP_PDF_CLEANUP_SECRET`。`x-camp-pdf-cleanup-secret` を照合 |

各Functionのentrypointはそれぞれのディレクトリの `index.js`。CLIの既定 `index.ts` を仮定せず、配備時の設定でentrypointを指定する必要がある。
リポジトリには本番project設定や自動配備を追加していない。SDKは `npm:@supabase/supabase-js@2.116.0` 固定。
利用者JWTを渡すdeliveryはgateway JWT検査を有効にする。worker/cleanupは利用者JWTではなく専用secretで呼び出すため、gateway検査を外す場合もFunction内のsecret検査を必須とする。
secret値・JWT・PDF本文・原本・住所・氏名はログに出さない。worker用secretは信頼されたA8の変換サービスだけに渡し、ブラウザ・Vercelには置かない。
A8の変換場所はR2の認証必須Linuxコンテナ案に従う。ソースとCIは `pdf-renderer/`、配備・digest登録は [A8変換設定](camp-pdf-renderer-setup.md) に従う。A7/A8のPRでは外部コンテナを配備しない。

## A3接続済み契約とA8への引き継ぎ

`private.camp_pdf_assignment_context(application_id)` はA3の `camp_room_assignments / camp_room_plan_versions / camp_room_mapping / calendar_claims` を照合する。本人の対象者ID、割当版、期間、定員、現在配置版、未解放claim、確認済み2階部屋の印字許可を検査する。旧 `room_allocations` へのfallbackはない。

PDFにはmappingの `print_name` を使う。A8設定に同じ部屋キーが含まれても無視し、A3由来の値を上書きしない。他の未割当対象者が追加されて `roster_version != saved_roster_version` でも、本人の配置とclaimが有効なら個人PDFの生成・確認を妨げない。全員配置の完全性はA11の配置表PDFの条件である。

`private.camp_pdf_render_context` は上記の配置情報とA8設定を結合する。A8は将来の追加SQLで `private.camp_pdf_render_settings(application_id)` だけを実装し、次を保証する。

1. `template_hash / settings_version / font_version / converter_image / mayor_name` を含む、検証済みで版付きのJSONを返す。原本・フォント・変換image・設定を不変に識別する。変更すればcontextも変わること。
2. 固定原本、Noto等の同梱フォント、配備先Linuxで文字抽出・埋込み・全ページ目視・1ページ欄内収容を検証する。
3. workerへ渡す検証結果を実際に算出する。A7のPDF署名・末尾・サイズ・hash検査だけでフォント／文字／レイアウトの正しさを証明したとは扱わない。

`begin_camp_application_pdf(application UUID, expected_input_version bigint, request_key UUID)` は本人セッション専用。
同じキー・同じ有効版の再送は同じversion ID。入力や配置が変わった再送はstale-update。
新しい要求キーは新しい版を作る。最新要求ができた時点で、古い未提出版は表示・登録対象から外れる。

worker POST契約:

- `operation: claim`, 任意の `jobId`。省略時は未処理の最新要求を1件取得。ジョブID、試行ID、source hash、固定snapshot、contextを返す。ジョブなしはnull。無効になった要求を検出した場合は失敗記録後nullを返し、次の要求を妨げない。
- `operation: complete`, `jobId / attemptId / sourceHash / pdfBase64 / validation`。
- `validation` は `page_count:1 / fonts_embedded:true / text_verified:true / layout_verified:true` をすべて要求。利用者申告は受け付けない。結果のSHA-256はFunctionが実bytesから計算する。
- `operation: fail`, `jobId / attemptId`。固定コードで失敗記録。
- 要求の待機期限は15分、実行leaseは5分。別試行や期限後の結果は登録不可。同じ確定済みbytes・検証結果の再送だけ成功を再通知する。
- upload後のDB応答が不明なときは削除しない。DBが既に確定済みかもしれないため、同じ要求を再送して照合する。

## A9への接続条件

A7は公開の確認・提出RPCやそのUIを追加しない。既存の提出RPCも置き換えない。
A9は同じversion IDの表示・明示確認・提出、原本／設定／入力／本人割当／JST日付の再検査を同じ業務トランザクションに統合する。
その専用private処理だけが `private.camp_pdf_submission=allowed` をトランザクション内で設定し、ready → submittedと確認／提出日時を更新する。
この設定単独は認可ではない。A9側は本人所有・対象資格・版・hash・期限・状態・確認を検査する必要がある。
A7はテーブル更新権限を公開しておらず、authenticated/service_roleは設定値だけ変更しても更新できない。
提出に伴う申請状態・受付番号・氏名同期・監査を原子的に確定し、料金・納付・stayを維持する。

## 保持・監査・清掃

`audit_logs` の `entity_type='camp_pdf'` を使う。生成要求、実行開始、登録成功／失敗、期限切れ、結果応答の取得失敗、配信許可／拒否／取得失敗、清掃予約／完了を記録。
配信認可は取得前・送信前の2回なので1リクエストに複数の許可記録があり得る。許可記録は受信完了・本人確認・提出を意味しない。
匿名・不明UUIDの大量要求を新しい業務監査行にしない。既知版の拒否は監査し、応答には存在情報を返さない。監査挿入が失敗した場合は正本登録・配信を失敗させる。
結果応答の取得失敗は `pdf_result_response_failed` に記録し、確定済みかもしれないジョブやPDFを変更しない。失敗した結果登録の生のDBエラーや入力snapshotは監査にコピーしない。

清掃は1回1ジョブ。DB参照なし、pending版、実行lease切れから1時間超、失敗／期限切れ、実行中でないことを再確認してcleaningに固定する。
その後にStorage APIで当該パスだけを削除し、専用tokenで完了記録する。清掃予約後のcallbackは拒否。
Storage失敗や完了応答喪失時は5分の清掃lease後に同じパスを再処理できる。
ready・submittedのPDFは清掃対象外。失敗ジョブ／文書メタデータは保持する。
workerからの異常に遅い保存、管理者が作った未知のpath等は自動削除対象に広げず、実Storage受入時に棚卸し・監視運用を確認する。

## 継続的な検証

`.github/workflows/ci.yml` のPortal checksでPR/mainのNodeテスト・lint・本番build、隔離PostgreSQLの全DB回帰と実別接続競合を実行する。CIは本番secretや本番DBを使わず、SQL適用・Function配備を行わない。追加の依存はCIの一時runtimeだけに置く。

## ローカル検証の再現

依存関係は `npm ci`。DB用runtimeは既存 `/private/tmp/hiraizumi-a1-postgres` の embedded-postgres / pg を使用する。
ローカルハーネスは.envやホストSupabaseへ接続せず、一時DBを起動し終了後削除する。

```bash
node --experimental-vm-modules --test tests/camp-pdfs.test.mjs
T10_DB_RUNTIME=/private/tmp/hiraizumi-a1-postgres node scripts/test-community-applications-db.mjs camp_pdf_versions.sql camp_pdf_versions_concurrency.sql
npm test
npm run lint
npm run build
```

DB検証ではAuthとStorageの最低限を代替する。Storageのmockは明示マーカー付きで、広いpermissive policyに対してA7のrestrictive policyが効くことを検査する。
PDFのテストbytesは配信・hash検査用の架空fixtureであり、R1の日本語・1ページ問題を解決した成果物ではない。
競合検証は別接続の実ロック待機を `pg_blocking_pids` で確認する。

## 検証結果（2026年9月13日）

A7 Node54件、全Node436件、A7 DB86項目・並行9ケース、全DB1,754項目・並行116ケースが成功。SQL001〜033のローカル適用、032→033の既存行不変・合成PDFなし、後片付け、lint、Turbopack本番buildを確認。起動したNext.jsに匿名GET/HEADを送り、401・no-store・リダイレクトなしを実HTTPでも確認した。ローカルサーバーは停止済み。

## 実環境で残す受入

- SQL 033適用前後の既存行比較、Storage policy、非公開バケット設定。
- 実JWTの署名検証、本人・他利用者・無効利用者・active職員・職員取消後のGET/HEAD/Range。
- Storageの直接一覧・取得・upload・update・delete・署名URL発行の拒否。
- 本番と同じコンテナからの生成、原本hash、フォント埋込み、文字抽出、欄内収容、スマートフォンの画面内確認。
- uploadとDBの各失敗点、遅延callback、再送、既存PDFのbyte hash保持、孤立object清掃。
- 配備設定のentrypoint、worker/cleanupの独立secret、容量・timeout、ログへの個人情報混入がないこと。

これらが未確認の間は「A7の本番受入完了」「A8の生成合格」「A9の確認提出完了」としない。
