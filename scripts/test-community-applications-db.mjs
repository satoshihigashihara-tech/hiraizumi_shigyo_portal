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
    }
  }
  const requested = process.argv.slice(2);
  if (requested.includes('--stays-only')) await c.query("select set_config('test.operations_phase','stays',false)");
  const single = ['application_operations.sql', 'camp_room_allocations_and_approval.sql', 'calendar_and_blocked_periods.sql', 'community_individual_applications.sql', 'community_individual_room_allocations_and_approval.sql'];
  const concurrent = ['camp_room_allocations_concurrency.sql', 'calendar_concurrency.sql', 'community_individual_applications_concurrency.sql', 'community_individual_room_allocations_concurrency.sql'];
  const selected = requested.includes('--migrate-only') ? [] : requested.includes('--single-only') ? single : requested.includes('--stays-only') ? ['application_operations.sql', ...(requested.includes('--stays-concurrency') ? ['--stays-concurrency'] : [])] : requested.length ? requested : [...single, ...concurrent, '--payments-concurrency', '--stays-concurrency'];
  for (const file of selected) {
    if (file === '--stays-concurrency') { stage=file; await stayConcurrency(c); continue; }
    if (file === '--payments-concurrency') { stage = file; await paymentConcurrency(c); continue; }
    assert.ok([...single, ...concurrent].includes(file), 'Unknown test file'); stage = file;
    const result = await c.query(await readFile(join(root, 'supabase/tests', file), 'utf8'));
    if (!concurrent.includes(file)) {
      const summary = (Array.isArray(result) ? result : [result]).flatMap(x => x.rows || []).find(x => x.passed_checks !== undefined);
      assert.ok(summary && Number(summary.passed_checks) > 0, 'Missing test summary');
      console.log('PASS', file, summary); continue;
    }
    const schema = file.startsWith('community_individual_room_') ? 't12i_concurrency_test' : file.startsWith('community_') ? 't10_concurrency_test' : file.startsWith('camp_room_') ? 't12_concurrency_test' : 't09_concurrency_test';
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
