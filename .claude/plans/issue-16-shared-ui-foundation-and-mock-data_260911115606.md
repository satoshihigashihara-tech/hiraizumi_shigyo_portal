# 利用者画面の共通土台（仮データ・共通UI部品・CSS基準値）の実装計画

## Context

イシュー #16 は、利用者画面（#17〜#24）の着手前に「全画面で共通して使う仮データ」と「共通UI部品」を1か所へ用意する作業です。現状 `app/` 配下には `layout.js` / `page.js` / `globals.css` / `page.module.css` と `app/actions/*` しか存在せず、共通部品置き場がありません。各画面イシューが個別に仮データやバッジ表現を作ると、状態語彙（申請／納付／滞在）の取り違えや、375px崩れ、色だけの状態区別が画面ごとに発生します。本計画では `app/components/` に「仮データ1ファイル＋表示ラベル辞書＋整形関数＋共通UI部品＋CSSトークン」を新設し、`app/layout.js` と `app/globals.css` を変更しない形で完結させます。

GitHub Issue: #16

**事前確認の結果（重要）**

- `/Users/YS/camp/hiraizumi_shigyo_portal/node_modules` 自体が存在しないため、`node_modules/next/dist/docs/` も**存在しません**。AGENTS.md が要求する「Next.js該当ガイドの確認」は現時点では実施できません。実装者は最初に `npm ci`（`package.json` / `package-lock.json` を書き換えないため `npm install` ではなく `npm ci`）を実行し、`node_modules/next/dist/docs/` 配下の App Router / Server・Client Component / CSS Modules / フォームとServer Actions（`useActionState`・`useFormStatus`）の各ガイドを読んでから着手してください。ガイドの記述が本計画と食い違う場合はガイドを優先します。
- `.claude/rules/frontend.md` は Tailwind CSS・GSAP・Oswald/Inter を前提としていますが、本リポジトリは Tailwind 未導入で、`docs/coding_rules.md` 2章が「通常CSSと既存のCSS Modulesを使用する。別のUIライブラリは合意なしに追加しない」と定めています。**本計画は `docs/coding_rules.md` を優先**し、`.claude/rules/frontend.md` のTailwind/GSAP/フォント規定には従いません（この不一致はPRで東原へ共有）。`.claude/rules/security.md` のうち `rel="noopener noreferrer"` の徹底は採用します。
- 置き場の判断：Next.js App Router では `app/` 配下のフォルダは `page.js` / `route.js` を含んだときだけルートになります。`app/components/` はどちらも持たないためURLは生えません。プライベートフォルダ（`_` 接頭辞）はフォルダ名がURLセグメントになるのを明示的に打ち消すための仕組みで、今回は不要です。加えて `docs/frontend-handoff.md`「ファイルの担当境界」がフロント担当の編集先として `app/components/` を明記しているため、**`app/components/` を採用**します（`app/_components/` へ変えると合意済みの担当境界とイシュー本文の例示から外れる）。運用ルールとして「`app/components/` 配下には `page.js` / `route.js` / `layout.js` を置かない」をREADMEとPRに明記します。

---

## 変更対象ファイル

### 1. CSS基準値（デザイントークン）とページ外枠

- **新規**: `app/components/PageShell.module.css`
- **変更箇所**: ファイル全体（新規作成）
- **変更内容**:
  - `.shell` クラスにCSSカスタムプロパティで基準値を定義する。`app/globals.css` を触らずに済ませるため、**トークンは `:root` ではなく `.shell` スコープへ置く**（子孫へ継承されるので、`PageShell` の内側にある全共通部品から `var(--sg-*)` で参照できる）。
  - 余白（4px基準）: `--sg-space-1: 4px` / `-2: 8px` / `-3: 12px` / `-4: 16px` / `-5: 24px` / `-6: 32px` / `-7: 48px`
  - 文字サイズ: `--sg-font-xs: 12px` / `-sm: 14px` / `-base: 16px` / `-lg: 18px` / `-xl: 20px` / `-2xl: 24px` / `-3xl: 28px`、`--sg-line-height: 1.6`
  - 角丸・線: `--sg-radius: 8px`、`--sg-radius-pill: 999px`、`--sg-border: 1px solid var(--sg-color-border)`
  - 色（いずれも本文4.5:1以上を満たす値を採用）:
    - 基本: `--sg-color-bg: #f4f6f8` / `--sg-color-surface: #ffffff` / `--sg-color-text: #1b1d1f` / `--sg-color-text-muted: #4d5358` / `--sg-color-border: #c9ced4` / `--sg-color-focus: #1f3c88`
    - 5トーン（`AlertMessage` と `StatusBadge` が共有）:
      - neutral: `--sg-neutral-bg: #f1f3f5` / `--sg-neutral-border: #5c6670` / `--sg-neutral-text: #343a40`
      - info: `--sg-info-bg: #eaf1fb` / `--sg-info-border: #1f3c88` / `--sg-info-text: #14306e`
      - success: `--sg-success-bg: #e7f4ec` / `--sg-success-border: #0f5132` / `--sg-success-text: #0b3d26`
      - warning: `--sg-warning-bg: #fdf3e3` / `--sg-warning-border: #8a5a00` / `--sg-warning-text: #6b4400`
      - danger: `--sg-danger-bg: #fdecec` / `--sg-danger-border: #b3261e` / `--sg-danger-text: #8c1d18`
  - レイアウト: `.shell { width: 100%; max-width: 960px; margin-inline: auto; padding: var(--sg-space-5) var(--sg-space-4); color: var(--sg-color-text); background: var(--sg-color-surface); font-size: var(--sg-font-base); line-height: var(--sg-line-height); overflow-wrap: anywhere; }`、`.shell * { min-width: 0; }`（フレックス子要素の375px横溢れ防止）
  - `@media (max-width: 480px)` で `padding: var(--sg-space-4) var(--sg-space-3)` へ縮小。
  - `@media (prefers-color-scheme: dark)` ブロックで `.shell` のトークンを暗色値へ上書き（`--sg-color-surface: #14171a`、`--sg-color-text: #ececec` ほか、トーン系も暗色版を定義）。既存 `app/globals.css` が `color-scheme: dark` と暗い `body` 背景を持つため、**共通部品は必ず背景色と文字色をセットで指定**し、継承任せにしない。
  - `.title`（`--sg-font-2xl`／`font-weight: 700`）、`.description`（`--sg-color-text-muted`）、`.body`（`display: flex; flex-direction: column; gap: var(--sg-space-5)`）。
  - 共通フォーカス可視化 `.shell :focus-visible { outline: 3px solid var(--sg-color-focus); outline-offset: 2px; }`。
