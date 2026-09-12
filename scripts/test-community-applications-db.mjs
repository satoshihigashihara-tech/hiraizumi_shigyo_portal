// Local-only PostgreSQL harness. No .env or hosted Supabase connection is read.
// Dependencies live outside the project: embedded-postgres and pg.
// T10_DB_RUNTIME can point to their existing package directory.
import { createRequire } from 'node:module';
import { readFile, readdir, mkdtemp, rm } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createServer } from 'node:net';
import assert from 'node:assert/strict';

const runtime = createRequire(join(resolve(process.env.T10_DB_RUNTIME || '/private/tmp/hiraizumi-t09-postgres'), 'package.json'));
const EmbeddedPostgres = runtime('embedded-postgres').default;
const { Client } = runtime('pg');
const root = fileURLToPath(new URL('../', import.meta.url));
const port = await new Promise((resolvePort, reject) => {
  const server = createServer(); server.on('error', reject);
  server.listen(0, '127.0.0.1', () => { const p = server.address().port; server.close(() => resolvePort(p)); });
});
const scratch = await mkdtemp(join(tmpdir(), 'hiraizumi-t10-'));
const password = randomUUID();
const pg = new EmbeddedPostgres({ databaseDir: join(scratch, 'data'), user: 'postgres', password, port, persistent: false,
  initdbFlags: ['--locale=C', '--encoding=UTF8'], postgresFlags: ['-h', '127.0.0.1', '-k', scratch], onLog() {}, onError() {} });
