import { redirect } from "next/navigation";
import AlertMessage from "@/app/components/AlertMessage";
import FormField from "@/app/components/FormField";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import buttonStyles from "@/app/components/Button.module.css";
import { normalizeInvite } from "@/utils/group-invitations/validation";
import styles from "@/app/user/groups/groups.module.css";

export const metadata = {
  title: "団体の招待コードを入力｜ひらいずみ志業ポータル",
  description: "団体代表者から受け取った招待コードを入力します。",
};

function firstQueryValue(value) {
  return Array.isArray(value) ? value[0] : value;
}

export default async function InviteCodePage({ searchParams }) {
  const query = (await searchParams) ?? {};
  const enteredCode = firstQueryValue(query.code);
  const submitted = Object.hasOwn(query, "code");

  if (typeof enteredCode === "string" && enteredCode !== "") {
    const code = normalizeInvite(enteredCode, "code");
    if (code) redirect(`/invite/${code}`);
  }

  const invalid = submitted;

  return (
    <PageShell
      title="団体の招待コードを入力"
      description="団体代表者から受け取った16文字の招待コードを入力してください。"
    >
      <AlertMessage tone="info" title="招待内容はログイン後に表示します">
        <p>団体名や利用日程などの情報は、本人確認のためログインした後に確認できます。</p>
      </AlertMessage>

      {invalid && (
        <AlertMessage tone="error" title="招待コードを確認してください">
          <p>招待コードが正しくありません。英数字16文字のコードをもう一度入力してください。</p>
        </AlertMessage>
      )}

      <form className={styles.form} action="/invite" method="get">
        <FormField
          id="code"
          name="code"
          label="招待コード"
          defaultValue={invalid ? enteredCode : ""}
          placeholder="ABCD-EFGH-JKLM-NPQR"
          hint="ハイフンや空白を含めて入力しても確認できます。"
          error={invalid ? "invalid-invite" : undefined}
          autoComplete="off"
          maxLength={24}
          required
        />
        <div className={styles.actions}>
          <button
            className={`${buttonStyles.button} ${buttonStyles.primary} ${buttonStyles.fullWidthOnMobile}`}
            type="submit"
          >
            招待内容を確認する
          </button>
          <LinkButton href="/" fullWidthOnMobile>トップへ戻る</LinkButton>
        </div>
      </form>
    </PageShell>
  );
}
