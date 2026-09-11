# 利用者・職員画面の共通UI部品

イシュー #16 で用意した共通土台です。利用者画面に加え、職員画面でもこのフォルダの部品を再利用します。各画面で独自のバッジ・エラー表示・ボタンを作らないようにします。仮データは利用者画面の初期実装専用であり、職員画面では使いません。

## 運用ルール

- **このフォルダに `page.js` / `route.js` / `layout.js` を置かない。** Next.js App Router では `app/` 配下のフォルダは `page.js` か `route.js` を含んだときだけURLになります。この2つを置かない限り `app/components/` はルート化されません。`.md` はルート化されません。
- 命名は、React component が `PascalCase.js`、依存なしの純粋モジュールが `kebab-case.js`（`docs/coding_rules.md` 3章）。
- CSSは CSS Modules（`*.module.css`）をコンポーネント単位で1枚。`app/globals.css` は「事前に相談」対象のため追加・変更しない。
- Client Component は `SubmitButton.js` だけ。ほかは Server Component のまま使う（`docs/routes.md` 9.1・9.2）。
- 状態の文字列を画面へ直接書かない。必ず `status-labels.js` を通す。
- エラーコードを画面へ直接出さない。必ず `messages.js` の `errorMessage()` を通す。

## CSS基準値（デザイントークン）

`PageShell.module.css` の `.shell` に定義し、子孫へ継承させています。各部品は `var(--sg-*, フォールバック値)` の形で参照するので、`PageShell` の外で単体利用しても最低限は破綻しません。ただしダークモードの差し替えは `.shell` 側にあるため、**原則として `PageShell` の内側で使ってください**。

| 種別 | トークン |
|---|---|
| 余白（4px基準） | `--sg-space-1`(4) 〜 `--sg-space-6`(32) |
| 文字サイズ | `--sg-font-xs`(12) 〜 `--sg-font-2xl`(24)、`--sg-line-height`(1.6) |
| 角丸 | `--sg-radius`(8px)、`--sg-radius-pill`(999px) |
| 基本色 | `--sg-color-surface / -text / -text-muted / -border / -focus` |
| 5トーン | `--sg-{neutral,info,success,warning,danger}-{bg,border,text}` |

`prefers-color-scheme: dark` のときは `.shell` 側でトークンを暗色へ差し替えます。新しい部品を足すときも、**背景色と文字色を必ずセットで指定**してください（`app/globals.css` が `color-scheme: dark` と暗い `body` 背景を持つため、継承任せにすると片方だけ暗くなります）。

## 部品一覧

| ファイル | 種別 | props |
|---|---|---|
| `PageShell.js` | Server | `title` / `description` / `children` |
| `StatusBadge.js` | Server | `kind`(`application`\|`group`\|`payment`\|`stay`、既定 `application`) / `value` / `showKind` |
| `StatusBadge.js` の `StatusRow` | Server | `children`（バッジ併記用。375pxで折り返す） |
| `FormField.js` | Server | `id` / `name` / `label` / `as`(`input`\|`textarea`\|`select`\|`checkbox`\|`radio`) / `type` / `defaultValue` / `placeholder` / `hint` / `error` / `required` / `disabled` / `options` / `rows` / `autoComplete` / `inputMode` / `maxLength` / `accept` / `value`(`checkbox`) / `defaultChecked`(`checkbox`) |
| `AlertMessage.js` | Server | `tone`(`error`\|`warning`\|`success`\|`info`) / `title` / `children` / `items` |
| `AlertMessage.js` の `errorAlertItems` | 関数 | `fieldErrors` → `[{ href, label }]` |
| `EmptyState.js` | Server | `title` / `description` / `action` |
| `SubmitButton.js` | **Client** | `children` / `pendingLabel` / `variant`(`primary`\|`secondary`\|`danger`) / `disabled` / `pending` / `fullWidthOnMobile` / `name` / `value` |
| `LinkButton.js` | Server | `href`(必須) / `children` / `variant`(`primary`\|`secondary`\|`danger`) / `fullWidthOnMobile`（`http(s)` / `mailto:` / `tel:` と同一オリジンの相対パスだけを描画し、それ以外の `href` は何も描画しない） |
| `ComingSoon.js` | Server | `title` / `description`（クリックできる要素を描画しない） |
| `MockDataNotice.js` | Server | `children` |

すべて `app/components/` にあります。別名エクスポートの2つを除き、次の形でインポートします。

