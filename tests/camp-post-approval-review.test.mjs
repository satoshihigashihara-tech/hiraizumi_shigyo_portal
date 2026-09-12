import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readFile } from 'node:fs/promises';
const camp='10000000-0000-4000-8000-000000000001', eligible='10000000-0000-4000-8000-000000000002';
const app='10000000-0000-4000-8000-000000000003', room='10000000-0000-4000-8000-000000000004', pdf='10000000-0000-4000-8000-000000000005';
const stamp='2026-09-13T03:00:00.123456+09:00';
const fields={campId:camp,rosterVersion:'7',roomPlanVersion:'9007199254740992',
 assignments:JSON.stringify([{eligible_user_id:eligible,room_id:room}]),
 participants:JSON.stringify([{eligible_user_id:eligible,updated_at:stamp,application_id:app,application_updated_at:stamp}]),reason:'変更理由',confirmed:'yes'};
const reviewFields={campId:camp,applicationId:app,updatedAt:stamp,roomPlanVersion:'9007199254740992',assignmentVersion:'3',submittedVersionId:pdf,reviewAction:'approve',reason:'再許可'};
const form=(more={},base=fields)=>new Map(Object.entries({...base,...more}));
async function harness(options={}) {
 const calls=[],context=vm.createContext({URLSearchParams,Date}),cache=new Map();
 const stubs={'server-only':{},'next/cache':{revalidatePath(...args){calls.push(['refresh',...args]);}},
 '@/utils/auth/guards':{async requireStaff(){calls.push(['auth']);if(options.denied)throw Error('denied');return {supabase:{async rpc(name,args){calls.push(['rpc',name,args]);return {data:options.data,error:options.error};}}};}}};
 async function load(name,parent) {
  if(name.startsWith('.')) name=new URL(name,parent.identifier).href;
  const key=stubs[name]?name:name.startsWith('@/')?new URL(`../${name.slice(2)}.js`,import.meta.url).href:name.endsWith('.js')?name:`${name}.js`;
  if(cache.has(key))return cache.get(key);
  const promise=(async()=>{
  let mod;
  if(stubs[key])mod=new vm.SyntheticModule(Object.keys(stubs[key]),function(){for(const [k,v]of Object.entries(stubs[key]))this.setExport(k,v);},{context,identifier:key});
  else mod=new vm.SourceTextModule(await readFile(new URL(key),'utf8'),{context,identifier:key});
  await mod.link(load);return mod;
  })();cache.set(key,promise);return promise;
 }
 const action=await load('@/app/actions/staff-camp-review');await action.evaluate();
 const query=await load('@/utils/staff-camps/review-queries');await query.evaluate();
 return {calls,action:action.namespace,query:query.namespace};
}
test('A10 every public action and query authenticates first',async()=>{
 const h=await harness({denied:true});
 for(const fn of [()=>h.action.changeCampRoomsState(null,null),()=>h.action.reviewCampRosterState(null,null),()=>h.query.getStaffCampRoomChange('bad'),()=>h.query.getStaffCampRosterReview('bad','bad')])await assert.rejects(fn(),/denied/);
 assert.equal(h.calls.length,4);
});
test('A10 change retains exact observed timestamps, bigint, and absence; sends one RPC',async()=>{
 const h=await harness({data:{camp_id:camp,roster_version:'7',room_plan_version:'9007199254740993',changed:true,changed_ids:[eligible],revised_ids:[app]}});
 const r=await h.action.changeCampRoomsState(null,form({ownerId:'spoof',fee:'1'}));
 assert.equal(r.saved,true);assert.equal(h.calls.filter(x=>x[0]==='rpc').length,1);
 const args=h.calls[1][2];assert.equal(args.expected_room_plan_version,'9007199254740992');assert.equal(args.expected_participants[0].application_updated_at,stamp);
 assert.equal(args.ownerId,undefined);assert.equal(args.fee,undefined);
 assert.ok(h.calls.some(x=>x[1]==='/user/applications/[applicationId]/confirm'));
 assert.ok(h.calls.some(x=>x[1]===`/staff/camps/${camp}/room-plan`));
 const none=await h.action.changeCampRoomsState(null,form({participants:JSON.stringify([{eligible_user_id:eligible,updated_at:stamp,application_id:null,application_updated_at:null}])}));
 assert.equal(none.saved,true);assert.equal(h.calls.filter(x=>x[0]==='rpc').at(-1)[2].expected_participants[0].application_id,null);
});
test('A10 malformed expectations, mismatch, missing confirmation, oversized reason never call DB',async()=>{
 const h=await harness();
 for(const patch of [{participants:'{}'},{participants:'[]'},{participants:'x'.repeat(16001)},{participants:JSON.stringify([{eligible_user_id:eligible,updated_at:stamp,application_id:null,application_updated_at:stamp}])},
 {participants:JSON.stringify([{eligible_user_id:app,updated_at:stamp,application_id:null,application_updated_at:null}])},{confirmed:''},{reason:''},{reason:'あ'.repeat(2001)},{roomPlanVersion:'9223372036854775808'}])assert.ok((await h.action.changeCampRoomsState(null,form(patch))).error);
 assert.ok(h.calls.every(x=>x[0]==='auth'));
});
test('A10 conflicts preserve input without retry or DB detail exposure',async()=>{
 for(const [error,expected]of [[{code:'40P01',message:'secret'},'stale-update'],[{code:'40001',message:'secret'},'stale-update'],[{code:'42501',message:'secret'},'staff-required'],[{code:'P0001',message:'submitted-pdf-inconsistent',details:'secret'},'submitted-pdf-inconsistent'],[{code:'23505',message:'secret'},'save-failed']]){
  const h=await harness({error});const r=await h.action.changeCampRoomsState(null,form());assert.equal(r.error,expected);assert.equal(r.fields.reason,fields.reason);assert.ok(!JSON.stringify(r).includes('secret'));assert.equal(h.calls.filter(x=>x[0]==='rpc').length,1);assert.ok(!h.calls.some(x=>x[0]==='refresh'));
 }
});
test('A10 review pins submitted PDF, assignment and microsecond version',async()=>{
 const h=await harness({data:{camp_id:camp,application_id:app,status:'approved',updated_at:stamp}});
 assert.equal((await h.action.reviewCampRosterState(null,form({},reviewFields))).saved,true);
 const args=h.calls[1][2];assert.equal(args.expected_submitted_version_id,pdf);assert.equal(args.expected_updated_at,stamp);assert.equal(args.expected_assignment_version,'3');
});
test('A10 action verifies result identity/version/state before reporting success',async()=>{
 for(const data of [null,{}, {camp_id:camp,application_id:app,status:'under_review',updated_at:stamp}]){
  const h=await harness({data});assert.equal((await h.action.reviewCampRosterState(null,form({},reviewFields))).error,'save-failed');assert.ok(!h.calls.some(x=>x[0]==='refresh'));
 }
 for(const patch of [{submittedVersionId:''},{assignmentVersion:'0'},{reviewAction:'reject'},{updatedAt:'2026-02-30T00:00:00Z'},{reviewAction:'request_revision',reason:''}]){
  const h=await harness();assert.ok((await h.action.reviewCampRosterState(null,form(patch,reviewFields))).error);assert.ok(!h.calls.some(x=>x[0]==='rpc'));
 }
});
test('A10 room change query projects paired expectations without identity leakage',async()=>{
 const participant={eligible_user_id:eligible,updated_at:stamp,application_id:app,application_updated_at:stamp,application_status:'approved',owner_id:'secret'};
 const data={camp_id:camp,roster_version:'7',room_plan_version:'3',can_change:true,proposed_revision_due_at:stamp,participants:[participant],
 eligible_users:[{id:eligible,management_name:'架空氏名',room_id:room,owner_id:'secret'}],rooms:[{id:room,name:'架空室',capacity:2}],secret:'secret'};
 const h=await harness({data});const r=await h.query.getStaffCampRoomChange(camp);
 assert.equal(r.context.expectations[0].updated_at,stamp);assert.equal(r.context.users[0].status,'approved');assert.ok(!JSON.stringify(r).includes('secret'));
 for(const bad of [{...data,participants:{}},{...data,participants:[null]},{...data,eligible_users:[null]},{...data,rooms:[null]},{...data,participants:[{...participant,application_updated_at:null}]}]) {
  const h=await harness({data:bad});assert.equal((await h.query.getStaffCampRoomChange(camp)).error,'load-failed');
 }
});
