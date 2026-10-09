#!/usr/bin/env python3
"""Derive node-sync-v1 mail-mode contract vectors from the closed schema.

One canonical seed per family is the root of every vector. For each seed this
generator emits the family's canonical accept vector, then derives rejects for
unknown and duplicate fields (top level and nested), missing required fields,
wrong or unknown family kinds, type confusion, every string, integer and array
bound at and one past its limit, every closed enum value plus near misses,
non-canonical decimals, identity, host and credential syntax, ordering and
uniqueness rules, cross-field rules and JSON syntax (non-canonical bytes,
invalid UTF-8, byte order mark, trailing data).

A small reference validator for the schema subset plus the codec rules that
JSON Schema cannot express confirms each expectation before it is written, so
the fixture cannot silently disagree with the schema.

Wires are raw-base64url bytes so invalid UTF-8 is representable. Every accept
vector is canonical: both codecs must decode it and re-encode identical bytes.

Usage: generate-mail-mode-contract-vectors.py [--check]
"""

import base64
import copy
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent / "Protocol" / "node-sync-v1"
SCHEMA = json.loads((ROOT / "node-sync-mail-mode.schema.json").read_text())
FIXTURE_PATH = ROOT / "fixtures" / "mail-mode-v1.json"
DEFS = SCHEMA["$defs"]
MAX_CANONICAL = SCHEMA["x-plainpost-maxCanonicalBytes"]


