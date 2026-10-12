import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import test from 'node:test';

async function queryHarness(rows) {
  const context=vm.createContext({});
  const chain={select(){return this;},eq(){return this;},order(){return this;},async limit(){return {data:rows,error:null};}};
  const boundary={
    'server-only':{},
    '@/utils/auth/guards':{requireActiveUser:async()=>({user:{id:'10000000-0000-4000-8000-000000000001'},supabase:{from:()=>chain}})},
    '@/utils/navigation/mode':{usageTypeForMode:()=>null},
  };
  const cache=new Map();
  async function load(name){
    if(cache.has(name)) return cache.get(name);
    let m;
    if(Object.hasOwn(boundary,name)){
      const values=boundary[name];
      m=new vm.SyntheticModule(Object.keys(values),function(){for(const [key,value] of Object.entries(values)) this.setExport(key,value);},{context});
    }else{
      const path=name.startsWith('@/')?name.slice(2)+'.js':name;
      m=new vm.SourceTextModule(await readFile(new URL('../'+path,import.meta.url),'utf8'),{context});
    }
    cache.set(name,m); await m.link(load); return m;
  }
  const m=await load('utils/user-applications/queries.js');await m.evaluate();return m.namespace;
}

const cancelled={id:'20000000-0000-4000-8000-000000000001',usage_type:'camp',status:'cancelled',
  original_application_id:null,start_date:'2026-12-01',end_date:'2026-12-02',updated_at:'2026-10-12T00:00:00Z',
  submitted_at:null,last_submitted_at:null,revision_due_at:null,decision_reason:null,
  camps:null,reception_numbers:null,application_charges:null,room_allocations:null,stays:null};

test('archived camp history does not prevent the owner from loading other applications',async()=>{
  const active={...cancelled,id:'20000000-0000-4000-8000-000000000002',status:'draft',camps:{name:'現在のキャンプ'}};
  const result=await (await queryHarness([cancelled,active])).getUserApplications();
  assert.equal(result.error,null);assert.equal(result.applications.length,2);
  assert.equal(result.applications[0].camp_name,'終了したキャンプ');
  assert.equal(result.applications[1].camp_name,'現在のキャンプ');
});

test('an open camp application with a missing camp still fails closed',async()=>{
  const result=await (await queryHarness([{...cancelled,status:'draft'}])).getUserApplications();
  assert.equal(result.error,'load-failed');assert.equal(result.applications.length,0);
});