```jsx
import AlertMessage, { errorAlertItems } from "@/app/components/AlertMessage";
import ComingSoon from "@/app/components/ComingSoon";
import EmptyState from "@/app/components/EmptyState";
import FormField from "@/app/components/FormField";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import StatusBadge, { StatusRow } from "@/app/components/StatusBadge";
import SubmitButton from "@/app/components/SubmitButton";
```

純粋モジュール：

| ファイル | 主なエクスポート |
|---|---|
| `status-labels.js` | `statusLabel(kind, value)` / `statusTone(kind, value)` / `isPaymentOverdue(charge, today)` / 各 `*_LABELS` |
| `messages.js` | `errorMessage(code)` / `fieldLabel(name)` / `ERROR_MESSAGES` / `FIELD_LABELS` / `MOCK_NOTICE_TEXT` |
| `format.js` | `formatJstDate` / `formatJstDateTime` / `formatDeadline` / `formatPeriod` / `formatYen` / `formatMonth` / `countStayDays` / `jstToday` |
| `mock-data.js` | `MOCK_USER` / `MOCK_CAMP` / `MOCK_ROOMS` / `MOCK_CONTACT` / `MOCK_APPLICATIONS` / `MOCK_APPLICATION_LIST` / `findMockApplication` / `findMockRoom` |

## 使い方の例

```jsx
import PageShell from "@/app/components/PageShell";
import MockDataNotice from "@/app/components/MockDataNotice";
import StatusBadge, { StatusRow } from "@/app/components/StatusBadge";
import { MOCK_APPLICATIONS } from "@/app/components/mock-data";
import { formatPeriod, formatYen, jstToday } from "@/app/components/format";
import { isPaymentOverdue } from "@/app/components/status-labels";

export default function Page() {
  const today = jstToday(); // Serverで1度だけ求めてpropsで配る
  const application = MOCK_APPLICATIONS[2];

  return (
    <PageShell title="申請の詳細" description="内容と状態を確認できます。">
      <MockDataNotice />
      <StatusRow>
        <StatusBadge kind="application" value={application.status} />
        <StatusBadge kind="payment" value={application.charge?.payment_status} />
        <StatusBadge kind="stay" value={application.stay?.status} />
      </StatusRow>
      <p>{formatPeriod(application.fields.start_date, application.fields.end_date)}</p>
      <p>
        {formatYen(application.charge?.total_amount)}
        {isPaymentOverdue(application.charge, today) && "（期限超過）"}
      </p>
    </PageShell>
  );
}
```

フォームとエラー表示：

```jsx
<form action={saveCommunityApplicationDraft}>
  {/* 更新競合の検査に使う。Dateを経由せず文字列のまま渡す */}
  <input type="hidden" name="updatedAt" value={application.updated_at} />

  {state?.error && (
    <AlertMessage tone="error" title="保存できませんでした" items={errorAlertItems(state.fieldErrors)}>
      <p>{errorMessage(state.error)}</p>
    </AlertMessage>
  )}

  {/* id は name と同じにする。errorAlertItems のアンカー先になる */}
  <FormField
    id="applicantName"
    name="applicantName"
    label="氏名"
    required
    maxLength={100}
    defaultValue={state?.fields?.applicantName ?? application.fields.user_name}
    error={state?.fieldErrors?.applicantName}
  />

  {/* 未回答と「不要」を区別する必要があるので、チェックボックスではなくラジオ */}
  <FormField
    as="radio"
    id="guardianConsentRequired"
    name="guardianConsentRequired"
    label="保護者同意書の要否"
    required
    hint="申請日に18歳未満の方は「必要」を選んでください。"
    options={[
      { value: "true", label: "必要" },
      { value: "false", label: "不要" },
    ]}
    defaultValue={state?.fields?.guardianConsentRequired ?? ""}
    error={state?.fieldErrors?.guardianConsentRequired}
  />

  {/* 提出前の最終確認。押されたときだけ confirmed=true が送信される */}
  <FormField
    as="checkbox"
    id="confirmed"
    name="confirmed"
    label="記載内容に誤りがないことを確認しました"
    required
    error={state?.fieldErrors?.confirmed}
  />

  {/* useFormStatus は同じ <form> の子孫でのみ pending を返す */}
  <SubmitButton pendingLabel="保存中…">下書きを保存</SubmitButton>
</form>
```

空表示、画面遷移、準備中表示：

```jsx
<EmptyState
  title="申請はありません"
  description="条件を変えるか、新しい申請を作成してください。"
  action={<LinkButton href="/staff/applications">一覧へ戻る</LinkButton>}
/>

{/* 実装済みの画面遷移だけをリンクとして表示する */}
<LinkButton href="/staff/applications/123" variant="primary" fullWidthOnMobile>
  申請を確認する
</LinkButton>

{/* 未実装機能には、動くように見えるボタンを置かない */}
<ComingSoon title="帳票の一括出力" description="現在は個別に確認してください。" />
```

