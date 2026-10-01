import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
const root = fileURLToPath(new URL("..", import.meta.url));
const directory = mkdtempSync(join(tmpdir(), "signalword-verification-"));
const project = `SignalWordVerify${Date.now()}`;
mkdirSync(join(directory, "supabase"));
for (const name of ["migrations", "functions", "seed.sql"]) {
  if (existsSync(join(root, "supabase", name))) {
    cpSync(join(root, "supabase", name), join(directory, "supabase", name), {
      recursive: true,
    });
  }
}
const config = readFileSync(join(root, "supabase/config.toml"), "utf8")
  .replace('project_id = "SignalWord"', `project_id = "${project}"`)
  .replace(/5432([0-9])/g, "5542$1");
writeFileSync(join(directory, "supabase/config.toml"), config);
console.log(`Isolated verification directory: ${directory}`);
console.log(
  `Local Docker project: ${project}; ports 55420–55429. Existing databases are preserved.`,
);
try {
  // Supabase startup may print local keys. Suppress them even in CI artifacts.
  execFileSync(join(root, "node_modules/.bin/supabase"), [
    "--workdir",
    directory,
    "start",
  ], { stdio: "ignore" });
  console.log(
    "PASS: new empty local project started and all migrations replayed.",
  );
} catch {
  throw Error(
    "ISOLATED_START_FAILED: inspect local Docker health; do not reset an existing database",
  );
}
