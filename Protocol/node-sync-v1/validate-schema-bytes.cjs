// This intentionally drives ajv-cli through its local keyword plug-in. The
// two documents use 256 and 257 two-byte characters: both meet maxLength 512,
// but only the first meets the 512 UTF-8 byte ceiling.
const childProcess = require("child_process");
const fileSystem = require("fs");
const operatingSystem = require("os");
const path = require("path");
const vectors = require("./fixtures/schema-byte-v1.json");
const protocolVectors = require("./fixtures/protocol-v1.json");
const expectedFamilyNames = [
  "attachmentRequest", "attachmentResult", "deltaPage", "deltaRequest",
  "googleProvisionRequest", "googleProvisionResult",
  "mailboxAssignmentsRequest", "mailboxAssignmentsResult", "messageRequest",
  "messageResult", "mutationResult", "problem", "searchPage",
  "searchRequest", "snapshotPage", "snapshotRequest", "statusRequest",
  "statusResult",
];
const expectedFamilyKinds = {
  attachmentRequest: "node-sync.attachment-request.v1",
  attachmentResult: "node-sync.attachment-result.v1",
  deltaPage: "node-sync.delta-page.v1",
  deltaRequest: "node-sync.delta-request.v1",
  googleProvisionRequest: "node-sync.google-provision-request.v1",
  googleProvisionResult: "node-sync.google-provision-result.v1",
  mailboxAssignmentsRequest: "node-sync.mailbox-assignments-request.v1",
  mailboxAssignmentsResult: "node-sync.mailbox-assignments-result.v1",
  messageRequest: "node-sync.message-request.v1",
  messageResult: "node-sync.message-result.v1",
  mutationResult: "node-sync.mutation-result.v1",
  problem: "node-sync.problem.v1",
  searchPage: "node-sync.search-page.v1",
  searchRequest: "node-sync.search-request.v1",
  snapshotPage: "node-sync.snapshot-page.v1",
  snapshotRequest: "node-sync.snapshot-request.v1",
  statusRequest: "node-sync.status-request.v1",
  statusResult: "node-sync.status-result.v1",
};
const expectedProblemCategories = [
  "invalid_request", "unauthorized", "conflict", "stale_cursor", "unavailable",
];
const document = ({ character, repeat }) => ({
  kind: "node-sync.message-request.v1",
  messageID: character.repeat(repeat)
});
const noncanonicalSignature = {
  accountID: "11111111-1111-4111-8111-111111111111",
  authorityEpoch: "2",
  clientID: "22222222-2222-4222-8222-222222222222",
  idempotencyKey: "signature-tail",
  issuedAt: "2026-08-20T12:34:56Z",
  kind: "node-sync.operation.v1",
  logicalMailboxID: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
  nodeID: "33333333-3333-4333-8333-333333333333",
  operation: { kind: "archive", messageIDs: ["message-001"] },
  signature: "A".repeat(85) + "E",
  trustEpoch: "1"
};
const validSearch = {
  after: "",
  kind: "node-sync.search-request.v1",
  limit: 200,
  logicalMailboxIDs: [],
  query: "q".repeat(4096)
};
const invalidSearches = [
  { ...validSearch, query: "" },
  { ...validSearch, query: "query\u0001control" },
  { ...validSearch, query: "q".repeat(4097) }
];
const validReferences = JSON.parse(protocolVectors.families.messageResult);
validReferences.message.inReplyTo = ["i".repeat(998)];
validReferences.message.references = ["r".repeat(998)];
const invalidReferences = JSON.parse(JSON.stringify(validReferences));
invalidReferences.message.references = ["r".repeat(999)];
if (!Array.isArray(protocolVectors.problems) || protocolVectors.problems.length !== expectedProblemCategories.length) {
  throw new Error("problem vectors are missing or incomplete");
}
const actualFamilyNames = Object.keys(protocolVectors.families).sort();
if (actualFamilyNames.length !== expectedFamilyNames.length ||
    actualFamilyNames.join("\0") !== [...expectedFamilyNames].sort().join("\0")) {
  throw new Error(`family vectors are missing or incomplete: expected ${expectedFamilyNames.length}, got ${actualFamilyNames.length}`);
}
const familyKinds = Object.fromEntries(Object.entries(protocolVectors.families).map(([name, raw]) => [name, JSON.parse(raw).kind]));
for (const [name, expectedKind] of Object.entries(expectedFamilyKinds)) {
  if (familyKinds[name] !== expectedKind) {
    throw new Error(`family ${name} has unexpected kind ${familyKinds[name]}`);
  }
}
const problemDocuments = protocolVectors.problems.map(JSON.parse);
const problemCategories = problemDocuments.map(document => document.category);
const hasExactProblemCategories = categories =>
  categories.length === expectedProblemCategories.length &&
  categories.length === new Set(categories).size &&
  categories.join("\0") === expectedProblemCategories.join("\0");
