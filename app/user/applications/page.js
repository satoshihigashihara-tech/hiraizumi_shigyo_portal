import EmptyState from "@/app/components/EmptyState";
import LinkButton from "@/app/components/LinkButton";
import MockDataNotice from "@/app/components/MockDataNotice";
import PageShell from "@/app/components/PageShell";
import StatusBadge, { StatusRow } from "@/app/components/StatusBadge";
import {
  formatDeadline,
  formatJstDateTime,
  formatPeriod,
} from "@/app/components/format";
import { MOCK_APPLICATION_LIST } from "@/app/components/mock-data";
import { USAGE_TYPE_LABELS } from "@/app/components/status-labels";
import styles from "./page.module.css";

/*
 * 申請一覧（/user/applications）。Server Component（docs/routes.md 2章5項・6.2）。
 *
 * 画面の目的（docs/routes.md 6.2）：
 * 「本人の進行中・過去の個別申請一覧」。詳細と新規申請への導線を持つ。
 *
 * 未接続：表示はすべて app/components/mock-data.js の仮データ。
 * ------------------------------------------------------------------
 * 本人データの取得はバックエンド担当（東原）が接続する（イシュー #19）。
 * 接続時は app/components/README.md「仮データの差し替え手順」に従い、
 *
 *     const { error, applications } = await getCommunityApplications(1);
 *
 * （utils/community-applications/queries.js・実装済み）へ置き換え、
 * mock-data.js の import と <MockDataNotice /> を同時に外す。
 * getCommunityApplications() は内部で requireActiveUser("/user/applications") を
 * 呼ぶため、未ログイン・停止中アカウントの遷移もそこで行われる
 * （docs/routes.md 8.1 の多層防御。1段目の app/user/layout.js 側のガードは
 * イシュー #18 の記載どおり未接続のまま）。
 *
 * この画面が扱う項目は getCommunityApplications() の返却列だけに限る：
 *   id / original_application_id / status / start_date / end_date /
 *   updated_at / submitted_at / last_submitted_at / revision_due_at /
 *   decision_reason
 * 詳細（getCommunityApplication）にしかない受付番号・料金・部屋・滞在は、
 * 一覧では出さずに詳細へ誘導する。ここで詳細用の項目を使うと、接続した
 * 途端に表示が消える画面になるため（docs/routes.md 9.5 の返却契約）。
 *
 * 日程は一覧の start_date / end_date をそのまま使う。詳細の fields は
 * coalesce(revision_start_date, start_date) なので、修正依頼中だけ両者が
 * 食い違う（docs/routes.md 9.5）。一覧は applications の列＝枠を確保して
 * いる期間を示し、修正候補の日程は詳細で確認してもらう。
 *
 * 表示の決まりごと（docs/coding_rules.md 7章）：
 * - 申請状態の文字列は必ず status-labels.js を通す。「申請済み」を「許可」と書かない。
 * - 期限・理由は色ではなく文字で表示する。バッジの色は補助。
 *
 * ページ送り：getCommunityApplications() は1ページ50件だが、初版は page=1 だけを
 * 表示する（docs/routes.md 9.5）。件数が50件を超える利用者が出てから、
 * URLクエリの追加と合わせて docs/routes.md 10章へ記載する。
 */

/**
 * 利用区分の日本語ラベル。未知の値でも壊れない。
 *
 * Object.hasOwn で自前のキーに限定する（status-labels.js と同じ対策）。
 * USAGE_TYPE_LABELS[value] だけでは "toString" などが関数として返る。
 *
 * TODO（T08/T16）: 同じ関数が app/user/page.js にもある。統合一覧の取得契約が
 * 決まると一覧の項目自体が変わるため、その時点で共通化する。共通化の判断材料は
 * このコメントに集約する（app/user/page.js 側からはここを参照する）。
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
 * 受付番号の欄に出す文字列。出す内容が無ければ null（欄ごと出さない）。
 *
 * 受付番号は提出が成功したときに発行される（docs/routes.md 6.2）。提出前は
 * 未発行であることを明示し、URLのUUIDで代用しない（docs/routes.md 3章7項・
 * app/components/README.md「特に間違えやすい3点」の3つ目）。
 *
 * 受付番号は詳細の表示項目で（docs/routes.md 6.2 の [applicationId] 行）、
 * 一覧の取得契約には含まれない。提出済みの申請に毎回「詳細で確認できます」と
 * 出しても分かることが増えないため、欄自体を出さずカード下部の詳細リンクに任せる。
 * 契約に追加されたら、その値をそのまま表示する。
 *
 * @param {object} row 一覧1件分
 * @returns {string|null}
 */
