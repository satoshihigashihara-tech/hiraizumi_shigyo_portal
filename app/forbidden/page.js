import { redirect } from "next/navigation";
import { logout } from "@/app/actions/auth";
import AlertMessage from "@/app/components/AlertMessage";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import SubmitButton from "@/app/components/SubmitButton";
import { createClient } from "@/utils/supabase/server";
import styles from "./page.module.css";

const REASONS = {
  "account-unavailable": {
    title: "現在このアカウントは利用できません",
    message:
      "利用終了後の情報整理中、または町の担当による利用停止中です。確認が必要な場合は、町の担当窓口へお問い合わせください。",
  },
  "staff-only": {
    title: "職員用の画面です",
    message: "このアカウントでは職員用画面を利用できません。利用者メニューへ戻ってください。",
  },
};

function firstParam(value) {
  if (Array.isArray(value)) return typeof value[0] === "string" ? value[0] : "";
  return typeof value === "string" ? value : "";
}

async function authenticatedViewer(returnTo) {
  const supabase = await createClient();
  const {
    data: { user },
    error,
  } = await supabase.auth.getUser();

  if (error || !user) {
    redirect(`/login?returnTo=${encodeURIComponent(returnTo)}`);
  }

  const { data: profile } = await supabase
    .from("profiles")
    .select("account_state")
    .eq("id", user.id)
    .maybeSingle();

  const { data: staffRole } = await supabase
    .from("staff_roles")
    .select("user_id")
    .eq("user_id", user.id)
    .maybeSingle();

  return {
    isActive: profile?.account_state === "active",
    isStaff: Boolean(staffRole),
  };
}

export const metadata = {
  title: "アクセスできません｜ひらいずみ志業ポータル",
  description: "現在のアカウントで利用できる画面をご案内します。",
};

export default async function ForbiddenPage({ searchParams }) {
  const query = (await searchParams) ?? {};
  const reason = firstParam(query.reason);
  const returnTo = Object.hasOwn(REASONS, reason)
    ? `/forbidden?reason=${encodeURIComponent(reason)}`
    : "/forbidden";
  const { isActive, isStaff } = await authenticatedViewer(returnTo);
  const effectiveReason =
    reason === "account-unavailable" && isActive ? "" : reason;
  const content = Object.hasOwn(REASONS, effectiveReason)
    ? REASONS[effectiveReason]
    : {
        title: "この画面にはアクセスできません",
        message: "現在のアカウントでは、この画面を利用できません。",
      };
  const accountUnavailable = effectiveReason === "account-unavailable";

  return (
    <div className={styles.page}>
      <PageShell title="アクセスできません">
        <AlertMessage tone="warning" title={content.title}>
          <p>{content.message}</p>
        </AlertMessage>

        <div className={styles.actions}>
          {!accountUnavailable && (
            <LinkButton href={isStaff ? "/staff" : "/user"} variant="primary" fullWidthOnMobile>
              {isStaff ? "職員メニューへ戻る" : "利用者メニューへ戻る"}
            </LinkButton>
          )}
          <LinkButton href="/" fullWidthOnMobile>
            トップへ戻る
          </LinkButton>
          <form action={logout}>
            <SubmitButton variant="secondary" pendingLabel="ログアウト中…" fullWidthOnMobile>
              ログアウト
            </SubmitButton>
          </form>
        </div>
      </PageShell>
    </div>
  );
}