def b64url(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def logical(byte_values):
    return b64url(bytes(byte_values))


LOGICAL_A = logical([7] * 32)
LOGICAL_B = logical([8] * 32)

FAMILIES = {
    "mailCapabilities": "node-sync.mail-capabilities.v1",
    "mailAccountsResult": "node-sync.mail-accounts-result.v1",
    "googleTokenImportRequest": "node-sync.google-token-import-request.v1",
    "imapProviderImportRequest": "node-sync.imap-provider-import-request.v1",
    "providerImportResult": "node-sync.provider-import-result.v1",
    "providerRemoveRequest": "node-sync.provider-remove-request.v1",
    "providerRemoveResult": "node-sync.provider-remove-result.v1",
    "accountSnapshotRequest": "node-sync.account-snapshot-request.v1",
    "mirrorCoordinatesRequest": "node-sync.mirror-coordinates-request.v1",
    "mirrorCoordinatesResult": "node-sync.mirror-coordinates-result.v1",
    "mailDeltaPage": "node-sync.mail-delta-page.v1",
}

SEEDS = {
    "mailCapabilities": {
        "googleImport": True, "imapImport": True, "kind": FAMILIES["mailCapabilities"],
        "mirrorCoordinates": True, "multiAccount": True, "version": "1",
    },
    "mailAccountsResult": {
        "accounts": [
            {
                "assignments": [], "logicalMailboxID": LOGICAL_B, "primary": False,
                "providerIdentity": "grace@example.test", "providerKind": "generic", "state": "degraded",
            },
            {
                "assignments": [
                    {"displayName": "Promotions", "logicalMailboxID": None, "mailboxHandle": "handle-promotions", "role": "other"},
                    {"authorityEpoch": "3", "displayName": "Inbox", "logicalMailboxID": LOGICAL_A, "mailboxHandle": "handle-inbox", "role": "inbox"},
                ],
                "logicalMailboxID": LOGICAL_A, "primary": True, "providerIdentity": "ada@example.test",
                "providerKind": "gmail", "state": "ready",
            },
        ],
        "kind": FAMILIES["mailAccountsResult"], "primaryState": "available",
    },
    "googleTokenImportRequest": {
        "expectedProviderIdentity": "ada@example.test", "kind": FAMILIES["googleTokenImportRequest"],
        "logicalMailboxID": LOGICAL_A, "refreshToken": "1//refresh-token",
    },
    "imapProviderImportRequest": {
        "expectedProviderIdentity": "grace@example.test",
        "imap": {"host": "imap.example.test", "port": "993", "security": "implicit_tls"},
        "kind": FAMILIES["imapProviderImportRequest"], "logicalMailboxID": LOGICAL_B, "password": "app-password",
        "roles": {"archive": "Archive", "drafts": "Drafts", "inbox": "INBOX", "sent": "Sent", "trash": "Trash"},
        "smtp": {"host": "smtp.example.test", "port": "587", "security": "starttls"},
        "username": "grace@example.test",
    },
    "providerImportResult": {
        "assignments": [{"authorityEpoch": "1", "displayName": "Inbox", "logicalMailboxID": LOGICAL_B, "mailboxHandle": "handle-inbox", "role": "inbox"}],
        "kind": FAMILIES["providerImportResult"], "logicalMailboxID": LOGICAL_B,
        "providerIdentity": "grace@example.test", "state": "created",
    },
    "providerRemoveRequest": {
        "expectedProviderIdentity": "grace@example.test", "kind": FAMILIES["providerRemoveRequest"], "logicalMailboxID": LOGICAL_B,
    },
    "providerRemoveResult": {"kind": FAMILIES["providerRemoveResult"], "logicalMailboxID": LOGICAL_B, "state": "removed"},
    "accountSnapshotRequest": {"after": "", "kind": FAMILIES["accountSnapshotRequest"], "limit": 50, "logicalMailboxID": LOGICAL_A},
    "mirrorCoordinatesRequest": {"kind": FAMILIES["mirrorCoordinatesRequest"], "messageIDs": ["gm2.message-001", "gm2.message-002"]},
    "mirrorCoordinatesResult": {
        "kind": FAMILIES["mirrorCoordinatesResult"],
        "records": [
            {"memberships": [], "messageID": "gm2.message-001", "rfcMessageID": None},
            {
                "memberships": [
                    {"flags": ["flagged", "seen"], "logicalMailboxID": LOGICAL_A, "mailboxPath": "INBOX", "uid": "42", "uidValidity": "7"},
                    {"flags": [], "logicalMailboxID": LOGICAL_B, "mailboxPath": "[Gmail]/All Mail", "uid": "4294967295", "uidValidity": "1"},
                ],
                "messageID": "gm2.message-002", "rfcMessageID": "<message-002@example.test>",
            },
        ],
    },
    "mailDeltaPage": {
        "changes": [
            {"kind": "baseline_complete", "logicalMailboxID": LOGICAL_A, "messageID": None, "threadID": None},
            {"kind": "tombstoned", "logicalMailboxID": LOGICAL_A, "messageID": "gm2.message-001", "threadID": None},
            {"kind": "upsert", "logicalMailboxID": LOGICAL_A, "messageID": "gm2.message-002", "threadID": "gm2.thread-002"},
        ],
        "kind": FAMILIES["mailDeltaPage"], "nextCursor": "opaque-tail-001", "revision": "7", "waitingAccounts": [LOGICAL_B],
    },
}


def canon(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def resolve(node):
    while "$ref" in node:
        node = DEFS[node["$ref"].split("/")[-1]]
    return node


def ref_name(node):
    return node["$ref"].split("/")[-1] if "$ref" in node else None


def type_ok(value, name):
    return {
        "string": isinstance(value, str), "boolean": isinstance(value, bool), "null": value is None,
        "integer": isinstance(value, int) and not isinstance(value, bool),
        "object": isinstance(value, dict), "array": isinstance(value, list),
    }[name]


def valid(value, node):
    """Reference validator for the JSON Schema subset used by this schema."""
    node = resolve(node)
    if "type" in node:
        types = node["type"] if isinstance(node["type"], list) else [node["type"]]
        if not any(type_ok(value, t) for t in types):
            return False
    if "const" in node and not (type(value) is type(node["const"]) and value == node["const"]):
        return False
    if "enum" in node and not any(type(value) is type(e) and value == e for e in node["enum"]):
        return False
    if isinstance(value, str):
        if len(value) < node.get("minLength", 0) or len(value) > node.get("maxLength", len(value)):
            return False
        if len(value.encode("utf-8", "surrogatepass")) > node.get("x-plainpost-maxUtf8Bytes", 1 << 62):
            return False
        if "pattern" in node and re.fullmatch(node["pattern"], value) is None:
            return False
    if isinstance(value, int) and not isinstance(value, bool):
        if value < node.get("minimum", value) or value > node.get("maximum", value):
            return False
    if isinstance(value, list):
        if not node.get("minItems", 0) <= len(value) <= node.get("maxItems", len(value)):
            return False
        if node.get("uniqueItems") and len({canon(v) for v in value}) != len(value):
            return False
        if "items" in node and not all(valid(v, node["items"]) for v in value):
            return False
    if isinstance(value, dict):
        if any(key not in value for key in node.get("required", [])):
            return False
        properties = node.get("properties", {})
        for key, child in value.items():
            if key in properties:
                if not valid(child, properties[key]):
                    return False
            elif node.get("additionalProperties") is False:
                return False
    if "oneOf" in node and sum(1 for v in node["oneOf"] if valid(value, v)) != 1:
        return False
    if "not" in node and valid(value, node["not"]):
        return False
    return True


def utf8(text):
    return text.encode("utf-8")


def strictly_sorted(keys):
    return all(keys[i - 1] < keys[i] for i in range(1, len(keys)))


def codec_rules(family, doc):
    """Codec rules beyond JSON Schema; the document is already schema-valid."""
    def own_assignments(assignments, owner):
        return all(a["logicalMailboxID"] in (None, owner) for a in assignments)

    if family == "mailAccountsResult":
        accounts = doc["accounts"]
        if len({a["logicalMailboxID"] for a in accounts}) != len(accounts):
            return False
        if len({a["providerIdentity"] for a in accounts}) != len(accounts):
            return False
        primaries = sum(1 for a in accounts if a["primary"])
        state = doc["primaryState"]
        if (state == "available") != (primaries == 1) or primaries > 1:
            return False
        if state == "none" and accounts:
            return False
        return all(own_assignments(a["assignments"], a["logicalMailboxID"]) for a in accounts)
    if family == "providerImportResult":
        return own_assignments(doc["assignments"], doc["logicalMailboxID"])
    if family == "mailDeltaPage":
        waiting = [base64.urlsafe_b64decode(w + "=") for w in doc["waitingAccounts"]]
        if not strictly_sorted(waiting):
            return False
        return all(c["logicalMailboxID"] not in doc["waitingAccounts"] for c in doc["changes"])
    if family == "imapProviderImportRequest":
        paths = [utf8(v) for v in doc["roles"].values()]
        return len(set(paths)) == len(paths)
    if family == "mirrorCoordinatesRequest":
        return strictly_sorted([utf8(v) for v in doc["messageIDs"]])
    if family == "mirrorCoordinatesResult":
        records = doc["records"]
        if not strictly_sorted([utf8(r["messageID"]) for r in records]):
            return False
        for record in records:
            keys = [(base64.urlsafe_b64decode(m["logicalMailboxID"] + "="), utf8(m["mailboxPath"])) for m in record["memberships"]]
            if not strictly_sorted(keys):
                return False
            if not all(strictly_sorted([utf8(f) for f in m["flags"]]) for m in record["memberships"]):
                return False
    return True


def accepts(family, doc):
    return valid(doc, DEFS[family]) and codec_rules(family, doc)


class Vectors:
    def __init__(self):
        self.items = []
        self.names = set()
        self.seen = set()

    def add(self, name, family, wire, expect, reason, check=True):
        """wire is a document (canonicalized) or raw text/bytes (syntax cases)."""
        if name in self.names:
            raise ValueError("duplicate vector " + name)
        if isinstance(wire, bytes):
            raw = wire
        elif isinstance(wire, str):
            raw = wire.encode("utf-8", "surrogatepass")
        else:
            raw = canon(wire).encode("utf-8")
            if check and accepts(family, wire) != (expect == "accept"):
                raise ValueError("reference validator disagrees with %s (%s)" % (name, reason))
        if expect == "accept":
            # Every accept vector must already be canonical and in bounds.
            if len(raw) > MAX_CANONICAL or canon(json.loads(raw)).encode("utf-8") != raw:
                raise ValueError("accept vector is not canonical: " + name)
            if not accepts(family, json.loads(raw)):
                raise ValueError("accept vector is invalid: " + name)
        self.names.add(name)
        self.items.append({"name": name, "family": family, "expect": expect, "reason": reason, "wire": b64url(raw)})


def get_path(doc, path):
    for key in path:
        doc = doc[key]
    return doc


def set_path(doc, path, value):
    get_path(doc, path[:-1])[path[-1]] = value


def delete_path(doc, path):
    del get_path(doc, path[:-1])[path[-1]]


def path_name(path):
    return ".".join(str(p) for p in path) or "root"


def mutated(seed, path, value):
    doc = copy.deepcopy(seed)
    set_path(doc, path, value)
    return doc


def locations(value, node, path):
    """Yield (path, property node) for every property, descending into objects and last array items.

    The last item is mutated so byte-bound probes keep sorted collections sorted."""
    resolved = resolve(node)
    if "oneOf" in resolved:
        for variant in resolved["oneOf"]:
            if valid(value, variant):
                yield from locations(value, variant, path)
                return
    if isinstance(value, dict):
        for key, child in sorted(value.items()):
            prop = resolved.get("properties", {}).get(key)
            if prop is None:
                continue
            yield path + [key], prop
            yield from locations(child, prop, path + [key])
    if isinstance(value, list) and "items" in resolved and value:
        yield from locations(value[-1], resolved["items"], path + [len(value) - 1])


def field_def(prop):
    """The named definition a property uses, looking through a nullable oneOf."""
    if "$ref" in prop:
        return ref_name(prop)
    for variant in prop.get("oneOf", []):
        if "$ref" in variant:
            return ref_name(variant)
    return None


def nullable(prop):
    return any(v.get("type") == "null" for v in prop.get("oneOf", []))


def bounded_string(def_name, length, unit):
    """A pattern-valid string of exactly `length` units for a string definition."""
    if def_name == "providerIdentity":
        suffix = "@example.test"
        return unit * (length - len(suffix)) + suffix
    if def_name == "host":
        return "h" + unit * (length - 1)
    return unit * length


# String definitions whose byte bound is also probed with two-byte scalars.
MULTIBYTE_OK = {"identifier", "messageReference", "credentialSecret", "username", "mailboxPath"}
NUL_REJECT = {"identifier", "messageReference", "cursor", "displayName", "credentialSecret", "username", "mailboxPath"}


def field_cases(vectors, family, seed, path, prop, once):
    base = "%s.%s" % (family, path_name(path))
    key = path[-1]
    name = field_def(prop)
    resolved = resolve(prop)
    label = (name or "inline") + ":" + str(key)
    value = get_path(seed, path)

    def add(tag, doc, expect, reason, check=True):
        vectors.add("%s.%s" % (base, tag), family, doc, expect, reason, check=check)

    # Required / optional members.
    if isinstance(key, str) and key != "kind":
        doc = copy.deepcopy(seed)
        delete_path(doc, path)
        expect = "accept" if accepts(family, doc) else "reject"
        add("missing", doc, expect, ("optional member may be omitted " if expect == "accept" else "required member ") + label)
        if expect == "accept":
            add("null", mutated(seed, path, None), "reject", "optional member is omitted, never null " + label)
        elif value is not None and not nullable(prop):
            add("null", mutated(seed, path, None), "reject", "non-nullable member " + label)
    if nullable(prop) and value is not None:
        add("null", mutated(seed, path, None), "accept", "nullable member " + label)

    # Closed nested objects.
    if isinstance(value, dict) and resolved.get("additionalProperties") is False and once(("object", name or label)):
        doc = copy.deepcopy(seed)
        get_path(doc, path)["unexpected"] = True
        add("unknownField", doc, "reject", "closed nested object " + label)
        first = sorted(value)[0]
        doc = copy.deepcopy(seed)
        get_path(doc, path)["@@DUPLICATE@@"] = None
        wire = canon(doc).replace('"@@DUPLICATE@@":null,', canon(first) + ":" + canon(value[first]) + ",", 1)
        add("duplicateField", wire, "reject", "duplicate nested key " + label, check=False)
        add("type.array", mutated(seed, path, [value]), "reject", "object type " + label)

    # Booleans.
    if resolved.get("type") == "boolean":
        add("boolean.flip", mutated(seed, path, not value), "accept" if accepts(family, mutated(seed, path, not value)) else "reject", "boolean value " + label)
        for other, tag in [("true", "string"), (1, "number")]:
            add("boolean." + tag, mutated(seed, path, other), "reject", "boolean type " + label)

    # Constants.
    if "const" in resolved and key != "kind":
        add("const.other", mutated(seed, path, "2"), "reject", "constant member " + label)
        add("const.number", mutated(seed, path, 1), "reject", "constant member type " + label)

    # Closed enums: every value and near misses.
    enum = resolved.get("enum")
    if enum and once(("enum", label)):
        for option in enum:
            doc = mutated(seed, path, option)
            if option != value:
                add("enum." + option, doc, "accept" if accepts(family, doc) else "reject", "closed enum value " + label)
        for miss, tag in [("unknown", "unknown"), (enum[-1].upper(), "upperCase"), (" " + enum[0], "leadingSpace"), ("", "empty")]:
            add("enum.reject." + tag, mutated(seed, path, miss), "reject", "value outside closed enum " + label)

    # Integers (page limits).
    if resolved.get("type") == "integer" and once(("integer", label)):
        low, high = resolved["minimum"], resolved["maximum"]
        for number, expect in [(low - 1, "reject"), (low, "accept"), (high, "accept"), (high + 1, "reject")]:
            add("integer.%d" % number, mutated(seed, path, number), expect, "integer bound %d..%d %s" % (low, high, label))
        add("integer.string", mutated(seed, path, str(value)), "reject", "integer type " + label)
        doc = mutated(seed, path, "@@NUMBER@@")
        for lexeme, tag in [("50.0", "fraction"), ("5e1", "exponent"), ("050", "leadingZero"), ("-1", "negative")]:
            add("integer." + tag, canon(doc).replace('"@@NUMBER@@"', lexeme), "reject", "non-canonical integer lexeme " + label, check=False)

    # Strings.
    if isinstance(value, str) and resolved.get("type") == "string" and once(("string", label)):
        limit = resolved.get("x-plainpost-maxUtf8Bytes")
        if limit and name not in ("logicalMailboxID", "port", "uint32Decimal", "positiveDecimal"):
            units = [("x" if name != "host" else "a", "ascii")]
            if name in MULTIBYTE_OK and once(("twoByte", name)):
                units.append(("\u00e9", "twoByte"))
            for unit, tag in units:
                count = limit // len(utf8(unit))
                at_bound = bounded_string(name, count, unit)
                if tag == "twoByte":
                    # One byte over while still far below maxLength code points.
                    over = at_bound + "x"
                else:
                    over = bounded_string(name, count + 1, unit)
                add("maxBytes.%s.atBound" % tag, mutated(seed, path, at_bound), "accept" if accepts(family, mutated(seed, path, at_bound)) else "reject", "%d UTF-8 byte bound %s" % (limit, label))
                add("maxBytes.%s.overBound" % tag, mutated(seed, path, over), "reject", "%d UTF-8 byte bound %s" % (limit, label))
        if resolved.get("minLength", 0) > 0:
            add("empty", mutated(seed, path, ""), "reject", "empty string " + label)
        if name in NUL_REJECT:
            add("nul", mutated(seed, path, "a\u0000b"), "reject", "NUL in string " + label)
        add("type.number", mutated(seed, path, 7), "reject", "string type " + label)

    # Arrays.
    if isinstance(value, list) and "maxItems" in resolved and once(("array", family, label)):
        limit = resolved["maxItems"]
        items = resolve(resolved["items"])
        if "minItems" in resolved:
            low = resolved["minItems"]
            add("minItems.%d" % (low - 1), mutated(seed, path, bounded_items(name, items, path, seed, low - 1)), "reject", "array lower bound %s" % label)
            add("minItems.%d" % low, mutated(seed, path, bounded_items(name, items, path, seed, low)), "accept", "array lower bound %s" % label)
        add("maxItems.atBound", mutated(seed, path, bounded_items(name, items, path, seed, limit)), "accept", "array bound %d items %s" % (limit, label))
        add("maxItems.overBound", mutated(seed, path, bounded_items(name, items, path, seed, limit + 1)), "reject", "array bound %d items %s" % (limit, label))
        add("type.object", mutated(seed, path, {}), "reject", "array type " + label)


def bounded_items(name, items, path, seed, count):
    """Distinct, correctly ordered items so only the count is under test."""
    key = path[-1]
    owner = get_path(seed, path[:-1])
    if key == "accounts":
        result = []
        for i in range(count):
            logical_id = logical([(i >> 8) & 255, i & 255] + [1] * 30)
            result.append({"assignments": [], "logicalMailboxID": logical_id, "primary": i == 0, "providerIdentity": "a%03d@x" % i, "providerKind": "gmail", "state": "ready"})
        return result
    if key == "assignments":
        return [{"displayName": "", "logicalMailboxID": None, "mailboxHandle": "h%03d" % i, "role": "other"} for i in range(count)]
    if key == "memberships":
        return [{"flags": [], "logicalMailboxID": LOGICAL_A, "mailboxPath": "m%03d" % i, "uid": str(i + 1), "uidValidity": "1"} for i in range(count)]
    if key == "records":
        return [{"memberships": [], "messageID": "m%03d" % i, "rfcMessageID": None} for i in range(count)]
    if key == "messageIDs":
        return ["m%03d" % i for i in range(count)]
    if key == "changes":
        return [{"kind": "upsert", "logicalMailboxID": LOGICAL_A, "messageID": "m%03d" % i, "threadID": "t%03d" % i} for i in range(count)]
    if key == "waitingAccounts":
        return [logical([(i >> 8) & 255, i & 255] + [2] * 30) for i in range(count)]
    if key == "flags":
        values = items["enum"]
        return (values * 2)[:count] if count > len(values) else values[:count]
    raise ValueError("no bounded items for " + key)


def family_cases(vectors, family, seed):
    text = canon(seed)
    vectors.add(family + ".seed", family, seed, "accept", "canonical seed")
    doc = copy.deepcopy(seed)
    del doc["kind"]
    vectors.add(family + ".kind.missing", family, doc, "reject", "family kind is required")
    vectors.add(family + ".kind.unknownVersion", family, mutated(seed, ["kind"], seed["kind"].replace(".v1", ".v2")), "reject", "unknown family version")
    other = "node-sync.problem.v1" if family != "mailCapabilities" else "node-sync.mail-accounts-result.v1"
    vectors.add(family + ".kind.otherFamily", family, mutated(seed, ["kind"], other), "reject", "family kind names another family")
    doc = copy.deepcopy(seed)
    doc["unexpected"] = True
    vectors.add(family + ".unknownField", family, doc, "reject", "closed object rejects unknown field")
    first = sorted(seed)[0]
    vectors.add(family + ".duplicateField", family, "{" + canon(first) + ":" + canon(seed[first]) + "," + text[1:], "reject", "duplicate top-level key", check=False)
    vectors.add(family + ".syntax.whitespace", family, text.replace(":", ": ", 1), "reject", "insignificant whitespace is not canonical", check=False)
    vectors.add(family + ".syntax.trailingNewline", family, text + "\n", "reject", "trailing bytes are not canonical", check=False)
    keys = sorted(seed)
    reordered = "{" + ",".join(canon(k) + ":" + canon(seed[k]) for k in reversed(keys)) + "}"
    vectors.add(family + ".syntax.keyOrder", family, reordered, "reject", "object keys sort by UTF-8 bytes", check=False)
    vectors.add(family + ".syntax.topLevelArray", family, "[" + text + "]", "reject", "family must be an object", check=False)
    def once(key):
        # Shared definitions are probed once across families; arrays per family.
        if key in vectors.seen:
            return False
        vectors.seen.add(key)
        return True

    for path, prop in locations(seed, DEFS[family], []):
        field_cases(vectors, family, seed, path, prop, once)


def special_cases(vectors):
    add = vectors.add
    # Logical mailbox identities.
    seed = SEEDS["providerRemoveRequest"]
    for value, tag in [("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "allZero"), (LOGICAL_B + "=", "padded"), (LOGICAL_B[:-1], "short"),
                       (LOGICAL_B[:-1] + "B", "nonCanonicalTrailingBits"), (LOGICAL_B.replace("C", "+"), "standardAlphabet")]:
        add("providerRemoveRequest.logicalMailboxID." + tag, "providerRemoveRequest", mutated(seed, ["logicalMailboxID"], value), "reject", "logical mailbox ID is 32 nonzero bytes in canonical raw base64url")

    # Provider identities: lower-case addr-spec.
    for value, expect, tag in [
        ("Ada@example.test", "reject", "upperCaseLocal"), ("ada@Example.test", "reject", "upperCaseDomain"), ("ada", "reject", "missingAt"),
        ("@example.test", "reject", "emptyLocal"), ("ada@", "reject", "emptyDomain"), ("ada@b@example.test", "reject", "twoAts"),
        ("ada @example.test", "reject", "space"), ("ada@example.test\n", "reject", "trailingNewline"), ("ad\u00e1@example.test", "reject", "nonASCII"),
        ("a.b+tag@mail.example-host.test", "accept", "dotAtom"), ("a@b", "accept", "minimum"),
    ]:
        add("providerRemoveRequest.expectedProviderIdentity.syntax." + tag, "providerRemoveRequest", mutated(seed, ["expectedProviderIdentity"], value), expect, "identity is a lower-case addr-spec of at most 320 bytes")
    accounts = SEEDS["mailAccountsResult"]
    add("mailAccountsResult.accounts.1.providerIdentity.syntax.upperCase", "mailAccountsResult", mutated(accounts, ["accounts", 1, "providerIdentity"], "ADA@example.test"), "reject", "identity is lower-case")
    add("providerImportResult.providerIdentity.syntax.upperCase", "providerImportResult", mutated(SEEDS["providerImportResult"], ["providerIdentity"], "Grace@example.test"), "reject", "identity is lower-case")

    # Credentials: CR, LF and NUL are rejected; invalid UTF-8 never decodes.
    for family, field in [("googleTokenImportRequest", "refreshToken"), ("imapProviderImportRequest", "password"), ("imapProviderImportRequest", "username")]:
        seed = SEEDS[family]
        for char, tag in [("\r", "carriageReturn"), ("\n", "lineFeed"), ("\u0000", "nul"), ("\r\n", "crlf")]:
            add("%s.%s.control.%s" % (family, field, tag), family, mutated(seed, [field], "secret" + char + "value"), "reject", "credential text excludes CR, LF and NUL")
        add("%s.%s.control.tab" % (family, field), family, mutated(seed, [field], "secret\tvalue"), "accept", "other control characters are carried verbatim")
        marker = mutated(seed, [field], "secret@@INVALID@@")
        wire = canon(marker).encode("utf-8").replace(b"@@INVALID@@", b"\xff")
        add("%s.%s.invalidUTF8" % (family, field), family, wire, "reject", "invalid UTF-8 byte sequence", check=False)
        wire = canon(marker).encode("utf-8").replace(b"@@INVALID@@", b"\\ud800")
        add("%s.%s.loneSurrogateEscape" % (family, field), family, wire, "reject", "lone surrogate escape", check=False)
        wire = canon(mutated(seed, [field], "a")).encode("utf-8").replace(b'"a"', b'"\\u0061"')
        add("%s.%s.escapedLetter" % (family, field), family, wire, "reject", "escapes beyond minimal RFC 8259 escaping are not canonical", check=False)

    # Endpoints.
    seed = SEEDS["imapProviderImportRequest"]
    for value, expect, tag in [("0", "reject", "zero"), ("1", "accept", "one"), ("65535", "accept", "max"), ("65536", "reject", "overMax"),
                               ("01", "reject", "leadingZero"), ("993 ", "reject", "trailingSpace"), ("+993", "reject", "plusSign"), ("-1", "reject", "negative")]:
        add("imapProviderImportRequest.imap.port.decimal." + tag, "imapProviderImportRequest", mutated(seed, ["imap", "port"], value), expect, "port is a canonical decimal string 1...65535")
    for value, expect, tag in [("IMAP.example.test", "reject", "upperCase"), ("imap.example.test.", "reject", "trailingDot"), ("-imap.example.test", "reject", "leadingHyphen"),
                               ("imap example.test", "reject", "space"), ("imap_example.test", "reject", "underscore"), ("192.0.2.10", "accept", "ipv4"), ("[2001:db8::1]", "reject", "ipv6Literal"),
                               ("mail", "accept", "singleLabel")]:
        add("imapProviderImportRequest.smtp.host.syntax." + tag, "imapProviderImportRequest", mutated(seed, ["smtp", "host"], value), expect, "host is a lower-case DNS name or IPv4 address of at most 253 bytes")

    # Mailbox role paths are distinct.
    for role in ["archive", "drafts", "sent", "trash"]:
        add("imapProviderImportRequest.roles.duplicate." + role, "imapProviderImportRequest", mutated(seed, ["roles", role], "INBOX"), "reject", "each role names a distinct mailbox path")
    doc = copy.deepcopy(seed)
    del doc["roles"]["archive"]
    doc["roles"]["trash"] = "Drafts"
    add("imapProviderImportRequest.roles.duplicate.withoutArchive", "imapProviderImportRequest", doc, "reject", "each role names a distinct mailbox path")
    add("imapProviderImportRequest.roles.caseDistinct", "imapProviderImportRequest", mutated(seed, ["roles", "archive"], "inbox"), "accept", "paths compare as exact UTF-8 bytes")

    # Capabilities version.
    seed = SEEDS["mailCapabilities"]
    for value, tag in [("2", "two"), ("0", "zero"), ("", "empty"), ("1.0", "fraction"), ("v1", "prefixed")]:
        add("mailCapabilities.version.reject." + tag, "mailCapabilities", mutated(seed, ["version"], value), "reject", "only version 1 decodes")
    add("mailCapabilities.allFalse", "mailCapabilities", {**seed, "googleImport": False, "imapImport": False, "mirrorCoordinates": False, "multiAccount": False}, "accept", "every capability may be absent")

    # Account catalogs.
    seed = SEEDS["mailAccountsResult"]
    empty = mutated(seed, ["accounts"], [])
    add("mailAccountsResult.accounts.empty", "mailAccountsResult", mutated(empty, ["primaryState"], "none"), "accept", "a Node without provider accounts")
    add("mailAccountsResult.accounts.emptyUnavailable", "mailAccountsResult", mutated(empty, ["primaryState"], "unavailable"), "accept", "only an unrepresentable primary account exists")
    add("mailAccountsResult.accounts.emptyAvailable", "mailAccountsResult", empty, "reject", "primaryState available names a listed primary account")
    doc = copy.deepcopy(seed)
    doc["accounts"] = [doc["accounts"][0]]
    doc["primaryState"] = "unavailable"
    add("mailAccountsResult.primaryState.unavailableWithSecondaries", "mailAccountsResult", doc, "accept", "an unrepresentable primary is omitted while secondaries are listed")
    add("mailAccountsResult.primaryState.noneWithAccounts", "mailAccountsResult", mutated(doc, ["primaryState"], "none"), "reject", "primaryState none means no provider accounts")
    add("mailAccountsResult.primaryState.availableWithoutPrimary", "mailAccountsResult", mutated(doc, ["primaryState"], "available"), "reject", "primaryState available names a listed primary account")
    add("mailAccountsResult.primaryState.unavailableWithPrimary", "mailAccountsResult", mutated(seed, ["primaryState"], "unavailable"), "reject", "a listed primary account is available")

    doc = copy.deepcopy(seed)
    doc["accounts"][0]["primary"] = True
    add("mailAccountsResult.primary.two", "mailAccountsResult", doc, "reject", "exactly one primary account")
    doc = copy.deepcopy(seed)
    doc["accounts"][1]["primary"] = False
    add("mailAccountsResult.primary.none", "mailAccountsResult", doc, "reject", "exactly one primary account")
    doc = copy.deepcopy(seed)
    doc["accounts"] = [doc["accounts"][1], doc["accounts"][0]]
    add("mailAccountsResult.order.primaryFirst", "mailAccountsResult", doc, "accept", "the Node chooses account order")
    doc = copy.deepcopy(seed)
    doc["accounts"][0]["logicalMailboxID"] = LOGICAL_A
    add("mailAccountsResult.logicalMailboxID.duplicate", "mailAccountsResult", doc, "reject", "each account is one logical mailbox")
    doc = copy.deepcopy(seed)
    doc["accounts"][0]["providerIdentity"] = "ada@example.test"
    add("mailAccountsResult.providerIdentity.duplicate", "mailAccountsResult", doc, "reject", "each provider identity is bound to one logical mailbox")
    doc = copy.deepcopy(seed)
    doc["accounts"][1]["assignments"][1]["logicalMailboxID"] = LOGICAL_B
    add("mailAccountsResult.assignments.otherLogicalMailbox", "mailAccountsResult", doc, "reject", "assignments belong to their own account")
    add("mailAccountsResult.assignments.authorityEpoch.zero", "mailAccountsResult", mutated(seed, ["accounts", 1, "assignments", 1, "authorityEpoch"], "0"), "reject", "authority epoch is positive")
    doc = copy.deepcopy(SEEDS["providerImportResult"])
    doc["assignments"][0]["logicalMailboxID"] = LOGICAL_A
    add("providerImportResult.assignments.otherLogicalMailbox", "providerImportResult", doc, "reject", "assignments belong to the imported account")
    add("providerImportResult.assignments.empty", "providerImportResult", mutated(SEEDS["providerImportResult"], ["assignments"], []), "accept", "import without assigned mailboxes")

    # All-account delta pages.
    seed = SEEDS["mailDeltaPage"]
    add("mailDeltaPage.waitingAccounts.empty", "mailDeltaPage", mutated(seed, ["waitingAccounts"], []), "accept", "no account is waiting for its first import")
    add("mailDeltaPage.changes.empty", "mailDeltaPage", mutated(seed, ["changes"], []), "accept", "no committed change")
    add("mailDeltaPage.waitingAccounts.unsorted", "mailDeltaPage", mutated(seed, ["waitingAccounts"], [LOGICAL_B, LOGICAL_A[:-1] + "A"]), "reject", "waiting accounts sort by logical mailbox bytes")
    add("mailDeltaPage.waitingAccounts.sorted", "mailDeltaPage", mutated(mutated(seed, ["changes"], []), ["waitingAccounts"], [LOGICAL_A, LOGICAL_B]), "accept", "waiting accounts sort by logical mailbox bytes")
    add("mailDeltaPage.waitingAccounts.duplicate", "mailDeltaPage", mutated(seed, ["waitingAccounts"], [LOGICAL_B, LOGICAL_B]), "reject", "a waiting account is listed once")
    add("mailDeltaPage.changes.namesWaitingAccount", "mailDeltaPage", mutated(seed, ["changes", 2, "logicalMailboxID"], LOGICAL_B), "reject", "a waiting account contributes no change")
    add("mailDeltaPage.revision.zero", "mailDeltaPage", mutated(seed, ["revision"], "0"), "reject", "revision is a positive decimal")
    add("mailDeltaPage.changes.upsertWithoutThread", "mailDeltaPage", mutated(seed, ["changes", 2, "threadID"], None), "reject", "an upsert names its thread")
    for kind in ["epoch_reset", "membership_removed"]:
        add("mailDeltaPage.changes.kind." + kind, "mailDeltaPage", mutated(seed, ["changes", 0, "kind"], kind), "accept", "metadata-only change kind")
    add("mailDeltaPage.changes.kind.unknown", "mailDeltaPage", mutated(seed, ["changes", 0, "kind"], "moved"), "reject", "closed change kind")
    add("mailDeltaPage.changes.tombstoneWithThread", "mailDeltaPage", mutated(seed, ["changes", 1, "threadID"], "gm2.thread-001"), "reject", "a tombstone carries no thread")
    add("mailDeltaPage.changes.baselineWithMessage", "mailDeltaPage", mutated(seed, ["changes", 0, "messageID"], "gm2.message-003"), "reject", "metadata-only changes carry no message")

    # Account snapshot cursors.
    seed = SEEDS["accountSnapshotRequest"]
    add("accountSnapshotRequest.after.opaque", "accountSnapshotRequest", mutated(seed, ["after"], "opaque/+=cursor"), "accept", "opaque continuation cursor")

    # Mirror coordinate requests.
    seed = SEEDS["mirrorCoordinatesRequest"]
    for value, tag in [(["gm2.message-002", "gm2.message-001"], "unsorted"), (["gm2.message-001", "gm2.message-001"], "duplicate"),
                       (["b", "B"], "byteOrder"), (["gm2.message-001", ""], "emptyIdentifier")]:
        add("mirrorCoordinatesRequest.messageIDs." + tag, "mirrorCoordinatesRequest", mutated(seed, ["messageIDs"], value), "reject", "message IDs are 1...200 identifiers sorted by UTF-8 bytes without duplicates")
    add("mirrorCoordinatesRequest.messageIDs.byteOrderAccepted", "mirrorCoordinatesRequest", mutated(seed, ["messageIDs"], ["B", "b"]), "accept", "message IDs sort by UTF-8 bytes")
    add("mirrorCoordinatesRequest.messageIDs.single", "mirrorCoordinatesRequest", mutated(seed, ["messageIDs"], ["gm2.message-001"]), "accept", "one message ID")

    # Mirror coordinate results.
    seed = SEEDS["mirrorCoordinatesResult"]
    membership = ["records", 1, "memberships", 0]
    for field in ["uid", "uidValidity"]:
        for value, expect, tag in [("0", "reject", "zero"), ("1", "accept", "one"), ("4294967295", "accept", "max"), ("4294967296", "reject", "overMax"),
                                   ("01", "reject", "leadingZero"), ("00", "reject", "zeros"), ("-1", "reject", "negative"), ("+7", "reject", "plusSign"), (" 7", "reject", "leadingSpace"),
                                   ("18446744073709551616", "reject", "overUInt64")]:
            add("mirrorCoordinatesResult.%s.decimal.%s" % (field, tag), "mirrorCoordinatesResult", mutated(seed, membership + [field], value), expect, "%s is a canonical decimal 1...4294967295" % field)
        add("mirrorCoordinatesResult.%s.type.number" % field, "mirrorCoordinatesResult", mutated(seed, membership + [field], 42), "reject", "%s is a decimal string" % field)
    for value, expect, tag in [(["seen", "flagged"], "reject", "unsorted"), (["seen", "seen"], "reject", "duplicate"), (["Seen"], "reject", "upperCase"),
                               (["\\Seen"], "reject", "imapSystemFlag"), (["answered", "deleted", "draft", "flagged", "seen"], "accept", "all")]:
        add("mirrorCoordinatesResult.flags." + tag, "mirrorCoordinatesResult", mutated(seed, membership + ["flags"], value), expect, "flags are a sorted unique subset of the closed flag set")
    doc = copy.deepcopy(seed)
    doc["records"] = [doc["records"][1], doc["records"][0]]
    add("mirrorCoordinatesResult.records.unsorted", "mirrorCoordinatesResult", doc, "reject", "records sort by message ID bytes")
    doc = copy.deepcopy(seed)
    doc["records"][0]["messageID"] = doc["records"][1]["messageID"]
    add("mirrorCoordinatesResult.records.duplicate", "mirrorCoordinatesResult", doc, "reject", "one record per message ID")
    doc = copy.deepcopy(seed)
    memberships = doc["records"][1]["memberships"]
    doc["records"][1]["memberships"] = [memberships[1], memberships[0]]
    add("mirrorCoordinatesResult.memberships.unsorted", "mirrorCoordinatesResult", doc, "reject", "memberships sort by logical mailbox bytes, then mailbox path bytes")
    doc = copy.deepcopy(seed)
    doc["records"][1]["memberships"][1]["logicalMailboxID"] = LOGICAL_A
    doc["records"][1]["memberships"][1]["mailboxPath"] = "INBOX"
    add("mirrorCoordinatesResult.memberships.duplicate", "mirrorCoordinatesResult", doc, "reject", "one membership per logical mailbox and path")
    doc = copy.deepcopy(seed)
    doc["records"][1]["memberships"][1]["mailboxPath"] = "INBOX"
    add("mirrorCoordinatesResult.memberships.samePathOtherLogicalMailbox", "mirrorCoordinatesResult", doc, "accept", "the same path in two logical mailboxes is two memberships")
    doc = copy.deepcopy(seed)
    doc["records"][1]["memberships"][1]["logicalMailboxID"] = LOGICAL_A
    add("mirrorCoordinatesResult.memberships.pathOrder", "mirrorCoordinatesResult", doc, "accept", "memberships of one logical mailbox sort by path bytes")
    doc = copy.deepcopy(seed)
    doc["records"][1]["memberships"][0]["mailboxPath"] = "[Gmail]/All Mail"
    doc["records"][1]["memberships"][1]["logicalMailboxID"] = LOGICAL_A
    doc["records"][1]["memberships"][1]["mailboxPath"] = "INBOX"
    add("mirrorCoordinatesResult.memberships.pathOrderReversed", "mirrorCoordinatesResult", doc, "reject", "memberships of one logical mailbox sort by path bytes")
    add("mirrorCoordinatesResult.records.empty", "mirrorCoordinatesResult", mutated(seed, ["records"], []), "accept", "no known messages")
    doc = mutated(seed, ["records", 1, "memberships", 1, "mailboxPath"], "INBOX/\u00e9t\u00e9 <&>")
    add("mirrorCoordinatesResult.mailboxPath.literalCharacters", "mirrorCoordinatesResult", doc, "accept", "slash, <, >, & and non-ASCII stay literal")
    add("mirrorCoordinatesResult.rfcMessageID.empty", "mirrorCoordinatesResult", mutated(seed, ["records", 1, "rfcMessageID"], ""), "reject", "RFC Message-ID is null or nonempty")

    # Whole-document syntax on one family.
    seed = canon(SEEDS["providerRemoveResult"])
    for wire, tag, reason in [
        (b"\xef\xbb\xbf" + seed.encode(), "bom", "byte order mark"), (b"", "empty", "empty body"), (seed.encode() + b"{}", "trailingValue", "trailing JSON value"),
        (seed[:-1].encode(), "unterminated", "unterminated object"), (seed.replace('"', "'").encode(), "singleQuotes", "single quotes"),
        (b'"removed"', "topLevelString", "family must be an object"), (b"null", "topLevelNull", "family must be an object"),
    ]:
        add("providerRemoveResult.syntax." + tag, "providerRemoveResult", wire, "reject", reason, check=False)
    wire = seed.replace('"state"', '"st\\u0061te"')
    add("providerRemoveResult.syntax.escapedKey", "providerRemoveResult", wire, "reject", "escaped keys are not canonical", check=False)
    wire = seed.replace('"state":"removed"', '"state":"removed","st\\u0061te":"absent"')
    add("providerRemoveResult.syntax.escapedDuplicateKey", "providerRemoveResult", wire, "reject", "duplicate key after unescaping", check=False)
    add("providerRemoveResult.syntax.caseAliasKey", "providerRemoveResult", seed.replace('"state"', '"State"'), "reject", "keys are case-sensitive", check=False)


def self_check():
    """Guard the decimal patterns against the integer ranges they encode."""
    port = DEFS["port"]
    uint32 = DEFS["uint32Decimal"]
    for number in list(range(0, 1200)) + list(range(9990, 10010)) + list(range(59990, 60010)) + list(range(64990, 65540)) + [99999]:
        if valid(str(number), port) != (1 <= number <= 65535):
            raise ValueError("port pattern disagrees at %d" % number)
    probes = [0, 1, 9, 10, 999999999, 1000000000, 3999999999, 4000000000, 4199999999, 4200000000, 4289999999, 4290000000,
              4293999999, 4294000000, 4294899999, 4294900000, 4294959999, 4294960000, 4294966999, 4294967000, 4294967199,
              4294967200, 4294967289, 4294967290, 4294967295, 4294967296, 4294967299, 4294967300, 4295000000, 5000000000, 9999999999]
    for number in probes:
        if valid(str(number), uint32) != (1 <= number <= 4294967295):
            raise ValueError("uint32 pattern disagrees at %d" % number)


def main():
    self_check()
    vectors = Vectors()
    if set(SEEDS) != set(FAMILIES) or set(FAMILIES) != {ref_name(v) for v in SCHEMA["oneOf"]}:
        raise ValueError("families, seeds and schema oneOf differ")
    for family in FAMILIES:
        if DEFS[family]["properties"]["kind"]["const"] != FAMILIES[family]:
            raise ValueError("kind constant differs for " + family)
        family_cases(vectors, family, SEEDS[family])
    special_cases(vectors)
    fixture = {
        "kind": "node-sync-v1.mail-mode-vectors",
        "schemaVersion": 1,
        "families": FAMILIES,
        "vectors": vectors.items,
    }
    rendered = json.dumps(fixture, indent=2, ensure_ascii=False) + "\n"
    if "--check" in sys.argv:
        if not FIXTURE_PATH.exists() or FIXTURE_PATH.read_text() != rendered:
            print("node-sync-v1 mail-mode contract vectors are stale; run Scripts/generate-mail-mode-contract-vectors.py", file=sys.stderr)
            return 1
        print("node-sync-v1 mail-mode contract vectors are current: %d vectors" % len(vectors.items))
        return 0
    FIXTURE_PATH.write_text(rendered)
    print("wrote %d vectors" % len(vectors.items))
    return 0


if __name__ == "__main__":
    sys.exit(main())
