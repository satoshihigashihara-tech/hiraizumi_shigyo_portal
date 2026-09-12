# A9 キャンプ申請PDF確認・提出契約

対象は `room_assignment_mode=eligible_roster` の本人申請だけ。legacy campとcommunityの保存・提出契約は変更しない。SQL037はA11予約済みのため、本機能はSQL038を使う。

## 利用者フロー

1. 本人は割り当て済みの申請で本人情報を保存する。部屋希望は入力せず、A3の事前割当を正本にする。
2. 確認画面で現在の入力版からPDF生成を要求する。生成済みPDFは認証済みの既存Routeから同じ不変版を表示する。
3. 利用者は1ページ全体と氏名同期の説明を確認し、チェック後にそのPDF版だけを提出する。

初回および許可以前の変更では様式中の `（変更）` に取り消し線を付け、過去に許可履歴がある変更では取り消し線を外す。判定はA7 snapshotの `previously_approved`、描画はA8 rendererを正本とする。

## DB境界

- `save_camp_roster_application_draft`: 所有者、active、名簿資格、期限、期待入力版を再検査し、許可された本人項目だけを保存する。
- `get_my_camp_pdf_submission_context`: 本人へ氏名3種と公開PDF状態だけを返す。メール、Storage path、snapshot、render context、worker情報は返さない。
- `submit_camp_application_with_pdf`: 施設から申請・PDFまで固定順でロックし、所有、資格、期限、入力版、配置版、active設定版、JST申請日、ready検証、生成job成功、同意書を再検査する。

提出は申請状態、受付番号・初回料金、PDF `ready→submitted`、提出PDF参照、プロフィール氏名、対象者管理用氏名、状態・氏名・PDF監査を1トランザクションで保存する。同じsubmission keyは同じ結果を返し、異なる2回目は拒否する。差し戻し再提出では既存の受付番号、料金・納付、滞在を変更しない。監査を含むどの書込みに失敗しても全体をrollbackする。

入力、配置、印字対応、active template、JST日付の変更後は古いPDFを提出できない。legacy保存・提出RPCから新方式を更新できないようDB境界でも閉じる。

## 運用

SQL038だけではA8 active設定や外部rendererを有効化しない。A7/A8の受入条件を満たすまで生成はfail closed。本機能のために `SUPABASE_SECRET_KEY` をVercelへ登録しない。ブラウザーへservice credential、署名秘密、Storage pathを渡さない。本番Supabase・Vercelへの適用は別承認作業とする。

ローカル検証はNode、lint、production build、PostgreSQL 17.6/18.4の全回帰・複数接続競合、A8 Python/LibreOffice/Popplerの1ページ検査を行う。