- **理由**: イシューの「CSSの書き方と、余白・文字サイズ・色の基準値を決める」に対する回答。`app/globals.css` は事前相談が必要なため、トークンをスコープ付きCSS Moduleに閉じ込めることで相談なしに基準値を導入できる。

### 2. ページ外枠コンポーネント

- **新規**: `app/components/PageShell.js`
- **変更箇所**: ファイル全体（新規作成）
- **変更内容**: `"use client"` を付けないServer Component。`export default function PageShell({ title, description, children })`。`<div className={styles.shell}>` の中に、`title` があれば `<h1 className={styles.title}>`、`description` があれば `<p className={styles.description}>`、続けて `<div className={styles.body}>{children}</div>` を描画する。`app/components/PageShell.module.css` を import。
- **理由**: トークンの適用点を1つに固定し、各画面が `<PageShell>` で包むだけで余白・最大幅・文字サイズ・ダークモード対応・375px対策を得られるようにする。`docs/routes.md` 9.1「Server Componentを基本とする」に沿う。

### 3. 状態値の日本語ラベル辞書

- **新規**: `app/components/status-labels.js`
- **変更箇所**: ファイル全体（新規作成）
- **変更内容**: 依存なしの純粋モジュール（`"use client"` も `server-only` も付けない）。`docs/database.md` 6章の保存値をキーにする。
  - `export const APPLICATION_STATUS_LABELS = { draft: "下書き", submitted: "申請済み", under_review: "審査中", revision_requested: "修正依頼", approved: "許可", rejected: "不許可", cancellation_requested: "キャンセル申請中", cancelled: "キャンセル済み" }`（イシュー必須の6値に加え、DBが持つ2値も未知値クラッシュ防止のため収録）
  - `export const GROUP_STATUS_LABELS`（`draft: "下書き"`, `collecting: "申請中"`, 以降は個別申請と同じ。団体画面は後続イシューだが辞書だけ先に持つ）
  - `export const PAYMENT_STATUS_LABELS = { unpaid: "未納", paid: "納付済み" }`
  - `export const STAY_STATUS_LABELS = { before_move_in: "入居前", staying: "滞在中", moved_out: "退去済み" }`
  - `export const USAGE_TYPE_LABELS = { camp: "スパルタキャンプ利用", community_individual: "地域活動利用・個人", community_group: "地域活動利用・団体" }`
  - `export const ROOM_PREFERENCE_LABELS = { shared_ok: "相部屋可", private_requested: "個室希望" }`
  - `export const USAGE_PLACE_LABELS = { common_and_second_floor: "共用部分及び2階個室" }`
  - `export const CALENDAR_AVAILABILITY_LABELS = { available: "申請可能", unavailable: "利用不可", not_yet_open: "受付開始前" }`（`docs/routes.md` 9.4）
  - `export const STATUS_KIND_LABELS = { application: "申請状態", group: "団体状態", payment: "納付状態", stay: "滞在状態" }`
  - `export const STATUS_TONES = { application: { draft: "neutral", submitted: "info", under_review: "info", revision_requested: "warning", approved: "success", rejected: "danger", cancellation_requested: "warning", cancelled: "neutral" }, payment: { unpaid: "warning", paid: "success" }, stay: { before_move_in: "neutral", staying: "info", moved_out: "neutral" }, group: { ... } }`
  - `export function statusLabel(kind, value)`：辞書に無い値・`null` は `"状態未設定"` / `"状態不明"` を返し、例外を投げない。
  - `export function statusTone(kind, value)`：未知は `"neutral"`。
  - `export function isPaymentOverdue(charge, today)`：`payment_status === "unpaid"` かつ `payment_due_date` が `today`（JST日付文字列）より前なら `true`。`docs/requirements.md` 16.2「未納のまま期限を過ぎたら『期限超過』と表示するが、納付状態は『未納』のまま」を表現するための判定のみを担い、状態値そのものは書き換えない。
