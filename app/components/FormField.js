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
 * チェックボックス（as="checkbox"）は単一の同意確認用で、押されたときだけ
 * value が送信されるHTMLの仕様に合わせる。ラジオ（as="radio"）は
 * 「未回答」と「false を選んだ」を区別する必要がある項目のために用意する
 * （docs/routes.md 9.5：guardianConsentRequired は true / false を明示、
 *  未回答は提出不可）。どちらの値も utils/community-applications/validation.js の
 * booleanField() が "true" / "false" として解釈する。
 *
 * @param {object} props
 * @param {string} props.id 入力欄のid。AlertMessage のアンカー先にもなる
 * @param {string} props.name フォームの name（docs/routes.md 9.5 の表と一致させる）
 * @param {string} props.label 項目名
 * @param {"input"|"textarea"|"select"|"checkbox"|"radio"} [props.as="input"] 入力欄の種類
 * @param {string} [props.type="text"] as="input" のときの type
 * @param {string|number} [props.defaultValue] 初期値。fields の保持値を渡す。
 *                                             as="radio" では選択済みの選択肢の value
 * @param {string} [props.placeholder]
 * @param {string} [props.hint] 入力の補足説明
 * @param {string} [props.error] バックエンドの fieldErrors[name]（エラーコード）。
 *                               部品側で日本語へ変換する
 * @param {boolean} [props.required=false]
 * @param {boolean} [props.disabled=false]
 * @param {{value: string, label: string}[]} [props.options] as="select"・as="radio" の選択肢
 * @param {number} [props.rows=4] as="textarea" の行数
 * @param {string} [props.autoComplete]
 * @param {string} [props.inputMode]
 * @param {number} [props.maxLength]
 * @param {string} [props.accept] type="file" で選択できる形式
 * @param {string} [props.value="true"] as="checkbox" で送信する値
 * @param {boolean} [props.defaultChecked=false] as="checkbox" の初期状態
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
  accept,
  value = "true",
  defaultChecked = false,
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

  const labelContent = (
    <>
      <span>{label}</span>
      {required && <span className={styles.required}>必須</span>}
    </>
  );

  const hintNode = hint ? (
    <p id={hintId} className={styles.hint}>
      {hint}
    </p>
  ) : null;

  const errorNode = error ? (
    <p id={errorId} className={styles.error} role="alert">
      <span aria-hidden="true">!</span>
      <span>{errorMessage(error)}</span>
    </p>
  ) : null;

  // チェックボックスは項目名そのものが操作対象の説明になるので、
  // 上に別の label を置かず、入力欄と項目名を1つの label にまとめる。
  if (as === "checkbox") {
    return (
      <div className={styles.field}>
        <label className={styles.choice} htmlFor={id}>
          <input
            {...shared}
            className={`${styles.control} ${error ? styles.controlHasError : ""}`}
            type="checkbox"
            value={value}
            defaultChecked={defaultChecked}
          />
          <span className={styles.label}>{labelContent}</span>
        </label>
        {hintNode}
        {errorNode}
      </div>
    );
  }

  // ラジオは入力欄が複数あるため、1つのidを指す label ではなく
  // fieldset + legend でグループ全体に項目名を関連付ける。
  if (as === "radio") {
    return (
      <fieldset
        className={`${styles.field} ${styles.fieldset}`}
        role="radiogroup"
        disabled={disabled}
        aria-invalid={Boolean(error)}
        aria-describedby={describedBy}
        aria-required={required || undefined}
      >
        <legend className={styles.label}>{labelContent}</legend>
        {hintNode}
        <div className={styles.choices}>
          {(options ?? []).map((option, index) => {
            // 先頭の選択肢に props.id を与える。AlertMessage のアンカー先を
            // fieldset にすると focus できず、エラー箇所へ移動できないため。
            const optionId = index === 0 ? id : `${id}-${index}`;
            return (
              <label
                key={option.value}
                className={styles.choice}
                htmlFor={optionId}
              >
                <input
                  className={`${styles.control} ${error ? styles.controlHasError : ""}`}
                  id={optionId}
                  name={name}
                  type="radio"
                  value={option.value}
                  defaultChecked={
                    defaultValue !== undefined &&
                    defaultValue !== null &&
                    defaultValue !== "" &&
                    String(defaultValue) === String(option.value)
                  }
                />
                <span>{option.label}</span>
              </label>
            );
          })}
        </div>
        {errorNode}
      </fieldset>
    );
  }

  return (
    <div className={styles.field}>
      <label className={styles.label} htmlFor={id}>
        {labelContent}
      </label>

      {hintNode}

      {as === "textarea" && (
        <textarea
          {...shared}
          className={`${styles.textarea} ${error ? styles.hasError : ""}`}
          defaultValue={defaultValue}
          placeholder={placeholder}
          rows={rows}
          maxLength={maxLength}
          autoComplete={autoComplete}
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
          accept={accept}
        />
      )}

      {errorNode}
    </div>
  );
}