const clients = [];
async function connect() {
  const c = new Client({ host: '127.0.0.1', port, user: 'postgres', password, database: 'postgres' });
  await c.connect(); clients.push(c); return c;
}
// Upgrade fixtures use real 013 APIs in this private, newly created local DB.
// Compare stored rows (not function output, whose contract 014 deliberately adds to).
async function prepareUpgrade(c) {
  const staff = randomUUID(), owner = randomUUID();
  for (const id of [staff, owner]) await c.query('insert into auth.users(id,email) values($1,$2)', [id, `upgrade-${id}@example.invalid`]);
  await c.query('insert into public.staff_roles(user_id) values($1)', [staff]);
  async function asActor(actor, sql, values = []) {
    await c.query('select set_config($1,$2,false)', ['request.jwt.claims', JSON.stringify({ sub: actor, email: `upgrade-${actor}@example.invalid`, role: 'authenticated' })]);
    await c.query('set role authenticated');
    try { return await c.query(sql, values); } finally { await c.query('reset role'); }
  }
  const camp = (await asActor(staff, `select public.create_staff_camp('架空の移行検証キャンプ',current_date+100,current_date+102,clock_timestamp()+interval '1 day') as id`)).rows[0].id;
  await asActor(staff, 'select public.add_camp_eligible_users($1,$2)', [camp, [`upgrade-${owner}@example.invalid`]]);
  const campApp = (await asActor(owner, 'select public.create_camp_application_draft($1) as id', [camp])).rows[0].id;
  await asActor(owner, `select public.save_camp_application_draft($1,'架空移行利用者','架空住所','0000000000','架空連絡先','架空住所','0000000000','架空キャンプ',null,false,'shared_ok')`, [campApp]);
  await asActor(owner, 'select * from public.submit_camp_application($1)', [campApp]);
  const version = async (id) => (await c.query('select updated_at::text as version from public.applications where id=$1', [id])).rows[0].version;
  await asActor(staff, "select * from public.review_camp_application($1,'start_review',$2)", [campApp, await version(campApp)]);
  const room = (await c.query("select id from public.rooms where name='桐'")).rows[0].id;
  await asActor(staff, 'select * from public.assign_camp_application_room($1,$2,$3)', [campApp, room, await version(campApp)]);
  await asActor(staff, "select * from public.review_camp_application($1,'approve',$2,'移行前の許可')", [campApp, await version(campApp)]);
  const communityApp = randomUUID();
  const fields = (await c.query(`select jsonb_build_object('user_name','架空移行利用者','user_address','架空住所','user_phone','0000000000',
    'emergency_name','架空連絡先','emergency_address','架空住所','emergency_phone','0000000000','purpose','架空調査','local_activity','町内の架空調査',
    'usage_place','common_and_second_floor','requires_guardian_consent',false,
    'start_date',((clock_timestamp() at time zone 'Asia/Tokyo')::date+20)::text,
    'end_date',((clock_timestamp() at time zone 'Asia/Tokyo')::date+22)::text) as fields`)).rows[0].fields;
  await asActor(owner, 'select * from public.create_community_application_draft($1,$2)', [communityApp, fields]);
  await asActor(owner, 'select * from public.submit_community_application($1,$2,$3,true)', [communityApp, await version(communityApp), randomUUID()]);
  await asActor(staff, "select * from public.review_community_application($1,'start_review',$2)", [communityApp, await version(communityApp)]);
  await asActor(staff, "select * from public.review_community_application($1,'request_revision',$2,'移行前の修正依頼')", [communityApp, await version(communityApp)]);
  await asActor(owner, 'select * from public.save_community_application_draft($1,$2,$3)', [communityApp, await version(communityApp), { ...fields, purpose: '修正中の架空調査' }]);
  await c.query("select set_config('request.jwt.claims','{}',false)");
  return { staff, owner, camp, applications: [campApp, communityApp] };
}
async function storedRows(c) {
  const result = {};
  for (const table of ['profiles','staff_roles','rooms','camps','camp_eligible_users','applications','room_allocations','stays',
    'calendar_claims','application_charges','charge_months','reception_numbers','reception_counters','application_status_events','audit_logs','consent_documents']) {
    result[table] = (await c.query(`select coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text),'[]') as rows from public.${table} t`)).rows[0].rows;
  }
  if ((await c.query("select to_regclass('public.staff_notes') is not null as present")).rows[0].present) {
    result.staff_notes=(await c.query("select coalesce(jsonb_agg(to_jsonb(n) order by n.id),'[]') as rows from public.staff_notes n")).rows[0].rows;
  }
  return result;
}
async function cleanupUpgrade(c, fixture) {
  await c.query('begin');
  await c.query('delete from public.audit_logs where actor_user_id=any($1::uuid[])', [[fixture.staff, fixture.owner]]);
  await c.query('delete from public.calendar_claims where application_id=any($1::uuid[]) or camp_id=$2', [fixture.applications, fixture.camp]);
  await c.query('delete from public.applications where id=any($1::uuid[])', [fixture.applications]);
  await c.query('delete from public.camps where id=$1', [fixture.camp]);
  await c.query('delete from auth.users where id=any($1::uuid[])', [[fixture.staff, fixture.owner]]);
  await c.query('commit');
  assert.equal((await c.query('select count(*)::integer as n from public.applications where id=any($1::uuid[])', [fixture.applications])).rows[0].n, 0);
}
// Phase 1 only: exercise real waiting on two local connections; no hosted DB.
async function paymentConcurrency(c) {
  const fixture = await prepareUpgrade(c);
  const a = await connect(), b = await connect();
  const app = fixture.applications[0];
  const actor = fixture.staff;
  async function session(client) {
    await client.query("select set_config('request.jwt.claims',$1,false)", [JSON.stringify({ sub: actor, role: 'authenticated' })]);
    await client.query('set role authenticated');
  }
  try {
    for (const scenario of ['same-version', 'review-versus-payment', 'staff-disabled-while-waiting', 'repeatable-read']) {
      const target = scenario === 'review-versus-payment' ? fixture.applications[1] : app;
      const version = (await c.query('select updated_at::text as v from public.applications where id=$1', [target])).rows[0].v;
      await session(a); await session(b);
      await a.query('begin');
      await b.query(scenario === 'repeatable-read' ? 'begin isolation level repeatable read' : 'begin');
      if (scenario === 'repeatable-read') await b.query('select count(*) from public.applications');
      if (scenario === 'staff-disabled-while-waiting') {
        await a.query('reset role');
        await a.query('select private.lock_calendar_facility()');
        await a.query("update public.profiles set account_state='disabled' where id=$1", [actor]);
      } else {
        await a.query("select * from public.update_application_payment($1,$2,'paid',$3)", [target, version,
          scenario === 'repeatable-read' ? '2028-01-02' : '2028-01-01']);
      }
      const peer = (await b.query('select pg_backend_pid() as pid')).rows[0].pid;
      const leader = (await a.query('select pg_backend_pid() as pid')).rows[0].pid;
      const promise = (scenario === 'review-versus-payment'
        ? b.query("select * from public.review_community_application($1,'reject',$2,'架空の不許可')", [target, version])
        : b.query("select * from public.update_application_payment($1,$2,'unpaid',null,'架空訂正')", [target, version]))
        .then(() => ({ ok: true }), error => ({ ok: false, code: error.code, message: error.message }));
      let waited = false;
      for (let i = 0; i < 100; i++) {
        if ((await c.query('select $2::integer=any(pg_blocking_pids($1)) as waiting', [peer, leader])).rows[0].waiting) { waited = true; break; }
        await new Promise(resolve => setTimeout(resolve, 20));
      }
      await a.query('reset role');
      const expected = await storedRows(a);
      await a.query('commit');
      const rejected = await promise;
      await b.query('rollback'); await b.query('reset role');
      assert.ok(waited && peer !== leader, `${scenario}: must prove actual waiting on distinct connections`);
      assert.equal(rejected.ok, false, scenario);
      assert.equal(rejected.code, scenario === 'repeatable-read' ? '40001' : scenario === 'staff-disabled-while-waiting' ? '42501' : 'P0001');
      if (['same-version', 'review-versus-payment'].includes(scenario)) assert.equal(rejected.message, 'stale-update');
      assert.deepEqual(await storedRows(c), expected, `${scenario}: losing transaction leaves no partial updates`);
      if (scenario === 'staff-disabled-while-waiting') await c.query("update public.profiles set account_state='active' where id=$1", [actor]);
      console.log('PASS payment concurrency', scenario);
    }
  } finally {
    await a.query('rollback'); await b.query('rollback');
    await cleanupUpgrade(c, fixture);
  }
  console.log('PASS payment concurrency cleanup');
}
// Phase 2: real RPC races on separate local connections, with temporary fixtures only.
async function stayConcurrency(c) {
  const scenarios = ['double-check-in', 'double-check-out', 'checkout-versus-room', 'room-versus-checkout',
    'payment-versus-checkout', 'camp-double-checkout', 'staff-disabled', 'repeatable-read', 'checkout-versus-submission'];
  async function session(client, actor) {
    await client.query("select set_config('request.jwt.claims',$1,false)", [JSON.stringify({ sub: actor,
      email: `upgrade-${actor}@example.invalid`, role: 'authenticated' })]);
    await client.query('set role authenticated');
  }
  const version = async (id) => (await c.query('select updated_at::text as v from public.applications where id=$1', [id])).rows[0].v;
  for (const scenario of scenarios) {
    const fixture = await prepareUpgrade(c);
    const staffB = randomUUID();
    await c.query('insert into auth.users(id,email) values($1,$2)', [staffB, `stay-${staffB}@example.invalid`]);
    await c.query('insert into public.staff_roles(user_id) values($1)', [staffB]);
    const a = await connect(), b = await connect();
    try {
      const camp = scenario === 'camp-double-checkout';
      const target = fixture.applications[camp ? 0 : 1];
      if (!camp) {
        const v = await version(target);
        await session(c, fixture.owner);
        await c.query('select * from public.submit_community_application($1,$2,$3,true)', [target,v,randomUUID()]);
        await c.query('reset role');
        let next = await version(target); await session(c, fixture.staff);
        await c.query("select * from public.review_community_application($1,'start_review',$2)", [target,next]);
        await c.query('reset role'); next = await version(target); await session(c, fixture.staff);
        await c.query("select * from public.assign_community_application_room($1,(select id from public.rooms where name='桐'),$2)", [target,next]);
        await c.query('reset role'); next = await version(target); await session(c, fixture.staff);
        await c.query("select * from public.review_community_application($1,'approve',$2)", [target,next]);
        await c.query('reset role');
      }
      // Date relocation is test setup, not a product operation.
      if (camp) await c.query("update public.camps set start_date=(clock_timestamp() at time zone 'Asia/Tokyo')::date,end_date=(clock_timestamp() at time zone 'Asia/Tokyo')::date+14 where id=$1", [fixture.camp]);
      await c.query("update public.applications set start_date=(clock_timestamp() at time zone 'Asia/Tokyo')::date,end_date=(clock_timestamp() at time zone 'Asia/Tokyo')::date+14 where id=$1", [target]);
      await c.query('update public.room_allocations r set start_date=a.start_date,end_date=a.end_date from public.applications a where a.id=r.application_id and a.id=$1', [target]);
      const checkout = !['double-check-in','staff-disabled','repeatable-read'].includes(scenario);
      if (checkout) {
        const v = await version(target); await session(c, fixture.staff);
        await c.query("select * from public.update_application_stay($1,$2,'check_in')", [target,v]); await c.query('reset role');
      }
      let candidate;
      if (scenario === 'checkout-versus-submission') {
        candidate = randomUUID(); fixture.applications.push(candidate);
        const fields = (await c.query(`select jsonb_build_object('user_name','架空利用者','user_address','架空住所','user_phone','0000000000',
          'emergency_name','架空連絡先','emergency_address','架空住所','emergency_phone','0000000000','purpose','架空調査',
          'local_activity','架空調査活動','usage_place','common_and_second_floor','requires_guardian_consent',false,
          'start_date',(clock_timestamp() at time zone 'Asia/Tokyo')::date+14,'end_date',(clock_timestamp() at time zone 'Asia/Tokyo')::date+15) as f`)).rows[0].f;
        await session(c,fixture.owner); await c.query('select * from public.create_community_application_draft($1,$2)',[candidate,fields]); await c.query('reset role');
      }
      const v = await version(target), candidateVersion = candidate ? await version(candidate) : null;
      await session(a, fixture.staff); await session(b, candidate ? fixture.owner : staffB);
      await a.query('begin'); await b.query(scenario === 'repeatable-read' ? 'begin isolation level repeatable read' : 'begin');
      await b.query("set local statement_timeout='8s'");
      if (scenario === 'repeatable-read') await b.query('select count(*) from public.applications');
      if (scenario === 'staff-disabled') {
        await a.query('reset role'); await a.query('select private.lock_calendar_facility()');
        await a.query("update public.profiles set account_state='disabled' where id=$1",[staffB]);
      } else if (scenario === 'room-versus-checkout') {
        await a.query("select * from public.assign_community_application_room($1,(select id from public.rooms where name='藤'),$2,'架空変更')",[target,v]);
      } else if (scenario === 'payment-versus-checkout') {
        await a.query("select * from public.update_application_payment($1,$2,'paid',null)",[target,v]);
      } else await a.query('select * from public.update_application_stay($1,$2,$3)',[target,v,checkout ? 'check_out' : 'check_in']);
      const leader = (await a.query('select pg_backend_pid() as pid')).rows[0].pid;
      const peer = (await b.query('select pg_backend_pid() as pid')).rows[0].pid;
      const pending = (scenario === 'checkout-versus-room'
        ? b.query("select * from public.assign_community_application_room($1,(select id from public.rooms where name='藤'),$2,'架空変更')",[target,v])
        : candidate ? b.query('select * from public.submit_community_application($1,$2,$3,true)',[candidate,candidateVersion,randomUUID()])
        : b.query('select * from public.update_application_stay($1,$2,$3)',[target,v,checkout ? 'check_out' : 'check_in']))
        .then(() => ({ ok:true }), error => ({ ok:false,code:error.code,message:error.message }));
      let waited = false;
      for (let n=0;n<100;n++) {
        if ((await c.query('select $2::integer=any(pg_blocking_pids($1)) as waiting',[peer,leader])).rows[0].waiting) { waited=true; break; }
        await new Promise(resolve => setTimeout(resolve,20));
      }
      await a.query('reset role'); const expected = await storedRows(a); await a.query('commit');
      const outcome = await pending;
      await b.query(candidate && outcome.ok ? 'commit' : 'rollback'); await b.query('reset role');
      assert.ok(waited && leader!==peer, `${scenario}: distinct connections and actual waiting`);
      if (candidate) {
        assert.equal(outcome.ok,true, JSON.stringify(outcome));
        assert.equal((await c.query('select status from public.applications where id=$1',[candidate])).rows[0].status,'submitted');
      } else {
        assert.equal(outcome.ok,false,scenario);
        assert.equal(outcome.code, scenario==='repeatable-read' ? '40001' : scenario==='staff-disabled' ? '42501' : 'P0001');
        if (!['repeatable-read','staff-disabled'].includes(scenario)) assert.equal(outcome.message,'stale-update');
        assert.deepEqual(await storedRows(c),expected,`${scenario}: no partial writes from losing RPC`);
      }
      console.log('PASS stay concurrency',scenario);
    } finally {
      await a.query('rollback'); await b.query('rollback'); await c.query('reset role');
      await cleanupUpgrade(c,fixture); await c.query('delete from auth.users where id=$1',[staffB]);
    }
  }
  console.log('PASS stay concurrency cleanup');
}
// Phase 3: notes share the parent version with legacy user operations and staff work.
async function auditNotesConcurrency(c) {
  const cases=['double-note','edit-note','note-versus-payment','camp-save-versus-note','consent-versus-note',
    'staff-disabled','repeatable-read','note-versus-camp-save'];
  async function session(client,actor,role='authenticated') {
    await client.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:actor,email:`upgrade-${actor}@example.invalid`,role})]);
    await client.query(`set role ${role}`);
  }
  for(const scenario of cases) {
    const fixture=await prepareUpgrade(c), target=fixture.applications[0], staffB=randomUUID();
    await c.query('insert into auth.users(id,email) values($1,$2)',[staffB,`notes-${staffB}@example.invalid`]);
    await c.query('insert into public.staff_roles(user_id) values($1)',[staffB]);
    const a=await connect(), b=await connect();
    try {
      const userOperation=scenario.includes('camp-save')||scenario==='consent-versus-note';
      if(userOperation) await c.query("update public.applications set status='revision_requested',revision_due_at=clock_timestamp()+interval '1 day' where id=$1",[target]);
      let noteId=null;
      if(scenario==='edit-note') {
        const v=(await c.query('select updated_at::text as v from public.applications where id=$1',[target])).rows[0].v;
        await session(c,fixture.staff);
        noteId=(await c.query("select * from public.save_application_staff_note($1,$2,null,'初期メモ')",[target,v])).rows[0].result_note_id;
        await c.query('reset role');
      }
      const v=(await c.query('select updated_at::text as v from public.applications where id=$1',[target])).rows[0].v;
      await session(a,scenario==='camp-save-versus-note'?fixture.owner:fixture.staff,scenario==='consent-versus-note'?'service_role':'authenticated');
      await session(b,scenario==='note-versus-camp-save'?fixture.owner:staffB);
      await a.query('begin');await b.query(scenario==='repeatable-read'?'begin isolation level repeatable read':'begin');
      await b.query("set local statement_timeout='8s'");
      if(scenario==='repeatable-read') await b.query('select count(*) from public.applications');
      const saveSql="select public.save_camp_application_draft($1,'架空変更者','架空住所','0000000000','架空連絡先','架空住所','0000000000','架空変更目的',null,false,'shared_ok')";
      if(scenario==='staff-disabled') {
        await a.query('reset role');await a.query('select private.lock_calendar_facility()');
        await a.query("update public.profiles set account_state='disabled' where id=$1",[staffB]);
      } else if(scenario==='camp-save-versus-note') await a.query(saveSql,[target]);
      else if(scenario==='consent-versus-note') await a.query("select public.register_guardian_consent_document($1,$2,$3,'application/pdf',10)",[target,fixture.owner,`applications/${target}/${randomUUID()}`]);
      else await a.query("select * from public.save_application_staff_note($1,$2,$3,'職員Aメモ')",[target,v,noteId]);
      const leader=(await a.query('select pg_backend_pid() as pid')).rows[0].pid;
      const peer=(await b.query('select pg_backend_pid() as pid')).rows[0].pid;
      const pending=(scenario==='note-versus-payment'?b.query("select * from public.update_application_payment($1,$2,'paid',null)",[target,v]):
        scenario==='note-versus-camp-save'?b.query(saveSql,[target]):b.query("select * from public.save_application_staff_note($1,$2,$3,'職員Bメモ')",[target,v,noteId]))
        .then(()=>({ok:true}),error=>({ok:false,code:error.code,message:error.message}));
      let waited=false;
      for(let n=0;n<100;n++) {
        if((await c.query('select $2::integer=any(pg_blocking_pids($1)) as waiting',[peer,leader])).rows[0].waiting){waited=true;break;}
        await new Promise(resolve=>setTimeout(resolve,20));
      }
      await a.query('reset role');const expected=await storedRows(a);await a.query('commit');
      const outcome=await pending;
      await b.query(scenario==='note-versus-camp-save'&&outcome.ok?'commit':'rollback');await b.query('reset role');
      assert.ok(waited&&peer!==leader,`${scenario}: actual wait on separate connections`);
      if(scenario==='note-versus-camp-save') {
        assert.equal(outcome.ok,true);
        assert.deepEqual((await storedRows(c)).staff_notes,expected.staff_notes,'legacy user save preserves note');
        assert.equal((await c.query("select count(*)::integer as n from public.audit_logs where entity_id=$1 and action='save_camp_draft'",[target])).rows[0].n,2);
      } else {
        assert.equal(outcome.ok,false,scenario);
        assert.equal(outcome.code,scenario==='repeatable-read'?'40001':scenario==='staff-disabled'?'42501':'P0001');
        if(!['repeatable-read','staff-disabled'].includes(scenario))assert.equal(outcome.message,'stale-update');
        assert.deepEqual(await storedRows(c),expected,`${scenario}: no partial notes or business writes`);
      }
      console.log('PASS audit/notes concurrency',scenario);
    } finally {
      await a.query('rollback');await b.query('rollback');await c.query('reset role');
      await cleanupUpgrade(c,fixture);await c.query('delete from auth.users where id=$1',[staffB]);
    }
  }
  console.log('PASS audit/notes concurrency cleanup');
}
// T18: group start serializes with other exclusive starts and individual submissions.
async function groupConcurrency(c) {
  const scenarios = ['group-versus-group', 'group-versus-individual', 'individual-versus-group', 'identical-retry'];
  const today = (await c.query("select (clock_timestamp() at time zone 'Asia/Tokyo')::date as d")).rows[0].d;
  async function actor(client, id) {
    await client.query("select set_config('request.jwt.claims',$1,false)", [JSON.stringify({ sub: id,
      email: `group-${id}@example.invalid`, role: 'authenticated' })]);
    await client.query('set role authenticated');
  }
  async function asActor(client, id, sql, values = []) {
    await actor(client, id);
    try { return await client.query(sql, values); } finally { await client.query('reset role'); }
  }
  for (const scenario of scenarios) {
    const ownerA = randomUUID(), ownerB = randomUUID(), groupA = randomUUID(), groupB = randomUUID();
    for (const id of [ownerA, ownerB]) await c.query('insert into auth.users(id,email) values($1,$2)', [id, `group-${id}@example.invalid`]);
    const dates = (await c.query("select ($1::date+25)::text as start_date,($1::date+27)::text as end_date", [today])).rows[0];
    const groupFields = (name) => ({ group_name: name, representative_name: '架空代表者', representative_address: '架空住所',
      representative_phone: '000-0000-0000', start_date: dates.start_date, end_date: dates.end_date,
      usage_place: 'common_and_second_floor', purpose: '架空の地域調査', local_activity: '町内で架空の聞き取り',
      special_notes: null, planned_participants: 4, representative_stays: false });
    await asActor(c, ownerA, 'select * from public.create_community_group_draft($1,$2)', [groupA, groupFields('架空団体A')]);
    const groupVersionA = (await c.query('select updated_at::text as v from public.group_applications where id=$1', [groupA])).rows[0].v;
    let targetB = groupB, versionB, keyA = randomUUID(), keyB = randomUUID(), individualB = false;
    if (scenario !== 'identical-retry') {
      if (scenario === 'group-versus-individual') {
        individualB = true; targetB = randomUUID();
        const fields = { user_name: '架空個人', user_address: '架空住所', user_phone: '000-0000-0000',
          emergency_name: '架空連絡先', emergency_address: '架空住所', emergency_phone: '000-0000-0000',
          purpose: '架空調査', local_activity: '町内で架空の活動', special_notes: null,
          usage_place: 'common_and_second_floor', requires_guardian_consent: false,
          start_date: dates.start_date, end_date: dates.end_date };
        await asActor(c, ownerB, 'select * from public.create_community_application_draft($1,$2)', [targetB, fields]);
        versionB = (await c.query('select updated_at::text as v from public.applications where id=$1', [targetB])).rows[0].v;
      } else {
        await asActor(c, ownerB, 'select * from public.create_community_group_draft($1,$2)', [groupB, groupFields('架空団体B')]);
        versionB = (await c.query('select updated_at::text as v from public.group_applications where id=$1', [groupB])).rows[0].v;
      }
    }
    const a = await connect(), b = await connect();
    try {
      await actor(a, scenario === 'individual-versus-group' ? ownerB : ownerA);
      await actor(b, scenario === 'identical-retry' ? ownerA : scenario === 'individual-versus-group' ? ownerA : ownerB);
      await a.query('begin'); await b.query('begin'); await b.query("set local statement_timeout='8s'");
      if (scenario === 'individual-versus-group') {
        const individual = randomUUID(); targetB = individual; individualB = true;
        const fields = { user_name: '架空個人', user_address: '架空住所', user_phone: '000-0000-0000',
          emergency_name: '架空連絡先', emergency_address: '架空住所', emergency_phone: '000-0000-0000',
          purpose: '架空調査', local_activity: '町内で架空の活動', special_notes: null,
          usage_place: 'common_and_second_floor', requires_guardian_consent: false,
          start_date: dates.start_date, end_date: dates.end_date };
        await a.query('select * from public.create_community_application_draft($1,$2)', [individual, fields]);
        const individualVersion = (await a.query('select updated_at::text as v from public.applications where id=$1', [individual])).rows[0].v;
        await a.query('select * from public.submit_community_application($1,$2,$3,true)', [individual, individualVersion, keyA]);
      } else {
        await a.query('select * from public.start_community_group_application($1,$2,$3,true)', [groupA, groupVersionA, keyA]);
      }
      const leader = (await a.query('select pg_backend_pid() as pid')).rows[0].pid;
      const peer = (await b.query('select pg_backend_pid() as pid')).rows[0].pid;
      const pending = (scenario === 'group-versus-individual'
        ? b.query('select * from public.submit_community_application($1,$2,$3,true)', [targetB, versionB, keyB])
        : b.query('select * from public.start_community_group_application($1,$2,$3,true)',
          scenario === 'identical-retry' ? [groupA, groupVersionA, keyA] : scenario === 'individual-versus-group'
            ? [groupA, groupVersionA, keyB] : [groupB, versionB, keyB]))
        .then(result => ({ ok: true, rows: result.rows }), error => ({ ok: false, code: error.code, message: error.message }));
      let waited = false;
      for (let n = 0; n < 100; n++) {
        if ((await c.query('select $2::integer=any(pg_blocking_pids($1)) as waiting', [peer, leader])).rows[0].waiting) { waited = true; break; }
        await new Promise(resolve => setTimeout(resolve, 20));
      }
      await a.query('commit'); await a.query('reset role');
      const outcome = await pending;
      if (scenario === 'identical-retry') await b.query('commit'); else await b.query('rollback');
      await b.query('reset role');
      assert.ok(waited && leader !== peer, `${scenario}: actual wait on separate connections`);
      if (scenario === 'identical-retry') {
        assert.equal(outcome.ok, true, JSON.stringify(outcome));
        assert.equal((await c.query('select count(*)::integer as n from public.reception_numbers where group_id=$1', [groupA])).rows[0].n, 1);
        assert.equal((await c.query('select count(*)::integer as n from public.group_status_events where group_id=$1 and to_status=\'collecting\'', [groupA])).rows[0].n, 1);
      } else {
        assert.deepEqual(outcome, { ok: false, code: 'P0001', message: 'calendar-unavailable' });
      }
      console.log('PASS group concurrency', scenario);
    } finally {
      await a.query('rollback'); await b.query('rollback'); await c.query('reset role');
      await c.query('delete from public.audit_logs where entity_id=any($1::uuid[])', [[groupA, groupB, targetB]]);
      await c.query('delete from public.calendar_claims where group_id=any($1::uuid[]) or application_id=$2', [[groupA, groupB], individualB ? targetB : null]);
      await c.query('delete from public.applications where id=$1', [individualB ? targetB : scenario === 'individual-versus-group' ? targetB : null]);
      await c.query('delete from public.group_applications where id=any($1::uuid[])', [[groupA, groupB]]);
      await c.query('delete from auth.users where id=any($1::uuid[])', [[ownerA, ownerB]]);
    }
  }
  console.log('PASS group concurrency cleanup');
}
// T19: invitation reissue, capacity and duplicate joining on real separate connections.
async function groupInvitationConcurrency(c) {
  const scenarios = ['last-slot', 'same-user', 'reissue-versus-join'];
  const today = (await c.query("select (clock_timestamp() at time zone 'Asia/Tokyo')::date::text as d")).rows[0].d;
  async function session(client, id) {
    await client.query("select set_config('request.jwt.claims',$1,false)", [JSON.stringify({ sub: id,
      email: `invite-${id}@example.invalid`, role: 'authenticated' })]);
    await client.query('set role authenticated');
  }
  async function asActor(client, id, sql, values = []) {
    await session(client, id);
    try { return await client.query(sql, values); } finally { await client.query('reset role'); }
  }
  for (const [index, scenario] of scenarios.entries()) {
    const representative = randomUUID(), first = randomUUID(), second = randomUUID(), third = randomUUID();
    const users = [representative, first, second, third];
    for (const id of users) await c.query('insert into auth.users(id,email) values($1,$2)', [id, `invite-${id}@example.invalid`]);
    const group = randomUUID(), start = (await c.query('select ($1::date+$2::integer)::text as d', [today, 20 + index * 8])).rows[0].d;
    const end = (await c.query('select ($1::date+2)::text as d', [start])).rows[0].d;
    const fields = { group_name: `架空同時招待${index}`, representative_name: '架空代表者', representative_address: '架空住所',
      representative_phone: '000-0000-0000', start_date: start, end_date: end, usage_place: 'common_and_second_floor',
      purpose: '架空地域調査', local_activity: '町内で架空調査', special_notes: null,
      planned_participants: scenario === 'last-slot' ? 2 : 3, representative_stays: false };
    await asActor(c, representative, 'select * from public.create_community_group_draft($1,$2)', [group, fields]);
    let version = (await c.query('select updated_at::text as v from public.group_applications where id=$1', [group])).rows[0].v;
    await asActor(c, representative, 'select * from public.start_community_group_application($1,$2,$3,true)', [group, version, randomUUID()]);
    version = (await c.query('select updated_at::text as v from public.group_applications where id=$1', [group])).rows[0].v;
    const invite = (await asActor(c, representative, 'select * from public.issue_community_group_invite($1,$2)', [group, version])).rows[0];
    const token = invite.invite_token;
    const appIds = [randomUUID(), randomUUID(), randomUUID()];
    if (scenario === 'last-slot') await asActor(c, first, "select * from public.join_community_group($1,'token',$2)", [token, appIds[0]]);
    const a = await connect(), b = await connect();
    try {
      await session(a, scenario === 'reissue-versus-join' ? representative : second);
      await session(b, scenario === 'same-user' ? second : third);
      await a.query('begin'); await b.query('begin'); await b.query("set local statement_timeout='8s'");
      if (scenario === 'reissue-versus-join') {
        version = (await a.query('select updated_at::text as v from public.group_applications where id=$1', [group])).rows[0].v;
        await a.query('select * from public.issue_community_group_invite($1,$2)', [group, version]);
      } else {
        await a.query("select * from public.join_community_group($1,'token',$2)", [token, appIds[1]]);
      }
      const leader = (await a.query('select pg_backend_pid() as pid')).rows[0].pid;
      const peer = (await b.query('select pg_backend_pid() as pid')).rows[0].pid;
      const pending = b.query("select * from public.join_community_group($1,'token',$2)", [token, appIds[2]])
        .then(result => ({ ok: true, rows: result.rows }), error => ({ ok: false, code: error.code, message: error.message }));
      let waited = false;
      for (let n = 0; n < 100; n++) {
        if ((await c.query('select $2::integer=any(pg_blocking_pids($1)) as waiting', [peer, leader])).rows[0].waiting) { waited = true; break; }
        await new Promise(resolve => setTimeout(resolve, 20));
      }
      await a.query('commit'); await a.query('reset role');
      const outcome = await pending;
      await b.query(scenario === 'same-user' && outcome.ok ? 'commit' : 'rollback'); await b.query('reset role');
      assert.ok(waited && leader !== peer, `${scenario}: actual wait on separate connections`);
      if (scenario === 'same-user') {
        assert.equal(outcome.ok, true, JSON.stringify(outcome));
        assert.equal(outcome.rows[0].result_application_id, appIds[1]);
        assert.equal((await c.query('select count(*)::integer as n from public.group_members where group_id=$1', [group])).rows[0].n, 1);
        assert.equal((await c.query('select count(*)::integer as n from public.applications where group_id=$1', [group])).rows[0].n, 1);
      } else {
        assert.equal(outcome.ok, false, scenario);
        assert.equal(outcome.code, 'P0001');
        assert.equal(outcome.message, scenario === 'last-slot' ? 'group-full' : 'invalid-invite');
      }
      if (scenario === 'last-slot') {
        assert.equal((await c.query("select count(*)::integer as n from public.group_members where group_id=$1 and state='active'", [group])).rows[0].n, 2);
      }
      if (scenario === 'reissue-versus-join') {
        assert.equal((await c.query('select count(*)::integer as n from public.group_members where group_id=$1', [group])).rows[0].n, 0);
        assert.equal((await c.query('select count(*)::integer as n from public.group_invites where group_id=$1 and revoked_at is null', [group])).rows[0].n, 1);
      }
      console.log('PASS group invitation concurrency', scenario);
    } finally {
      await a.query('rollback'); await b.query('rollback'); await c.query('reset role');
      await c.query('delete from public.audit_logs where entity_id=$1 or actor_user_id=any($2::uuid[])', [group, users]);
      await c.query('delete from public.calendar_claims where group_id=$1', [group]);
      await c.query('delete from public.group_invites where group_id=$1', [group]);
      await c.query('delete from public.group_members where group_id=$1', [group]);
      await c.query('delete from public.audit_logs where entity_id=any($1::uuid[])', [appIds]);
      await c.query('delete from public.applications where group_id=$1', [group]);
      await c.query('delete from public.group_applications where id=$1', [group]);
      await c.query('delete from auth.users where id=any($1::uuid[])', [users]);
    }
  }
  console.log('PASS group invitation concurrency cleanup');
}
// T21: a participant submission and Cron expiry serialize on the facility row.
async function groupExpirationConcurrency(c) {
  const rep=randomUUID(),u1=randomUUID(),u2=randomUUID(),group=randomUUID(),a1=randomUUID(),a2=randomUUID();
  const users=[rep,u1,u2];
  for (const id of users) await c.query('insert into auth.users(id,email) values($1,$2)',[id,`expiry-${id}@example.invalid`]);
  const dates=(await c.query("select current_date+30 as s,current_date+32 as e")).rows[0];
  await c.query('begin');
  await c.query(`insert into public.group_applications(id,representative_user_id,group_name,start_date,end_date,usage_place,purpose,local_activity,
    planned_participants,status,submitted_at,participant_due_at) values($1,$2,'架空同時期限団体',$3,$4,'common_and_second_floor','架空目的','架空活動',2,'collecting',clock_timestamp(),clock_timestamp()+interval '1 hour')`,[group,rep,dates.s,dates.e]);
  await c.query(`insert into public.applications(id,user_id,usage_type,group_id,status,start_date,end_date,user_name,user_address,user_phone,email_snapshot,
    emergency_name,emergency_address,emergency_phone,requires_guardian_consent,submitted_at,last_submitted_at)
    values($1,$2,'community_group',$3,'submitted',$4,$5,'架空一郎','架空住所','000-0000-0000',$6,'架空連絡先','架空住所','000-0000-0000',false,clock_timestamp(),clock_timestamp()),
      ($7,$8,'community_group',$3,'draft',$4,$5,'架空二郎','架空住所','000-0000-0000',null,'架空連絡先','架空住所','000-0000-0000',false,null,null)`,
    [a1,u1,group,dates.s,dates.e,`expiry-${u1}@example.invalid`,a2,u2]);
  await c.query('insert into public.group_members(group_id,application_id) values($1,$2),($1,$3)',[group,a1,a2]);
  await c.query('commit');
  const version=(await c.query('select updated_at::text v from public.applications where id=$1',[a2])).rows[0].v;
  const submit=await connect(),cron=await connect();
  try {
    await submit.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:u2,email:`expiry-${u2}@example.invalid`,role:'authenticated'})]);
    await submit.query('set role authenticated'); await submit.query('begin'); await cron.query('begin');
    await submit.query('select * from public.submit_group_participant_application($1,$2,$3,true)',[a2,version,randomUUID()]);
    const leader=(await submit.query('select pg_backend_pid() pid')).rows[0].pid;
    const peer=(await cron.query('select pg_backend_pid() pid')).rows[0].pid;
    const pending=cron.query("select * from private.expire_due_community_groups(500,clock_timestamp()+interval '2 hours')");
    let waited=false; for(let n=0;n<100;n++){if((await c.query('select $2::integer=any(pg_blocking_pids($1)) waiting',[peer,leader])).rows[0].waiting){waited=true;break;} await new Promise(r=>setTimeout(r,20));}
    await submit.query('commit'); const expiry=await pending; await cron.query('commit');
    assert.ok(waited&&leader!==peer,'expiry must wait on participant submission');
    assert.equal(expiry.rows.length,0); assert.equal((await c.query('select status from public.group_applications where id=$1',[group])).rows[0].status,'under_review');
    console.log('PASS group expiration concurrency submission-wins');
  } finally {
    await submit.query('rollback');await cron.query('rollback');await c.query('reset role');
    await c.query('delete from public.audit_logs where entity_id=any($1::uuid[]) or actor_user_id=any($2::uuid[])',[[group,a1,a2],users]);
    await c.query('delete from public.calendar_claims where group_id=$1',[group]);await c.query('delete from public.group_invites where group_id=$1',[group]);
    await c.query('delete from public.group_members where group_id=$1',[group]);await c.query('delete from public.applications where group_id=$1',[group]);
    await c.query('delete from public.group_applications where id=$1',[group]);await c.query('delete from auth.users where id=any($1::uuid[])',[users]);
  }
  console.log('PASS group expiration concurrency cleanup');
}
let stage = 'start';
let failed = false;
try {
  await pg.initialise(); await pg.start(); const c = await connect();
  console.log('Local PostgreSQL', (await c.query('show server_version')).rows[0].server_version);
  await c.query(`
    create role anon nologin;
    create role authenticated nologin;
    create role service_role nologin bypassrls;
    create schema auth;
    create table auth.users (
      id uuid primary key, instance_id uuid, aud text, role text, email text,
      encrypted_password text, email_confirmed_at timestamptz, last_sign_in_at timestamptz,
      raw_app_meta_data jsonb, raw_user_meta_data jsonb, created_at timestamptz, updated_at timestamptz
    );
    create function auth.uid() returns uuid language sql stable as $$
      select coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''),
        nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid;
    $$;
    create function auth.jwt() returns jsonb language sql stable as $$
      select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb,
        jsonb_build_object('sub', current_setting('request.jwt.claim.sub', true),
          'email', current_setting('request.jwt.claim.email', true)));
    $$;
    grant usage on schema public, auth to anon, authenticated, service_role;
    grant execute on all functions in schema auth to anon, authenticated, service_role;
  `);
  let upgrade;
  let beforeUpgrade;
  let paymentUpgrade;
  let beforePaymentUpgrade;
  let stayUpgrade;
  let beforeStayUpgrade;
  let auditUpgrade;
  let beforeAuditUpgrade;
  let searchUpgrade;
  let beforeSearchUpgrade;
  for (const file of (await readdir(join(root, 'supabase/migrations'))).filter(x => x.endsWith('.sql')).sort()) {
    stage = file; await c.query(await readFile(join(root, 'supabase/migrations', file), 'utf8'));
    console.log('PASS migration', file);
    if (file === '202609100013_community_individual_applications.sql') {
      stage = 'prepare 013 upgrade fixtures';
      upgrade = await prepareUpgrade(c); beforeUpgrade = await storedRows(c);
    }
    if (file === '202609110014_community_individual_room_allocations_and_approval.sql') {
      stage = 'verify 013 to 014 stored data';
      assert.deepEqual(await storedRows(c), beforeUpgrade);
      await cleanupUpgrade(c, upgrade);
      console.log('PASS 013 to 014 upgrade: 16 tables unchanged; fictional fixtures removed');
      paymentUpgrade = await prepareUpgrade(c); beforePaymentUpgrade = await storedRows(c);
    }
    if (file === '202609110015_application_payments.sql') {
      assert.deepEqual(await storedRows(c), beforePaymentUpgrade);
      await cleanupUpgrade(c, paymentUpgrade);
      console.log('PASS 014 to 015 upgrade: 16 tables unchanged; fictional fixtures removed');
      stayUpgrade = await prepareUpgrade(c); beforeStayUpgrade = await storedRows(c);
    }
    if (file === '202609110016_application_stays.sql') {
      assert.deepEqual(await storedRows(c), beforeStayUpgrade);
      await cleanupUpgrade(c, stayUpgrade);
      console.log('PASS 015 to 016 upgrade: 16 tables unchanged; fictional fixtures removed');
      auditUpgrade=await prepareUpgrade(c); beforeAuditUpgrade=await storedRows(c);
    }
    if (file === '202609110017_application_audit_and_staff_notes.sql') {
      const afterAuditUpgrade=await storedRows(c);
      assert.deepEqual(afterAuditUpgrade.staff_notes,[]); delete afterAuditUpgrade.staff_notes;
      assert.deepEqual(afterAuditUpgrade,beforeAuditUpgrade);
      await cleanupUpgrade(c,auditUpgrade);
      console.log('PASS 016 to 017 upgrade: 16 tables unchanged; no backfilled audit');
      searchUpgrade=await prepareUpgrade(c); beforeSearchUpgrade=await storedRows(c);
    }
    if (file === '202609110018_staff_application_search.sql') {
      assert.deepEqual(await storedRows(c),beforeSearchUpgrade);
      await cleanupUpgrade(c,searchUpgrade);
      console.log('PASS 017 to 018 upgrade: existing rows unchanged');
    }
  }
  const requested = process.argv.slice(2);
  if (requested.includes('--audit-notes-only')) await c.query("select set_config('test.operations_phase','audit-notes',false)");
  if (requested.includes('--staff-search-only')) await c.query("select set_config('test.operations_phase','staff-search',false)");
  if (requested.includes('--stays-only')) await c.query("select set_config('test.operations_phase','stays',false)");
  const single = ['application_operations.sql', 'camp_room_allocations_and_approval.sql', 'calendar_and_blocked_periods.sql', 'community_individual_applications.sql', 'community_individual_room_allocations_and_approval.sql', 'community_groups.sql', 'group_invitations.sql', 'group_participant_submissions.sql', 'group_review_and_approval.sql', 'group_changes_and_cancellation.sql', 'group_deadline_expiration.sql', 'account_cleanup.sql', 'camp_roster_identity_foundation.sql', 'camp_roster_eligible_user_management.sql'];
  const concurrent = ['camp_room_allocations_concurrency.sql', 'calendar_concurrency.sql', 'community_individual_applications_concurrency.sql', 'community_individual_room_allocations_concurrency.sql', 'camp_roster_identity_concurrency.sql', 'camp_roster_eligible_user_management_concurrency.sql'];
  const selected = requested.includes('--migrate-only') ? [] : requested.includes('--single-only') ? single : requested.includes('--stays-only') ? ['application_operations.sql', ...(requested.includes('--stays-concurrency') ? ['--stays-concurrency'] : [])] : requested.includes('--audit-notes-only') ? ['application_operations.sql', ...(requested.includes('--audit-notes-concurrency') ? ['--audit-notes-concurrency'] : [])] : requested.includes('--staff-search-only') ? ['application_operations.sql'] : requested.length ? requested : [...single, ...concurrent, '--payments-concurrency', '--stays-concurrency', '--audit-notes-concurrency', '--groups-concurrency', '--group-invitations-concurrency', '--group-expiration-concurrency'];
  for (const file of selected) {
    if (file === '--group-invitations-concurrency') { stage=file; await groupInvitationConcurrency(c); continue; }
    if (file === '--group-expiration-concurrency') { stage=file; await groupExpirationConcurrency(c); continue; }
    if (file === '--groups-concurrency') { stage=file; await groupConcurrency(c); continue; }
    if (file === '--audit-notes-concurrency') { stage=file; await auditNotesConcurrency(c); continue; }
    if (file === '--stays-concurrency') { stage=file; await stayConcurrency(c); continue; }
    if (file === '--payments-concurrency') { stage = file; await paymentConcurrency(c); continue; }
    assert.ok([...single, ...concurrent].includes(file), 'Unknown test file'); stage = file;
    const result = await c.query(await readFile(join(root, 'supabase/tests', file), 'utf8'));
    if (!concurrent.includes(file)) {
      const summary = (Array.isArray(result) ? result : [result]).flatMap(x => x.rows || []).find(x => x.passed_checks !== undefined);
      assert.ok(summary && Number(summary.passed_checks) > 0, 'Missing test summary');
      console.log('PASS', file, summary); continue;
    }
    const schema = file === 'camp_roster_eligible_user_management_concurrency.sql' ? 'a2_roster_management_concurrency_test' : file.startsWith('camp_roster_') ? 'a1_roster_concurrency_test' : file.startsWith('community_individual_room_') ? 't12i_concurrency_test' : file.startsWith('community_') ? 't10_concurrency_test' : file.startsWith('camp_room_') ? 't12_concurrency_test' : 't09_concurrency_test';
    const a = await connect(), b = await connect();
    const workers = await Promise.allSettled([a.query(`call ${schema}.worker_a()`), b.query(`call ${schema}.worker_b()`)]);
    const failures = workers.flatMap((r, i) => r.status === 'rejected' ? [{ worker: i ? 'B' : 'A', message: r.reason.message, code: r.reason.code, where: r.reason.where }] : []);
    if (failures.length) throw new Error(JSON.stringify(failures));
    const verified = (await c.query(`select * from ${schema}.verify()`)).rows;
    assert.ok(verified.length > 0 && verified.every(x => x.passed && x.backend_a !== x.backend_b));
    console.log('PASS', file, { checked_cases: verified.length, all_passed: true });
    await c.query(`begin; select ${schema}.cleanup(); drop schema ${schema} cascade; commit`);
    assert.equal((await c.query('select to_regnamespace($1) is null as gone', [schema])).rows[0].gone, true);
    console.log('PASS cleanup', schema);
  }
} catch (error) {
  // SQL diagnostics only, never connection options, credentials or environment.
  console.error('FAIL', stage, { message: error.message, code: error.code, where: error.where, position: error.position });
  failed = true;
  process.exitCode = 1;
} finally {
  for (const c of clients) { try { await c.query('rollback'); await c.end(); } catch {} }
  try { await pg.stop(); } finally { await rm(scratch, { recursive: true, force: true }); }
}

process.exitCode = failed ? 1 : 0;
