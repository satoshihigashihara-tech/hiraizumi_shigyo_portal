# A12 総合受入計画

2026年9月13日、静的監査基準 `fbd1c8c`（A8 PR #111、SQL036まで）。この文書は実行計画であり、総合受入成功の記録ではない。A9・A10・A11のmain反映後にrebaseし、最終commitと依存PR番号を記録して実行する。監査時点で公開中PRは0件、A12専用Issueは確認できない。既存Issue #79は発表練習まで含むため、本作業だけで閉じない。

## 既存の根拠と監査所見

- 契約は [MVP受入](mvp-acceptance.md)、[ライフサイクル](camp-roster-lifecycle.md)、[PDF保存・認可](camp-pdf-storage-setup.md)、[PDF変換設定](camp-pdf-renderer-setup.md)、[DB](database.md)、[画面・Action](routes.md) を照合する。tasks.mdの過去の未適用記述を現在の配備状況と混同しない。
- `scripts/test-community-applications-db.mjs` はローカルの新規DBのみを起動し、migrationを名前順・全文で適用する。17.6の実バージョン検査、関数本体検査、SQL032コピー一致／欠落拒否、既存行比較、別接続競合、後片付けがある。
- DBの単一接続・並行スイートはrunner内で列挙されている。後続SQLテストを置くだけでは全回帰へ追加されないため、A9〜A11の登録漏れを検査する。
- 移行時の既存行比較は個別の境界に限定される。SQL033では共通行とbackfillなし、SQL035では新方式配置・申請・保持情報も比較する。SQL036以後を含む最終アップグレードの保持範囲を追加監査する。
- CIはNode 24のtest/lint/build、PostgreSQL17.6/18.4全回帰、Linuxコンテナ内のPDF最大入力検証とartifact保存を実施する。Nodeのmockや静的UI検査だけでは実ブラウザー受入を代替しない（Next.js同梱testing/Playwright/Route Handlerガイド確認済み）。
- 現状のPDF試験は1ページ、日本語抽出、フォント埋込み、最大入力を機械検査する。PNGの目視による欄ずれ・欠落・重なりとA11配置表のQAは別途必要。

## 実行マトリクス

| 範囲 | 実行・合格条件 | 証拠 |
| --- | --- | --- |
| 移行 | 両PG版で001〜最新の空DB連続適用。旧camp・個人・団体と新方式の既存fixtureを境界前に作り、既存申請・料金・納付・stay・claim・監査・過去PDFの保持を比較。自動モード切替・過去PDF合成・設定自動有効化なし | migration一覧/hash、DB版、比較結果、cleanup |
| 本人提出 A9 | 同じPDF版の表示・明示確認・提出。未生成／失敗／未確認／古い入力版・配置版・設定版は契約どおり拒否。二重提出・再送で重複版／受付番号／料金を作らない。旧RPC・直接書込による新方式提出の迂回を拒否 | SQL・Node・実HTTP／ブラウザー |
| 修正・審査 A10 | 提出後配置変更、修正依頼、再生成、再確認・再提出、許可を最終契約に沿って検査。旧提出版と金額等の保持、途中失敗の全体取消。滞在開始後・期間変更・削除の未提供操作は閉じたまま | SQL、状態・版・監査比較 |
| 配置表 A11 | 全員配置完了を必須にし、追加／終了／氏名変更／再配置後の古い版を拒否または契約どおり表示。職員のみ取得、本人経路に他参加者情報を漏らさない | SQL、配信試験、PDF PNG |
| 同時更新 | 独立backend PIDとpg_blocking_pidsによる実待機を証明。提出対入力／配置変更／参加終了／職員失効、PDF完了対再生成／清掃、許可対再提出、対象者登録対Auth削除を確認。勝敗両順序とREPEATABLE READを必要境界で検査し、敗者の部分更新なし | 両PG版のcase別結果、cleanup |
| 認可 | 匿名・本人・別利用者・無効利用者・active職員・権限剥奪後を比較。GET/HEAD/単一Range・不正Range、no-store、UUID差替え、直接Storage一覧／取得／書込／署名URL発行を確認。管理キーをVercelへ追加しない | SQL role試験と実JWT試験を区別 |
| 他モード | legacy camp、地域個人（取消・延長・部屋・納付・入退去）、団体（招待・参加者・審査・減員・期限切れ）、公開／職員カレンダー、アカウント清掃の既存全回帰 | 全runner・Node結果 |
| PDF | 固定Linux imageで原本・設定・入力snapshot hash一致、日本語／和暦／部屋印字／最大入力／1ページ／フォント埋込み。A11最大人数も確認。全出力PNGを目視し欠落・重なりなし。PCとスマートフォンの同一版確認・提出を確認 | image digest、PDF hash、抽出・PNG、画面結果 |
| アプリ | Node全件、lint、production build、匿名の保護URLとPDF Routeの実HTTP。利用モード切替、認証後return-to、390px画面、エラー時入力保持・二重操作防止 | コマンド終了値、集計、ブラウザー結果 |