- **理由**: 「申請済み」を「許可」と書かない・3種類の状態を混同しないというイシュー要件と `docs/coding_rules.md` 7章を、辞書レベルで構造的に担保する。各画面での文字列直書きを禁止できる。

### 4. エラーコード→日本語案内の辞書

- **新規**: `app/components/messages.js`
- **変更箇所**: ファイル全体（新規作成）
- **変更内容**:
  - `export const ERROR_MESSAGES = { ... }`：`docs/tasks.md` 4.2・4.4 と `docs/routes.md` 9.4・9.5 に列挙されたコードを網羅する。少なくとも `required` / `invalid` / `short` / `required-fields` / `invalid-fields` / `field-too-long` / `invalid-phone` / `invalid-place` / `invalid-period` / `invalid-duration` / `start-too-soon` / `end-too-late` / `deadline-passed` / `not-eligible` / `capacity-full` / `room-capacity-full` / `facility-capacity-full` / `calendar-unavailable` / `duplicate-stay` / `guardian-consent` / `confirmation-required` / `file-required` / `invalid-size` / `invalid-type` / `invalid-content` / `upload-failed` / `invalid-version` / `stale-update` / `revision-expired` / `not-editable` / `not-submittable` / `invalid-status` / `stay-completed` / `room-required` / `invalid-room` / `reason-required` / `reason-too-long` / `date-conflict` / `camp-has-applications` / `not-found` / `forbidden` / `load-failed` / `update-failed` / `unexpected` を収録。文言は `docs/tasks.md` 4.4 の表に合わせる（例：`stale-update` →「別の更新が先に完了したため保存されませんでした。最新の情報を読み込み直してから、もう一度ご確認ください。」）。
  - `export function errorMessage(code)`：未知コードは `"処理できませんでした。時間をおいて、もう一度お試しください。"` を返す。**コード文字列をそのまま画面へ出さない**。
  - `export const FIELD_LABELS = { applicantName: "氏名", applicantAddress: "住所", applicantPhone: "電話番号", emergencyContactName: "緊急連絡先の氏名", emergencyContactAddress: "緊急連絡先の住所", emergencyContactPhone: "緊急連絡先の電話番号", usagePurpose: "使用目的", localActivity: "平泉町内で行う活動", notes: "特記事項", usagePlace: "使用箇所", startDate: "使用開始日", endDate: "使用終了日", guardianConsentRequired: "保護者同意書の要否", requestedRoomPreference: "相部屋希望", email: "メールアドレス", password: "パスワード" }`（キーは `docs/tasks.md` 4.1・9.5 のフォーム `name` と一致させる）
  - `export const MOCK_NOTICE_TEXT = "この画面は開発用の仮データを表示しています。実際の申請データとは接続していません。"`
- **理由**: `docs/coding_rules.md` 4章「エラーコードを日本語表示へ変換する」を1か所で守る。バックエンド側の `{ error, fields, fieldErrors }` 返却（`docs/routes.md` 9.5）とフォーム名で素直に突き合わせできる。

### 5. 日本時間・金額の整形関数

- **新規**: `app/components/format.js`
- **変更箇所**: ファイル全体（新規作成）
- **変更内容**: 依存なしの純粋モジュール。すべて `Intl.DateTimeFormat("ja-JP", { timeZone: "Asia/Tokyo", ... })` を使い、実行環境のタイムゾーンに依存させない。
  - `export function formatJstDate(value)` → `"2026年9月10日"`（`null` / 不正値は `""`）
  - `export function formatJstDateTime(value)` → `"2026年9月8日 23:59"`（`docs/requirements.md` 6.2の表示形式）
  - `export function formatDeadline(value)` → DB保存値が排他的境界のため **1分引いて** 表示（`docs/database.md` 8章・`docs/routes.md` 9.4）。例：`2026-10-01T00:00+09:00` → `"2026年9月30日 23:59"`
  - `export function formatPeriod(startDate, endDate)` → `"2026年9月10日 〜 2026年9月12日"`、片方欠落は `"未定"`
  - `export function formatYen(amount)` → `"9,600円"`（`Number.isInteger` 以外は `""`）
  - `export function formatMonth(value)` → `"2026年8月"`（料金内訳の `month` 用）
  - `export function countStayDays(startDate, endDate)` → 両端を含む日数（表示補助のみ。料金確定はサーバー側）
- **理由**: 日時は全画面で必要で、サーバー（UTC想定）とブラウザの差異によるハイドレーション不一致・表示ずれを防ぐ。期限の「1分引く」ルールは見落としやすく、共通化の価値が高い。

