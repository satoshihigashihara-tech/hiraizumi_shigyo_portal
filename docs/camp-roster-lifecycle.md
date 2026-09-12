# A4 新方式キャンプの参加終了（SQL035）

基準：main `c02b16a`（A3/A5、A7 SQL033、A6 SQL034、PostgreSQL17.6検証強化）。R0「キャンプ追加仕様の影響調査」とR2「R2 対象者・配置・提出版・認可レビュー」の契約を照合した追加実装。対象は `eligible_roster` の職員操作と共通入退去の新方式分岐。キャンプ作成・移行・期間変更・削除・再参加・滞在中の部屋移動は追加しない。本番有効化のR2条件は解除しない。

## 状態と解放日

| 操作・直前状態 | 資格／参加 | 申請 | stay |
|---|---|---|---|
| withdraw・未申請 | 無効／released | 作成しない | 作成しない |
| withdraw・draft／submitted／under_review／revision_requested | 無効／released | cancelled | 既存行を保持 |
| withdraw・approved・入居前 | 無効／released | cancelled | before_move_inのまま、架空の入退去日時を作らない |
| withdraw・滞在中 | 無効／released | cancelled | 退去確認必須。同じトランザクションでmoved_out |
| withdraw・退去済み | 無効／released | approvedを保持 | 過去の実入退去を保持 |
| withdraw・rejected／cancelled | 無効／released | 元の終了状態を保持 | 保持 |
| reject・提出済み／審査中／修正待ち／許可済み入居前 | 有効／released | rejected | 入居前の既存行を保持 |
| 共通check_out・approved・滞在中 | 有効／released | approvedを保持 | moved_out |

`reject` は未申請・draft・既終了申請・滞在中・退去済みを拒否する。共通CHECKにある地域活動用 `cancellation_requested` はこの新方式入口では受け付けない。資格無効化だけで占有を消さない。

`released_from` はDBが全ロック待機後のJST日付から決定する。開始前は開始日、開始後は確認日翌日、終了後は予定終了日翌日を上限とする。未入居でも経過済みの日付へ遡及して占有を消さない。既に退去済みなら実退去日翌日を使う。占有日は `start_date <= d <= end_date AND (released_from IS NULL OR d < released_from)`。退去当日は残す。クライアントから解放日は受け取らない。

## 原子性と正本

施設ロック（SQL026の団体期限処理を含む）→active職員・関係profile→camp→部屋／対応設定→対象者→申請→stay→対象者順の割当→claimをロックする。権限、campモード・削除、期待版、対象者・申請・stay・割当の整合を待機後に検査する。

終了処理は対象者、現在割当、不変配置版、camp版、申請、必要な退去、状態履歴、職員監査を一括更新する。監査失敗、業務エラー、直列化失敗は全体取消。二重送信・他画面・配置保存・対象者編集・本人入力・入退去との競合は古い要求を拒否し、最新期待版への自動差替えや再試行をしない。

- `roster_version` は配置対象集合からの除外で1増加。
- `room_plan_version` は未割当の終了でも1増加し、不変スナップショットを追加。
- 本人割当があれば `assignment_version` を1増加。他者の現在割当・割当版・過去配置版を変更しない。解放済み行も新しい終了スナップショットへ含める。
- 直前が完全保存済みなら `saved_roster_version` を新集合に追随させる。追加者の未配置などで未保存なら未保存のまま。
- 初回確定時刻・キャンプ専有claimは保持。最後の参加者の終了でも施設全体を地域活動へ開放しない。初回保存前は未確保のまま。
- 対象者ID・Auth結合・申請所有者・管理用氏名・入力版・氏名写し・profilesの氏名を変更しない。終了後の通常登録や全員保存で再参加させない。

## 料金・滞在・PDF・認証への影響

受付番号、料金、月別明細、納付状態、過去許可、同意書、PDF版とStorage objectは削除・再作成・減額しない。理由と終了履歴は追加する。取消時の料金調整・返金はこの操作に含めない。

共通 `update_application_stay(uuid,timestamptz,text)` と `get_application_stay(uuid)` の引数・戻り値契約を保ち、`eligible_roster` だけ `camp_room_assignments` を正本にする。`room_allocation` は互換取得キーであり、新方式の `room_allocations` 行を作る意味ではない。退去後は `is_current=false` の履歴と実stayを返す。入居はapproved・before_move_in・有効対象者・有効配置・確認済み部屋・定員・claim・JST利用期間を再検査する。修正待ち・審査中は入居できない。

A1の申請整合トリガーは「releasedかつ実moved_outのapproved」だけを履歴保持の例外とする。その他の開いた申請は参加資格が必要。既存のアカウント清掃に、新方式の有効参加予定（結合済みID、または未結合で現在の確認済みメール一致）があれば阻止する条件を追加。終了後は既存の完了・他申請・職員・団体の保護条件で清掃を再判定し、Auth削除自体は行わない。新方式登録／Auth削除全経路の受入・移行はA12に残る。

