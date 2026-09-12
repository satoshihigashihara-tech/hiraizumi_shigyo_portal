import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import vm from "node:vm";

const ROOT = new URL("../", import.meta.url);
const USER = "10000000-0000-4000-8000-000000000001";
const APPLICATION = "20000000-0000-4000-8000-000000000001";
const form = (values={}) => new Map(Object.entries({ applicationId: APPLICATION,
  reason: "本人から停止依頼", confirmed: "true", ...values }));

async function harness(response={ data: true, error: null },denied=false,applicationOverrides={}) {
  const calls=[]; const context=vm.createContext({ URLSearchParams,URL }); const cache=new Map();
  const application={ id:APPLICATION,user_id:USER,usage_type:"community_individual",camp_id:null,
    status:"cancelled",...applicationOverrides };
  const supabase={
    from(table){ calls.push(["from",table]); return { select(columns){ calls.push(["select",columns]); return this; },
      eq(column,value){ calls.push(["eq",column,value]); return this; },
      async maybeSingle(){ calls.push(["single"]); return {data:application,error:null}; } }; },
    async rpc(name,args){ calls.push(["rpc",name,JSON.parse(JSON.stringify(args))]); return response; },
  };
  const stubs={
    "server-only":{},
    "next/cache":{ revalidatePath(path){ calls.push(["revalidate",path]); } },
    "next/navigation":{ redirect(path){ calls.push(["redirect",path]); throw new Error("REDIRECT"); } },
    "@/utils/auth/guards":{ async requireStaff(path){ calls.push(["auth",path]); if(denied) throw new Error("AUTH"); return {supabase}; } },
  };
  async function load(specifier){
    if(cache.has(specifier)) return cache.get(specifier);
    const values=stubs[specifier]; let loadedModule;
    if(values) loadedModule=new vm.SyntheticModule(Object.keys(values),function(){ for(const [key,value] of Object.entries(values))this.setExport(key,value); },{context,identifier:specifier});
    else { const filename=specifier.startsWith("@/")?`${specifier.slice(2)}.js`:specifier; loadedModule=new vm.SourceTextModule(await readFile(new URL(filename,ROOT),"utf8"),{context,identifier:filename}); }
    cache.set(specifier,loadedModule); await loadedModule.link(load); return loadedModule;
  }
  const loadedModule=await load("app/actions/staff-accounts.js"); await loadedModule.evaluate(); return {api:loadedModule.namespace,calls};
}

test("staff disable authorizes first, sends fixed RPC fields, and redirects",async()=>{
  const {api,calls}=await harness();
  await assert.rejects(api.disableUserAccountState(null,form()),/REDIRECT/);
  assert.deepEqual(calls[0],["auth","/staff"]);
  assert.deepEqual(calls.find(call=>call[0]==="rpc"),["rpc","disable_user_account",{target_user_id:USER,disable_reason:"本人から停止依頼"}]);
  assert.equal(calls.at(-1)[1],`/staff/community/applications/${APPLICATION}?updated=account-disabled`);
});

for(const [values,code] of [[{applicationId:"bad"},"invalid-application"],[{reason:""},"reason-required"],
  [{reason:"あ".repeat(2001)},"reason-too-long"],[{confirmed:""},"confirmation-required"]])
  test(`staff disable rejects ${code} before RPC`,async()=>{
    const {api,calls}=await harness(); const result=await api.disableUserAccountState(null,form(values));
    assert.equal(result.error,code); assert.equal(calls.some(call=>call[0]==="rpc"),false);
  });

test("staff disable does not expose unknown database errors",async()=>{
  const {api}=await harness({data:null,error:{message:"secret database detail"}});
  assert.equal((await api.disableUserAccountState(null,form())).error,"update-failed");
});

test("staff disable stops at authorization failure",async()=>{
  const {api,calls}=await harness(undefined,true);
  await assert.rejects(api.disableUserAccountState(null,form()),/AUTH/); assert.deepEqual(calls,[["auth","/staff"]]);
});

test("staff disable rejects a non-terminal application before RPC",async()=>{
  const {api,calls}=await harness(undefined,false,{status:"approved"});
  const result=await api.disableUserAccountState(null,form());
  assert.equal(result.error,"invalid-application");
  assert.equal(calls.some(call=>call[0]==="rpc"),false);
});

test("account stop UI requires reason and confirmation without exposing a user id",async()=>{
  const [forms,forbidden,community,camp]=await Promise.all([
    readFile(new URL("app/staff/camps/[campId]/applications/[applicationId]/OperationForms.js",ROOT),"utf8"),
    readFile(new URL("app/forbidden/page.js",ROOT),"utf8"),
    readFile(new URL("app/staff/community/applications/[applicationId]/page.js",ROOT),"utf8"),
    readFile(new URL("app/staff/camps/[campId]/applications/[applicationId]/page.js",ROOT),"utf8"),
  ]);
  assert.match(forms,/name="applicationId"/);
  assert.doesNotMatch(forms,/name="userId"/);
  assert.match(forms,/name="reason"/);
  assert.match(forms,/name="confirmed"/);
  assert.match(forbidden,/初期化が完了したとの案内を受けた後/);
  assert.match(forbidden,/以前の申請は自動では新しいアカウントへ結び付きません/);
  assert.match(community,/AccountDisableForm/);
  assert.match(camp,/AccountDisableForm/);
});
