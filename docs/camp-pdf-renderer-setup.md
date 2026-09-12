# A8 キャンプ申請PDF変換設定

## 実装状態

SQL036と変換imageのソースを追加した。本番SupabaseへのSQL適用、GHCRへのimage push、コンテナ配備、active設定の登録は未実施であり、`private.camp_pdf_render_settings(uuid)` は引き続き `pdf-prerequisites-unavailable` で閉じる。

対象はA7と同じく、新方式campの使用許可申請書だけである。正式な使用許可通知書、納付書、保護者同意書、地域活動、legacy campは扱わない。

## 固定資産

| 項目 | A8 settings version 1 |
|---|---|
| 原本 | `pdf-renderer/assets/02-02.使用許可申請書（様式第１号）.docx` |
| 原本SHA-256 | `39d3621b02fd4559fa227f263f541ccc92dbd0d1b19a663891d0783407c33bfe` |
| フォント | Noto Serif JP 2.003、SIL Open Font License 1.1 |
| フォントSHA-256 | `2c9a12dbd4f2408c4610c7ee84a108b62d7236c3775baed618c64d9cb44b2f04` |
| 町長名 | `青木 幸保`。2026年9月13日に平泉町公式「町長の部屋」と2026年8月4日の町長選挙無投票公告で照合 |
| 変換image | 配備後の `ghcr.io/...@sha256:<64桁>` を使用。tagは設定登録不可 |

原本は変更せず同梱する。差込DOCXでは本文とスタイルのフォント参照、指定スロットの文字、変更申請の取り消し線だけを変更し、原本に残る別規則の文書タイトル・個人作成者メタデータを除去する。他のpackage partとrelationshipは保存する。詳細は `pdf-renderer/template-contract.md`。

## 変換と検証

`pdf-renderer/worker.py` はブラウザから直接呼ばれない。32文字以上の `CAMP_PDF_WORKER_SECRET` を使い、A7の `camp-pdf-worker` へHTTPSでclaim/complete/failを送る。claimが返したsource snapshotとrender contextが一致し、原本hash、設定版、フォント版、町長名、配備image digestが一致した場合だけ変換する。

変換はLinux上のLibreOffice Writerで行う。申請日と利用日は和暦に変換し、A3の印字用部屋名を使用する。氏名20、住所30、電話20、目的60、特記事項80、部屋名15文字をDBと変換器の両方で検査する。上限超過をフォント縮小で押し込まず拒否する。

出力はPopplerで次を実測する。

- A4縦1ページ
- Noto Serif JPを含む全使用フォントの埋込み
- 町長名、和暦、本人・緊急連絡先、目的、特記事項、A3部屋名の日本語文字抽出
- 144 DPI PNG生成と最大入力fixtureの欄内収容

検証値はコンテナ自身が算出し、成功した4項目だけをA7 workerへ送る。変換失敗はfailを通知するが、completeの応答喪失時は既に正本が確定した可能性があるためfailを送らない。

## SQL036適用と配備順序

以下はメインチャット担当。順序を入れ替えない。

1. SQL035までが本番に適用済みであることを確認し、`supabase/migrations/202609130036_camp_pdf_renderer_settings.sql` 全体を1トランザクションで適用する。active設定は作られない。
2. `docker build --tag camp-pdf-renderer:a8-v1 pdf-renderer` を実行し、CIと同じ最大入力テストを通す。
3. 承認したprivate GHCR repositoryへimageをpushし、registryが返すmanifest digestを控える。tagやローカルimage IDを代用しない。
4. 同じdigestのimageを認証されたLinux実行基盤へ配備する。環境変数は `CAMP_PDF_WORKER_URL`、`CAMP_PDF_WORKER_SECRET`、`CAMP_PDF_CONVERTER_IMAGE=ghcr.io/...@sha256:<digest>`。secret、snapshot、PDF本文をログへ出さない。
5. 配備imageから最大入力fixtureを再生成し、PDF、抽出テキスト、`pdffonts`、PNGを人が確認する。PR CIのartifactだけで本番imageを検証済みとしない。
6. 検証したdigestだけを次の管理トランザクションで登録・有効化する。プレースホルダーは実値へ置換し、再実行しない。

```sql
begin;
select private.lock_calendar_facility();
insert into private.camp_pdf_render_setting_versions(
  settings_version,template_hash,font_version,converter_image,mayor_name,
  user_name_limit,user_address_limit,emergency_name_limit,emergency_address_limit,
  purpose_limit,special_notes_limit,room_name_limit,verified_at
) values (
  1,
  '39d3621b02fd4559fa227f263f541ccc92dbd0d1b19a663891d0783407c33bfe',
  'NotoSerifJP-2.003+sha256:2c9a12dbd4f2408c4610c7ee84a108b62d7236c3775baed618c64d9cb44b2f04',
  'ghcr.io/OWNER/IMAGE@sha256:REPLACE_WITH_64_HEX_DIGEST',
  '青木 幸保',20,30,20,30,60,80,15,clock_timestamp()
);
insert into private.camp_pdf_active_render_setting(singleton,settings_version)
values(true,1)
on conflict(singleton) do update
set settings_version=excluded.settings_version,activated_at=clock_timestamp();
commit;
```

設定版の行は更新・削除できない。原本、フォント、町長名、上限、imageのいずれかを変更するときは新しいversion行を追加し、検証後にactiveポインタだけを切り替える。

## 適用後の読取確認

```sql
select settings_version,template_hash,font_version,converter_image,mayor_name,verified_at
from private.camp_pdf_render_setting_versions order by settings_version;
select * from private.camp_pdf_active_render_setting;
select pg_get_functiondef('private.camp_pdf_render_settings(uuid)'::regprocedure);
```

本番の個人データやPDF本文は確認SQLへ含めない。A3の実部屋対応・印字許可が未承認の間、またはA9が未実装の間は、active設定登録後も利用者向け確認提出を公開しない。
