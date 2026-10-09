import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const here = new URL(".", import.meta.url).pathname;
const schema = join(here, "node-session.schema.json");
const v3Schema = join(here, "node-session-v3.schema.json");
const base = JSON.parse(readFileSync(join(here, "fixtures/session-v1.json")));
const v3 = JSON.parse(readFileSync(join(here, "fixtures/session-v3.json")));
const corpus = JSON.parse(readFileSync(join(here, "fixtures/acceptance-v1.json")));
const disposition = JSON.parse(readFileSync(join(here, "fixtures/middleware-disposition-v1.json")));
const dir = mkdtempSync(join(tmpdir(), "node-session-v1-"));
const v3Fields = ["resultWire", "refreshWire", "leaseWire", "trustCommitWire", "admissionEvidenceWire", "cleanupCapabilityWire", "claimProofSignature"];
function activationWithinBounds(activation) {
  const sizes = v3Fields.map((field) => Buffer.from(activation[field], "base64url").length);
  return sizes.every((size) => size > 0 && size <= 64 * 1024) && sizes.reduce((total, size) => total + size, 0) <= 128 * 1024 && sizes.at(-1) === 64;
}
function fixedProblem(problem, name) {
  if (typeof problem?.type !== "string" || !Number.isInteger(problem.status) || problem.status < 400 || problem.status > 599) throw new Error(`invalid middleware problem ${name}`);
}
try {
	if (disposition.kind !== "node-session-v1.middleware-disposition" || disposition.schemaVersion !== 1 || !Array.isArray(disposition.closedPreConsumption) || disposition.closedPreConsumption.length !== 3) throw new Error("middleware disposition fixture header is invalid");
	for (const problem of disposition.closedPreConsumption) fixedProblem(problem, problem.name);
	fixedProblem(disposition.exactConsumed, "exact-consumed");
	fixedProblem(disposition.preConsumptionUncertain, "pre-consumption-uncertain");
	for (const example of disposition.postDispatchExamples ?? []) {
		if (typeof example.name !== "string" || !Number.isInteger(example.status) || example.status < 400 || example.status > 599) throw new Error(`invalid post-dispatch example ${example.name}`);
	}
	if (disposition.exactConsumed.type !== "urn:plainpost:node-sequence-consumed" || disposition.exactConsumed.status !== 409 || disposition.preConsumptionUncertain.type !== "urn:plainpost:node-sequence-unavailable" || disposition.preConsumptionUncertain.status !== 503) throw new Error("middleware terminal problem fixture is invalid");
	const v3File = join(dir, "session-v3.json"); writeFileSync(v3File, JSON.stringify(v3));
	try { execFileSync("npx", ["--yes", "ajv-cli@5", "validate", "-s", v3Schema, "-d", v3File, "--spec=draft2020", "--strict=false"], { stdio: "ignore" }); } catch { throw new Error("session-v3 fixture is not schema-valid"); }
	if (!activationWithinBounds(v3.activation)) throw new Error("session-v3 fixture violates activation bounds");
	const oversized = structuredClone(v3); oversized.activation.resultWire = Buffer.alloc(64 * 1024 + 1, 1).toString("base64url");
	const oversizedFile = join(dir, "session-v3-oversized.json"); writeFileSync(oversizedFile, JSON.stringify(oversized));
	let oversizedAccepted = true; try { execFileSync("npx", ["--yes", "ajv-cli@5", "validate", "-s", v3Schema, "-d", oversizedFile, "--spec=draft2020", "--strict=false"], { stdio: "ignore" }); } catch { oversizedAccepted = false; }
	if (oversizedAccepted) throw new Error("session-v3 per-field bound accepted");
	const exactAggregate = structuredClone(v3);
	exactAggregate.activation.resultWire = Buffer.alloc(64 * 1024, 1).toString("base64url");
	exactAggregate.activation.refreshWire = Buffer.alloc(128 * 1024 - 64 * 1024 - 64 - 4, 1).toString("base64url");
	for (const field of ["leaseWire", "trustCommitWire", "admissionEvidenceWire", "cleanupCapabilityWire"]) exactAggregate.activation[field] = Buffer.from([1]).toString("base64url");
	const exactAggregateFile = join(dir, "session-v3-aggregate-exact.json"); writeFileSync(exactAggregateFile, JSON.stringify(exactAggregate));
	try { execFileSync("npx", ["--yes", "ajv-cli@5", "validate", "-s", v3Schema, "-d", exactAggregateFile, "--spec=draft2020", "--strict=false"], { stdio: "ignore" }); } catch { throw new Error("session-v3 exact aggregate is not schema-valid"); }
	if (!activationWithinBounds(exactAggregate.activation)) throw new Error("session-v3 exact aggregate rejected");
	exactAggregate.activation.refreshWire = Buffer.alloc(128 * 1024 - 64 * 1024 - 64 - 3, 1).toString("base64url");
	if (activationWithinBounds(exactAggregate.activation)) throw new Error("session-v3 aggregate-over-128KiB accepted");
  for (const item of [...corpus.requestCases, ...corpus.endpointCases]) {
    const candidate = structuredClone(base);
    if ("field" in item) candidate.request[item.field] = item.value;
    else candidate.endpoint.ciphertext = item.ciphertext;
    const file = join(dir, `${item.name}.json`); writeFileSync(file, JSON.stringify(candidate));
    let accepted = true;
    try { execFileSync("npx", ["--yes", "ajv-cli@5", "validate", "-s", schema, "-d", file, "--spec=draft2020", "--strict=false"], { stdio: "ignore" }); } catch { accepted = false; }
    if (accepted !== item.accepted) throw new Error(`${item.name}: AJV accepted=${accepted}, want ${item.accepted}`);
  }
  for (const item of corpus.activationCases) {
    const candidate = structuredClone(base);
    candidate.activation[item.field] = Buffer.alloc(item.bytes, 1).toString("base64url");
    const file = join(dir, `${item.name}.json`); writeFileSync(file, JSON.stringify(candidate));
    let accepted = true;
    try { execFileSync("npx", ["--yes", "ajv-cli@5", "validate", "-s", schema, "-d", file, "--spec=draft2020", "--strict=false"], { stdio: "ignore" }); } catch { accepted = false; }
    if (accepted !== item.accepted) throw new Error(`${item.name}: AJV accepted=${accepted}, want ${item.accepted}`);
  }
  for (const item of corpus.bodyCases) {
    const bytes = Buffer.byteLength(item.unit.repeat(item.repeat), "utf8");
    if ((bytes <= 1_048_576) !== item.accepted) throw new Error(`${item.name}: UTF-8 boundary mismatch`);
  }
} finally { rmSync(dir, { recursive: true, force: true }); }
