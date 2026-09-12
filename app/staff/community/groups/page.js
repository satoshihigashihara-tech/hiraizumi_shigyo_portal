import AlertMessage from "@/app/components/AlertMessage";
import EmptyState from "@/app/components/EmptyState";
import FormField from "@/app/components/FormField";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import StatusBadge from "@/app/components/StatusBadge";
import { formatPeriod } from "@/app/components/format";
import { errorMessage } from "@/app/components/messages";
import { GROUP_STATUS_LABELS } from "@/app/components/status-labels";
import { getStaffCommunityGroups } from "@/utils/community-groups/staff-queries";
import styles from "./groups.module.css";

export const metadata = { title: "団体申請の審査｜ひらいずみ志業ポータル" };

const STATUS_OPTIONS = [
  { value: "", label: "すべての団体状態" },
  ...Object.entries(GROUP_STATUS_LABELS).map(([value, label]) => ({ value, label })),
];

function pageHref(filters, page) {
  const query = new URLSearchParams({ page: String(page) });
  if (filters.q) query.set("q", filters.q);
  if (filters.status) query.set("status", filters.status);
  return `/staff/community/groups?${query}`;
}

export default async function StaffCommunityGroupsPage({ searchParams }) {
  const result = await getStaffCommunityGroups((await searchParams) ?? {});
  return (
    <PageShell title="団体申請の審査" description="団体単位の審査状況と参加人数を確認します。">
      <div className={styles.actions}>
        <LinkButton href="/staff">職員ホームへ戻る</LinkButton>
      </div>
      <section className={styles.panel} aria-labelledby="group-search-heading">
        <h2 id="group-search-heading">団体を検索</h2>
        <form className={styles.filterGrid} method="get">
          <FormField id="q" name="q" label="団体名" defaultValue={result.filters.q} maxLength={100} />
          <FormField as="select" id="status" name="status" label="団体状態" defaultValue={result.filters.status} options={STATUS_OPTIONS} />
          <div className={styles.filterActions}>
            <button className={styles.searchButton} type="submit">検索する</button>
            <LinkButton href="/staff/community/groups">条件をクリア</LinkButton>
          </div>
        </form>
      </section>
      {result.error && (
        <AlertMessage tone="error" title="団体申請を検索できませんでした">
          <p>{errorMessage(result.error)}</p>
        </AlertMessage>
      )}
      {!result.error && (
        <section className={styles.list} aria-labelledby="group-results-heading">
          <div className={styles.resultsHeader}>
            <h2 id="group-results-heading">検索結果</h2>
            <p>{result.pagination.totalCount}件</p>
          </div>
          {result.groups.length === 0 ? (
            <EmptyState title="条件に一致する団体申請はありません" description="検索条件を変えてお試しください。" />
          ) : (
            <ul className={styles.list}>
              {result.groups.map((group) => (
                <li className={styles.card} key={group.id}>
                  <h2>{group.group_name || "団体名未設定"}</h2>
                  <StatusBadge kind="group" value={group.status} showKind />
                  <dl className={styles.facts}>
                    <div><dt>利用期間</dt><dd>{formatPeriod(group.start_date, group.end_date)}</dd></div>
                    <div><dt>予定人数</dt><dd>{group.planned_participants}人</dd></div>
                    <div><dt>目的確認</dt><dd>{group.purpose_reviewed_at ? "確認済み" : "未確認"}</dd></div>
                  </dl>
                  <LinkButton href={`/staff/community/groups/${group.id}`} variant="primary" fullWidthOnMobile>団体を審査する</LinkButton>
                </li>
              ))}
            </ul>
          )}
          <nav className={styles.pagination} aria-label="検索結果のページ">
            {result.pagination.page > 1 && <LinkButton href={pageHref(result.filters, result.pagination.page - 1)}>前のページ</LinkButton>}
            <span>{result.pagination.page}ページ</span>
            {result.pagination.hasNext && <LinkButton href={pageHref(result.filters, result.pagination.page + 1)}>次のページ</LinkButton>}
          </nav>
        </section>
      )}
    </PageShell>
  );
}
