/*
 * 開発用の仮データ。
 *
 * - 実在の個人情報を含まない。メールは RFC 2606 の予約ドメイン example.com、
 *   電話番号は実在しない 000- 始まり、氏名・住所は「（架空）」を明記する。
 * - バックエンド接続時にこのファイルごと削除・置換する。各画面へ値を
 *   ばらばらに埋め込まない（docs/frontend-handoff.md「ファイルの担当境界」）。
 * - UUIDは明らかに架空と分かる反復パターンで、既存 utils/calendar/validation.js
 *   の UUID_PATTERN（バージョン1〜5・variant 8/9/a/b）に適合させている。
 * - 受付番号は「SG-西暦-連番」（docs/requirements.md 6.3）。UUIDとは別値。
 *
 * 項目名は実際の返却契約に合わせる：
 *   MOCK_APPLICATIONS       … utils/community-applications/queries.js の
 *                             getCommunityApplication() が返す application
 *   MOCK_APPLICATION_LIST   … 同 getCommunityApplications() が返す applications
 *
 * 補助項目（usage_type / camp_id）は上記の返却契約には含まれない。
 * 一覧の区分表示のために仮データ側で持たせているだけで、キャンプ・統合一覧の
 * 取得契約（T08/T16）が決まったら差し替える。
 */

/** 利用者プロフィール（profiles） */
export const MOCK_USER = {
  id: "00000000-0000-4000-8000-000000000001",
  email: "camp-demo@example.com",
  full_name: "志業 太郎（架空）",
  address: "岩手県西磐井郡平泉町大字平泉字架空1-2-3",
  phone: "000-0000-0000",
  emergency_name: "志業 花子（架空）",
  emergency_address: "岩手県西磐井郡平泉町大字平泉字架空1-2-3",
  emergency_phone: "000-0000-0001",
  account_state: "active",
};

/**
 * スパルタキャンプ（camps）。
 * application_deadline はDBの排他的境界なので、表示は format.js の
 * formatDeadline() を通す（→「2026年7月31日 23:59」）。
 */
export const MOCK_CAMP = {
  id: "33333333-3333-4333-8333-333333333333",
  name: "第0期 スパルタキャンプ（架空）",
  start_date: "2026-08-15",
  end_date: "2026-09-15",
  application_deadline: "2026-08-01T00:00:00.000000+09:00",
};

/** 部屋マスタ8件・合計15人（docs/database.md 5.5） */
export const MOCK_ROOMS = [
  { id: "22222222-2222-4222-8222-222222222201", name: "桐", capacity: 1 },
  { id: "22222222-2222-4222-8222-222222222202", name: "藤", capacity: 1 },
  { id: "22222222-2222-4222-8222-222222222203", name: "梅", capacity: 2 },
  { id: "22222222-2222-4222-8222-222222222204", name: "竹", capacity: 2 },
  { id: "22222222-2222-4222-8222-222222222205", name: "松", capacity: 2 },
  { id: "22222222-2222-4222-8222-222222222206", name: "あやめ", capacity: 2 },
  { id: "22222222-2222-4222-8222-222222222207", name: "もみぢ", capacity: 2 },
  { id: "22222222-2222-4222-8222-222222222208", name: "さくら", capacity: 3 },
];

/** 問い合わせ先（contact_settings）。滞在中の案内表示に使う */
export const MOCK_CONTACT = {
  name: "平泉町 担当課（架空）",
  phone: "000-000-0000",
  service_hours: "平日 8:30〜17:15",
};

/**
 * 申請3件。
 *
 * application の項目は getCommunityApplication() の返却と同じ：
 *   id / status / updated_at / reserved_start_date / reserved_end_date /
 *   submitted_at / last_submitted_at / revision_due_at / decision_reason /
 *   approval_comment / reception_number / has_consent / can_edit /
 *   room_allocation / stay / fields / events / estimated_months / charge
 *
 * fields のキーは utils/community-applications/validation.js の FIELD_NAMES
 * が示すDB列名（snake_case）。フォームの name（camelCase）との対応は
 * messages.js の FIELD_LABELS を参照する。
 *
 * updated_at はマイクロ秒付きの文字列のまま保持する。
 * 画面側は Date を経由させず、この文字列をそのまま hidden input へ渡す
 * （docs/tasks.md 4.4・docs/routes.md 9.5）。
 */
