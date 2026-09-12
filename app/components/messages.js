/*
 * エラーコード → 日本語案内の辞書。
 *
 * docs/coding_rules.md 4章：
 * 「エラー時は秘密情報やDB内部情報を画面へ返さず、安定したエラーコードを
 *   日本語表示へ変換する」
 *
 * コード文字列をそのまま画面へ出さない。未知コードは errorMessage() が
 * 汎用文へ落とすので、バックエンドが新しいコードを追加しても画面は壊れない。
 *
 * 収録元：docs/tasks.md 4.2・4.4、docs/routes.md 9.4・9.5・9.6、
 * utils/community-applications/validation.js の CODES、
 * utils/calendar/validation.js の ERROR_CODES と calendarErrorCode() の分岐、
 * app/actions/*.js の分岐（profile.js・guardian-consent.js・staff-camps.js を含む）。
 * 職員側だけで返るコードも、共通部品の誤配線を検出できるよう収録する。
 *
 * 依存なしの純粋モジュール。
 */

export const ERROR_MESSAGES = {
  // 認証（app/actions/auth.js）
  required: "必要な項目が入力されていません。入力内容をご確認ください。",
  invalid: "メールアドレスまたはパスワードが正しくありません。",
  short: "パスワードは6文字以上で入力してください。",
  signup: "新規登録を完了できませんでした。入力内容を確認するか、町の担当へお問い合わせください。",
  confirm: "確認メールを送信しました。メール内の案内に従って登録を完了してください。",
  "login-required": "ログインの有効期限が切れました。もう一度ログインしてください。",

  // 入力検証
  "required-fields": "必須項目が入力されていません。未入力の項目をご確認ください。",
  "invalid-fields": "入力内容に誤りがあります。該当項目をご確認ください。",
  "field-too-long": "入力できる文字数を超えています。該当項目を短くしてください。",
  // プロフィール更新は項目別ではなく画面全体で1コードを返す（app/actions/profile.js の FIELD_LIMITS 判定）
  "too-long": "入力できる文字数を超えています。該当項目を短くしてください。",
  "invalid-phone": "電話番号の形式が正しくありません。数字とハイフンで入力してください。",
  "invalid-email": "メールアドレスの形式が正しくありません。",
  "invalid-place": "使用箇所の指定が正しくありません。選び直してください。",
  "invalid-name": "名称の入力内容をご確認ください。",

  // 日程・期限
  "invalid-period":
    "日付の指定が正しくありません。実在する日付で、開始日が終了日より後にならないようにしてください。",
  "invalid-duration": "利用期間は1泊2日から14泊15日までです。期間を調整してください。",
  "start-too-soon": "利用開始日は申請日の14日後以降にしてください。",
  "end-too-late": "利用終了日は申請日の60日後までにしてください。",
  "deadline-passed": "申請期限を過ぎています。町の担当へお問い合わせください。",
  "invalid-deadline": "期限の指定が正しくありません。利用開始日より前の日時にしてください。",
  "invalid-month": "月の指定が正しくありません。",

  // 資格・定員・競合
  "not-eligible": "この申請の対象者として登録されていません。町の担当へお問い合わせください。",
  "capacity-full": "施設の定員に達しているため、この日程では申請できません。",
  "room-capacity-full": "選択した期間の部屋定員を超えます。割当状況を確認してください。",
  "facility-capacity-full": "施設全体の定員15人を超えます。申請状況を確認してください。",
  "calendar-unavailable": "選択した日程は利用できません。カレンダーで空き状況をご確認ください。",
  "duplicate-stay": "同じ期間に重なる申請があります。日程をご確認ください。",
  "date-conflict":
    "ほかの日程と重なっています。影響する日程を確認してから、もう一度操作してください。",
  "camp-has-applications":
    "この期間には既存の申請があるため変更できません。対象の申請を確認してください。",
  "camp-unavailable": "キャンプ設定が変更されています。最新の期間と申請内容を確認してください。",
  "camp-dates-changed":
    "キャンプの期間が変更されています。最新の期間と申請内容を確認してください。",
  "invalid-camp": "対象のキャンプが見つかりません。申請の入口からやり直してください。",
  "invalid-group": "対象の団体申請が見つかりません。団体申請の一覧からやり直してください。",
  "invalid-participant-count": "予定人数は2人から15人までで入力してください。",
  "invalid-invite": "招待リンクまたはコードが正しくありません。もう一度ご確認ください。",
  "invite-not-available": "この団体では現在、招待を利用できません。最新の団体状態をご確認ください。",
  "invite-expired": "招待の有効期限が切れています。団体代表者へ新しい招待をご確認ください。",
  "group-full": "予定人数に達しているため、この団体には参加できません。",
  "duplicate-group-member": "すでにこの団体へ参加しています。申請一覧をご確認ください。",
  "representative-not-staying": "代表者が宿泊しない設定のため、参加人数の条件をご確認ください。",
  "group-member-inconsistent": "団体の参加状況を確認できません。町の担当へお問い合わせください。",
  "participant-deadline-passed": "参加者の提出期限を過ぎています。町の担当へお問い合わせください。",
  "representative-participant": "団体代表者はこの参加者操作の対象にできません。",

  // 同意書・ファイル
  "guardian-consent": "保護者の同意書が必要です。同意書を添付してから提出してください。",
  "confirmation-required": "申請内容の最終確認に同意してから提出してください。",
  "file-required": "ファイルが選択されていません。",
  "invalid-size": "ファイルの容量が上限を超えています。5MB以下のファイルを選び直してください。",
  "invalid-type":
    "対応していないファイル形式です。PDF・JPEG・PNGのいずれかを選んでください。",
  "invalid-content": "ファイルの内容を確認できませんでした。別のファイルを選び直してください。",
  "upload-failed": "ファイルを保存できませんでした。時間をおいて、もう一度お試しください。",
  // 署名付きURLの発行失敗（app/actions/guardian-consent.js）。ファイル自体は残っている
  "download-failed": "ファイルを取得できませんでした。時間をおいて、もう一度お試しください。",
  "invalid-path": "ファイルの参照先が正しくありません。もう一度お試しください。",

  // 更新競合（docs/routes.md 9.4）
  "invalid-version":
    "別の更新が先に完了したため保存されませんでした。最新の情報を読み込み直してから、もう一度ご確認ください。",
  "stale-update":
    "別の更新が先に完了したため保存されませんでした。最新の情報を読み込み直してから、もう一度ご確認ください。",

  // 状態・操作可否
  "revision-expired": "修正期限を過ぎています。町の担当へお問い合わせください。",
  "not-editable": "現在の状態では編集できません。",
  "not-submittable": "現在の状態では提出できません。",
  "invalid-status": "現在の申請状態では、この操作はできません。",
  "invalid-action": "この操作は受け付けられません。",
  "stay-completed": "退去済みのため、この操作はできません。",
  "stay-started": "すでに滞在が始まっています。キャンセルではなく、町へ連絡して早期退去の手続きをしてください。",
  "invalid-extension": "継続元の申請情報が正しくありません。申請一覧からやり直してください。",
  "invalid-extension-period": "継続期間は、元の利用終了日の翌日から連続する日程で指定してください。",
  "extension-not-available": "現在の状態または日程では継続申請できません。町の担当へお問い合わせください。",
  "extension-exists": "この申請には進行中の継続申請があります。申請一覧から続きの申請をご確認ください。",
  "invalid-application": "対象の申請が見つかりません。申請一覧からやり直してください。",
  "invalid-submission-key": "提出を受け付けられませんでした。画面を読み込み直してください。",

  // 部屋・理由（職員操作。本人画面でも誤配線検出のため収録する）
  "room-required": "許可する前に部屋を割り当ててください。",
  "invalid-room": "部屋を選び直してください。",
  "invalid-room-plan": "部屋別人数の入力を確認してください。",
  "duplicate-room": "同じ部屋が重複しています。部屋別人数を確認してください。",
  "allocation-count-mismatch": "部屋別人数の合計を参加者数と一致させてください。",
  "purpose-review-required": "先に団体の利用目的を確認してください。",
  "participants-not-approved": "予定人数分の参加者をすべて許可してから団体を許可してください。",
  "reason-required": "理由を入力してください。",
  "reason-too-long": "理由は2,000文字以内で入力してください。",
  // 対象者メールの一括登録（app/actions/staff-camps.js・utils/calendar/validation.js）
  "invalid-emails": "メールアドレスの形式が正しくありません。該当の行をご確認ください。",
  "too-many-emails": "一度に登録できるのは1,000件までです。件数を分けて登録してください。",

  // データ不整合（画面から自動修復しない）
  "invalid-allocation": "保存済みの情報が整合していません。管理担当へ確認してください。",
  "invalid-stay": "保存済みの情報が整合していません。管理担当へ確認してください。",
  "calendar-inconsistent": "保存済みの情報が整合していません。管理担当へ確認してください。",
  "application-inconsistent": "保存済みの情報が整合していません。管理担当へ確認してください。",

  // 取得・保存の失敗
  "not-found": "対象の情報が見つかりません。",
  forbidden: "この操作を行う権限がありません。",
  "load-failed": "情報を読み込めませんでした。時間をおいて、もう一度お試しください。",
  "update-failed": "保存できませんでした。時間をおいて、もう一度お試しください。",
  // プロフィール更新の保存失敗（app/actions/profile.js）。update-failed と同義
  "save-failed": "保存できませんでした。時間をおいて、もう一度お試しください。",
  "invalid-page": "ページの指定が正しくありません。",
  "invalid-query": "検索文字を100文字以内で入力してください。",
  "invalid-usage-type": "利用区分を選び直してください。",
  "invalid-application-status": "申請状態を選び直してください。",
  "invalid-payment-status": "納付状態を選び直してください。",
  "invalid-stay-status": "滞在状態を選び直してください。",
  "invalid-payment-deadline": "納付期限の日付を選び直してください。",
  "charge-not-found": "料金情報が見つかりません。最新の画面を読み込み直してください。",
  "note-required": "職員メモを入力してください。",
  "note-too-long": "職員メモは2,000文字以内で入力してください。",
  "invalid-note": "職員メモの指定が正しくありません。",
  "note-not-found": "職員メモが見つかりません。最新の画面を読み込み直してください。",
  unexpected: "処理できませんでした。時間をおいて、もう一度お試しください。",
};

