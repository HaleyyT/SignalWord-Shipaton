const uuid = (value) =>
  typeof value === "string" &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
const json = (body, status = 200) =>
  Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
async function equal(a, b) {
  if (typeof b !== "string" || b.length < 32) return false;
  const hash = async (value) =>
    new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)),
    );
  const [x, y] = await Promise.all([hash(a), hash(b)]);
  let n = 0;
  for (let i = 0; i < x.length; i++) n |= x[i] ^ y[i];
  return n === 0;
}
export async function journalDigest(entries) {
  const bytes = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(JSON.stringify(entries)),
  );
  return [...new Uint8Array(bytes)].map((v) => v.toString(16).padStart(2, "0"))
    .join("");
}
function validateEntry(input) {
  if (
    !input || Array.isArray(input) ||
    Object.keys(input).some((k) =>
      !["id", "userId", "contactId", "generation", "kind"].includes(k)
    ) ||
    !uuid(input.id) || !uuid(input.userId) ||
    !["delete", "withdraw"].includes(input.kind) ||
    (input.kind === "withdraw"
      ? !uuid(input.contactId) || !Number.isSafeInteger(input.generation) ||
        input.generation < 1
      : input.contactId !== undefined || input.generation !== undefined)
  ) throw Error("INVALID_ENTRY");
  return input.kind === "delete"
    ? { id: input.id, userId: input.userId, kind: input.kind }
    : {
      id: input.id,
      userId: input.userId,
      kind: input.kind,
      contactId: input.contactId,
      generation: input.generation,
    };
}