export const MOCK_APPLICATIONS = [
  // 1件目：下書き（キャンプ）。枠・受付番号・料金を持たない
  {
    id: "11111111-1111-4111-8111-111111111111",
    usage_type: "camp",
    camp_id: MOCK_CAMP.id,
    status: "draft",
    updated_at: "2026-09-01T01:15:00.123456+00:00",
    reserved_start_date: null,
    reserved_end_date: null,
    submitted_at: null,
    last_submitted_at: null,
    revision_due_at: null,
    decision_reason: null,
    approval_comment: null,
    reception_number: null,
    has_consent: false,
    can_edit: true,
    room_allocation: null,
    stay: null,
    fields: {
      user_name: MOCK_USER.full_name,
      user_address: MOCK_USER.address,
      user_phone: MOCK_USER.phone,
      emergency_name: MOCK_USER.emergency_name,
      emergency_address: MOCK_USER.emergency_address,
      emergency_phone: MOCK_USER.emergency_phone,
      purpose: "スパルタキャンプへの参加のため。",
      local_activity: null,
      special_notes: null,
      usage_place: "common_and_second_floor",
      start_date: MOCK_CAMP.start_date,
      end_date: MOCK_CAMP.end_date,
      requires_guardian_consent: false,
    },
    events: [],
    // 下書きは見込計算のみ（docs/database.md 5.7）
    estimated_months: [
      {
        month: "2026-08-01",
        usage_days: 17,
        daily_rate: 300,
        monthly_cap: 9000,
        amount: 5100,
      },
      {
        month: "2026-09-01",
        usage_days: 15,
        daily_rate: 300,
        monthly_cap: 9000,
        amount: 4500,
      },
    ],
    charge: null,
    // 補助項目：キャンプ申請の相部屋希望（getCommunityApplication の返却外）
    requested_room_preference: "shared_ok",
  },

  // 2件目：修正依頼（地域活動・個人）。
  // fields の日程が修正候補、reserved_* が元の提出期間（docs/routes.md 9.5）。
  // 詳細RPC get_community_application は
  //   fields.start_date := coalesce(revision_start_date, start_date)
  // なので、修正依頼中だけ fields（10/11〜13＝修正候補）と
  // reserved_*（10/10〜12＝applications.start_date/end_date の予約済み期間）が
  // 食い違う。一覧は applications の列をそのまま返すため reserved_* 側と一致する。
  // この2件目は、その差を画面側が取り違えていないか確かめるための唯一の例。
  // 納付期限を過ぎた未納の例。「期限超過」は表示だけで、納付状態は「未納」のまま。
  {
    id: "11111111-1111-4111-8111-111111111112",
    usage_type: "community_individual",
    camp_id: null,
    status: "revision_requested",
    updated_at: "2026-09-08T23:40:12.654321+00:00",
    reserved_start_date: "2026-10-10",
    reserved_end_date: "2026-10-12",
    submitted_at: "2026-09-05T02:10:00.000000+00:00",
    last_submitted_at: "2026-09-05T02:10:00.000000+00:00",
    revision_due_at: "2026-10-01T00:00:00.000000+09:00",
    decision_reason: "町内で行う活動の具体的な内容を追記してください。",
    approval_comment: null,
    reception_number: "SG-2026-0001",
    has_consent: false,
    can_edit: true,
    room_allocation: null,
    stay: null,
    fields: {
      user_name: MOCK_USER.full_name,
      user_address: MOCK_USER.address,
      user_phone: MOCK_USER.phone,
      emergency_name: MOCK_USER.emergency_name,
      emergency_address: MOCK_USER.emergency_address,
      emergency_phone: MOCK_USER.emergency_phone,
      purpose: "地域活動の打ち合わせと現地確認のため。",
      local_activity: "平泉町内の史跡周辺で清掃活動を行います。",
      special_notes: null,
      usage_place: "common_and_second_floor",
      start_date: "2026-10-11",
      end_date: "2026-10-13",
      requires_guardian_consent: false,
    },
    events: [
      {
        from_status: "draft",
        to_status: "submitted",
        public_reason: null,
        occurred_at: "2026-09-05T02:10:00.000000+00:00",
      },
      {
        from_status: "submitted",
        to_status: "under_review",
        public_reason: null,
        occurred_at: "2026-09-07T00:20:00.000000+00:00",
      },
      {
        from_status: "under_review",
        to_status: "revision_requested",
        public_reason: "町内で行う活動の具体的な内容を追記してください。",
        occurred_at: "2026-09-08T23:40:12.654321+00:00",
      },
    ],
    // 修正候補の日程にもとづく見込（2026-10-11〜13 の3日分）
    estimated_months: [
      {
        month: "2026-10-01",
        usage_days: 3,
        daily_rate: 300,
        monthly_cap: 9000,
        amount: 900,
      },
    ],
    // charge は初回提出で作成済み。金額は元の提出期間（reserved_*）にもとづく。
    // getCommunityApplication の charge は total_amount / payment_status /
    // payment_due_date / months だけを返す（paid_at・calculated_at は返らない）。
    charge: {
      total_amount: 900,
      payment_status: "unpaid",
      payment_due_date: "2026-09-05",
      months: [
        {
          month: "2026-10-01",
          usage_days: 3,
          daily_rate: 300,
          monthly_cap: 9000,
          amount: 900,
        },
      ],
    },
    requested_room_preference: null,
  },

  // 3件目：許可（キャンプ）。部屋割当・滞在あり、納付済み
  {
    id: "11111111-1111-4111-8111-111111111113",
    usage_type: "camp",
    camp_id: MOCK_CAMP.id,
    status: "approved",
    updated_at: "2026-07-25T06:05:30.987654+00:00",
    reserved_start_date: MOCK_CAMP.start_date,
    reserved_end_date: MOCK_CAMP.end_date,
    submitted_at: "2026-07-20T01:00:00.000000+00:00",
    last_submitted_at: "2026-07-20T01:00:00.000000+00:00",
    revision_due_at: null,
    decision_reason: null,
    approval_comment: "利用当日は共用部分の使い方の説明を受けてください。",
    reception_number: "SG-2026-0002",
    has_consent: true,
    can_edit: false,
    room_allocation: {
      room_id: MOCK_ROOMS[7].id,
      room_name: MOCK_ROOMS[7].name,
      people_count: 1,
      start_date: MOCK_CAMP.start_date,
      end_date: MOCK_CAMP.end_date,
      released_from: null,
      // is_current=false の旧割当を現在の部屋として表示しない（docs/routes.md 9.6）
      is_current: true,
    },
    stay: {
      status: "before_move_in",
      checked_in_at: null,
      checked_out_at: null,
    },
    fields: {
      user_name: MOCK_USER.full_name,
      user_address: MOCK_USER.address,
      user_phone: MOCK_USER.phone,
      emergency_name: MOCK_USER.emergency_name,
      emergency_address: MOCK_USER.emergency_address,
      emergency_phone: MOCK_USER.emergency_phone,
      purpose: "スパルタキャンプへの参加のため。",
      local_activity: null,
      special_notes: "到着は15時ごろの予定です。",
      usage_place: "common_and_second_floor",
      start_date: MOCK_CAMP.start_date,
      end_date: MOCK_CAMP.end_date,
      requires_guardian_consent: true,
    },
    events: [
      {
        from_status: "draft",
        to_status: "submitted",
        public_reason: null,
        occurred_at: "2026-07-20T01:00:00.000000+00:00",
      },
      {
        from_status: "submitted",
        to_status: "under_review",
        public_reason: null,
        occurred_at: "2026-07-22T00:30:00.000000+00:00",
      },
      {
        from_status: "under_review",
        to_status: "approved",
        public_reason: "利用当日は共用部分の使い方の説明を受けてください。",
        occurred_at: "2026-07-25T06:05:30.987654+00:00",
      },
    ],
    estimated_months: [],
    // 8月17日分5,100円＋9月15日分4,500円＝9,600円（docs/requirements.md 16.1）
    charge: {
      total_amount: 9600,
      payment_status: "paid",
      payment_due_date: "2026-08-10",
      months: [
        {
          month: "2026-08-01",
          usage_days: 17,
          daily_rate: 300,
          monthly_cap: 9000,
          amount: 5100,
        },
        {
          month: "2026-09-01",
          usage_days: 15,
          daily_rate: 300,
          monthly_cap: 9000,
          amount: 4500,
        },
      ],
    },
    requested_room_preference: "private_requested",
  },
];

