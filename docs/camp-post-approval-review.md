# A10 許可後の部屋変更・修正依頼・再審査（SQL039）

A9 PR #113・A11 PR #112のマージ済みmain `b02834b` に事前設計コミットをrebaseして実装。対象は `usage_type=camp` / `room_assignment_mode=eligible_roster`。従来camp・地域個人・団体の公開RPCと状態は保持する。

## 操作と保持

- 部屋変更はcamp開始前・全員入居前に限定し、理由と明示確認を必須にする。全有効参加者の配置、対象者更新時刻、申請ID／更新時刻（申請なしも明示）、名簿版・配置版を検査する。
- DBが実差分を求める。未申請とdraftは状態を保持。変更されたsubmitted／under_review／approvedだけをrevision_requestedへ戻す。既存revision_requestedは状態と有効期限を保持して追加変更理由を監査し、期限切れを自動再開しない。
- 修正期限はロック後DB時刻のJST日付+4日00:00とcamp開始日00:00の早い方。期限を作れない変更は全体拒否。画面に変更前後・対象者・修正期限を表示する。
- A9で本人が新しいPDFを確認・再提出した後、submitted→under_review→approved。初回許可だけstayを作成し、再許可は正常な既存before_move_inのID・値を保持する。許可履歴とstayの欠落／不整合は拒否する。
- 不許可はA4の参加終了RPCへ接続し、割当解放と申請終了を一括処理する。修正待ち・再審査中は入居できない。
- 受付番号・料金と月別明細・納付状態／日時・claim・初回配置確定時刻・過去許可・過去配置・PDF正本を保持する。減額、返金、滞在中の実部屋移動、遡及変更、再参加を追加しない。

## 公開API

`get_staff_camp_room_change_context(uuid)` は固定順のロック内で現在配置と期待値を返す。本人情報・Auth UUID・メール・Storage pathを含めない。`change_camp_rooms_and_request_revisions(uuid,bigint,bigint,jsonb,jsonb,text,boolean)` が部屋・修正依頼・配置版・履歴・監査を1トランザクションで保存する。部屋交換は完成配置で定員検査し、解放済み対象者も不変配置snapshotに残す。差分がなく集合も保存済みなら何も更新しない。

期待対象者JSONは `eligible_user_id / updated_at / application_id / application_updated_at` の4キー。全員をちょうど1回含め、申請なしは後者2項目をnullにする。旧4引数 `save_camp_room_plan` の提出後変更拒否は保持する。

`get_staff_camp_roster_application_review(uuid,uuid)` は最新submittedの正式snapshot、提出PDF履歴の最小メタデータ、現在配置、操作可否、期待版、A4不許可用期待値を返す。

`review_camp_roster_application(uuid,uuid,timestamptz,bigint,bigint,uuid,text,text)` はcamp ID、申請ID、申請updated_at、camp配置版、本人割当版、submitted PDF ID、操作、理由の順。操作は `start_review / request_revision / approve`。旧審査RPCへ新方式を転送しない。

Actionは `app/actions/staff-camp-review.js`。フォームはUUID、bigintの10進文字列、DB時刻の小数6桁を保持する。更新時に期待値を再取得して置換しない。失敗時は入力を保持し、40001／40P01も再読込を促すstale-updateへ変換する。生のDB DETAILを返さない。

## 正式提出とPDF

審査画面は編集中のapplicationsから正式提出情報を描画せず、A9の `latest_submitted_camp_pdf_version_id` が指す不変snapshotを使う。審査時に所有・scope・入力版・最後の提出時刻・source hash・生成成功・本人割当ID／版／部屋／期間を検査する。現在のactiveテンプレートや今日の日付へ過去の正式提出を読み替えない。他者の部屋だけの変更で本人のsubmitted版を無効にしない。

A4は変更のない本人割当行の配置版を更新しない。そのためA7の現在配置取得を、camp最新の不変snapshotに本人の割当が正確に含まれることを検査する方式へ補正した。未提出PDFはcamp版・当日・入力・設定の比較を引き続き行い、旧版の提出や遅延callbackを拒否する。提出PDFの本文、結果、Storage objectは変更しない。

A11は配置版または氏名版が変わった生成物を現行として使わない。A10はA11文書やjobを直接更新しない。A8の過去許可判定と取り消し線を維持し、許可後最大入力の実PDFレンダーをCIへ追加した。変換エンジン・Word原本・フォント・active設定自体は変更しない。

## 検証と適用

ローカルPostgreSQL17.6／18.4でSQL001〜039の全文適用、038→039の既存行不変、全DB単体と別接続競合を実行する。A10の単体は初回許可→部屋変更→再提出→再許可を2周し、stay・料金・納付・過去PDFの保持を比較する。28並行ケースはobserverで実Lock待機を確認し、二重操作、A3保存、A9提出／入力、A4終了、納付、権限取消、期限越え、A7/A11 callbackを検証する。fixtureは架空データで、最後にschema・一時DBを除去する。

全Node、lint、本番build、GitHub ActionsのPG2版とA8/A10/A11 Linux PDF回帰を完了条件とする。PDFは埋込み・抽出・ページ数・PNGを確認する。DB用架空PDFのhash保持を実PDF生成合格として扱わない。

本番用SQLは `supabase/migrations/202609130039_camp_post_approval_review.sql`。SQL038の後にメインチャットが保存・適用する。テストSQLとfixtureを本番SQL Editorへ保存しない。この変更は本番SQL適用・実JWT受入・外部Function/Storage配備・新方式の本番有効化を行わない。コードの最終検証・配布状態はtasks.mdと対応PRを参照する。
