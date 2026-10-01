import {tmpdir} from "node:os";
import { readFileSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

// Tests can use an independently created local Supabase project without touching
// an existing developer database. Never accept a hosted database URL here.
export const localWorkdir = resolve(
  process.env.SIGNALWORD_LOCAL_WORKDIR ||
    fileURLToPath(new URL("..", import.meta.url)),
);
const config = readFileSync(
  resolve(localWorkdir, "supabase/config.toml"),
  "utf8",
);
const project = /^project_id\s*=\s*"([A-Za-z0-9_-]+)"/m.exec(config)?.[1];
if (!project) throw Error("LOCAL_PROJECT_ID_REQUIRED");
export const localContainer = `supabase_db_${project}`;
export const localGatewayContainer = `supabase_kong_${project}`;
export const localRestContainer = `supabase_rest_${project}`;

/** Reject overlapping DB suites instead of allowing one suite to consume another's fixtures. */
export function acquireLocalFixtureLock() {
  const lock=resolve(tmpdir(),`signalword-fixture-${project}.lock`);
  try {mkdirSync(lock);} catch {throw Error(`LOCAL_FIXTURE_IN_USE: ${lock}. Wait for the owner; only remove a stale lock after verifying its process stopped.`);}
  writeFileSync(resolve(lock,'pid'),String(process.pid));
  process.once('exit',()=>{try{rmSync(lock,{recursive:true});}catch{}});
}