A7は終了者の未提出PDFの生成・取得・生成結果登録を資格・参加状態から拒否する。さらにcamp配置版が増加するので、そのcampの既存未提出確認版はA7の既存比較で古い版になる。他の有効参加者は再生成できる。提出済み版は改変せず、active職員は認証配信から取得できる。Storage削除やPDF状態の一括書換えは行わず、未提出版の清掃はA7の期限・参照検査に従う。A8変換器は未実装のまま。

## Server Action・取得契約

`getStaffCampRosterLifecycle(campId, eligibleUserId)` はactive職員認証後、`get_staff_camp_roster_lifecycle` を呼び、`{error, participant}` を返す。対象者ID・管理氏名・資格／参加・終了根拠・campの文字列版・対象者updated_at・最新の開いた申請（なければ最新終了申請）のID／updated_at／状態・stay状態・解放日・操作可否だけを返す。メール、Auth結合、住所、他人情報を返さない。表示の操作可否は助言であり、更新RPCが再検査する。

`endCampRosterParticipationState(previousState, FormData)`：

| フィールド | 必須条件 |
|---|---|
| `campId`, `eligibleUserId` | UUID |
| `updatedAt` | 取得した対象者のtimestamptz。小数6桁を保持 |
| `rosterVersion`, `roomPlanVersion` | bigint範囲内の10進文字列 |
| `applicationId`, `applicationUpdatedAt` | 取得時に申請ありなら両方必須。なしなら両方空 |
| `endAction` | `withdraw` または `reject` |
| `reason` | 空白除去後1〜2000文字。不許可理由は本人にも表示される |
| `confirmed` | `yes`。申請終了・資格への影響を確認 |
| `checkoutConfirmed` | 滞在中の取りやめは `yes`。対面で退去確認した場合だけ指定 |

RPCは同じ順序の期待値を `expected_*` として受け、確認はbooleanで受ける。公開RPCから `complete` を指定できない。通常退去は既存共通Actionのcheck_outを使う。成功時は `{error:null,saved:true,result}`。失敗時は `{error,fields}` で入力を保持する。DBのDETAILは返さない。成功したcamp・名簿・申請・本人画面・カレンダーを再検証する。

主なエラー：`staff-required`、`not-found`、`eligible-roster-required`、`invalid-version`、`stale-update`、`invalid-action`、`reason-required`、`reason-too-long`、`confirmation-required`、`checkout-confirmation-required`、`invalid-status`、`invalid-stay`、`invalid-allocation`、`calendar-inconsistent`。未分類は `save-failed`／`load-failed`。40001/40P01は再読込を求める `stale-update`。

新方式の終了UIはA5へ渡す。このActionは利用者向け取消や旧キャンプの無効化Actionへ接続しない。料金・滞在・提出PDFの既存取得との互換性は維持する。

## 適用と検証

本番用ファイルは **`supabase/migrations/202609130035_camp_roster_lifecycle.sql`**。メインチャットがSQL034適用済みを確認し、SQL035としてSQL Editorへ保存・番号順に適用する。本タスクは本番Supabase、Storage、Function、Vercel設定を変更しない。

SQL035は追加テーブルなし・既存業務データ更新なし。RPC定義の追加／置換とEXECUTE制限だけ。新方式campを自動作成・切替したり、部屋対応表を有効化したりしない。適用時はトランザクション末尾の成功を確認し、2つの新公開RPCと既存共通stay RPCの存在を確認する。新RPCはauthenticatedのみEXECUTE可、private helperは直接実行不可。公開前の実職員・実JWT・Storageの受入は別途必要。

検証SQL・fixtureはリポジトリ専用でSQL Editorへ保存しない。単体は末尾ROLLBACK。runnerが共有fixtureを先に読み、競合では2 worker＋observerで実Lock待機を確認し、最後に専用schema・架空データ・一時DBを削除する。

```bash
T10_DB_RUNTIME=/private/tmp/hiraizumi-a3-postgres176 T10_DB_EXPECTED_VERSION=17.6 node scripts/test-community-applications-db.mjs camp_roster_lifecycle.sql camp_roster_lifecycle_concurrency.sql
T10_DB_RUNTIME=/private/tmp/hiraizumi-a3-postgres176 T10_DB_EXPECTED_VERSION=17.6 node scripts/test-community-applications-db.mjs
npm test
npm run lint
npm run build
```

CIも同じ全DB runnerを実行する。ローカル検証はAuth/Storage代替と架空PDFメタデータを使い、本物のPDF変換・ブラウザー受入を成功扱いにしない。最終結果と配布状況は `tasks.md` のA4節に記録する。