### 6. 仮データの集約ファイル

- **新規**: `app/components/mock-data.js`
- **変更箇所**: ファイル全体（新規作成）
- **変更内容**: 冒頭に「開発用の仮データ。実在の個人情報を含まない。バックエンド接続時に削除・置換する」旨のコメントを置く。値の項目名は `docs/database.md` 5章のDB列名（snake_case）に合わせ、フォーム初期値として使うキーは `docs/tasks.md` 4.1・9.5 のフォーム名（camelCase）に合わせる。UUIDは明らかに架空と分かる反復パターン（例 `"11111111-1111-4111-8111-111111111111"`）で、既存 `UUID_PATTERN`（バージョン1〜5・variant 8/9/a/b）に適合する形にする。
  - `export const MOCK_USER`：`{ id, email: "camp-demo@example.com", full_name: "志業 太郎（架空）", address: "岩手県西磐井郡平泉町大字平泉字架空1-2-3", phone: "000-0000-0000", emergency_name: "志業 花子（架空）", emergency_address: 同上, emergency_phone: "000-0000-0001", account_state: "active" }`（`example.com` はRFC 2606の予約ドメイン、電話番号は実在しない `000-` 始まりで、`utils/community-applications/validation.js` の電話正規表現も通る）
  - `export const MOCK_CAMP`：`{ id, name: "第0期 スパルタキャンプ（架空）", start_date: "2026-08-15", end_date: "2026-09-15", application_deadline: "2026-07-31T15:00:00.000000+00:00" }`（表示は `formatDeadline` で「2026年7月31日 23:59」）
  - `export const MOCK_ROOMS`：`docs/database.md` 5.5 のマスタ8件 `[{ id, name: "桐", capacity: 1 }, { 藤, 1 }, { 梅, 2 }, { 竹, 2 }, { 松, 2 }, { あやめ, 2 }, { もみぢ, 2 }, { さくら, 3 }]`（合計15人）
  - `export const MOCK_CONTACT`：`{ name: "平泉町 担当課（架空）", phone: "000-000-0000", service_hours: "平日 8:30〜17:15" }`（`contact_settings`。滞在中表示用、任意だが安価なので収録）
  - `export const MOCK_APPLICATIONS`：3件。各要素の形は `docs/routes.md` 9.5 の `getCommunityApplication` 返却に寄せる。
    - 共通キー: `id, usage_type, camp_id, group_id, status, reception_number, start_date, end_date, user_name, user_address, user_phone, email_snapshot, emergency_name, emergency_address, emergency_phone, usage_place: "common_and_second_floor", purpose, local_activity, special_notes, requires_guardian_consent, room_preference, submitted_at, last_submitted_at, revision_due_at, decision_reason, approval_comment, updated_at, has_consent, can_edit, charge, stay, room_allocation, events`
    - `updated_at` はマイクロ秒付き文字列（例 `"2026-09-01T01:15:00.123456+00:00"`）。**画面側は Date を経由せずそのまま hidden input へ渡す**というバックエンド契約（`docs/tasks.md` 4.4）を仮データ段階から守らせる。
    - 1件目 `draft`（`usage_type: "camp"`、`camp_id: MOCK_CAMP.id`、`reception_number: null`、`submitted_at: null`、`charge: null`、`stay: null`、`room_allocation: null`、`room_preference: "shared_ok"`、`can_edit: true`、`events: []`）
    - 2件目 `revision_requested`（`usage_type: "community_individual"`、`camp_id: null`、`reception_number: "SG-2026-0001"`、`start_date: "2026-10-10"`、`end_date: "2026-10-12"`、`local_activity` あり、`revision_due_at: "2026-09-30T15:00:00.000000+00:00"`、`decision_reason: "町内で行う活動の具体的な内容を追記してください。"`、`can_edit: true`、`charge: { total_amount: 900, payment_status: "unpaid", payment_due_date: "2026-09-20", paid_at: null, calculated_at, months: [{ month: "2026-10-01", usage_days: 3, daily_rate: 300, monthly_cap: 9000, amount: 900 }] }`（期限超過表示の確認用）、`stay: null`、`events` 4件）
    - 3件目 `approved`（`usage_type: "camp"`、`reception_number: "SG-2026-0002"`、期間はキャンプ固定期間 `2026-08-15`〜`2026-09-15`、`approval_comment`、`can_edit: false`、`charge: { total_amount: 9600, payment_status: "paid", payment_due_date: "2026-08-10", paid_at, calculated_at, months: [{ month: "2026-08-01", usage_days: 17, daily_rate: 300, monthly_cap: 9000, amount: 5100 }, { month: "2026-09-01", usage_days: 15, daily_rate: 300, monthly_cap: 9000, amount: 4500 }] }`（`docs/requirements.md` 16.1 の例と一致）、`stay: { status: "before_move_in", checked_in_at: null, checked_out_at: null }`、`room_allocation: { room_id, room_name: "さくら", people_count: 1, start_date, end_date, released_from: null }`、`events` 4件）
  - `events` の各要素は本人開示可能な4項目のみ `{ from_status, to_status, public_reason, occurred_at }`（`docs/tasks.md` 4.4：職員IDは含めない）
  - `export function findMockApplication(applicationId)` / `export function findMockRoom(roomId)`：見つからなければ `null`。
  - 受付番号は `SG-西暦-連番`（`docs/requirements.md` 6.3）。**UUIDと受付番号を別値として持つ**ことを仮データでも表現する。
