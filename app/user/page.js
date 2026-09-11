import ComingSoon from "@/app/components/ComingSoon";
import EmptyState from "@/app/components/EmptyState";
import LinkButton from "@/app/components/LinkButton";
import MockDataNotice from "@/app/components/MockDataNotice";
import PageShell from "@/app/components/PageShell";
import StatusBadge, { StatusRow } from "@/app/components/StatusBadge";
import {
  formatDeadline,
  formatJstDate,
  formatPeriod,
  jstToday,
} from "@/app/components/format";
import { MOCK_APPLICATIONS, MOCK_CAMP } from "@/app/components/mock-data";
import { USAGE_TYPE_LABELS, isPaymentOverdue } from "@/app/components/status-labels";
import { DUE_KINDS, needsUserAction, nextAction } from "./next-action";
import styles from "./page.module.css";

/*
 * 利用者ホーム（/user）。Server Component（docs/routes.md 2章5項・6.1）。
 *
 * 画面の目的（docs/routes.md 6.1）：
 * 「自分の申請・団体の状態、期限、次に必要な操作をまとめて表示する」
 *
 * docs/routes.md 2章4項により、この /user 自体がホーム。/user/dashboard は作らない。
 *
 * 未接続：表示はすべて app/components/mock-data.js の仮データ。
 * ------------------------------------------------------------------
 * 本人データの取得はバックエンド担当（東原）が接続する（イシュー #18）。
 * ホームの取得契約は docs/tasks.md T08 で未確定のため、ここでは
 * getCommunityApplication() の返却形と同じ形をした MOCK_APPLICATIONS を
 * そのまま並べている。接続時は app/components/README.md「仮データの差し替え手順」
 * に従い、取得処理の置き換えと <MockDataNotice /> の削除を同時に行う。
 *
 * 注意：mock-data.js の usage_type / camp_id は取得契約に含まれない補助項目。
 * キャンプと地域活動を1画面で確認できるようにするための仮の値なので、
 * T08の統合一覧の契約が決まったら差し替える。
 *
 * 表示の決まりごと（docs/coding_rules.md 7章）：
 * - 申請状態・納付状態・滞在状態は必ず分けて表示する。
 *   「申請済み」を「許可」と書かない。状態の文字列は status-labels.js を通す。
 * - 期限・修正理由は色ではなく文字で表示する。バッジの色は補助。
 * - 団体（/user/groups）と招待はこの段階の対象外。押せるボタンは置かず
 *   ComingSoon で案内する（イシュー #18）。
 */

/**
 * 一覧に出す利用期間を決める。
 *
 * 修正依頼中だけ、fields の日程（修正候補）と reserved_* の日程（提出済みで
 * 枠を確保している元の期間）が食い違う。詳細RPCが
 * `fields.start_date := coalesce(revision_start_date, start_date)` を返すため
 * （docs/routes.md 9.5・app/components/mock-data.js の注記）。
 *
 * ホームは「今どの期間で枠を押さえているか」を示すので reserved_* を優先し、
 * 提出前（reserved_* が null）のときだけ fields の日程を使う。
 * 修正候補の日程は、食い違うときに別行で併記する。
 *
 * @param {object} application
 * @returns {{start: string|null, end: string|null}}
 */
function reservedPeriod(application) {
  return {
    start: application.reserved_start_date ?? application.fields.start_date,
    end: application.reserved_end_date ?? application.fields.end_date,
  };
}

/**
 * 修正候補の日程が、枠を確保している期間と違うかどうか。
 * 違うときだけ「修正後の候補」として併記し、利用者が取り違えないようにする。
 *
 * @param {object} application
 * @returns {boolean}
 */
function hasDifferentRevisionPeriod(application) {
  const reserved = reservedPeriod(application);
  return (
    application.status === "revision_requested" &&
    (reserved.start !== application.fields.start_date ||
      reserved.end !== application.fields.end_date)
  );
}

/**
 * 申請の見出し。キャンプ申請はキャンプ名、それ以外は利用区分名。
 *
 * Object.hasOwn で自前のキーに限定する（status-labels.js と同じ対策）。
 * USAGE_TYPE_LABELS[value] だけでは "toString" などが関数として返る。
 *
 * @param {object} application
 * @returns {string}
 */
function applicationTitle(application) {
  if (application.usage_type === "camp" && application.camp_id === MOCK_CAMP.id) {
    return MOCK_CAMP.name;
  }
  return usageTypeLabel(application.usage_type);
}

/**
 * 利用区分の日本語ラベル。未知の値でも壊れない。
 *
 * 同じ関数が app/user/applications/page.js にもある。共通化の判断材料（T08/T16）は
 * そちらのコメントに集約しているので、まとめるときはそちらを参照する。
 *
 * @param {string|null|undefined} usageType
 * @returns {string}
 */
function usageTypeLabel(usageType) {
  return usageType && Object.hasOwn(USAGE_TYPE_LABELS, usageType)
    ? USAGE_TYPE_LABELS[usageType]
    : "利用区分未設定";
}