## 職員画面で流用するときの注意

1. 各 `page.js` の本文を `PageShell` で包みます。これにより最大幅、余白、文字サイズ、フォーカス表示、ダークモード用の全トークン、375px対策が適用されます。`app/staff/layout.js` の認証保護やナビゲーションは置き換えません。
2. 申請・団体・納付・滞在は別の状態です。`StatusBadge` の `kind` を明示し、複数表示するときは `StatusRow` で囲みます。職員画面では `showKind` を付けると、何の状態かを目でも区別できます。色は補助であり、日本語ラベルを消してはいけません。
3. Actionの失敗は `AlertMessage` と `errorMessage()` で日本語表示します。入力エラーは `errorAlertItems(state.fieldErrors)` も渡し、`FormField` の `id` と `name` を同じ値にしてエラー箇所へ移動できるようにします。DBエラーや内部コードをそのまま表示しません。
4. 保存・審査・取消などの送信には `SubmitButton` を使い、`<form>` の内側に置きます。画面遷移には `LinkButton` を使います。削除や取消には `variant="danger"` を使いますが、色だけに頼らずボタン本文にも操作名を書き、既存の確認手順を省略しません。
5. 0件は空白にせず `EmptyState`、未実装機能は無効ボタンにせず `ComingSoon` を使います。職員画面へ `MockDataNotice` や `mock-data.js` を持ち込みません。
6. 共通部品は親画面の表や独自グリッドまでは整形しません。職員画面側でも長いメールアドレス、受付番号、表を375pxで確認し、必要ならカード表示や折り返しを画面固有CSSへ追加します。利用者画面のCSS Moduleを職員画面から直接インポートしません。

最小例：

```jsx
import PageShell from "@/app/components/PageShell";
import StatusBadge from "@/app/components/StatusBadge";

export default function StaffApplicationSummary({ application }) {
  return (
    <PageShell title="申請の確認" description="内容を確認して審査してください。">
      <StatusBadge kind="application" value={application.status} showKind />
      {/* 職員画面固有の内容 */}
    </PageShell>
  );
}
```

## 仮データの差し替え手順

1. 画面の取得処理を `utils/community-applications/queries.js` などの実取得へ置き換える。
2. その画面から `mock-data.js` の import と `<MockDataNotice />` を外す。
3. 全画面の接続が済んだら `mock-data.js` を削除する。

`mock-data.js` の項目名は実際の返却契約に合わせてあるため、項目名の付け替え作業は不要です。

- `MOCK_APPLICATIONS` の各要素 = `getCommunityApplication(id, mode)` が返す `application`（下書き・修正依頼・許可・申請済み・延泊の5件）
- `MOCK_APPLICATION_LIST` の各要素 = `getCommunityApplications(page)` が返す `applications` の1件。料金・部屋・滞在は一覧の返却契約に含まれないため持たない
- ただし `usage_type` / `camp_id` / `requested_room_preference` は**返却契約に含まれない補助項目**です。キャンプ・統合一覧の取得契約（T08/T16）が決まったら差し替えてください。`original_application_id` / `reception_number` も現時点の一覧取得契約には無く（Issue #27 で追加を依頼中）、確定前の画面確認用として一覧側にも値を持たせています。

## 特に間違えやすい3点

1. **`updated_at` は文字列のまま扱う。** `new Date(...)` を経由させるとマイクロ秒が落ち、更新競合の検査に通らなくなります（`docs/tasks.md` 4.4）。hidden input へそのまま渡します。
2. **期限は保存値から1分引いて表示する。** DBには「翌日00:00」の排他的境界が入っています（`docs/database.md` 8章）。`formatDeadline()` を使ってください。`formatJstDateTime()` をそのまま使うと1分ずれます。
3. **受付番号はサーバー取得値を表示する。** URLクエリの値を根拠に提出成功を表示しません（`docs/tasks.md` 4.2）。UUIDと受付番号は別の値です。

## テスト

依存なしの純粋モジュール（`format.js` / `status-labels.js` / `messages.js` / `mock-data.js`）は
`tests/components-foundation.test.mjs` で検証しています。JSXを含む部品は対象外です。

```bash
NODE_OPTIONS=--experimental-vm-modules node --test tests/*.test.mjs
```

日付・金額・状態ラベルの分岐を変えたら、このファイルも合わせて更新してください。