- **理由**: イシューの「仮データを1ファイルへ集約」「実在する個人情報は使わない」を満たしつつ、後で東原が実データへ差し替えるときに項目名の対応作業が発生しないようにする。

### 7. 状態表示部品

- **新規**: `app/components/StatusBadge.js`、`app/components/StatusBadge.module.css`
- **変更箇所**: ファイル全体（新規作成）
- **変更内容**:
  - Server Component。`export default function StatusBadge({ kind = "application", value, showKind = false })`。
  - `status-labels.js` の `statusLabel(kind, value)` と `statusTone(kind, value)` を使い、`<span className={`${styles.badge} ${styles[tone]}`}>` を描画。バッジ内に **必ず日本語ラベル文字列を描画**し、色は補助のみ（トーンごとに背景・文字色・左ボーダー3pxを変える）。
  - 種別の取り違え防止として、常にスクリーンリーダー向けに `<span className={styles.srOnly}>{STATUS_KIND_LABELS[kind]}：</span>` を先頭に入れる。`showKind` が `true` のときは視覚的にも「申請状態 許可」のように種別を表示する。
  - CSS: `display: inline-flex; align-items: center; gap: 4px; padding: 2px var(--sg-space-2); border-radius: var(--sg-radius-pill); border: 1px solid ...; font-size: var(--sg-font-sm); white-space: nowrap;`。`.srOnly` は `position:absolute; width:1px; height:1px; clip-path: inset(50%); overflow:hidden;`。
  - 併記用に `export function StatusRow({ children })`（`display:flex; flex-wrap: wrap; gap: var(--sg-space-2)`）を同ファイルから名前付きエクスポートし、申請／納付／滞在の3バッジを横並びにできるようにする（375pxでは折り返す）。
- **理由**: イシューの「色だけで区別せず文字でも表示」「申請・納付・滞在を別々の表示にする」を、部品の構造（`kind` 必須・ラベル文字列必須）で強制する。

### 8. フォーム項目部品

- **新規**: `app/components/FormField.js`、`app/components/FormField.module.css`
- **変更箇所**: ファイル全体（新規作成）
- **変更内容**:
  - Server Component（内部状態を持たない非制御入力）。`export default function FormField({ id, name, label, as = "input", type = "text", defaultValue, placeholder, hint, error, required = false, disabled = false, options, rows = 4, autoComplete, inputMode, maxLength })`。
  - 描画構造: `<div className={styles.field}>` → `<label className={styles.label} htmlFor={id}>{label}{required && <span className={styles.required}>必須</span>}</label>` → `hint` があれば `<p id={`${id}-hint`} className={styles.hint}>` → `as` に応じて `<input>` / `<textarea>` / `<select>`（`options` は `[{ value, label }]`）→ `error` があれば `<p id={`${id}-error`} className={styles.error} role="alert">{errorMessage(error)}</p>`。
  - 入力要素には `id`、`name`、`defaultValue`、`aria-invalid={Boolean(error)}`、`aria-describedby`（hint / error のidを空白区切りで結合）、`aria-required` を付ける。`required` はHTML必須属性ではなく表示とARIAで扱い、**送信自体はサーバー検証に委ねる**（ブラウザ検証だけに依存しない、`.claude/rules/security.md`）。
  - `error` にはバックエンドの `fieldErrors[name]`（エラーコード）をそのまま渡し、部品側で `errorMessage()` により日本語化する。
  - CSS: 入力欄は `width: 100%; min-height: 44px; font-size: 16px;`（iOSの自動ズーム回避）、`padding: var(--sg-space-2) var(--sg-space-3)`、`border: var(--sg-border)`、`border-radius: var(--sg-radius)`、`background: var(--sg-color-surface); color: var(--sg-color-text);`。エラー時は `.hasError` で枠線を `--sg-danger-border` にしつつ、文字によるエラー文も必ず出す。`.required` は文字「必須」を表示（色のみに頼らない）。
- **理由**: イシューの「`label` + 入力欄 + 項目別エラー表示」と `docs/requirements.md` 8.3「エラー理由を該当項目の近くへ表示し、入力済みの内容を保持する」を満たす。非制御＋`defaultValue` にすることで、Server Component のまま `fields` 再表示による入力保持が成立する。

### 9. 画面上部のエラー・お知らせ表示

