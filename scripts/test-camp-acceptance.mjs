import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

// Uses only the caller's newly created, isolated local DB. Never opens a hosted connection.
export async function campAcceptance(c, connect) {
  const owner = randomUUID(), staff = randomUUID(), camp = randomUUID();
  const email = `a12-${owner}@example.invalid`;
  await c.query("insert into auth.users(id,email,email_confirmed_at) values($1,$2,clock_timestamp()),($3,$4,clock_timestamp())",
    [owner,email,staff,`a12-${staff}@example.invalid`]);
  await c.query('insert into public.staff_roles(user_id) values($1)',[staff]);
  await c.query("insert into public.camps(id,name,start_date,end_date,application_deadline,created_by,room_assignment_mode) values($1,'A12 fictional',current_date+120,current_date+122,clock_timestamp()+interval '1 day',$2,'eligible_roster')",[camp,staff]);
  const a = await connect(), b = await connect();
  try {
    await a.query('begin');
    await a.query('select private.lock_calendar_facility()');
    await a.query("select set_config('request.jwt.claims',$1,true)",[JSON.stringify({sub:staff,role:'authenticated'})]);
    await a.query('set local role authenticated');
    await a.query('select * from public.create_camp_roster_eligible_user($1,$2,$3)',[camp,'架空参加予定',email]);
    await a.query('reset role');
    // The cleanup worker may already have claimed its job before registration.
    // Its later Auth DELETE must recheck participation after the facility lock.
    const pidA=(await a.query('select pg_backend_pid() pid')).rows[0].pid;
    const pidB=(await b.query('select pg_backend_pid() pid')).rows[0].pid;
    assert.notEqual(pidA,pidB);
    const deletion=b.query('delete from auth.users where id=$1',[owner]).then(()=>({ok:true}),error=>({ok:false,message:error.message}));
    let waited=false;
    for(let i=0;i<100;i++) {
      waited=(await c.query('select $1::int=any(pg_blocking_pids($2)) waited',[pidA,pidB])).rows[0].waited;
      if(waited) break;
      await new Promise(resolve=>setTimeout(resolve,10));
    }
    await a.query('commit');
    const result=await deletion;
    assert.equal(result.ok,false,'Auth deletion must reject a newly committed camp participant');
    assert.equal(result.message,'camp-participation-open');
    assert.equal(waited,true,'Auth deletion must actually wait on the registration transaction');
    assert.equal((await c.query('select count(*)::int n from auth.users where id=$1',[owner])).rows[0].n,1);
    assert.equal((await c.query('select count(*)::int n from public.profiles where id=$1',[owner])).rows[0].n,1);
    console.log('PASS A12 registration-versus-Auth-delete: distinct connections, actual lock wait, Auth/profile retained');
    for (const scenario of ['linked-email-changed','unverified-unlinked','disabled','released','legacy']) {
      await c.query('begin');
      if(scenario==='linked-email-changed') {
        await c.query('update public.camp_eligible_users set linked_user_id=$1,linked_at=clock_timestamp(),linked_email_normalized=$2 where camp_id=$3',[owner,email,camp]);
        await c.query("update auth.users set email='changed-a12@example.invalid' where id=$1",[owner]);
      }
      if(scenario==='unverified-unlinked') await c.query('update auth.users set email_confirmed_at=null where id=$1',[owner]);
      if(scenario==='disabled') await c.query('update public.camp_eligible_users set disabled_at=clock_timestamp() where camp_id=$1',[camp]);
      if(scenario==='released') await c.query("update public.camp_eligible_users set participation_status='released',released_at=clock_timestamp(),release_reason='架空終了' where camp_id=$1",[camp]);
      if(scenario==='legacy') {
        await c.query('update public.camp_eligible_users set disabled_at=clock_timestamp() where camp_id=$1',[camp]);
        const legacy=randomUUID();
        await c.query("insert into public.camps(id,name,start_date,end_date,application_deadline,created_by) values($1,'A12 legacy',current_date+140,current_date+142,clock_timestamp()+interval '1 day',$2)",[legacy,staff]);
        await c.query('insert into public.camp_eligible_users(camp_id,email_normalized) values($1,$2)',[legacy,email]);
      }
      if(scenario==='linked-email-changed') await assert.rejects(c.query('delete from auth.users where id=$1',[owner]),/camp-participation-open/);
      else {
        await c.query('delete from auth.users where id=$1',[owner]);
        assert.equal((await c.query('select count(*)::int n from auth.users where id=$1',[owner])).rows[0].n,0);
      }
      await c.query('rollback');
      console.log('PASS A12 Auth-delete boundary',scenario);
    }
    // A stale RR snapshot cannot bypass a roster registration that committed
    // after the delete transaction's first read.
    await b.query('begin isolation level repeatable read');
    await b.query('select count(*) from public.camp_eligible_users');
    await a.query('select private.lock_calendar_facility()');
    await assert.rejects(b.query('delete from auth.users where id=$1',[owner]),error=>error.code==='40001');
    await b.query('rollback');
    console.log('PASS A12 Auth-delete REPEATABLE READ rejects stale snapshot');
    assert.equal((await c.query("select has_function_privilege('authenticated','private.guard_camp_participant_auth_delete()','EXECUTE') allowed")).rows[0].allowed,false);
    await c.query('delete from public.camp_eligible_users where camp_id=$1',[camp]);
    await b.query('begin');
    await b.query('delete from auth.users where id=$1',[owner]);
    await a.query('begin');
    await a.query("select set_config('request.jwt.claims',$1,true)",[JSON.stringify({sub:staff,role:'authenticated'})]);
    await a.query('set local role authenticated');
    const registration=a.query('select * from public.create_camp_roster_eligible_user($1,$2,$3)',[camp,'架空再登録',email]);
    let reverseWait=false;
    for(let i=0;i<100;i++) {
      reverseWait=(await c.query('select $1::int=any(pg_blocking_pids($2)) waited',[pidB,pidA])).rows[0].waited;
      if(reverseWait) break;
      await new Promise(resolve=>setTimeout(resolve,10));
    }
    await b.query('commit'); await registration; await a.query('commit');
    assert.equal(reverseWait,true);
    assert.equal((await c.query('select count(*)::int n from auth.users where id=$1',[owner])).rows[0].n,0);
    assert.equal((await c.query('select linked_user_id from public.camp_eligible_users where camp_id=$1',[camp])).rows[0].linked_user_id,null);
    console.log('PASS A12 Auth-delete-versus-registration: actual lock wait, later roster stays unbound');
  } finally {
    await c.query('rollback'); await a.query('rollback'); await b.query('rollback');
    await c.query('delete from public.camp_eligible_users where camp_id=$1',[camp]);
    await c.query('delete from public.camps where id=$1',[camp]);
    await c.query('delete from public.audit_logs where actor_user_id=$1',[staff]);
    await c.query('delete from auth.users where id=any($1::uuid[])',[[owner,staff]]);
  }
  console.log('PASS A12 acceptance cleanup');
}
