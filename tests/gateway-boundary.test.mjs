import test from 'node:test';
import assert from 'node:assert/strict';
import { createCheckInGateway } from '../supabase/functions/_shared/check-in.ts';
import { createContactNetworkGateway } from '../supabase/functions/_shared/contact-network.ts';
const config={url:'https://backend.example.test',anonKey:'public-fixture',serviceRoleKey:'server-fixture'};
test('timer and routed alert creation use server authorization; reads retain caller isolation',async()=>{
 const original=globalThis.fetch; const calls=[];
 globalThis.fetch=async(url,init)=>{calls.push({url,headers:init.headers,body:JSON.parse(init.body)});return Response.json(url.includes('routed')?[{}]:null);};
 try {
  const timer=createCheckInGateway(config);
  await timer.change('verified-user','caller-token','command',{action:'cancel',timerId:'timer'},'fake',[]);
  await timer.recover('verified-user','caller-token');
  await createContactNetworkGateway(config).create({kind:'test',triggerMethod:'manual',clientTriggeredAt:'2026-09-28T00:00:00Z'},'verified-user','command','fake',[],'caller-token');
  for(const i of [0,2]) {assert.equal(calls[i].headers.Authorization,'Bearer server-fixture');assert.equal(calls[i].headers.apikey,'server-fixture');assert.equal(calls[i].body.p_user_id,'verified-user');assert.match(calls[i].url,/rpc\/gateway_/);}
  assert.equal(calls[1].headers.Authorization,'Bearer caller-token');assert.equal(calls[1].headers.apikey,'public-fixture');
 }finally{globalThis.fetch=original;}
});