- **新規**: `app/components/AlertMessage.js`、`app/components/AlertMessage.module.css`
- **変更箇所**: ファイル全体（新規作成）
- **変更内容**:
  - Server Component。`export default function AlertMessage({ tone = "info", title, children, items })`。
  - `tone` は `"error" | "warning" | "success" | "info"`。トーンに応じた見出し接頭辞テキスト（`"エラー"` / `"注意"` / `"完了"` / `"お知らせ"`）を必ず描画し、色のみで種別を伝えない。
  - `role` は `tone === "error" ? "alert" : "status"`、`aria-live` を対応させる。
  - `items` は `[{ href, label }]` の配列。渡された場合は `<ul>` でアンカーリンク（例 `href: "#applicantName"`）を描画し、`docs/requirements.md` 8.3「エラー箇所へ移動できるようにする」を満たす。
  - `export function errorAlertItems(fieldErrors)`：`{ フォーム名: コード }` を `FIELD_LABELS` と `ERROR_MESSAGES` で `[{ href: `#${name}`, label: `${FIELD_LABELS[name]}：${errorMessage(code)}` }]` へ変換するヘルパーを同ファイルから名前付きエクスポート。
  - CSS: `border-left: 4px solid`、トーン別の背景・文字色、`padding: var(--sg-space-4)`、`border-radius: var(--sg-radius)`。
- **理由**: 各画面が独自のエラー表示を作らないようにする。バックエンドの `{ error, fields, fieldErrors }` 返却形（`docs/routes.md` 9.5）を、そのまま「上部サマリー＋項目別エラー」に流し込める導線を作る。

### 10. 空一覧の案内表示

- **新規**: `app/components/EmptyState.js`、`app/components/EmptyState.module.css`
- **変更箇所**: ファイル全体（新規作成）
- **変更内容**: Server Component。`export default function EmptyState({ title = "表示できる情報はありません", description, action })`。破線枠 `border: 1px dashed var(--sg-color-border)`、中央寄せ、`padding: var(--sg-space-6) var(--sg-space-4)`。`action` は `ReactNode`（`LinkButton` を渡す想定）で、渡されなければリンクを描画しない。
- **理由**: `docs/coding_rules.md` 7章が求める「空状態」の共通化。一覧系画面（#18〜#20想定）で再利用する。

### 11. ボタン（送信中に無効化できるもの）

- **新規**: `app/components/Button.module.css`、`app/components/SubmitButton.js`、`app/components/LinkButton.js`
- **変更箇所**: ファイル全体（新規作成）
- **変更内容**:
  - `Button.module.css`：`.button`（`min-height: 44px; padding: 0 var(--sg-space-5); border-radius: var(--sg-radius); font-size: var(--sg-font-base); font-weight: 600; cursor: pointer; display: inline-flex; align-items: center; justify-content: center;`）、`.primary` / `.secondary` / `.danger`、`.button:disabled { opacity: .65; cursor: not-allowed; }`、`@media (max-width: 480px) { .fullWidthOnMobile { width: 100%; } }`、`@media (hover: hover) and (pointer: fine)` 内のみホバー指定（既存 `app/page.module.css` の書き方に合わせる）。
  - `SubmitButton.js`：**唯一の Client Component**。先頭に `"use client";`。`react-dom` の `useFormStatus()` で `pending` を取得し、`export default function SubmitButton({ children, pendingLabel = "送信中…", variant = "primary", disabled = false, pending: pendingProp })` とする。`const { pending } = useFormStatus();` と `const isPending = pendingProp ?? pending;` を組み合わせ、`useActionState` 側の `isPending` を props で上書きできるようにする（`docs/routes.md` 9.4・9.5 が `useActionState` 併用を想定しているため）。`disabled={isPending || disabled}`、`aria-busy={isPending}`、ラベルは `isPending ? pendingLabel : children`（**文字でも送信中を伝える**）。`useFormStatus` は同じ `<form>` の子孫でのみ機能するため、その制約をファイル冒頭のコメントに明記する。
  - `LinkButton.js`：Server Component。`next/link` を使い `export default function LinkButton({ href, children, variant = "secondary", fullWidthOnMobile = false })`。外部リンク用途では `rel="noopener noreferrer"` を付ける分岐を持たせる（`.claude/rules/security.md`）。
- **理由**: イシューの「ボタン（送信中に無効化できるもの）」と `docs/requirements.md` 8.3「送信処理中はボタンを無効化」を満たす。Client Component をこの1ファイルに限定し、`docs/routes.md` 9.2「必要な部分だけClient」に沿う。

### 12. 「準備中」表示部品

- **新規**: `app/components/ComingSoon.js`、`app/components/ComingSoon.module.css`
- **変更箇所**: ファイル全体（新規作成）
- **変更内容**: Server Component。`export default function ComingSoon({ title = "準備中", description })`。**クリックできる要素（`<button>` / `<a>`）を一切描画しない**仕様とし、`<p>` と補足文のみ。`aria-hidden` は付けない。冒頭コメントに「`docs/frontend-handoff.md`：対象外機能に、動くように見せるボタンを置かない」と根拠を記す。
- **理由**: イシューの「『準備中』表示用の部品」。誤って disabled ボタンを置くと「押せば動くはず」と誤解されるため、構造で禁止する。