const FALLBACK_MESSAGE = "処理できませんでした。時間をおいて、もう一度お試しください。";

/**
 * エラーコードを日本語案内へ変換する。
 * 未知コード・null は汎用文を返し、コード文字列を画面へ出さない。
 *
 * @param {string|null|undefined} code バックエンドが返す安定したエラーコード
 * @returns {string} 日本語の案内文
 */
export function errorMessage(code) {
  if (typeof code !== "string" || code === "") return FALLBACK_MESSAGE;
  // Object.hasOwn で自前のキーに限定する。ERROR_MESSAGES[code] だと
  // "toString" のような Object.prototype のプロパティ名が関数として返り、
  // 案内文のつもりで関数を描画してしまう。
  return Object.hasOwn(ERROR_MESSAGES, code) ? ERROR_MESSAGES[code] : FALLBACK_MESSAGE;
}

/**
 * フォームの name → 項目名（日本語）。
 * キーは docs/routes.md 9.5・docs/tasks.md 4.1 のフォーム名と一致させる。
 * fieldErrors のキーがそのまま引けるようにするための辞書。
 */
export const FIELD_LABELS = {
  // 共通申請項目
  applicantName: "氏名",
  applicantAddress: "住所",
  applicantPhone: "電話番号",
  emergencyContactName: "緊急連絡先の氏名",
  emergencyContactAddress: "緊急連絡先の住所",
  emergencyContactPhone: "緊急連絡先の電話番号",
  usagePurpose: "使用目的",
  localActivity: "平泉町内で行う活動",
  notes: "特記事項",
  usagePlace: "使用箇所",
  startDate: "使用開始日",
  endDate: "使用終了日",
  guardianConsentRequired: "保護者同意書の要否",
  guardianConsentFile: "保護者同意書",
  requestedRoomPreference: "相部屋希望",
  confirmed: "提出前の最終確認",

  // 団体申請
  groupName: "団体名",
  representativeName: "代表者氏名",
  representativeAddress: "代表者住所",
  representativePhone: "代表者電話番号",
  plannedParticipants: "予定人数",
  representativeStays: "代表者本人の宿泊",

  // 認証
  email: "メールアドレス",
  password: "パスワード",

  // プロフィール
  fullName: "氏名",
  address: "住所",
  phone: "電話番号",
  emergencyName: "緊急連絡先の氏名",
  emergencyAddress: "緊急連絡先の住所",
  emergencyPhone: "緊急連絡先の電話番号",

  // 職員操作（共通部品の取り違え検出用に収録）
  roomId: "部屋",
  reason: "理由",
  approvalComment: "許可コメント",
  paymentStatus: "納付状態",
  paymentDueDate: "納付期限",
  body: "職員メモ",
};

/**
 * フォーム名に対応する項目名を返す。辞書に無ければフォーム名をそのまま返さず
 * 「入力項目」とする（内部名を画面へ出さないため）。
 *
 * @param {string} name フォームの name
 * @returns {string}
 */
export function fieldLabel(name) {
  if (typeof name !== "string" || name === "") return "入力項目";
  // errorMessage() と同じ理由で Object.hasOwn を使う
  return Object.hasOwn(FIELD_LABELS, name) ? FIELD_LABELS[name] : "入力項目";
}

/** 仮データ表示中であることを示す固定文（MockDataNotice が使う） */
export const MOCK_NOTICE_TEXT =
  "この画面は開発用の仮データを表示しています。実際の申請データとは接続していません。";
