# A11 職員用配置表PDF（SQL037）

## 対象と認可

`eligible_roster` キャンプの最新の確定済み配置だけを、active職員が作成・取得できる。匿名、一般利用者、団体代表者には、存在有無を含めて氏名・対象者ID・部屋名・配置を返さない。ブラウザへStorage path、署名URL、管理キーを渡さず、Vercelには既存の公開Supabase設定と利用者JWTだけを置く。

配置表は氏名、`camp_eligible_users.id`、A3で確認済みの `print_name`、開始日・終了日を含む。メール、Auth UUID、住所、電話、申請本文、料金、納付、stayは含めない。対象集合は有効かつ `participating` の対象者だけである。

## A3・版・競合契約

生成要求と配信認可のたびに施設ロック配下で、次を再検査する。

- `saved_roster_version = roster_version`、確定日時と配置版が存在し、1〜15名全員が現在の配置版で1人1室に配置済み。
- `camp_room_plan_versions` の不変snapshot、現在割当、期間、対象集合が一致する。
- 部屋定員と施設15人上限、未解放camp claim、確認済み2階部屋、割当・印字許可、印字名が有効。
- 氏名変更を表す `roster_label_version` も一致する。対象者、氏名、部屋、期間、配置版、A8設定の変更後は旧PDFを配信しない。

`camp_room_plan_pdf_versions` は生成入力・hash・A8 contextを固定し、結果を1回だけ登録する。UPDATE/DELETEやStorage上書きを許可しない。同じ要求の再送は現在版だけ同じIDを返し、古い期待版は `stale-update`。不完全配置は `room-plan-incomplete`。A3の保存・参加終了・日程競合契約を迂回しない。

## 生成・保存・配信

A8の認証済みLinux worker、LibreOffice、Poppler、Noto Serif JP 2.003を再利用する。配置表はA4横、最大15名を複数ページへ安全に改ページし、行をページ間で分断しない。全ページPNG、文字抽出、全フォント埋込み、1〜8ページ、3MiB以下を検査した結果だけを登録する。

保存先は既存の非公開 `camp-application-pdfs` バケット内の `room-plans/{version UUID}/{attempt UUID}.pdf`。既存A7申請PDFとは名前空間・DB正本を分離する。配信は `/api/staff/camps/room-plan-pdfs/[versionId]` のGET/HEADから、Next.js → `camp-room-plan-pdf-delivery` → DB認可 → Storage hash検査 → DB再認可の順で行う。全応答はprivate/no-store、リダイレクト・Range・304を使わない。

SQL037、Function、renderer sourceを配布しても、SQL036のactive設定、非公開バケット、A7 worker secret、A11 delivery Functionが実環境で揃うまでは作成できない。秘密情報をVercelへ追加しない。

## 検証

A12で5ptから9ptへ拡大し、用紙幅・罫線・折返しを明示した。15名の通常fixtureは2ページ、camp名200文字・各氏名200文字・各部屋名100文字の最大fixtureは4ページ。両方の全ページをPNGで目視し、行分断・欠落・重なりなしを確認する。変更したrendererを配備するときは新しいOCI digestを検証して設定する（旧digestのまま差し替えない）。

`supabase/tests/staff_camp_room_plan_pdfs.sql` は職員限定、A8ゲート、完全配置、snapshot最小化、不変登録、一般利用者拒否、氏名変更後の失効、直接table権限拒否を検査する。`pdf-renderer/test-room-plan-renderer.sh` は15名の実PDFについてページ、全差込文字、Noto埋込み、PNGを検査する。CIはNode/lint/build、PostgreSQL 17.6/18.4全回帰とA8/A11レンダーartifactを実行する。