## 再現と完了手順

```bash
npm ci --no-audit --no-fund
npm test
npm run lint
npm run build
T10_DB_RUNTIME=/private/tmp/hiraizumi-a3-postgres176 T10_DB_EXPECTED_VERSION=17.6 node scripts/test-community-applications-db.mjs
T10_DB_RUNTIME=/private/tmp/hiraizumi-a1-postgres T10_DB_EXPECTED_VERSION=18.4 node scripts/test-community-applications-db.mjs
```

runtimeは各版のembedded-postgresとpgを隔離配置する。存在とバージョンを確認してから使う。PDFはCIのDocker手順を再利用し、対象commitのartifactを取得して検査する。秘密値・実個人情報をログ／Gitへ残さない。テストfixtureを本番へ投入しない。

1. A9〜A11のマージと契約を確認し、最新mainへrebase。後続の新規スイートと認可・移行境界を監査する。
2. 上記全検証を実行し、軽微な不具合と文書を補正する。制度判断や重大な新設計が必要なら、その論点だけを未決として明記する。
3. 本番の適用SQL・private bucket／Function配備・renderer digest／active設定・部屋mappingの状態を安全に照会する。未配備は未確認として残し、ローカル代替を本番成功と記録しない。既存の本番有効化条件は総合承認だけで解除しない。
4. 結果にcommit、環境、項目数、失敗／未実施理由、成果物、後片付けを記載。PR作成・push後、application／両DB／PDFと他の必須CIすべての成功を確認してマージする。紐づく専用Issueが存在する場合だけ対応範囲の完了を反映する。

## 2026年9月13日 実行結果

A9 PR #113、A10 PR #115、A11 PR #112を含むmain `303f192837fe8f69bcaa53186d1e67eb4eaa21fd` へ計画コミットを保持してrebaseした。配布と最終CIは [A12 PR #116](https://github.com/satoshihigashihara-tech/hiraizumi_shigyo_portal/pull/116) を正とする。

### 検出した欠陥と修正

1. 清掃job取得と後続Auth API DELETEの間に対象者が登録されると、未結合の有効参加予定があってもAuth／プロフィールが削除された。別接続で再現し、SQL040のAuth BEFORE DELETEトリガーへ施設ロックと参加予定の再検査を追加した。結合済みID、未結合かつ確認済みの現在メールを保護する。未確認メール・終了済み・無効・従来campへの新たな削除制限は加えない。古いREPEATABLE READは施設guard更新で拒否する。
2. A11の15名配置表が5ptかつ用紙左側に偏っていた。9ptとHTML tableの明示幅・罫線・折返しへ補正した。最大人数だけでなく、camp名200文字・各氏名200文字・各部屋名100文字の実Linuxレンダーを追加した。

