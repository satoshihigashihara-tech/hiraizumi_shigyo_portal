# 利用者画面の共通部品

イシュー #16 で用意した共通土台です。画面イシュー（#17〜#24）はここの部品と仮データを使い、各画面で独自のバッジ・エラー表示・仮データを作らないようにします。

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
| 余白（4px基準） | `--sg-space-1`(4) 〜 `--sg-space-7`(48) |
| 文字サイズ | `--sg-font-xs`(12) 〜 `--sg-font-3xl`(28)、`--sg-line-height`(1.6) |
| 角丸・線 | `--sg-radius`(8px)、`--sg-radius-pill`(999px)、`--sg-border` |
| 基本色 | `--sg-color-bg / -surface / -text / -text-muted / -border / -focus` |
| 5トーン | `--sg-{neutral,info,success,warning,danger}-{bg,border,text}` |

`prefers-color-scheme: dark` のときは `.shell` 側でトークンを暗色へ差し替えます。新しい部品を足すときも、**背景色と文字色を必ずセットで指定**してください（`app/globals.css` が `color-scheme: dark` と暗い `body` 背景を持つため、継承任せにすると片方だけ暗くなります）。

## 部品一覧

| ファイル | 種別 | props |
|---|---|---|
| `PageShell.js` | Server | `title` / `description` / `children` |
| `StatusBadge.js` | Server | `kind`(`application`\|`group`\|`payment`\|`stay`、既定 `application`) / `value` / `showKind` |
| `StatusBadge.js` の `StatusRow` | Server | `children`（バッジ併記用。375pxで折り返す） |
| `FormField.js` | Server | `id` / `name` / `label` / `as`(`input`\|`textarea`\|`select`) / `type` / `defaultValue` / `placeholder` / `hint` / `error` / `required` / `disabled` / `options` / `rows` / `autoComplete` / `inputMode` / `maxLength` |
| `AlertMessage.js` | Server | `tone`(`error`\|`warning`\|`success`\|`info`) / `title` / `children` / `items` |
| `AlertMessage.js` の `errorAlertItems` | 関数 | `fieldErrors` → `[{ href, label }]` |
| `EmptyState.js` | Server | `title` / `description` / `action` |
| `SubmitButton.js` | **Client** | `children` / `pendingLabel` / `variant` / `disabled` / `pending` / `fullWidthOnMobile` |
| `LinkButton.js` | Server | `href`(必須) / `children` / `variant` / `fullWidthOnMobile` |
| `ComingSoon.js` | Server | `title` / `description`（クリックできる要素を描画しない） |
| `MockDataNotice.js` | Server | `children` |

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

  {/* useFormStatus は同じ <form> の子孫でのみ pending を返す */}
  <SubmitButton pendingLabel="保存中…">下書きを保存</SubmitButton>
</form>
```

## 仮データの差し替え手順

1. 画面の取得処理を `utils/community-applications/queries.js` などの実取得へ置き換える。
2. その画面から `mock-data.js` の import と `<MockDataNotice />` を外す。
3. 全画面の接続が済んだら `mock-data.js` を削除する。

`mock-data.js` の項目名は実際の返却契約に合わせてあるため、項目名の付け替え作業は不要です。

- `MOCK_APPLICATIONS` の各要素 = `getCommunityApplication(id, mode)` が返す `application`
- `MOCK_APPLICATION_LIST` の各要素 = `getCommunityApplications(page)` が返す `applications` の1件
- ただし `usage_type` / `camp_id` / `requested_room_preference` は**返却契約に含まれない補助項目**です。キャンプ・統合一覧の取得契約（T08/T16）が決まったら差し替えてください。

## 特に間違えやすい3点

1. **`updated_at` は文字列のまま扱う。** `new Date(...)` を経由させるとマイクロ秒が落ち、更新競合の検査に通らなくなります（`docs/tasks.md` 4.4）。hidden input へそのまま渡します。
2. **期限は保存値から1分引いて表示する。** DBには「翌日00:00」の排他的境界が入っています（`docs/database.md` 8章）。`formatDeadline()` を使ってください。`formatJstDateTime()` をそのまま使うと1分ずれます。
3. **受付番号はサーバー取得値を表示する。** URLクエリの値を根拠に提出成功を表示しません（`docs/tasks.md` 4.2）。UUIDと受付番号は別の値です。
