/*
 * 申請の状態から「次に必要な操作」を決める。
 *
 * docs/routes.md 6.1：利用者ホームは「自分の申請・団体の状態、期限、
 * 次に必要な操作をまとめて表示する」。
 *
 * docs/coding_rules.md 7章：
 * - 申請状態・納付状態・滞在状態を分けて表示する。「申請済み」を「許可」と書かない。
 * - 期限や理由は色だけに頼らず、必ず文字で表示する。
 *   → この関数は必ず summary（文）を返し、期限も due として文字表示用に返す。
 *     バッジの色は補助でしかないため、ここでは色を一切決めない。
 *
 * 画面（app/user/page.js）から表示の判断を切り出しているのは、状態の数が多く、
 * JSXの中に条件分岐を並べると「許可」と「納付済み」の取り違えのような
 * 読み違いが起きやすいため。ここは値を決めるだけで、整形（format.js）と
 * 描画は呼び出し側が行う。
 *
 * 依存は同じく純粋モジュールの status-labels.js だけ。
 */

import { isPaymentOverdue } from "@/app/components/status-labels";

/**
 * 期限の種類。
 *
 * DBの保存形式が違うため、整形関数を取り違えないよう種類を明示して返す
 * （app/components/README.md「特に間違えやすい3点」の2つ目）。
 *
 * - "boundary" … 「翌日00:00」の排他的境界 timestamptz。formatDeadline() で
 *                1分引いて表示する。revision_due_at がこれ。
 * - "date"     … 日付列（YYYY-MM-DD）。formatJstDate() で表示する。
 *                charge.payment_due_date がこれ。
 */
export const DUE_KINDS = {
  boundary: "boundary",
  date: "date",
};

/**
 * 申請詳細のURL（docs/routes.md 6.2）。
 *
 * @param {string} applicationId
 * @returns {string}
 */
function detailHref(applicationId) {
  return `/user/applications/${applicationId}`;
}

/**
 * 申請の入力・修正画面のURL（docs/routes.md 6.2）。
 *
 * @param {string} applicationId
 * @returns {string}
 */
function editHref(applicationId) {
  return `/user/applications/${applicationId}/edit`;
}

/**
 * 許可後の「次に必要な操作」を決める。
 *
 * 「許可」は申請状態であって、納付状態でも滞在状態でもない。
 * 許可されていても未納なら次の操作は納付であり、納付済みなら滞在の案内へ移る。
 * この3つを1つの状態として混ぜないために、許可の分岐だけを切り出す。
 *
 * @param {object} application
 * @param {string} today 日本時間の今日（YYYY-MM-DD）
 * @returns {{summary: string, href: string, linkLabel: string, due: object|null, overdue: boolean}}
 */
function approvedAction(application, today) {
  const charge = application.charge;
  const overdue = isPaymentOverdue(charge, today);

  if (charge && charge.payment_status === "unpaid") {
    return {
      summary: overdue
        ? "利用料が未納のまま納付期限を過ぎています。町の担当へご連絡ください。"
        : "利用料を納付してください。",
      href: detailHref(application.id),
      linkLabel: "料金と納付の内容を見る",
      due: charge.payment_due_date
        ? {
            label: "納付の期限",
            value: charge.payment_due_date,
            kind: DUE_KINDS.date,
          }
        : null,
      overdue,
    };
  }

  // 納付済み、または料金がまだ確定していない場合は滞在の段階で案内する。
  const staySummary = {
    before_move_in: "利用開始日に備えてください。当日の入居手続きは町が行います。",
    staying: "滞在中です。困ったことがあれば町の担当へご連絡ください。",
    moved_out: "退去済みです。手続きはすべて終わっています。",
  };
  const stayStatus = application.stay?.status;

  return {
    summary:
      stayStatus && Object.hasOwn(staySummary, stayStatus)
        ? staySummary[stayStatus]
        : "許可されています。内容は申請の詳細で確認できます。",
    href: detailHref(application.id),
    linkLabel: "申請の詳細を見る",
    due: null,
    overdue: false,
  };
}

/**
 * 申請1件について「次に必要な操作」を返す。
 *
 * 未知の状態でも例外を投げず、詳細への導線だけを返す（画面クラッシュより
 * 表示劣化を選ぶ。status-labels.js の statusLabel と同じ方針）。
 * switch で分岐するため、"toString" のような Object.prototype のキーが
 * 渡されても既定の分岐へ落ちる。
 *
 * @param {object} application MOCK_APPLICATIONS の1件（= getCommunityApplication の返却）
 * @param {string} today 日本時間の今日（YYYY-MM-DD）。format.js の jstToday() を使う
 * @returns {{summary: string, href: string, linkLabel: string, due: object|null, overdue: boolean}}
 *          summary は必ず文字列。due は {label, value, kind} または null
 */
export function nextAction(application, today) {
  const id = application.id;

  switch (application.status) {
    case "draft":
      return {
        summary: "入力の途中です。内容を入力して提出してください。",
        href: editHref(id),
        linkLabel: "入力を続ける",
        due: null,
        overdue: false,
      };

    case "submitted":
      return {
        summary: "提出を受け付けました。町が確認するまでお待ちください。",
        href: detailHref(id),
        linkLabel: "申請の詳細を見る",
        due: null,
        overdue: false,
      };

    case "under_review":
      return {
        summary: "町が審査しています。今のところ必要な操作はありません。",
        href: detailHref(id),
        linkLabel: "申請の詳細を見る",
        due: null,
        overdue: false,
      };

    case "revision_requested":
      return {
        summary: "修正の依頼があります。内容を直して、もう一度提出してください。",
        href: editHref(id),
        linkLabel: "修正する",
        due: application.revision_due_at
          ? {
              label: "再提出の期限",
              value: application.revision_due_at,
              kind: DUE_KINDS.boundary,
            }
          : null,
        overdue: false,
      };

    case "approved":
      return approvedAction(application, today);

    case "rejected":
      return {
        summary: "この申請は不許可になりました。理由を確認してください。",
        href: detailHref(id),
        linkLabel: "理由を確認する",
        due: null,
        overdue: false,
      };

    case "cancellation_requested":
      return {
        summary: "キャンセルの申請を町が確認しています。結果をお待ちください。",
        href: detailHref(id),
        linkLabel: "申請の詳細を見る",
        due: null,
        overdue: false,
      };

    case "cancelled":
      return {
        summary: "この申請はキャンセル済みです。",
        href: detailHref(id),
        linkLabel: "申請の詳細を見る",
        due: null,
        overdue: false,
      };

    default:
      return {
        summary: "内容を申請の詳細で確認してください。",
        href: detailHref(id),
        linkLabel: "申請の詳細を見る",
        due: null,
        overdue: false,
      };
  }
}

/**
 * 利用者が自分で操作する必要がある申請かどうか。
 *
 * ホーム上部の「次に必要な操作」へ集めるのは、この関数が true を返す申請だけ。
 * 審査待ちや終了済みの申請まで並べると、本当に手を動かす必要があるものが
 * 埋もれてしまうため。
 *
 * @param {object} application
 * @param {string} today 日本時間の今日（YYYY-MM-DD）
 * @returns {boolean}
 */
export function needsUserAction(application, today) {
  if (application.status === "draft" || application.status === "revision_requested") {
    return true;
  }
  if (application.status === "approved") {
    return isPaymentOverdue(application.charge, today) ||
      application.charge?.payment_status === "unpaid";
  }
  return false;
}
