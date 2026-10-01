import { journalDigest } from "../infrastructure/control/service.mjs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

/** The operator first quarantines and restores into isolation. This final step
 * replays the independently durable journal, verifies the database receipt, and
 * only then requests reopening. Any failure leaves the authority quarantined.
 */
export async function reconcileAndRelease(
  { controlOrigin, backendOrigin, adminKey, serviceKey, fetchImpl = fetch },
) {
  const control = new URL(controlOrigin), backend = new URL(backendOrigin);
  if (
    backend.origin !== "https://voepalyamwgenceawdvl.supabase.co" ||
    backend.pathname !== "/" || backend.search || backend.hash ||
    backend.username || backend.password
  ) throw Error("DEVELOPMENT_PROJECT_REQUIRED");
  if (
    // This operator command is deliberately limited to the approved development authority.
    control.origin !== "https://authority-dev.signalword.app" || control.pathname !== "/" ||
    control.username || control.password || control.search || control.hash
  ) throw Error("CONTROL_ORIGIN_INVALID");
  if (typeof adminKey !== "string" || adminKey.length < 32 || !serviceKey) {
    throw Error("RESTORE_CREDENTIALS_REQUIRED");
  }
  async function request(url, method, body, key, db = false) {
    const r = await fetchImpl(url, {
      method,
      redirect: "error",
      signal: AbortSignal.timeout(20_000),
      headers: {
        Authorization: `Bearer ${key}`,
        "Content-Type": "application/json",
        ...(db ? { apikey: key } : {}),
      },
      ...(body ? { body: JSON.stringify(body) } : {}),
    });
    if (!r.ok) throw Error("RESTORE_REMAINS_QUARANTINED");
    return r.status === 204 ? null : r.json();
  }
  const snapshot = await request(
    new URL("/snapshot", control),
    "GET",
    null,
    adminKey,
  );
  if (
    snapshot?.state?.quarantined !== true || !snapshot.state.backupAt ||
    !Array.isArray(snapshot.entries) ||
    snapshot.digest !== await journalDigest(snapshot.entries)
  ) throw Error("RESTORE_SNAPSHOT_INVALID");
  const proof = {
    p_restore_id: snapshot.state.restoreId,
    p_version: snapshot.state.version,
    p_digest: snapshot.digest,
  };
  await request(
    new URL("/rest/v1/rpc/reconcile_restore_journal", backend),
    "POST",
    { ...proof, p_entries: snapshot.entries },
    serviceKey,
    true,
  );
  const verified = await request(
    new URL("/rest/v1/rpc/restore_receipt_matches", backend),
    "POST",
    proof,
    serviceKey,
    true,
  );
  if (verified !== true) throw Error("RESTORE_RECEIPT_MISSING");
  const result = await request(new URL("/release", control), "POST", {
    restoreId: proof.p_restore_id,
    version: proof.p_version,
    digest: proof.p_digest,
  }, adminKey);
  if (result?.released !== true) throw Error("RESTORE_REMAINS_QUARANTINED");
  return { released: true, journalVersion: proof.p_version };
}
if (
  process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  if (!process.argv.includes("--reconcile-and-release-development")) {
    throw Error("EXPLICIT_DEVELOPMENT_RELEASE_REQUIRED");
  }
  const result = await reconcileAndRelease({
    controlOrigin: process.env.SAFETY_CONTROL_URL,
    backendOrigin: process.env.SUPABASE_URL,
    adminKey: process.env.SAFETY_CONTROL_ADMIN,
    serviceKey: process.env.SUPABASE_SERVICE_ROLE_KEY,
  });
  console.log(JSON.stringify(result));
}