### 13. 仮データ表示であることの明示部品

- **新規**: `app/components/MockDataNotice.js`
- **変更箇所**: ファイル全体（新規作成）
- **変更内容**: Server Component。`AlertMessage`（`tone="info"`）と `messages.js` の `MOCK_NOTICE_TEXT` を組み合わせるだけの薄いラッパー。`export default function MockDataNotice({ children })` とし、`children` があれば未接続箇所の補足を追記できる。
- **理由**: 完了条件「PR本文に、仮データであることと未接続の部分を書く」を画面側でも可視化し、レビュー時と結合時の取り違えを防ぐ。

### 14. 共通部品の使い方メモ（任意）

- **新規（任意）**: `app/components/README.md`
- **変更箇所**: ファイル全体（新規作成）
- **変更内容**: 各部品のprops一覧、`app/components/` に `page.js` / `route.js` / `layout.js` を置かない運用ルール、命名規則（コンポーネント＝PascalCaseファイル、純粋モジュール＝kebab-caseファイル）、トークン一覧、仮データの差し替え手順を短くまとめる。Next.js は `app/` 配下の `.md` をルート化しないため安全。
- **理由**: 画面イシュー #17〜#24 の担当（将来の自分・東原）が、部品を探さずに使えるようにする。不要と判断すれば各ファイル冒頭のJSDocコメントで代替する。

### 15. 変更しないファイル（要相談・今回のPRでは触らない）

- **要相談（今回は変更しない）**: `app/globals.css`、`app/layout.js`、`package.json`、`package-lock.json`
- **変更箇所**: なし
- **変更内容**:
  - `app/globals.css`：デザイントークンを `:root` へ置くのが本来は望ましいが、事前相談が必要なため今回は **`PageShell.module.css` のスコープ付きトークンで代替**する。PRに「将来 `:root` へ移す提案」として記載し、東原の合意後に別PRで移行する。
  - `app/layout.js`：`docs/routes.md` 13章は `lang="ja"` とサービス名メタデータを求める。**`lang="ja"` は2026年9月11日に対応済み**（作業ツリーで変更済み・未コミット。本PRに含める場合は事前相談対象のファイルであることをPR本文へ明記する）。`metadata` は `title: "Create Next App"` / `description: "Generated by create next app"` のままで未対応のため、同じPRで直すか別PRにするかを東原へ確認する。共通部品は `lang` に依存しない実装にする。
  - `package.json` / `package-lock.json`：UIライブラリを追加しないため変更なし。依存取得は `npm ci`（ロックファイルを書き換えない）で行う。
- **理由**: イシューの「決めること・相談すること」および `docs/frontend-handoff.md`「事前に相談」の担当境界を守る。

---

## 設計上の考慮点

**置き場の決定**：`app/components/`（`page.js` / `route.js` を持たないためルート化されない、かつ `docs/frontend-handoff.md` のフロント担当編集先と一致）。`app/_components/` のようなプライベートフォルダは、フォルダ名がURLセグメントになる場合の打ち消し手段であり、今回は不要。ただし「このフォルダに `page.js` / `route.js` / `layout.js` を追加しない」は運用ルールとして明文化する。

**Server / Client の境界**：新規13コンポーネントのうち `"use client"` を付けるのは `SubmitButton.js` だけ。`status-labels.js` / `messages.js` / `format.js` / `mock-data.js` は `server-only` を付けない純粋モジュールにして、将来の小さなClient Componentからも import 可能にする。ただし仮データは原則 Server Component で読み込み、クライアントバンドルに個人情報様のデータを載せない（`docs/routes.md` 9.2「Clientへ渡すpropsは最小限」）。

**CSS方式**：CSS Modules（`*.module.css`）をコンポーネント単位で1枚ずつ。グローバルCSSは追加しない。トークンはカスタムプロパティで `PageShell` にスコープし、各部品は `var(--sg-*, フォールバック値)` の形で書いて、`PageShell` の外で単体利用されても破綻しないようにする。

**ダークモード**：既存 `app/globals.css` が `prefers-color-scheme: dark` で `body` を暗色にし `color-scheme: dark` を設定している。共通部品は必ず `background` と `color` をセットで指定し、`PageShell.module.css` のダークモードブロックでトークンを差し替える。これにより `globals.css` を変更せずに両モードで読める。

**375px対応**：最大幅 `960px` + `margin-inline: auto`、横パディング16px（480px以下は12px）、`overflow-wrap: anywhere`、`.shell * { min-width: 0 }`、表は使わず `<dl>` / 縦積みカードを推奨、ボタンは `min-height: 44px` かつ480px以下で全幅化。既存 `globals.css` の `overflow-x: hidden` が横溢れを隠してしまうため、検証は見た目ではなく内側要素の `scrollWidth` で行う（下記検証手順）。