if (problemDocuments.some(document => document.kind !== expectedFamilyKinds.problem) ||
    !hasExactProblemCategories(problemCategories)) {
  throw new Error("problem vectors are missing, duplicated, or remapped");
}
const duplicatedProblemCategories = [...problemCategories];
duplicatedProblemCategories[0] = duplicatedProblemCategories[1];
if (hasExactProblemCategories(duplicatedProblemCategories)) {
  throw new Error("problem vector duplicate mutation was not rejected");
}
const sizedCanonicalFamily = (raw, length) => {
  const emptyBody = raw.replace("\"value\":\"Done\"", "\"value\":\"\"");
  const replacement = "x".repeat(length - Buffer.byteLength(emptyBody, "utf8"));
  const result = emptyBody.replace("\"value\":\"\"", "\"value\":\"" + replacement + "\"");
  if (Buffer.byteLength(result, "utf8") !== length) {
    throw new Error("canonical family test vector has the wrong byte length");
  }
  return result;
};
const canonicalFamilyBounds = protocolVectors.bounds.canonicalFamily;
const familyAtLimit = sizedCanonicalFamily(protocolVectors.families.messageResult, canonicalFamilyBounds.acceptedBytes);
const familyOverLimit = sizedCanonicalFamily(protocolVectors.families.messageResult, canonicalFamilyBounds.rejectedBytes);
if (vectors.kind !== "node-sync-v1.schema-byte-vectors" || vectors.schemaVersion !== 1) {
  throw new Error("x-plainpost-maxUtf8Bytes positive/negative vectors failed");
}
const directory = fileSystem.mkdtempSync(path.join(operatingSystem.tmpdir(), "node-sync-schema-"));
try {
  const positive = path.join(directory, "positive.json");
  const negative = path.join(directory, "negative.json");
  const invalidSignature = path.join(directory, "invalid-signature.json");
  const searchPositive = path.join(directory, "search-positive.json");
  const referencePositive = path.join(directory, "reference-positive.json");
  const referenceNegative = path.join(directory, "reference-negative.json");
  const familyPositive = path.join(directory, "family-positive.json");
  const familyNegative = path.join(directory, "family-negative.json");
  const familyKindMutation = path.join(directory, "family-kind-mutation.json");
  fileSystem.writeFileSync(positive, JSON.stringify(document(vectors.positive)));
  fileSystem.writeFileSync(negative, JSON.stringify(document(vectors.negative)));
  fileSystem.writeFileSync(invalidSignature, JSON.stringify(noncanonicalSignature));
  fileSystem.writeFileSync(searchPositive, JSON.stringify(validSearch));
  fileSystem.writeFileSync(referencePositive, JSON.stringify(validReferences));
  fileSystem.writeFileSync(referenceNegative, JSON.stringify(invalidReferences));
  fileSystem.writeFileSync(familyPositive, familyAtLimit);
  fileSystem.writeFileSync(familyNegative, familyOverLimit);
  const mutatedFamily = JSON.parse(protocolVectors.families.messageResult);
  mutatedFamily.kind = expectedFamilyKinds.searchPage;
  fileSystem.writeFileSync(familyKindMutation, JSON.stringify(mutatedFamily));
  const problemPaths = protocolVectors.problems.map((raw, index) => {
    const filename = path.join(directory, `problem-${index}.json`);
    fileSystem.writeFileSync(filename, raw);
    return filename;
  });
  const familyPaths = Object.entries(protocolVectors.families).map(([name, raw]) => {
    const filename = path.join(directory, `family-${name}.json`);
    fileSystem.writeFileSync(filename, raw);
    return filename;
  });
  const searchNegatives = invalidSearches.map((value, index) => {
    const filename = path.join(directory, `search-negative-${index}.json`);
    fileSystem.writeFileSync(filename, JSON.stringify(value));
    return filename;
  });
  const args = ["--yes", "ajv-cli@5", "validate", "--spec=draft2020", "--strict=false", "-s", path.join(__dirname, "node-sync.schema.json"), "-c", path.join(__dirname, "validate-max-utf8-bytes.cjs")];
  const run = data => childProcess.spawnSync("npx", [...args, "-d", data], { encoding: "utf8" });
  const pass = run(positive);
  const fail = run(negative);
  const signatureFail = run(invalidSignature);
  const searchPass = run(searchPositive);
  const searchFails = searchNegatives.map(run);
  const referencePass = run(referencePositive);
  const referenceFail = run(referenceNegative);
  const familyPass = run(familyPositive);
  const familyFail = run(familyNegative);
  const familyKindMutationFail = run(familyKindMutation);
  const familyResults = familyPaths.map(run);
  const problemResults = problemPaths.map(run);
  if (pass.status !== 0 || fail.status === 0 || signatureFail.status === 0 || searchPass.status !== 0 || searchFails.some(result => result.status === 0) || referencePass.status !== 0 || referenceFail.status === 0 || familyPass.status !== 0 || familyFail.status === 0 || familyKindMutationFail.status === 0 || familyResults.some(result => result.status !== 0) || problemResults.some(result => result.status !== 0)) {
    throw new Error("x-plainpost-maxUtf8Bytes positive/negative vectors failed\n" + pass.stderr + fail.stderr);
  }
  console.log("x-plainpost-maxUtf8Bytes vectors passed");
} finally {
  fileSystem.rmSync(directory, { recursive: true, force: true });
}