/** Independent authority: this state and journal are never in the application DB backup. */
export class ControlService {
  constructor(storage, bucket, secrets, now = () => Date.now()) {
    Object.assign(this, { storage, bucket, secrets, now });
  }
  async entries() {
    const result = [];
    let after;
    for (;;) {
      const page = await this.storage.list({
        prefix: "entry/",
        limit: 500,
        ...(after ? { startAfter: after } : {}),
      });
      for (const [key, entry] of page) {
        if (!entry.durable) throw Error("JOURNAL_INCOMPLETE");
        const object = await this.bucket.get(`journal/${entry.input.id}.json`);
        if (!object || await object.text() !== JSON.stringify(entry)) {
          throw Error("JOURNAL_INCOMPLETE");
        }
        result.push(entry);
        after = key;
      }
      if (page.size < 500) break;
    }
    return result.sort((a, b) => a.sequence - b.sequence);
  }
  async handle(request) {
    try {
      const keys = [
        this.secrets.reader,
        this.secrets.writer,
        this.secrets.admin,
      ];
      if (
        keys.some((k) => typeof k !== "string" || k.length < 32) ||
        new Set(keys).size !== 3
      ) return json({ error: "CONTROL_NOT_CONFIGURED" }, 503);
      const token = (request.headers.get("Authorization") ?? "").replace(
        /^Bearer /,
        "",
      );
      const [reader, writer, admin] = await Promise.all(
        keys.map((k) => equal(token, k)),
      );
      const path = new URL(request.url).pathname;
      if (!reader && !writer && !admin) {
        return json({ error: "UNAUTHORIZED" }, 401);
      }
      let state = await this.storage.get("state");
      if (!state) {
        state = {
          quarantined: true,
          coverageStart: new Date(this.now()).toISOString(),
          version: 0,
          restoreId: crypto.randomUUID(),
        };
        await this.storage.put("state", state);
      }
      if (
        path === "/gate" && request.method === "GET" &&
        (reader || writer || admin)
      ) {
        const subject = request.headers.get("X-SignalWord-Subject");
        if (subject && !uuid(subject)) return json({ allowed: false }, 403);
        const deleted = subject
          ? await this.storage.get(`deleted/${subject}`)
          : false;
        const issued = request.headers.get("X-SignalWord-Issued-At");
        const stale = subject && state.sessionEpoch &&
          (!issued || !Number.isFinite(Number(issued)) ||
            Number(issued) < state.sessionEpoch);
        const allowed = !state.quarantined && !deleted && !stale;
        return json({ allowed }, allowed ? 200 : 503);
      }
      if (request.method === "GET" && path === "/snapshot" && admin) {
        const entries = await this.entries();
        return json({ state, entries, digest: await journalDigest(entries) });
      }
      if (request.method !== "POST") return json({ error: "NOT_FOUND" }, 404);
      const readerStream = request.body?.getReader();
      let bytes = "";
      let size = 0;
      if (readerStream) {
        const decoder = new TextDecoder();
        for (;;) {
          const { value, done } = await readerStream.read();
          if (done) break;
          size += value.byteLength;
          if (size > 2048) {
            await readerStream.cancel();
            return json({ error: "INVALID_REQUEST" }, 400);
          }
          bytes += decoder.decode(value, { stream: true });
        }
        bytes += decoder.decode();
      }
      const body = JSON.parse(bytes);
      if (path === "/journal" && (writer || admin)) {
        const input = validateEntry(body);
        const key = `entry/${input.id}`;
        let entry = await this.storage.get(key);
        if (entry && JSON.stringify(entry.input) !== JSON.stringify(input)) {
          return json({ error: "IDEMPOTENCY_CONFLICT" }, 409);
        }
        if (!entry) {
          // Allocate and persist before writing R2; retry resumes the same sequence.
          state = { ...state, version: state.version + 1 };
          entry = {
            input,
            sequence: state.version,
            recordedAt: new Date(this.now()).toISOString(),
            durable: false,
          };
          await this.storage.put({ state, [key]: entry });
        }
        if (!entry.durable) {
          const objectKey = `journal/${input.id}.json`;
          const content = JSON.stringify({ ...entry, durable: true });
          const existing = await this.bucket.get(objectKey);
          if (existing) {
            if (await existing.text() !== content) {
              throw Error("JOURNAL_CONFLICT");
            }
          } else {
            const stored = await this.bucket.put(objectKey, content, {
              onlyIf: { etagDoesNotMatch: "*" },
            });
            if (!stored) throw Error("JOURNAL_WRITE_UNCERTAIN");
          }
          entry = { ...entry, durable: true };
          await this.storage.put(key, entry);
          if (input.kind === "delete") {
            await this.storage.put(`deleted/${input.userId}`, true);
          }
        }
        // Repeat the deletion index write after an interrupted durable-entry update.
        if (input.kind === "delete") {
          await this.storage.put(`deleted/${input.userId}`, true);
        }
        return json({ durable: true, sequence: entry.sequence });
      }
      if (path === "/quarantine" && admin) {
        const backupAt = Date.parse(body.backupAt);
        if (
          !Number.isFinite(backupAt) || backupAt > this.now() ||
          backupAt < Date.parse(state.coverageStart) ||
          backupAt < this.now() - 90 * 86400000
        ) return json({ error: "JOURNAL_COVERAGE_MISSING" }, 409);
        state = {
          ...state,
          quarantined: true,
          sessionEpoch: Math.ceil(this.now() / 1000),
          restoreId: crypto.randomUUID(),
          backupAt: new Date(backupAt).toISOString(),
        };
        await this.storage.put("state", state);
        return json(state);
      }
      if (path === "/release" && admin) {
        const entries = await this.entries();
        if (
          !state.quarantined || !state.backupAt ||
          body.restoreId !== state.restoreId ||
          body.version !== state.version ||
          body.digest !== await journalDigest(entries)
        ) return json({ error: "RECONCILIATION_STALE" }, 409);
        state = { ...state, quarantined: false };
        await this.storage.put("state", state);
        return json({ released: true });
      }
      return json({ error: "NOT_FOUND" }, 404);
    } catch {
      return json({ error: "CONTROL_UNAVAILABLE" }, 503);
    }
  }
}
