import { errorMessage } from "./messages";
import styles from "./FormField.module.css";

/**
 * フォーム1項目（label ＋ 入力欄 ＋ 項目別エラー）。Server Component。
 *
 * 内部状態を持たない非制御入力にしているため、Server Component のまま
 * バックエンドが返す fields を defaultValue へ流し込むだけで
 * 「送信失敗時に利用者の入力を保持する」（docs/requirements.md 8.3）が成立する。
 *
 * required はHTMLの必須属性ではなく、表示（「必須」の文字）とARIAで扱う。
 * ブラウザ検証だけに依存せず、送信の可否はサーバー検証に委ねる
 * （.claude/rules/security.md・docs/coding_rules.md 4章）。
 *
 * @param {object} props
 * @param {string} props.id 入力欄のid。AlertMessage のアンカー先にもなる
 * @param {string} props.name フォームの name（docs/routes.md 9.5 の表と一致させる）
 * @param {string} props.label 項目名
 * @param {"input"|"textarea"|"select"} [props.as="input"] 入力欄の種類
 * @param {string} [props.type="text"] as="input" のときの type
 * @param {string|number} [props.defaultValue] 初期値。fields の保持値を渡す
 * @param {string} [props.placeholder]
 * @param {string} [props.hint] 入力の補足説明
 * @param {string} [props.error] バックエンドの fieldErrors[name]（エラーコード）。
 *                               部品側で日本語へ変換する
 * @param {boolean} [props.required=false]
 * @param {boolean} [props.disabled=false]
 * @param {{value: string, label: string}[]} [props.options] as="select" の選択肢
 * @param {number} [props.rows=4] as="textarea" の行数
 * @param {string} [props.autoComplete]
 * @param {string} [props.inputMode]
 * @param {number} [props.maxLength]
 */
export default function FormField({
  id,
  name,
  label,
  as = "input",
  type = "text",
  defaultValue,
  placeholder,
  hint,
  error,
  required = false,
  disabled = false,
  options,
  rows = 4,
  autoComplete,
  inputMode,
  maxLength,
}) {
  const hintId = hint ? `${id}-hint` : null;
  const errorId = error ? `${id}-error` : null;
  const describedBy = [hintId, errorId].filter(Boolean).join(" ") || undefined;

  const shared = {
    id,
    name,
    disabled,
    "aria-invalid": Boolean(error),
    "aria-describedby": describedBy,
    "aria-required": required || undefined,
  };

  return (
    <div className={styles.field}>
      <label className={styles.label} htmlFor={id}>
        <span>{label}</span>
        {required && <span className={styles.required}>必須</span>}
      </label>

      {hint && (
        <p id={hintId} className={styles.hint}>
          {hint}
        </p>
      )}

      {as === "textarea" && (
        <textarea
          {...shared}
          className={`${styles.textarea} ${error ? styles.hasError : ""}`}
          defaultValue={defaultValue}
          placeholder={placeholder}
          rows={rows}
          maxLength={maxLength}
        />
      )}

      {as === "select" && (
        <select
          {...shared}
          className={`${styles.select} ${error ? styles.hasError : ""}`}
          defaultValue={defaultValue}
        >
          {(options ?? []).map((option) => (
            <option key={option.value} value={option.value}>
              {option.label}
            </option>
          ))}
        </select>
      )}

      {as === "input" && (
        <input
          {...shared}
          className={`${styles.input} ${error ? styles.hasError : ""}`}
          type={type}
          defaultValue={defaultValue}
          placeholder={placeholder}
          autoComplete={autoComplete}
          inputMode={inputMode}
          maxLength={maxLength}
        />
      )}

      {error && (
        <p id={errorId} className={styles.error} role="alert">
          <span aria-hidden="true">!</span>
          <span>{errorMessage(error)}</span>
        </p>
      )}
    </div>
  );
}