function receptionNumberText(row) {
  if (!row.submitted_at) return "提出前のため、まだ発行されていません";
  return row.reception_number ?? null;
}

/**
 * 申請1件の行。
 *
 * @param {object} props
 * @param {object} props.row getCommunityApplications() の applications 1件分
 */
function ApplicationListItem({ row }) {
  /*
   * 再提出した申請かどうか。修正依頼を受けて出し直すと last_submitted_at だけが
   * 進む（submitted_at は初回提出のまま）。両方同じ日時なら1回しか提出していない
   * ので、同じ値を2行に出さない。
   */
  const resubmitted =
    row.last_submitted_at !== null && row.last_submitted_at !== row.submitted_at;

  const receptionNumber = receptionNumberText(row);

  return (
    <li className={styles.card}>
      {/*
       * 見出しの利用区分。usage_type は getCommunityApplications() の返却列に
       * 含まれない（一覧は usage_type = "community_individual" で絞り込み済み）。
       * 既定値を与えないと、接続した途端に全カードの見出しが
       * 「利用区分未設定」になる。統合一覧の取得契約（T08/T16）で区分が
       * 返るようになったら、その値がそのまま使われる。
       */}
      <h3 className={styles.cardTitle}>
        {usageTypeLabel(row.usage_type ?? "community_individual")}
      </h3>

      {/*
       * 一覧で分かるのは申請状態だけ。納付状態・滞在状態は別の状態であり、
       * 一覧の取得契約に含まれないため、ここでまとめて1つのバッジにしない
       * （docs/coding_rules.md 7章）。
       */}
      <StatusRow>
        <StatusBadge kind="application" value={row.status} showKind />
      </StatusRow>

      <dl className={styles.facts}>
        <div className={styles.fact}>
          <dt className={styles.factKey}>利用期間</dt>
          <dd className={styles.factValue}>
            {formatPeriod(row.start_date, row.end_date)}
          </dd>
        </div>

        {receptionNumber && (
          <div className={styles.fact}>
            <dt className={styles.factKey}>受付番号</dt>
            <dd className={styles.factValue}>{receptionNumber}</dd>
          </div>
        )}

        {row.submitted_at && (
          <div className={styles.fact}>
            <dt className={styles.factKey}>提出日時</dt>
            <dd className={styles.factValue}>
              {formatJstDateTime(row.submitted_at)}
            </dd>
          </div>
        )}

        {resubmitted && (
          <div className={styles.fact}>
            <dt className={styles.factKey}>再提出日時</dt>
            <dd className={styles.factValue}>
              {formatJstDateTime(row.last_submitted_at)}
            </dd>
          </div>
        )}

        {/*
         * 再提出の期限。DBには「翌日00:00」の排他的境界が入っているので
         * formatDeadline() で1分引いて表示する（docs/database.md 8章）。
         * formatJstDateTime() をそのまま使うと1分ずれる。
         */}
        {row.revision_due_at && (
          <div className={styles.fact}>
            <dt className={styles.factKey}>再提出の期限</dt>
            <dd className={styles.factValue}>
              {formatDeadline(row.revision_due_at)}
            </dd>
          </div>
        )}

        <div className={styles.fact}>
          <dt className={styles.factKey}>最終更新</dt>
          <dd className={styles.factValue}>
            {formatJstDateTime(row.updated_at)}
          </dd>
        </div>
      </dl>

      {/* 修正・不許可の理由は町からの連絡なので、そのまま文字で出す */}
      {row.decision_reason && (
        <p className={styles.reason}>
          <span className={styles.reasonKey}>町からの連絡：</span>
          {row.decision_reason}
        </p>
      )}

      <div className={styles.cardLink}>
        <LinkButton href={`/user/applications/${row.id}`} fullWidthOnMobile>
          申請の詳細を見る
        </LinkButton>
      </div>
    </li>
  );
}

