import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import vm from "node:vm";

const ROOT = new URL("../", import.meta.url);
const USER = "10000000-0000-4000-8000-000000000001";
const form = (values={}) => new Map(Object.entries({ userId: USER, reason: "本人から停止依頼", ...values }));

async function harness(response={ data: true, error: null },denied=false) {
  const calls=[]; const context=vm.createContext({ URLSearchParams,URL }); const cache=new Map();
  const supabase={ async rpc(name,args){ calls.push(["rpc",name,JSON.parse(JSON.stringify(args))]); return response; } };
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
  await assert.rejects(api.disableUserAccount(form({ accountState:"active",email:"hidden@example.invalid" })),/REDIRECT/);
  assert.deepEqual(calls[0],["auth","/staff"]);
  assert.deepEqual(calls.find(call=>call[0]==="rpc"),["rpc","disable_user_account",{target_user_id:USER,disable_reason:"本人から停止依頼"}]);
  assert.equal(calls.at(-1)[1],"/staff?updated=account-disabled");
});

for(const [values,code] of [[{userId:"bad"},"invalid-user"],[{reason:""},"reason-required"],[{reason:"あ".repeat(2001)},"reason-too-long"]])
  test(`staff disable rejects ${code} before RPC`,async()=>{
    const {api,calls}=await harness(); const result=await api.disableUserAccount(form(values));
    assert.equal(result.error,code); assert.equal(calls.some(call=>call[0]==="rpc"),false);
  });

test("staff disable does not expose unknown database errors",async()=>{
  const {api}=await harness({data:null,error:{message:"secret database detail"}});
  assert.equal((await api.disableUserAccount(form())).error,"update-failed");
});

test("staff disable stops at authorization failure",async()=>{
  const {api,calls}=await harness(undefined,true);
  await assert.rejects(api.disableUserAccount(form()),/AUTH/); assert.deepEqual(calls,[["auth","/staff"]]);
});
