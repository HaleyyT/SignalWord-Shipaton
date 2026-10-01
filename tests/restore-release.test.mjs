import test from "node:test";
import assert from "node:assert/strict";
import { reconcileAndRelease } from "../scripts/restore-release.mjs";
import { journalDigest } from "../infrastructure/control/service.mjs";
const config = {
  controlOrigin: "https://authority-dev.signalword.app",
  backendOrigin: "https://voepalyamwgenceawdvl.supabase.co",
  adminKey: "a".repeat(32),
  serviceKey: "fixture-service",
};
const snapshot = async () => ({
  state: {
    quarantined: true,
    backupAt: new Date().toISOString(),
    restoreId: crypto.randomUUID(),
    version: 0,
  },
  entries: [],
  digest: await journalDigest([]),
});
test("restore release requires an independently verified database receipt", async () => {
  const paths = [];
  const snap = await snapshot();
  const result = await reconcileAndRelease({
    ...config,
    fetchImpl: async (url) => {
      paths.push(url.pathname);
      if (url.pathname === "/snapshot") return Response.json(snap);
      if (
        url.pathname.endsWith("reconcile_restore_journal")
      ) return new Response(null, { status: 204 });
      if (url.pathname.endsWith("restore_receipt_matches")) {
        return Response.json(true);
      }
      return Response.json({ released: true });
    },
  });
  assert.equal(result.released, true);
  assert.deepEqual(paths, [
    "/snapshot",
    "/rest/v1/rpc/reconcile_restore_journal",
    "/rest/v1/rpc/restore_receipt_matches",
    "/release",
  ]);
});
for (const failure of ["storage", "receipt", "stale"]) {
  test(`restore ${failure} failure never reports successful reopening`, async () => {
    const snap = await snapshot();
    let released = false;
    await assert.rejects(() =>
      reconcileAndRelease({
        ...config,
        fetchImpl: async (url) => {
          if (url.pathname === "/snapshot") return Response.json(snap);
          if (url.pathname.endsWith("reconcile_restore_journal")) {
            return new Response(null, {
              status: failure === "storage" ? 503 : 204,
            });
          }
          if (url.pathname.endsWith("restore_receipt_matches")) {
            return Response.json(failure !== "receipt");
          }
          released = true;
          return new Response(null, { status: 409 });
        },
      })
    );
    assert.equal(released, failure === "stale");
  });
}
test("wrong project and corrupted snapshot fail before replay", async () => {
  await assert.rejects(
    () =>
      reconcileAndRelease({
        ...config,
        backendOrigin: "https://production.example.test",
        fetchImpl: () => {
          throw Error("must not request");
        },
      }),
    /DEVELOPMENT_PROJECT_REQUIRED/,
  );
  await assert.rejects(
    () =>
      reconcileAndRelease({
        ...config,
        fetchImpl: async () =>
          Response.json({ ...await snapshot(), digest: "bad" }),
      }),
    /RESTORE_SNAPSHOT_INVALID/,
  );
});

// An operator typo must never transmit the administration credential elsewhere.
test("restore refuses another authority before sending credentials", async () => {
  let requested = false;
  await assert.rejects(() => reconcileAndRelease({
    ...config, controlOrigin: "https://another-authority.example.test",
    fetchImpl: async () => { requested = true; throw Error("unexpected request"); },
  }), /CONTROL_ORIGIN_INVALID/);
  assert.equal(requested, false);
});