/**
 * 期限を種類に応じて整形する。
 *
 * 排他的境界（翌日00:00）の timestamptz と、日付列（YYYY-MM-DD）で
 * 使う関数が違う。取り違えると期限が1分ずれる
 * （app/components/README.md「特に間違えやすい3点」の2つ目）。
 *
 * @param {{value: string, kind: string}|null} due
 * @returns {string} 整形結果。due が無ければ空文字
 */
function formatDue(due) {
  if (!due) return "";
  return due.kind === DUE_KINDS.boundary
    ? formatDeadline(due.value)
    : formatJstDate(due.value);
}

/**
 * 申請1件のカード。
 *
 * @param {object} props
 * @param {object} props.application
 * @param {string} props.today 日本時間の今日（YYYY-MM-DD）
 */
function ApplicationCard({ application, today }) {
  const action = nextAction(application, today);
  const period = reservedPeriod(application);

  /*
   * カード内では、上の一覧（dl）が既に出している納付の期限を繰り返さない。
   * 許可かつ未納のとき nextAction が返す期限は納付の期限そのものなので、
   * 同じ日付が1枚のカードに2回出てしまうため。
   * 上部の「次に必要な操作」では dl が無いので、そちらでは必ず出す。
   */
  const dueText =
    action.due && action.due.value === application.charge?.payment_due_date
      ? ""
      : formatDue(action.due);

  return (
    <li className={styles.card}>
      <h3 className={styles.cardTitle}>{applicationTitle(application)}</h3>

      {/*
       * 申請・納付・滞在は別々の状態。1つのバッジにまとめない。
       * 料金や滞在がまだ無い申請では、その種別のバッジを出さない
       * （「状態未設定」と出すより、行が無いほうが誤解が少ない）。
       */}
      <StatusRow>
        <StatusBadge kind="application" value={application.status} showKind />
        {application.charge && (
          <StatusBadge
            kind="payment"
            value={application.charge.payment_status}
            showKind
          />
        )}
        {application.stay && (
          <StatusBadge kind="stay" value={application.stay.status} showKind />
        )}
      </StatusRow>

      <dl className={styles.facts}>
        <div className={styles.fact}>
          <dt className={styles.factKey}>利用区分</dt>
          <dd className={styles.factValue}>
            {usageTypeLabel(application.usage_type)}
          </dd>
        </div>

        <div className={styles.fact}>
          <dt className={styles.factKey}>利用期間</dt>
          <dd className={styles.factValue}>
            {formatPeriod(period.start, period.end)}
          </dd>
        </div>

        {/*
         * 修正依頼中は、枠を確保している期間と修正候補の日程が違うことがある。
         * どちらか一方しか出さないと、利用者が別の期間を確保できたと誤解する。
         */}
        {hasDifferentRevisionPeriod(application) && (
          <div className={styles.fact}>
            <dt className={styles.factKey}>修正後の候補</dt>
            <dd className={styles.factValue}>
              {formatPeriod(
                application.fields.start_date,
                application.fields.end_date,
              )}
              （再提出するまで確定しません）
            </dd>
          </div>
        )}

        {/*
         * 納付の期限。申請状態にかかわらず、料金が確定していれば必ず出す。
         * 未納のまま期限を過ぎても納付状態は「未納」のままなので
         * （docs/requirements.md 16.2・docs/database.md 5.7）、
         * バッジだけでは期限超過が伝わらない。文字で添える。
         */}
        {application.charge?.payment_due_date && (
          <div className={styles.fact}>
            <dt className={styles.factKey}>納付の期限</dt>
            <dd className={styles.factValue}>
              {formatJstDate(application.charge.payment_due_date)}
              {isPaymentOverdue(application.charge, today) &&
                "（期限を過ぎています）"}
            </dd>
          </div>
        )}

        <div className={styles.fact}>
          <dt className={styles.factKey}>受付番号</dt>
          <dd className={styles.factValue}>
            {/* 提出前は未発行。URLのUUIDで代用しない（docs/routes.md 3章7項） */}
            {application.reception_number ?? "提出前のため、まだ発行されていません"}
          </dd>
        </div>
      </dl>

      {/* 次に必要な操作は必ず文字で示す。色や配置だけで伝えない */}
      <div className={styles.action}>
        <p className={styles.actionSummary}>{action.summary}</p>

        {dueText && (
          <p className={styles.actionDue}>
            {action.due.label}：{dueText}
            {action.overdue && "（期限を過ぎています）"}
          </p>
        )}

        {/* 修正・不許可の理由は町からの連絡なので、そのまま文字で出す */}
        {application.decision_reason && (
          <p className={styles.reason}>
            <span className={styles.reasonKey}>町からの連絡：</span>
            {application.decision_reason}
          </p>
        )}

        <div className={styles.cardLink}>
          <LinkButton href={action.href} fullWidthOnMobile>
            {action.linkLabel}
          </LinkButton>
        </div>
      </div>
    </li>
  );
}