既存A1/A2のAuth削除後のID保持テストは、A4の正規参加終了RPCを先に実行する契約へ整合した。参加中の削除拒否と、終了後のAuth UUID履歴保持／同じメールの別アカウントによる引継ぎ拒否を両立して検査する。制度仕様・料金・返金・本番モード切替は変更していない。

### 自動検証・PDF実物

- PostgreSQL **17.6 / 18.4**：各SQL001〜040全文適用、関数本体検査、既存単体 **2,061項目**、既存別接続 **160ケース**。A12は追加の登録→削除／削除→登録の実待機2ケース、古いREPEATABLE READ拒否1ケース、結合後メール変更・未確認メール・無効化・終了・legacy境界5ケースとprivate helper実行権限を検査する。
- SQL039→040で申請・配置・claim・料金・納付・stay・監査・過去PDFを持つfixtureの不変を確認。既存の013〜018、032→033、034→035、038→039移行保持も全実行。検証用schema・架空fixture・ローカル一時DBはrunnerのfinallyで後片付けする。
- Node **472件**、ESLint、production build成功。Python renderer **14件**成功。旧camp、地域個人、団体、カレンダー、納付・入退去、清掃の全スイートを実行。
- Linux CIのA8/A9初回最大入力PDFとA10許可後最大入力PDFは各1ページ、和暦・部屋名・日本語抽出・Noto Serif JP埋込みを確認。初回の「変更」取り消し線と許可後の線なしをPNGでも確認。
- A11修正版は通常15名が2ページ、全項目最大長の15名が4ページ。全6ページを目視し欠落・重なり・行分断なし。長文版は各ページに見出しが繰り返される。全差込文字の抽出・フォント埋込み・ページ上限・PNG生成も成功。対象成果物はCI run `34712282451` の `a11-max-room-plan-linux`。A8/A10目視基準はmain run `34711614506`。最終PR CIでも同じレンダーを再実行する。

### 本番の安全確認（変更なし）

Supabase SQL Editorで `BEGIN READ ONLY` / `ROLLBACK` の集計だけを実行した。PostgreSQL17.6、A9/A10の2公開関数とA11生成関数の存在、PDF bucket1件・公開bucket0件、Storage restrictive policy1件、active PDF設定0件、割当enabled mapping0件を確認。SQL040トリガーは0件で**本番未適用**。既存SQL文書を置換せず、新規の確認クエリを保存せず実行した。

VercelはProjectに `NEXT_PUBLIC_SUPABASE_URL` と `NEXT_PUBLIC_SUPABASE_ANON_KEY` の2件（Production/Preview）、Sharedは「No shared variables linked」。値を開かず、管理キー／worker secretを追加していない。本番トップはHTTP200、本人PDF・職員配置表PDFの匿名GETはHTTP401かつ `private, no-store, max-age=0`。保護画面はNext.jsのストリーミング応答がHTTP200になり得るため、HTTPステータスだけを認証成功や漏えい判定に使わない。

### 既知の制限と公開前条件

外部Linux常設実行先がないため、active設定0を維持する。ローカル／CIの生成成功は本番の生成・画面内確認・提出E2E成功ではない。実JWTでの本人・他人・失効職員の配信、実Storage失敗補償、スマートフォンからの同一版確認提出は本番生成を有効化できる環境で継続する。今回のrole/Storage代替による認可試験をそれらの成功に読み替えない。

SQL040を本番に適用する担当は、SQL039適用後に全文を保存・適用し、トリガー存在を確認する。Auth管理schemaへのトリガー作成権限は配備環境で検査する。外部Auth APIとの境界はローカルSQLで検証済みだが、Supabase独自のAuth実装を再現した証明ではない。SQL040適用前に清掃の自動削除や新方式の公開を有効化しない。A12で本番データを削除したり、PDF設定・部屋mapping・Cronを有効化したりしていない。
