import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const here = new URL(".", import.meta.url).pathname;
const schema = join(here, "account.schema.json");
const manifest = JSON.parse(readFileSync(join(here, "fixtures/production-session-key-manifest-v1.json")));
const vectors = JSON.parse(readFileSync(join(here, "fixtures/crypto-vectors-v1.json")));
const dir = mkdtempSync(join(tmpdir(), "account-v1-"));
try {
  const valid = join(dir, "manifest.json"); writeFileSync(valid, JSON.stringify(manifest));
  execFileSync("npx", ["--yes", "ajv-cli@5", "validate", "-s", schema, "-d", valid, "--spec=draft2020", "--strict=false"], { stdio: "ignore" });
  const mutated = structuredClone(manifest); mutated.unexpected = true;
  const invalid = join(dir, "manifest-extra.json"); writeFileSync(invalid, JSON.stringify(mutated));
  let accepted = true;
  try { execFileSync("npx", ["--yes", "ajv-cli@5", "validate", "-s", schema, "-d", invalid, "--spec=draft2020", "--strict=false"], { stdio: "ignore" }); } catch { accepted = false; }
  if (accepted) throw new Error("SessionKeyManifestV1 accepted an unknown property");

  const admission = vectors.syncNodeEnrollmentV2;
  const response = { kind: "account.sync-node-admission-response.v2", result: JSON.parse(admission.resultCanonicalJSON), refreshCredential: JSON.parse(admission.refreshCanonicalJSON), offlineLease: JSON.parse(admission.leaseCanonicalJSON), cleanupCapability: JSON.parse(admission.capabilityCanonicalJSON) };
  const responseFile = join(dir, "admission-v2.json"); writeFileSync(responseFile, JSON.stringify(response));
  execFileSync("npx", ["--yes", "ajv-cli@5", "validate", "-s", schema, "-d", responseFile, "--spec=draft2020", "--strict=false"], { stdio: "ignore" });
  response.unexpected = true; writeFileSync(responseFile, JSON.stringify(response));
  accepted = true;
  try { execFileSync("npx", ["--yes", "ajv-cli@5", "validate", "-s", schema, "-d", responseFile, "--spec=draft2020", "--strict=false"], { stdio: "ignore" }); } catch { accepted = false; }
  if (accepted) throw new Error("V2 admission response accepted an unknown property");
} finally { rmSync(dir, { recursive: true, force: true }); }