export const metadata = {
  title: "申請一覧｜ひらいずみ志業ポータル",
  description: "過去の申請と現在の進行状況を一覧で確認できます。",
};

export default async function UserApplicationsPage({ searchParams }) {
  // Next.js 16 では searchParams は Promise
  // （node_modules/next/dist/docs/01-app/03-api-reference/03-file-conventions/page.md）
  const query = (await searchParams) ?? {};

  /*
   * 仮データ限定の表示切り替え。`/user/applications?mock=empty` で申請0件の
   * 画面を確認できる。イシュー #19 の完了条件「0件表示も確認できる」を
   * 仮データのまま確かめるためだけのもので、バックエンド接続時に
   * mock-data.js ごと削除する。`?error=` のような実仕様のクエリではないので、
   * docs/routes.md 10章には足さない（/user と同じ扱い）。
   */
  const mock = Array.isArray(query.mock) ? query.mock[0] : query.mock;
  const showEmpty = mock === "empty";
  const applications = showEmpty ? [] : MOCK_APPLICATION_LIST;

  return (
    <PageShell
      title="申請一覧"
      description="提出した申請と、提出前の下書きを表示します。"
    >
      <MockDataNotice>
        <p>
          申請の内容・状態・日程はすべて仮の値です。ログイン中の利用者の申請は
          まだ表示していません。
          {showEmpty && "いまは申請0件の表示を確認する指定になっています。"}
        </p>
      </MockDataNotice>

      {applications.length === 0 ? (
        <EmptyState
          title="申請はまだありません"
          description="スパルタキャンプ利用と地域活動利用の申請を、ここから始められます。提出前の下書きもこの画面に表示されます。"
          action={
            /* 0件のときも、件数ありのときと同じ導線（新規申請・ホーム）を出す */
            <div className={styles.actions}>
              <LinkButton
                href="/user/applications/new"
                variant="primary"
                fullWidthOnMobile
              >
                新しく申請する
              </LinkButton>
              <LinkButton href="/user" fullWidthOnMobile>
                利用者ホームへ戻る
              </LinkButton>
            </div>
          }
        />
      ) : (
        <>
          <div className={styles.actions}>
            <LinkButton
              href="/user/applications/new"
              variant="primary"
              fullWidthOnMobile
            >
              新しく申請する
            </LinkButton>
            <LinkButton href="/user" fullWidthOnMobile>
              利用者ホームへ戻る
            </LinkButton>
          </div>

          <section className={styles.section} aria-labelledby="applications-heading">
            <h2 className={styles.sectionTitle} id="applications-heading">
              申請の一覧
            </h2>

            {/*
             * 件数は色や並びではなく文字で示す。読み上げでも件数が伝わる。
             *
             * 並び順には触れない。仮データ（MOCK_APPLICATION_LIST）は定義順のまま
             * 並ぶため、いまの画面は新しい順になっていない。接続後は
             * created_at の降順で返る（docs/routes.md 9.5）ので、そのときに
             * 「新しく登録したものから順に表示しています」を添える。
             */}
            <p className={styles.note}>
              {applications.length}件の申請があります。料金・納付の状態、部屋や滞在の
              情報は、各申請の詳細で確認できます。
            </p>

            {/*
             * list-style: none を当てた <ul> は Safari/VoiceOver でリストとして
             * 読み上げられないことがある。role="list" を添えて、上の「◯件の申請が
             * あります」と読み上げの件数を一致させる。
             */}
            <ul className={styles.cardList} role="list">
              {applications.map((row) => (
                <ApplicationListItem key={row.id} row={row} />
              ))}
            </ul>
          </section>
        </>
      )}
    </PageShell>
  );
}