/**
 * 申請一覧の仮データ。
 * getCommunityApplications() の返却列（id / status / start_date / end_date /
 * updated_at / submitted_at / last_submitted_at / revision_due_at /
 * decision_reason）に合わせる。詳細と違い、日程は入れ子ではなく直下にある。
 * usage_type は一覧の区分表示のための補助項目。
 *
 * 日程は詳細の fields ではなく reserved_* から作る。一覧は applications テーブルの
 * start_date / end_date 列をそのまま select するのに対し、詳細RPCの fields は
 * coalesce(revision_start_date, start_date) だからで、修正依頼中は両者が異なる
 * （docs/routes.md 9.5「修正中はfieldsの日程が候補、reservedの日程が元の提出期間」）。
 * reserved_* は提出前（submitted_at が null）だと null になるが、そのとき
 * revision_start_date も null なので fields の日程が applications の列と一致する。
 * ここで fields を使うと、修正依頼中の2件目だけ一覧が実データと食い違う。
 */
export const MOCK_APPLICATION_LIST = MOCK_APPLICATIONS.map((application) => ({
  id: application.id,
  status: application.status,
  start_date: application.reserved_start_date ?? application.fields.start_date,
  end_date: application.reserved_end_date ?? application.fields.end_date,
  updated_at: application.updated_at,
  submitted_at: application.submitted_at,
  last_submitted_at: application.last_submitted_at,
  revision_due_at: application.revision_due_at,
  decision_reason: application.decision_reason,
  usage_type: application.usage_type,
}));

/**
 * 申請IDから仮データを探す。見つからなければ null（例外を投げない）。
 *
 * @param {string} applicationId 申請UUID
 * @returns {object|null}
 */
export function findMockApplication(applicationId) {
  return (
    MOCK_APPLICATIONS.find(
      (application) => application.id === applicationId,
    ) ?? null
  );
}

/**
 * 部屋IDから仮データを探す。見つからなければ null。
 *
 * @param {string} roomId 部屋UUID
 * @returns {object|null}
 */
export function findMockRoom(roomId) {
  return MOCK_ROOMS.find((room) => room.id === roomId) ?? null;
}