**状態語彙の安全性**：`statusLabel(kind, value)` が `kind` 必須のため、納付状態の値を申請状態の辞書で引く事故が起きない。未知値でも例外を投げず `"状態不明"` を返し、画面クラッシュより表示劣化を選ぶ。DB上は8値ある個別申請状態を全部収録し、イシュー記載の6値だけに絞らない（`cancellation_requested` / `cancelled` が来ても壊れない）。

**バックエンド契約との整合**：`updated_at` はマイクロ秒付き文字列のまま保持（Date変換禁止）、期限表示は保存値から1分引く、受付番号はURLクエリではなくサーバー取得値を表示する、という3点を仮データとコメントで先に固定しておく。これらは後から直すと事故になりやすい。

**トレードオフ**：(a) `format.js` / `messages.js` はイシューの箇条書きに明示されていないが、日時表記ルール（JST・期限1分引き）とエラーコード日本語化はすべての画面イシューで必ず必要になるため、共通土台に含める方が安全。(b) 部品のギャラリーページは**コミットしない**。ルートを作るのは画面イシューの範囲であり、`app/components/` にプレビュー用 `page.js` を置くとルート化されてしまうため。視覚確認は `app/page.js` を一時的に書き換えて行い、**コミット前に必ず `git checkout -- app/page.js` で戻す**。

**未解決・要相談リスト（PRに記載）**：`app/globals.css` へのトークン移設、`app/layout.js` の `metadata`（`lang="ja"` は対応済み）、`messages.js` のエラーコード網羅性と文言の妥当性、`mock-data.js` の項目名がバックエンド返却と一致しているか。

---

## 検証方法

1. `git pull` 後、`main` から `codex/user-ui-foundation` ブランチを作成する（`docs/coding_rules.md` 1章）。
2. `npm ci` を実行して依存を取得する（`npm install` は使わない。`package.json` / `package-lock.json` は相談対象）。その後 `ls node_modules/next/dist/docs/` で存在を確認し、App Router / Server・Client Components / CSS Modules / フォームと Server Actions（`useFormStatus`・`useActionState`）の各ガイドを読む。**現時点ではこのディレクトリが存在しないため、本計画はガイド未確認の状態で作成されている**。記述が食い違う場合はガイドを優先し、`SubmitButton` の `useFormStatus` の import 元とシグネチャを必ず確認する。
3. `npm run lint` が警告・エラーなしで完了することを確認する。
4. `npm run build` が成功することを確認する。未参照モジュールはバンドルされないため、ビルド成功だけを合格条件にしない（手順5の一時確認と併用する）。
5. `npm run dev` を起動し、`app/page.js` を**一時的に**共通部品のギャラリー（`PageShell` + `MockDataNotice` + 申請3件のカード + 全状態バッジ + `FormField` の各 `as` + `AlertMessage` 4トーン + `EmptyState` + `SubmitButton` + `LinkButton` + `ComingSoon`）へ差し替えて目視確認する。確認後は `git checkout -- app/page.js` で必ず元へ戻し、差分に含めない。
6. DevTools のデバイスツールバーで 375px / 390px / 768px / 1280px を確認する。`globals.css` の `overflow-x: hidden` により横溢れが隠れるため、コンソールで `[...document.querySelectorAll('*')].filter(el => el.scrollWidth > 375)` を実行して375px幅で溢れる要素が無いことを確認する。
7. DevTools の Rendering パネルで `prefers-color-scheme: dark` をエミュレートし、全部品で文字と背景のコントラストが保たれることを確認する。同じく「Emulate vision deficiencies → Achromatopsia（全色盲）」で、申請・納付・滞在の各状態が**文字だけで判別できる**ことを確認する。
8. キーボードのみで Tab 移動し、フォーカスリングが全操作要素で見えること、`<label>` クリックで対応する入力欄にフォーカスが移ること、`AlertMessage` の `items` リンクから該当入力欄へ移動できることを確認する。
9. 送信中無効化は、一時ギャラリー内に遅延させた仮のServer Action（`await new Promise((resolve) => setTimeout(resolve, 2000))`）を置いてボタンが無効化され「送信中…」と表示されることを確認し、確認後はその一時ファイルを削除する（`app/actions/` は東原の担当領域のためコミットしない）。
10. `git diff --stat` で `app/globals.css`、`package.json`、`package-lock.json`、`app/actions/*` に差分が無いことを確認する。`app/layout.js` は `lang="en"` → `lang="ja"` の1行だけが差分であることを確認し（それ以外の変更が混ざっていないこと）、事前相談対象のファイルを含む旨をPR本文へ明記する。AGENTS.md は `next dev` が同じ内容を再生成するだけなので差分が出ないことも確認する。
11. PR本文に、目的、追加した部品とpropsの一覧、**仮データであること**、未接続の部分（認証・データ取得・Server Action 未接続、`app/layout.js` の `lang="ja"` とメタデータ未対応、団体・カレンダー系部品は後続）、375px・ダークモード・キーボード操作の確認結果、`npm run lint` / `npm run build` の結果、スクリーンショットを記載し、`app/globals.css` へのトークン移設と `app/layout.js` 変更を東原へ相談事項として明記する。