export const metadata = {
  title: "利用者ホーム｜ひらいずみ志業ポータル",
  description: "自分の申請の状態と、次に必要な操作を確認できます。",
};

export default async function UserHomePage({ searchParams }) {
  // Next.js 16 では searchParams は Promise
  // （node_modules/next/dist/docs/01-app/03-api-reference/03-file-conventions/page.md）
  const query = (await searchParams) ?? {};

  /*
   * 仮データ限定の表示切り替え。`/user?mock=empty` で申請0件の画面を確認できる。
   *
   * イシュー #18 の完了条件「申請0件の表示も確認できる」を、仮データのまま
   * 確かめられるようにするためだけのもの。バックエンド接続時に
   * mock-data.js ごと削除する（app/components/README.md「仮データの差し替え手順」）。
   * `?error=` のような実仕様のクエリではないので、docs/routes.md には足さない。
   */
  const mock = Array.isArray(query.mock) ? query.mock[0] : query.mock;
  const showEmpty = mock === "empty";
  const applications = showEmpty ? [] : MOCK_APPLICATIONS;

  /*
   * 日本時間の「今日」。納付の期限超過の判定に使う。
   * 呼ぶたびに結果が変わるため、Serverで1度だけ求めて渡す
   * （app/components/format.js の jstToday）。
   */
  const today = jstToday();
  const actionNeeded = applications.filter((application) =>
    needsUserAction(application, today),
  );

  return (
    <PageShell
      title="利用者ホーム"
      description="申請の状態と、次に必要な操作を確認できます。"
    >
      <MockDataNotice>
        <p>
          申請の内容・状態・料金はすべて仮の値です。ログイン中の利用者の情報は
          まだ表示していません。
          {showEmpty && "いまは申請0件の表示を確認する指定になっています。"}
        </p>
      </MockDataNotice>

      {applications.length === 0 ? (
        <EmptyState
          title="申請はまだありません"
          description="スパルタキャンプ利用と地域活動利用の申請を、ここから始められます。提出前の下書きもこの画面に表示されます。"
          action={
            <LinkButton href="/user/applications/new" variant="primary" fullWidthOnMobile>
              新しく申請する
            </LinkButton>
          }
        />
      ) : (
        <>
          <section className={styles.section} aria-labelledby="next-action-heading">
            <h2 className={styles.sectionTitle} id="next-action-heading">
              次に必要な操作
            </h2>

            {actionNeeded.length === 0 ? (
              <p className={styles.note}>
                いま操作が必要な申請はありません。町からの連絡をお待ちください。
              </p>
            ) : (
              /*
               * list-style: none を当てた <ul> は Safari/VoiceOver でリストとして
               * 読み上げられないことがあるので role="list" を添える
               * （/user/applications 側も同じ作り）。
               */
              <ul className={styles.actionList} role="list">
                {actionNeeded.map((application) => {
                  const action = nextAction(application, today);
                  const dueText = formatDue(action.due);
                  return (
                    <li className={styles.actionItem} key={application.id}>
                      <p className={styles.actionItemTitle}>
                        {applicationTitle(application)}
                      </p>
                      <p>{action.summary}</p>
                      {dueText && (
                        <p className={styles.actionDue}>
                          {action.due.label}：{dueText}
                          {action.overdue && "（期限を過ぎています）"}
                        </p>
                      )}
                      <LinkButton href={action.href} fullWidthOnMobile>
                        {action.linkLabel}
                      </LinkButton>
                    </li>
                  );
                })}
              </ul>
            )}
          </section>

          <section className={styles.section} aria-labelledby="applications-heading">
            <h2 className={styles.sectionTitle} id="applications-heading">
              申請の状況
            </h2>
            <ul className={styles.cardList} role="list">
              {applications.map((application) => (
                <ApplicationCard
                  application={application}
                  key={application.id}
                  today={today}
                />
              ))}
            </ul>

            <div className={styles.sectionLink}>
              <LinkButton href="/user/applications" fullWidthOnMobile>
                申請の一覧を見る
              </LinkButton>
            </div>
          </section>
        </>
      )}

      <section className={styles.section} aria-labelledby="links-heading">
        <h2 className={styles.sectionTitle} id="links-heading">
          その他の操作
        </h2>
        <div className={styles.links}>
          <LinkButton href="/user/applications/new" variant="primary" fullWidthOnMobile>
            新しく申請する
          </LinkButton>
          <LinkButton href="/user/applications" fullWidthOnMobile>
            申請の一覧
          </LinkButton>
          <LinkButton href="/user/profile" fullWidthOnMobile>
            プロフィールの確認・変更
          </LinkButton>
        </div>
      </section>

      {/*
       * 団体・招待はイシュー #18 の対象外（docs/routes.md 6.4・6.5）。
       * 押せるが動かないボタンを置かないため、ComingSoon で案内だけにする。
       */}
      <ComingSoon
        title="団体での申請・招待リンクからの参加"
        description="現在は準備中です。団体での利用をご検討の場合は、町の担当へお問い合わせください。"
      />
    </PageShell>
  );
}
