/*
 * 状態値の日本語ラベル辞書。
 *
 * キーは docs/database.md 6章の保存値。画面で状態の文字列を直接書かず、
 * 必ず statusLabel(kind, value) を通す。kind を必須にすることで
 * 「納付状態の値を申請状態の辞書で引く」取り違えを構造的に防ぐ。
 *
 * docs/coding_rules.md 7章：
 * 「申請済み」を「許可済み」と表示しない。申請・納付・滞在の状態を分ける。
 *
 * 依存なしの純粋モジュール。"use client" も server-only も付けないため、
 * Server Component からも小さな Client Component からも import できる。
 */

/** 個別申請（個人・団体参加者）の状態。DBが持つ8値すべてを収録する */
export const APPLICATION_STATUS_LABELS = {
  draft: "下書き",
  submitted: "申請済み",
  under_review: "審査中",
  revision_requested: "修正依頼",
  approved: "許可",
  rejected: "不許可",
  cancellation_requested: "キャンセル申請中",
  cancelled: "キャンセル済み",
};

/** 団体全体の状態。draft / collecting 以外は個別申請と同じ */
export const GROUP_STATUS_LABELS = {
  draft: "下書き",
  collecting: "申請中",
  under_review: "審査中",
  revision_requested: "修正依頼",
  approved: "許可",
  rejected: "不許可",
  cancellation_requested: "キャンセル申請中",
  cancelled: "キャンセル済み",
};

/** 納付状態。期限超過は状態値ではなく isPaymentOverdue() で表示に足す */
export const PAYMENT_STATUS_LABELS = {
  unpaid: "未納",
  paid: "納付済み",
};

/** 滞在状態（入退去） */
export const STAY_STATUS_LABELS = {
  before_move_in: "入居前",
  staying: "滞在中",
  moved_out: "退去済み",
};

/** 利用区分（applications.usage_type） */
export const USAGE_TYPE_LABELS = {
  camp: "スパルタキャンプ利用",
  community_individual: "利用申請",
  community_group: "地域活動利用・団体",
};

/** 相部屋希望（キャンプ申請の requested_room_preference） */
export const ROOM_PREFERENCE_LABELS = {
  shared_ok: "相部屋可",
  private_requested: "個室希望",
};

/** 使用箇所。現在は1種類のみ（docs/routes.md 9.5） */
export const USAGE_PLACE_LABELS = {
  common_and_second_floor: "共用部分及び2階個室",
};

/** 公開カレンダーの空き状況（docs/routes.md 9.4） */
export const CALENDAR_AVAILABILITY_LABELS = {
  available: "申請可能",
  unavailable: "利用不可",
  not_yet_open: "受付開始前",
};

/** 状態の種別名。バッジのスクリーンリーダー向け接頭辞にも使う */
export const STATUS_KIND_LABELS = {
  application: "申請状態",
  group: "団体状態",
  payment: "納付状態",
  stay: "滞在状態",
};

const LABELS_BY_KIND = {
  application: APPLICATION_STATUS_LABELS,
  group: GROUP_STATUS_LABELS,
  payment: PAYMENT_STATUS_LABELS,
  stay: STAY_STATUS_LABELS,
};

/**
 * 状態ごとの配色トーン。色は補助であり、バッジには必ず日本語ラベルも描画する
 * （docs/coding_rules.md 7章「色だけで状態を区別しない」）。
 */
export const STATUS_TONES = {
  application: {
    draft: "neutral",
    submitted: "info",
    under_review: "info",
    revision_requested: "warning",
    approved: "success",
    rejected: "danger",
    cancellation_requested: "warning",
    cancelled: "neutral",
  },
  group: {
    draft: "neutral",
    collecting: "info",
    under_review: "info",
    revision_requested: "warning",
    approved: "success",
    rejected: "danger",
    cancellation_requested: "warning",
    cancelled: "neutral",
  },
  payment: {
    unpaid: "warning",
    paid: "success",
  },
  stay: {
    before_move_in: "neutral",
    staying: "info",
    moved_out: "neutral",
  },
};

/**
 * 辞書から自前のキーだけを引く。
 *
 * dictionary[key] と書くと Object.prototype のプロパティ名（"toString" など）が
 * 関数として返り、未知値のはずが関数を描画して画面が壊れる。Object.hasOwn で
 * 自前のキーに限定すれば、想定外の値は必ずフォールバックへ落ちる。
 */
function ownValue(dictionary, key) {
  return dictionary && Object.hasOwn(dictionary, key) ? dictionary[key] : null;
}

/**
 * 状態値を日本語ラベルへ変換する。
 * 未設定・未知の値でも例外を投げず、画面クラッシュより表示劣化を選ぶ。
 *
 * @param {"application"|"group"|"payment"|"stay"} kind 状態の種別
 * @param {string|null|undefined} value DBの保存値
 * @returns {string} 日本語ラベル
 */
export function statusLabel(kind, value) {
  if (value === null || value === undefined || value === "") return "状態未設定";
  return ownValue(ownValue(LABELS_BY_KIND, kind), value) ?? "状態不明";
}

/**
 * 状態値の配色トーンを返す。未知の値は neutral。
 *
 * @param {"application"|"group"|"payment"|"stay"} kind 状態の種別
 * @param {string|null|undefined} value DBの保存値
 * @returns {"neutral"|"info"|"success"|"warning"|"danger"}
 */
export function statusTone(kind, value) {
  return ownValue(ownValue(STATUS_TONES, kind), value) ?? "neutral";
}

/**
 * 納付が期限超過かどうかを判定する。
 *
 * docs/requirements.md 16.2 / docs/database.md 5.7：
 * 未納のまま納付期限を過ぎたら「期限超過」と表示するが、
 * 納付状態そのものは「未納」のままとする。よってこの関数は表示補助だけを担い、
 * 状態値を書き換えない。
 *
 * @param {{payment_status?: string, payment_due_date?: string|null}|null|undefined} charge
 * @param {string} today 日本時間の今日（YYYY-MM-DD）。format.js の jstToday() を使う
 * @returns {boolean}
 */
export function isPaymentOverdue(charge, today) {
  if (!charge || charge.payment_status !== "unpaid") return false;
  const due = charge.payment_due_date;
  if (typeof due !== "string" || typeof today !== "string") return false;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(due) || !/^\d{4}-\d{2}-\d{2}$/.test(today)) {
    return false;
  }
  return due < today;
}
