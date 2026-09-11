import AlertMessage from "@/app/components/AlertMessage";
import EmptyState from "@/app/components/EmptyState";
import FormField from "@/app/components/FormField";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import StatusBadge, { StatusRow } from "@/app/components/StatusBadge";
import { formatJstDate, formatPeriod, formatYen } from "@/app/components/format";
import { errorMessage } from "@/app/components/messages";
import { APPLICATION_STATUS_LABELS, PAYMENT_STATUS_LABELS,
  STAY_STATUS_LABELS, USAGE_TYPE_LABELS } from "@/app/components/status-labels";
import { searchStaffApplications } from "@/utils/application-operations/queries";
import styles from "./page.module.css";

const options = (labels, first) => [
  { value: "", label: first },
  ...Object.entries(labels).map(([value, label]) => ({ value, label })),
];
const APPLICATION_OPTIONS = options(APPLICATION_STATUS_LABELS, "すべての申請状態");
const PAYMENT_OPTIONS = options({ ...PAYMENT_STATUS_LABELS, overdue: "期限超過" }, "すべての納付状態");
const STAY_OPTIONS = options(STAY_STATUS_LABELS, "すべての滞在状態");
const USAGE_OPTIONS = options({
  camp: USAGE_TYPE_LABELS.camp,
  community_individual: USAGE_TYPE_LABELS.community_individual,
}, "すべての利用区分");

function pageHref(filters, page) {
  const query = new URLSearchParams({ page: String(page) });
  for (const key of ["q", "usageType", "applicationStatus", "paymentStatus", "stayStatus", "from", "to"]) {
    if (filters[key]) query.set(key, filters[key]);
  }
  return `/staff?${query}`;
}

export default async function StaffPage({ searchParams }) {
  const input = await searchParams;
  const result = await searchStaffApplications(input);
  const { filters, applications, pagination } = result;

  return (
    <PageShell title="職員ホーム" description="個人申請を検索し、審査や利用状況を確認します。">
      {result.error && <AlertMessage tone="error" title="申請を検索できませんでした"><p>{errorMessage(result.error)}</p></AlertMessage>}
      <section className={styles.panel} aria-labelledby="search-title">
        <h2 id="search-title">個人申請を検索</h2>
        <form className={styles.filters} method="get">
          <FormField id="q" name="q" label="氏名・受付番号・キャンプ名" defaultValue={filters.q} maxLength={100} />
          <FormField as="select" id="usageType" name="usageType" label="利用区分" defaultValue={filters.usageType} options={USAGE_OPTIONS} />
          <FormField as="select" id="applicationStatus" name="applicationStatus" label="申請状態" defaultValue={filters.applicationStatus} options={APPLICATION_OPTIONS} />
          <FormField as="select" id="paymentStatus" name="paymentStatus" label="納付状態" defaultValue={filters.paymentStatus} options={PAYMENT_OPTIONS} />
          <FormField as="select" id="stayStatus" name="stayStatus" label="滞在状態" defaultValue={filters.stayStatus} options={STAY_OPTIONS} />
          <FormField id="from" name="from" label="この日以降を含む" type="date" defaultValue={filters.from} />
          <FormField id="to" name="to" label="この日以前を含む" type="date" defaultValue={filters.to} />
          <div className={styles.filterActions}>
            <button className={styles.searchButton} type="submit">検索する</button>
            <LinkButton href="/staff">条件をクリア</LinkButton>
          </div>
        </form>
      </section>
      {!result.error && <section className={styles.results} aria-labelledby="results-title">
        <div className={styles.resultsHeading}><h2 id="results-title">検索結果</h2><p>{pagination.totalCount}件</p></div>
        {applications.length === 0 ? <EmptyState title="条件に一致する個人申請はありません" description="検索条件を変えてお試しください。" /> :
          <ul className={styles.applicationList}>{applications.map((application) =>
            <li className={styles.applicationCard} key={application.id}>
              <div className={styles.cardHeading}><div><p className={styles.campName}>{application.usage_type === "camp" ? (application.camp_name || "キャンプ名未設定") : USAGE_TYPE_LABELS.community_individual}</p><h3>{application.applicant_name || "氏名未設定"}</h3></div>
                <StatusRow><StatusBadge kind="application" value={application.status} />
                  {application.payment_status && <StatusBadge kind="payment" value={application.payment_status === "overdue" ? "unpaid" : application.payment_status} />}
                  {application.payment_status === "overdue" && <strong className={styles.overdue}>期限超過</strong>}
                  {application.stay_status && <StatusBadge kind="stay" value={application.stay_status} />}</StatusRow>
              </div>
              <dl className={styles.facts}>
                <div><dt>受付番号</dt><dd>{application.reception_number || "未発行"}</dd></div>
                <div><dt>利用期間</dt><dd>{formatPeriod(application.start_date, application.end_date)}</dd></div>
                <div><dt>料金</dt><dd>{application.total_amount === null ? "未確定" : formatYen(application.total_amount)}</dd></div>
                <div><dt>納付期限</dt><dd>{application.payment_due_date ? formatJstDate(application.payment_due_date) : "未設定"}</dd></div>
              </dl>
              <LinkButton href={application.detail_path} variant="primary" fullWidthOnMobile>申請を確認する</LinkButton>
            </li>)}</ul>}
        <nav className={styles.pagination} aria-label="検索結果のページ">
          {pagination.page > 1 && <LinkButton href={pageHref(filters, pagination.page - 1)}>前のページ</LinkButton>}
          <span>{pagination.page}ページ</span>
          {pagination.hasNext && <LinkButton href={pageHref(filters, pagination.page + 1)}>次のページ</LinkButton>}
        </nav>
      </section>}
    </PageShell>
  );
}
