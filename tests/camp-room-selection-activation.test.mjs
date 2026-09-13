import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const root = new URL("../", import.meta.url);

test("camp room selection activates the approved eight-room master", async () => {
  const sql = await readFile(
    new URL("supabase/migrations/202609130042_enable_camp_room_selection.sql", root),
    "utf8",
  );

  for (const room of ["桐", "藤", "梅", "竹", "松", "あやめ", "もみぢ", "さくら"]) {
    assert.match(sql, new RegExp(`'${room}'`));
  }
  assert.match(sql, /assignment_enabled = true/);
  assert.match(sql, /printing_enabled = true/);
  assert.match(sql, /floor = 2/);
  assert.match(sql, /sum\(capacity\).*<> 15/s);
  assert.match(sql, /room-master-mismatch/);
  assert.match(sql, /room-mapping-activation-failed/);
});

test("staff room-plan query only returns activated mappings as options", async () => {
  const sql = await readFile(
    new URL("supabase/migrations/202609130032_camp_room_plan_bulk_save.sql", root),
    "utf8",
  );
  const form = await readFile(
    new URL("app/staff/camps/[campId]/room-plan/CampRoomPlanForm.js", root),
    "utf8",
  );

  assert.match(sql, /join public\.camp_room_mapping m on m\.room_id=r\.id where m\.assignment_enabled/);
  assert.match(form, /plan\.rooms\.map\(\(room\) => <option/);
});
