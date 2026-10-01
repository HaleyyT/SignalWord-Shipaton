import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { acquireLocalFixtureLock, localContainer } from "./local-fixture.mjs";

acquireLocalFixtureLock();
// Hosted PostgREST loads safeupdate; ordinary local postgres sessions do not.
// Load it in this disposable test connection, then restore the usual test role.
const suite = readFileSync(new URL("../supabase/tests/restore_protection.test.sql", import.meta.url), "utf8");
const sql = "CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions; LOAD 'safeupdate'; SET SESSION AUTHORIZATION postgres;\n" + suite.replace(
  "select no_plan();",
  `select no_plan();
select throws_ok($guard$update public.viewer_tokens set revoked_at=now()$guard$,
 '21000','UPDATE requires a WHERE clause','hosted safe-update guard is active');`
);
const result = spawnSync("docker", ["exec", "-i", "--env", "PGOPTIONS=-c search_path=public,extensions", localContainer,
 "psql", "-X", "-v", "ON_ERROR_STOP=1", "-U", "supabase_admin", "-d", "postgres"],
 { input: sql, encoding: "utf8", maxBuffer: 4 * 1024 * 1024 });
const output = `${result.stdout ?? ""}\n${result.stderr ?? ""}`;
if (result.status !== 0 || /^\s*not ok\b/im.test(output)) {
 console.error(output);
 process.exit(result.status || 1);
}
const count = (output.match(/^\s*ok \d+ -/gm) ?? []).length;
if (count < 1) throw Error("RESTORE_SAFEUPDATE_ASSERTIONS_MISSING");
console.log(`PASS: hosted safe-update restore regression (${count} assertions).`);
