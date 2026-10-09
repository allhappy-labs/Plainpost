#!/usr/bin/env python3
"""Derive node-calendar-v1 contract vectors from the closed schema.

The positive canonical families in fixtures/protocol-v1.json are the seeds.
For every schema definition reached from a seed, this generator emits
field-specific accept/reject vectors once: string and identifier bounds,
array bounds and uniqueness, every closed enum value, counters, nullability,
required and unknown/duplicate nested fields, date-time and timezone rules,
family variants, pagination, JSON syntax and oversized input. A small
reference validator for the schema subset confirms each structural
expectation before it is written.

Usage: generate-calendar-contract-vectors.py [--check]
"""

import copy
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent / "Protocol" / "node-calendar-v1"
SCHEMA = json.loads((ROOT / "node-calendar.schema.json").read_text())
FIXTURE_PATH = ROOT / "fixtures" / "protocol-v1.json"
DEFS = SCHEMA["$defs"]
MAX_DOCUMENT = 8 << 20
COUNTER_MAX = 9007199254740991

FAMILY_DEF = {
    "receipt": "receipt", "capabilities": "capabilities", "connectionsRequest": "connectionsRequest",
    "connectionsResult": "connectionsResult", "connectionRequest": "connectionRequest",
    "caldavConnectionRequest": "connectionRequest", "disconnectRequest": "disconnectRequest",
    "connectionResult": "connectionResult", "eventRequest": "eventRequest", "eventResult": "eventResult",
    "windowRequest": "windowRequest", "windowResult": "windowResult", "commandRequest": "commandRequest",
    "commandResult": "commandResult", "operationReadRequest": "operationReadRequest",
    "operationReadResult": "operationReadResult", "invitationReadRequest": "invitationReadRequest",
    "invitationReadResult": "invitationReadResult", "receiptRequest": "receiptRequest",
    "receiptResult": "receiptResult", "invitationRequest": "invitationRequest", "invitationResult": "invitationResult",
}
# Smaller seeds first so each definition's field vectors use the smallest document.
def seed_order(families):
    return sorted(FAMILY_DEF, key=lambda name: (len(families[name]), name))

# Private calendar routes: method, path, request fixture family, result fixture
# family and the Node's request body ceiling in bytes.
ROUTES = [
    {"method": "GET", "path": "/v1/calendar/capabilities", "request": "", "result": "capabilities", "bodyLimit": 0},
    {"method": "POST", "path": "/v1/calendar/connections/read", "request": "connectionsRequest", "result": "connectionsResult", "bodyLimit": 65536},
    {"method": "POST", "path": "/v1/calendar/connections/configure", "request": "connectionRequest", "result": "connectionResult", "bodyLimit": 65536},
    {"method": "POST", "path": "/v1/calendar/connections/disconnect", "request": "disconnectRequest", "result": "connectionResult", "bodyLimit": 65536},
    {"method": "POST", "path": "/v1/calendar/window", "request": "windowRequest", "result": "windowResult", "bodyLimit": 262144},
    {"method": "POST", "path": "/v1/calendar/event", "request": "eventRequest", "result": "eventResult", "bodyLimit": 262144},
    {"method": "POST", "path": "/v1/calendar/invitations", "request": "invitationReadRequest", "result": "invitationReadResult", "bodyLimit": 262144},
    {"method": "POST", "path": "/v1/calendar/commands", "request": "commandRequest", "result": "commandResult", "bodyLimit": 262144},
    {"method": "POST", "path": "/v1/calendar/operations/read", "request": "operationReadRequest", "result": "operationReadResult", "bodyLimit": 262144},
]

NO_NUL = "^[^\\u0000]*$"
TIMEZONE = "^[A-Za-z0-9_+/-]+$"
DATE_TIME = re.compile(r"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(Z|([+-])(\d{2}):(\d{2}))$")


def canon(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def resolve(node):
    while "$ref" in node:
        node = DEFS[node["$ref"].split("/")[-1]]
    return node


def ref_name(node):
    return node["$ref"].split("/")[-1] if "$ref" in node else None


def valid_date_time(text):
    match = DATE_TIME.match(text)
    if not match:
        return False
    year, month, day, hour, minute, second = (int(match.group(i)) for i in range(1, 7))
    if not (1 <= month <= 12 and hour <= 23 and minute <= 59 and second <= 59):
        return False
    leap = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)
    days = [31, 29 if leap else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
    if not 1 <= day <= days:
        return False
    if match.group(7) != "Z":
        offset_hour, offset_minute = int(match.group(9)), int(match.group(10))
        if offset_hour > 23 or offset_minute > 59 or (offset_hour == 0 and offset_minute == 0):
            return False
    return True


def type_ok(value, name):
    return {
        "string": isinstance(value, str), "boolean": isinstance(value, bool), "null": value is None,
        "integer": isinstance(value, int) and not isinstance(value, bool),
        "object": isinstance(value, dict), "array": isinstance(value, list),
    }[name]


def valid(value, node):
    """Reference validator for the schema subset used by node-calendar-v1."""
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
        if "pattern" in node:
            if node["pattern"] == NO_NUL:
                if "\x00" in value:
                    return False
            elif node["pattern"] == TIMEZONE:
                if not re.fullmatch(r"[A-Za-z0-9_+/-]+", value):
                    return False
            else:
                raise ValueError("unsupported pattern " + node["pattern"])
        if node.get("format") == "date-time" and not valid_date_time(value):
            return False
    if isinstance(value, int) and not isinstance(value, bool):
        if value < node.get("minimum", value) or value > node.get("maximum", value):
            return False
    if isinstance(value, list):
        if len(value) > node.get("maxItems", len(value)):
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
            elif isinstance(node.get("additionalProperties"), dict) and not valid(child, node["additionalProperties"]):
                return False
            if "propertyNames" in node and not valid(key, node["propertyNames"]):
                return False
    if "oneOf" in node and sum(1 for v in node["oneOf"] if valid(value, v)) != 1:
        return False
    if "anyOf" in node and not any(valid(value, v) for v in node["anyOf"]):
        return False
    if "not" in node and valid(value, node["not"]):
        return False
    return True


class Cases:
    def __init__(self):
        self.items = []
        self.names = set()

    def add(self, name, family, wire, expect, reason, expand=None, canonical=False, check=True):
        if name in self.names:
            raise ValueError("duplicate case " + name)
        if isinstance(wire, str):
            text = wire
        else:
            text = canon(wire)
        if check and expand is None and not isinstance(wire, str):
            schema_valid = valid(wire, DEFS[FAMILY_DEF[family]])
            if schema_valid != (expect == "accept"):
                raise ValueError("reference validator disagrees with %s (%s)" % (name, reason))
        case = {"name": name, "family": family, "expect": expect, "reason": reason, "wire": text}
        if expand:
            case["expand"] = expand
            if expect == "accept" and expanded_size(text, expand) > MAX_DOCUMENT:
                raise ValueError("accept case exceeds document bound: " + name)
        if canonical:
            case["canonical"] = True
        self.names.add(name)
        self.items.append(case)


def expansion(token, unit, count, separator=""):
    """One ordered byte expansion: token -> unit*count joined by separator.

    "{i}" in unit becomes a five-digit zero-padded index. unitHex carries raw
    bytes (for invalid UTF-8) instead of unit text."""
    spec = {"token": token, "count": count}
    if isinstance(unit, bytes):
        spec["unitHex"] = unit.hex()
    else:
        spec["unit"] = unit
    if separator:
        spec["separator"] = separator
    return spec


def expand_bytes(text, expand):
    data = text.encode()
    for spec in expand:
        unit = bytes.fromhex(spec["unitHex"]) if "unitHex" in spec else spec["unit"].encode()
        units = [unit.replace(b"{i}", b"%05d" % index) for index in range(spec["count"])]
        data = data.replace(spec["token"].encode(), spec.get("separator", "").encode().join(units))
    return data


def expanded_size(text, expand):
    return len(expand_bytes(text, expand))


def expand_text(text, expand):
    return expand_bytes(text, expand).decode()


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


def locations(value, node, path, owner):
    """Yield (path, property node, owning definition, property key) for each value."""
    name = ref_name(node) or owner
    resolved = resolve(node)
    for combiner in ("oneOf", "anyOf"):
        if combiner in resolved:
            for variant in resolved[combiner]:
                if valid(value, variant):
                    yield from locations(value, variant, path, ref_name(variant) or name)
                    break
    if isinstance(value, dict):
        for key, child in sorted(value.items()):
            prop = resolved.get("properties", {}).get(key)
            if prop is None:
                continue
            yield path + [key], prop, name, key
            yield from locations(child, prop, path + [key], name)
    if isinstance(value, list) and "items" in resolved:
        for index, child in enumerate(value[:1]):
            yield from locations(child, resolved["items"], path + [index], name)


def string_constraints(node):
    """Merge a string property's own constraints (following $ref)."""
    merged = {}
    for part in [node, resolve(node)]:
        for key in ("maxLength", "minLength", "pattern", "enum", "const", "format", "type"):
            if key in part:
                merged[key] = part[key]
    return merged


def main():
    fixture = json.loads(FIXTURE_PATH.read_text())
    families = fixture["families"]
    cases = Cases()
    seen = set()

    def once(key):
        if key in seen:
            return False
        seen.add(key)
        return True

    for family in seed_order(families):
        seed = json.loads(families[family])
        root_def = FAMILY_DEF[family]
        root = {"$ref": "#/$defs/" + root_def}
        if not valid(seed, root):
            raise ValueError("seed does not validate: " + family)
        cases.add(family + ".seed", family, families[family], "accept", "canonical seed", canonical=True, check=False)
        # Family-level variants.
        if "kind" in seed:
            doc = copy.deepcopy(seed)
            del doc["kind"]
            cases.add(family + ".kind.missing", family, doc, "reject", "family kind is required")
            doc = copy.deepcopy(seed)
            doc["kind"] = "node-calendar.problem.v1"
            cases.add(family + ".kind.wrongVariant", family, doc, "reject", "family kind names another variant")
            doc = copy.deepcopy(seed)
            doc["kind"] = seed["kind"].replace(".v1", ".v2")
            cases.add(family + ".kind.unknownVersion", family, doc, "reject", "unknown family version")
        text = families[family]
        cases.add(family + ".syntax.whitespace", family, "\n " + text.replace(",", ", ").replace(":", ": ", 1) + "\t", "accept", "insignificant whitespace is accepted but not canonical", check=False)
        doc = copy.deepcopy(seed)
        doc["unexpected"] = True
        cases.add(family + ".unknownField", family, doc, "reject", "closed object rejects unknown field")
        first = sorted(seed)[0]
        cases.add(family + ".duplicateField", family, "{" + canon(first) + ":" + canon(seed[first]) + "," + text[1:], "reject", "duplicate top-level key", check=False)
        for path, prop, owner, key in locations(seed, root, [], root_def):
            value = get_path(seed, path)
            parent = get_path(seed, path[:-1])
            parent_node = None
            label = "%s.%s" % (owner, key) if isinstance(key, str) else owner
            base = "%s.%s" % (family, path_name(path))
            constraints = string_constraints(prop)
            resolved = resolve(prop)
            # Required and unknown/duplicate nested fields.
            if isinstance(key, str) and key != "kind" and once(("required", label)):
                doc = copy.deepcopy(seed)
                delete_path(doc, path)
                owner_node = None
                expect = "accept" if valid(doc, root) else "reject"
                cases.add(base + ".missing", family, doc, expect, "required field " + label)
            if isinstance(value, dict) and resolved.get("additionalProperties") is False and value and once(("nested", ref_name(prop) or label)):
                doc = copy.deepcopy(seed)
                get_path(doc, path)["unexpected"] = True
                cases.add(base + ".unknownField", family, doc, "reject", "closed nested object " + label)
                nested_first = sorted(value)[0]
                doc = copy.deepcopy(seed)
                get_path(doc, path)["@@DUPLICATE@@"] = None
                wire = canon(doc).replace('"@@DUPLICATE@@":null,', canon(nested_first) + ":" + canon(value[nested_first]) + ",", 1)
                cases.add(base + ".duplicateField", family, wire, "reject", "duplicate nested key " + label, check=False)
            # Closed enums: every value and a near miss.
            enum = resolved.get("enum")
            if enum and all(isinstance(e, str) for e in enum) and once(("enum", label)):
                for option in enum:
                    doc = copy.deepcopy(seed)
                    set_path(doc, path, option)
                    if valid(doc, root):
                        cases.add("%s.enum.%s" % (base, option or "empty"), family, doc, "accept", "closed enum value " + label, canonical=True)
                for miss in ["unknown", (enum[-1] or "x").upper(), " " + (enum[0] or "x")]:
                    doc = copy.deepcopy(seed)
                    set_path(doc, path, miss)
                    cases.add("%s.enum.reject.%s" % (base, re.sub(r"[^A-Za-z0-9]", "_", miss)), family, doc, "reject", "value outside closed enum " + label)
            if resolved.get("type") == "array" and isinstance(resolved.get("items"), dict) and "enum" in resolve(resolved["items"]) and once(("enumItems", label)):
                for option in resolve(resolved["items"])["enum"]:
                    doc = copy.deepcopy(seed)
                    set_path(doc, path, [option])
                    cases.add("%s.enum.%s" % (base, option), family, doc, "accept", "closed enum item " + label, canonical=True)
                doc = copy.deepcopy(seed)
                set_path(doc, path, ["exchange"])
                cases.add(base + ".enum.reject.item", family, doc, "reject", "array item outside closed enum " + label)
                if resolved.get("uniqueItems"):
                    doc = copy.deepcopy(seed)
                    set_path(doc, path, [resolve(resolved["items"])["enum"][0]] * 2)
                    cases.add(base + ".uniqueItems", family, doc, "reject", "duplicate closed enum items " + label)
            # Counters.
            if resolved.get("type") == "integer" and once(("counter", label)):
                for number, expect, reason in [(0, "accept", "minimum counter"), (COUNTER_MAX, "accept", "maximum safe counter"), (COUNTER_MAX + 1, "reject", "unsafe counter"), (-1, "reject", "negative counter")]:
                    doc = copy.deepcopy(seed)
                    set_path(doc, path, number)
                    cases.add("%s.counter.%s" % (base, str(number).replace("-", "minus")), family, doc, expect, reason + " " + label, canonical=expect == "accept")
                for lexeme, tag in [("1.0", "fraction"), ("1e0", "exponent"), ("01", "leadingZero"), ('"1"', "string"), ("-0", "negativeZero"), ("true", "boolean"), ("null", "null")]:
                    doc = copy.deepcopy(seed)
                    set_path(doc, path, "@@NUMBER@@")
                    cases.add("%s.counter.%s" % (base, tag), family, canon(doc).replace('"@@NUMBER@@"', lexeme), "reject", "non-canonical counter lexeme " + label, check=False)
            # Booleans.
            if resolved.get("type") == "boolean" and once(("boolean", label)):
                for lexeme, tag in [("1", "number"), ('"true"', "string"), ("null", "null")]:
                    doc = copy.deepcopy(seed)
                    set_path(doc, path, "@@BOOLEAN@@")
                    cases.add("%s.boolean.%s" % (base, tag), family, canon(doc).replace('"@@BOOLEAN@@"', lexeme), "reject", "boolean type " + label, check=False)
            # Strings.
            if isinstance(value, str) and "enum" not in constraints and "const" not in constraints:
                if "maxLength" in constraints and constraints.get("format") is None and constraints.get("pattern") in (None, NO_NUL) and once(("string", label)):
                    limit = constraints["maxLength"]
                    for unit, tag in [("x", "ascii"), ("\u00e9", "twoByte"), ("\U0001F600", "fourByte")]:
                        for count, expect in [(limit, "accept"), (limit + 1, "reject")]:
                            doc = copy.deepcopy(seed)
                            set_path(doc, path, "@@STRING@@")
                            probe = copy.deepcopy(seed)
                            set_path(probe, path, unit * count)
                            if expect == "accept" and not valid(probe, root):
                                continue
                            if expect == "reject" and valid(probe, root):
                                raise ValueError("bound probe unexpectedly valid " + base)
                            cases.add("%s.maxLength.%s.%s" % (base, tag, "atBound" if expect == "accept" else "overBound"), family, canon(doc), expect, "%s bound %d code points for %s" % (tag, limit, label), expand=[expansion("@@STRING@@", unit, count)], canonical=expect == "accept")
                    if constraints.get("minLength", 0) > 0:
                        doc = copy.deepcopy(seed)
                        set_path(doc, path, "")
                        cases.add(base + ".minLength", family, doc, "reject", "empty identifier " + label)
                    doc = copy.deepcopy(seed)
                    set_path(doc, path, "a\u0000b")
                    cases.add(base + ".nul", family, doc, "reject", "NUL is rejected in every string " + label, check=constraints.get("pattern") == NO_NUL)
                    doc = copy.deepcopy(seed)
                    set_path(doc, path, 7)
                    cases.add(base + ".type.number", family, doc, "reject", "string type " + label)
                if constraints.get("format") == "date-time" and once(("dateTime", label)):
                    for text_value, expect, tag in [("2026-10-25T02:00:00+01:00", "accept", "offset"), ("2028-02-29T23:59:59Z", "accept", "leapDay"),
                                                    ("2026-10-25T00:00:00.000Z", "reject", "fraction"), ("2026-10-25t00:00:00z", "reject", "lowercase"),
                                                    ("2026-10-25T00:00:00+00:00", "reject", "zeroOffset"), ("2026-02-30T00:00:00Z", "reject", "invalidDay"),
                                                    ("2026-10-25T24:00:00Z", "reject", "hour24"), ("2026-10-25T23:59:60Z", "reject", "leapSecond"),
                                                    ("2026-10-25T00:00:00", "reject", "missingOffset"), ("2026-10-25", "reject", "dateOnly"), ("2026-10-25T00:00:00+24:00", "reject", "offsetHour")]:
                        doc = copy.deepcopy(seed)
                        set_path(doc, path, text_value)
                        cases.add("%s.dateTime.%s" % (base, tag), family, doc, expect, "strict RFC 3339 profile " + label, canonical=expect == "accept")
                if constraints.get("pattern") == TIMEZONE and once(("timezone", label)):
                    in_calendar_time = isinstance(parent, dict) and "value" in parent and "kind" in parent
                    for text_value, expect, tag, check in [("Etc/GMT+5", "accept", "digits", True), ("America/Port-au-Prince", "accept", "hyphen", True),
                                                          ("Europe/Z\u00fcrich", "reject", "nonAscii", True), ("Bad Zone", "reject", "space", True), ("", "reject", "empty", True),
                                                          ("A" * 256, "reject", "overBound", True)] + ([("Mars/Olympus", "reject", "unknownZone", False), ("Local", "reject", "localZone", False), ("GMT+5", "reject", "gmtOffsetAlias", False), ("UTC-3", "reject", "utcOffsetAlias", False), ("europe/zurich", "reject", "nonCanonicalCase", False), ("EUROPE/ZURICH", "reject", "upperCase", False), ("EST", "accept", "legacyLink", True)] if in_calendar_time else []):
                        doc = copy.deepcopy(seed)
                        set_path(doc, path, text_value)
                        cases.add("%s.timezone.%s" % (base, tag), family, doc, expect, ("calendar time zone must be a known IANA name " if not check else "timezone syntax ") + label, canonical=expect == "accept", check=check)
            # Nullability.
            prop_types = resolved.get("type") if isinstance(resolved.get("type"), list) else None
            nullable = (prop_types and "null" in prop_types) or any(resolve(v).get("type") == "null" for v in resolved.get("oneOf", []))
            if isinstance(key, str) and once(("null", label)):
                doc = copy.deepcopy(seed)
                set_path(doc, path, None)
                if nullable:
                    cases.add(base + ".null", family, doc, "accept", "nullable field " + label, canonical=True)
                elif value is not None:
                    cases.add(base + ".null", family, doc, "reject", "non-nullable field " + label)
            # Arrays: bounds and uniqueness.
            if isinstance(value, list) and "maxItems" in resolved and once(("array", label)):
                limit = resolved["maxItems"]
                items = resolve(resolved["items"])
                if value:
                    unit = canon(value[0])
                    if resolved.get("uniqueItems"):
                        if not isinstance(value[0], str):
                            raise ValueError("unique non-string array " + base)
                        unit = canon(value[0][:40] + "-{i}")
                elif items.get("type") == "string" or "$ref" in resolved["items"]:
                    unit = canon("item-{i}")
                else:
                    unit = None
                if unit is not None:
                    doc = copy.deepcopy(seed)
                    set_path(doc, path, "@@ARRAY@@")
                    wire = canon(doc).replace('"@@ARRAY@@"', "[@@ITEMS@@]")
                    for count, expect in [(limit, "accept"), (limit + 1, "reject")]:
                        spec = [expansion("@@ITEMS@@", unit, count, ",")]
                        size = expanded_size(wire, spec)
                        if expect == "accept" and size > MAX_DOCUMENT:
                            continue
                        probe = json.loads(expand_text(wire, spec))
                        if valid(probe, root) != (expect == "accept"):
                            raise ValueError("array bound probe disagrees " + base)
                        cases.add("%s.maxItems.%s" % (base, "atBound" if expect == "accept" else "overBound"), family, wire, expect, "array bound %d items for %s" % (limit, label), expand=spec, canonical=expect == "accept")
                if resolved.get("uniqueItems") and value and isinstance(value[0], str):
                    doc = copy.deepcopy(seed)
                    set_path(doc, path, [value[0], value[0]])
                    cases.add(base + ".uniqueItems", family, doc, "reject", "duplicate identifiers " + label)
    add_special(cases, families)
    fixture["routes"] = ROUTES
    fixture["cases"] = cases.items
    rendered = json.dumps(fixture, indent=2, ensure_ascii=False) + "\n"
    if "--check" in sys.argv:
        if FIXTURE_PATH.read_text() != rendered:
            print("node-calendar-v1 contract vectors are stale; run Scripts/generate-calendar-contract-vectors.py", file=sys.stderr)
            return 1
        print("node-calendar-v1 contract vectors are current: %d cases" % len(cases.items))
        return 0
    FIXTURE_PATH.write_text(rendered)
    print("wrote %d cases" % len(cases.items))
    return 0


def add_special(cases, families):
    event_request = families["eventRequest"]
    seed = json.loads(event_request)
    # JSON syntax and encoding.
    for name, wire, expect, reason in [
        ("syntax.bom", "\ufeff" + event_request, "reject", "byte order mark"),
        ("syntax.trailingValue", event_request + "{}", "reject", "trailing JSON value"),
        ("syntax.trailingGarbage", event_request + " x", "reject", "trailing bytes"),
        ("syntax.empty", "", "reject", "empty body"),
        ("syntax.whitespaceOnly", " \n", "reject", "whitespace only"),
        ("syntax.topLevelArray", "[" + event_request + "]", "reject", "family must be an object"),
        ("syntax.topLevelString", '"event-001"', "reject", "family must be an object"),
        ("syntax.unterminated", event_request[:-1], "reject", "unterminated object"),
        ("syntax.trailingComma", event_request[:-1] + ",}", "reject", "trailing comma"),
        ("syntax.singleQuotes", event_request.replace('"', "'"), "reject", "single quotes"),
        ("syntax.invalidEscape", event_request.replace("event-001", "event\\x001"), "reject", "invalid escape"),
        ("syntax.rawControl", event_request.replace("event-001", "event\u0001001"), "reject", "unescaped control character"),
        ("syntax.loneHighSurrogate", event_request.replace("event-001", "event\\ud800"), "reject", "lone high surrogate escape"),
        ("syntax.loneLowSurrogate", event_request.replace("event-001", "event\\udc00"), "reject", "lone low surrogate escape"),
        ("syntax.reversedSurrogates", event_request.replace("event-001", "event\\ude00\\ud83d"), "reject", "reversed surrogate escapes"),
        ("syntax.surrogatePair", event_request.replace("event-001", "event\\ud83d\\ude00"), "accept", "escaped surrogate pair"),
        ("syntax.escapedSolidus", event_request.replace("event-001", "event\\/001"), "accept", "escaped solidus"),
        ("syntax.escapedKeyDuplicate", event_request.replace('"eventID":"event-001"', '"eventID":"event-001","event\\u0049D":"event-002"'), "reject", "duplicate key after unescaping"),
        ("syntax.escapedKnownKey", event_request.replace('"eventID"', '"event\\u0049D"'), "accept", "escaped key names the known field"),
        ("syntax.caseAliasKey", event_request.replace('"eventID"', '"EventID"'), "reject", "keys are case-sensitive"),
        ("syntax.nanLiteral", event_request.replace('"event-001"', "NaN"), "reject", "non-JSON literal"),
        ("syntax.deepNesting", event_request[:-1] + ',"unexpected":' + "[" * 128 + "]" * 128 + "}", "reject", "deep nesting in unknown field"),
    ]:
        cases.add("eventRequest." + name, "eventRequest", wire, expect, reason, check=False)
    # Invalid UTF-8 is carried as a Latin-1 marker the harness converts to raw bytes.
    cases.add("eventRequest.syntax.invalidUTF8", "eventRequest", event_request.replace("event-001", "event@@INVALID_UTF8@@"), "reject", "invalid UTF-8 byte sequence", expand=[expansion("@@INVALID_UTF8@@", b"\xff", 1)], check=False)
    title = json.loads(families["eventResult"])
    for escaped, tag in [("\\u0001", "controlEscape"), ("\\u2028", "lineSeparator"), ("\\u00e9", "escapedLatin"), ("\\\"", "quote"), ("\\n", "newline")]:
        wire = families["eventResult"].replace('"title":"Planning"', '"title":"Plan' + escaped + 'ning"')
        cases.add("eventResult.canonical.title." + tag, "eventResult", wire, "accept", "canonical string escaping is identical across codecs", check=False)
    # Oversized input: a document above 8 MiB whose fields are individually in bounds.
    window = json.loads(families["windowResult"])
    event = window["events"][0]
    event["notes"] = "@@NOTES@@"
    window["events"] = ["@@EVENT@@"]
    wire = canon(window).replace('"@@EVENT@@"', "@@EVENTS@@")
    unit = canon(event)
    for count, expect in [(7, "accept"), (8, "reject")]:
        # Expansion order matters: events first, then every notes token.
        spec = [expansion("@@EVENTS@@", unit, count, ","), expansion("@@NOTES@@", "n", 1 << 20)]
        size = expanded_size(wire, spec)
        if (size <= MAX_DOCUMENT) != (expect == "accept"):
            raise ValueError("oversized input probe size %d" % size)
        cases.add("windowResult.oversizedInput.%dEvents" % count, "windowResult", wire, expect, "document size bound %d bytes (size %d)" % (MAX_DOCUMENT, size), expand=spec, check=False)
    # Pagination.
    for cursor, expect, tag in [("", "accept", "empty"), ("opaque/+=cursor", "accept", "opaque")]:
        doc = json.loads(families["windowRequest"])
        doc["cursor"] = cursor
        cases.add("windowRequest.pagination.cursor." + tag, "windowRequest", doc, expect, "window cursor", canonical=True)
        doc = json.loads(families["windowResult"])
        doc["nextCursor"] = cursor
        cases.add("windowResult.pagination.nextCursor." + tag, "windowResult", doc, expect, "window continuation", canonical=True)
    doc = json.loads(families["windowResult"])
    doc["events"] = []
    doc["nextCursor"] = ""
    cases.add("windowResult.pagination.emptyFinalPage", "windowResult", doc, "accept", "empty final page", canonical=True)
    for family, field in [("windowRequest", "cursor"), ("windowResult", "nextCursor")]:
        doc = json.loads(families[family])
        del doc[field]
        cases.add("%s.pagination.%s.missing" % (family, field), family, doc, "reject", "pagination field is required")
    doc = json.loads(families["windowResult"])
    doc["failures"] = {"4a7f52f8-0b83-4ce5-b4cc-9646a22e84ba": "unavailable"}
    cases.add("windowResult.failures.connection", "windowResult", doc, "accept", "per-connection failure", canonical=True)
    doc["failures"] = {"4a7f52f8-0b83-4ce5-b4cc-9646a22e84ba": 1}
    cases.add("windowResult.failures.valueType", "windowResult", doc, "reject", "failure value must be a string")
    doc["failures"] = {"": "unavailable"}
    cases.add("windowResult.failures.emptyKey", "windowResult", doc, "reject", "failure key must be an identifier")
    doc["failures"] = {"@@KEY@@": "unavailable"}
    for count, expect in [(512, "accept"), (513, "reject")]:
        cases.add("windowResult.failures.keyBound.%d" % count, "windowResult", canon(doc), expect, "failure key identifier bound", expand=[expansion("@@KEY@@", "k", count)], canonical=expect == "accept", check=False)
    doc = json.loads(families["windowResult"])
    doc["failures"] = {"c": "x" * 513}
    cases.add("windowResult.failures.valueBound", "windowResult", doc, "reject", "failure value bound")
    # Route-body unions.
    command = json.loads(families["commandRequest"])
    both = copy.deepcopy(command)
    both["command"]["response"] = "accepted"
    cases.add("commandRequest.union.editAndResponse", "commandRequest", both, "reject", "command carries exactly one of edit or response")
    neither = copy.deepcopy(command)
    del neither["command"]["edit"]
    cases.add("commandRequest.union.neither", "commandRequest", neither, "reject", "command requires edit or response")
    edit_invitation = copy.deepcopy(command)
    edit_invitation["command"]["invitationID"] = "invitation-001"
    cases.add("commandRequest.union.editWithInvitation", "commandRequest", edit_invitation, "reject", "edits never name an invitation")
    response = copy.deepcopy(command)
    del response["command"]["edit"]
    response["command"]["response"] = "accepted"
    response["command"]["invitationID"] = "invitation-001"
    cases.add("commandRequest.union.response", "commandRequest", response, "accept", "response command", canonical=True)
    targeted = copy.deepcopy(response)
    targeted["command"]["targetCalendarID"] = "calendar-002"
    cases.add("commandRequest.targetCalendarID.present", "commandRequest", targeted, "accept", "response names the destination calendar", canonical=True)
    targeted_null = copy.deepcopy(response)
    targeted_null["command"]["targetCalendarID"] = None
    cases.add("commandRequest.targetCalendarID.null", "commandRequest", targeted_null, "reject", "omitted, never null, destination calendar")
    targeted_empty = copy.deepcopy(response)
    targeted_empty["command"]["targetCalendarID"] = ""
    cases.add("commandRequest.targetCalendarID.empty", "commandRequest", targeted_empty, "reject", "destination calendar is an identifier")
    # A first page may ask to refresh; the member is present only as true.
    for tag, value, expect in [("true", True, "accept"), ("false", False, "reject"), ("null", None, "reject"), ("string", "true", "reject")]:
        doc = json.loads(families["windowRequest"])
        doc["refresh"] = value
        cases.add("windowRequest.refresh." + tag, "windowRequest", doc, expect, "refresh is omitted or true", canonical=expect == "accept")
    for option in ["needsAction", "accepted", "tentative", "declined"]:
        doc = copy.deepcopy(response)
        doc["command"]["response"] = option
        cases.add("commandRequest.union.response." + option, "commandRequest", doc, "accept", "closed response enum", canonical=True)
    for option in ["", "ACCEPTED", "maybe"]:
        doc = copy.deepcopy(response)
        doc["command"]["response"] = option
        cases.add("commandRequest.union.response.reject." + (option or "empty"), "commandRequest", doc, "reject", "response outside closed enum")
    empty_invitation = copy.deepcopy(response)
    empty_invitation["command"]["invitationID"] = ""
    cases.add("commandRequest.union.responseWithoutInvitation", "commandRequest", empty_invitation, "reject", "responses name their invitation")
    # Edit time: an unchanged start/end pair is the explicit empty date_time sentinel.
    unchanged = copy.deepcopy(command)
    for field in ("start", "end"):
        unchanged["command"]["edit"][field] = {"kind": "date_time", "timezone": "", "value": ""}
    cases.add("commandRequest.edit.unchangedTime", "commandRequest", unchanged, "accept", "title-only and series safe-field edits keep the provider time", canonical=True)
    for tag, sentinel in [
        ("dateKind", {"kind": "date", "timezone": "", "value": ""}),
        ("timezoneOnly", {"kind": "date_time", "timezone": "Europe/Zurich", "value": ""}),
        ("valueOnly", {"kind": "date_time", "timezone": "", "value": "2026-10-25T09:30:00"}),
    ]:
        doc = copy.deepcopy(unchanged)
        doc["command"]["edit"]["start"] = sentinel
        cases.add("commandRequest.edit.unchangedTime.reject." + tag, "commandRequest", doc, "reject", "the unchanged sentinel is exactly empty date_time")
    for tag, source in [("calendarTime", command), ("unchangedTime", unchanged)]:
        doc = copy.deepcopy(source)
        doc["command"]["edit"]["end"]["unexpected"] = True
        cases.add("commandRequest.edit.end.unknownField." + tag, "commandRequest", doc, "reject", "both edit time variants are closed objects")
    # Floating event times keep no zone: an offset-free wall value with an empty timezone.
    floating_ok = {"kind": "date_time", "timezone": "", "value": "2026-10-25T09:30:00"}
    # The strict wall-time profile is a codec rule beyond the reference schema subset.
    for tag, value, expect, check in [
        ("accept", floating_ok, "accept", True),
        ("offset", {"kind": "date_time", "timezone": "", "value": "2026-10-25T09:30:00Z"}, "reject", True),
        ("dateKind", {"kind": "date", "timezone": "", "value": "2026-10-25"}, "reject", True),
        ("invalidDay", {"kind": "date_time", "timezone": "", "value": "2026-02-30T09:30:00"}, "reject", False),
        ("lowercase", {"kind": "date_time", "timezone": "", "value": "2026-10-25t09:30:00"}, "reject", False),
    ]:
        doc = json.loads(families["windowResult"])
        doc["events"][0]["start"] = copy.deepcopy(value)
        doc["events"][0]["end"] = copy.deepcopy(value) if expect == "accept" else doc["events"][0]["end"]
        cases.add("windowResult.floatingTime." + tag, "windowResult", doc, expect, "floating event times are offset-free wall values without a zone", canonical=expect == "accept", check=check)
        doc = json.loads(families["invitationReadResult"])
        doc["invitations"][0]["start"] = copy.deepcopy(value)
        cases.add("invitationReadResult.floatingTime." + tag, "invitationReadResult", doc, expect, "floating invitation times are never labelled with a zone", canonical=expect == "accept", check=check)
    doc = copy.deepcopy(command)
    doc["command"]["edit"]["start"] = copy.deepcopy(floating_ok)
    cases.add("commandRequest.edit.floatingTime.reject", "commandRequest", doc, "reject", "edits always name the zone they were made in")
    google = json.loads(families["connectionRequest"])
    caldav = json.loads(families["caldavConnectionRequest"])
    mixed = copy.deepcopy(google)
    mixed["command"]["kind"] = "caldav"
    cases.add("connectionRequest.union.kindMismatch", "connectionRequest", mixed, "reject", "provider kind selects its configuration")
    both_config = copy.deepcopy(google)
    both_config["command"]["configuration"]["caldav"] = caldav["command"]["configuration"]["caldav"]
    cases.add("connectionRequest.union.bothConfigurations", "connectionRequest", both_config, "reject", "exactly one provider configuration")
    empty_config = copy.deepcopy(google)
    empty_config["command"]["configuration"] = {}
    cases.add("connectionRequest.union.emptyConfiguration", "connectionRequest", empty_config, "reject", "configuration is a closed union")
    update = copy.deepcopy(google)
    update["command"]["connectionID"] = "4a7f52f8-0b83-4ce5-b4cc-9646a22e84ba"
    update["command"]["expectedGeneration"] = 1
    update["command"]["sendingMailboxID"] = "mailbox-001"
    update["command"]["attendeeAddress"] = "owner@example.test"
    cases.add("connectionRequest.update", "connectionRequest", update, "accept", "update names an existing connection", canonical=True)
    null_connection = copy.deepcopy(google)
    null_connection["command"]["connectionID"] = None
    cases.add("connectionRequest.connectionID.null", "connectionRequest", null_connection, "reject", "omitted, never null, connection ID")
    origins = copy.deepcopy(caldav)
    origins["command"]["configuration"]["caldav"]["approvedRedirectOrigins"] = ["https://calendar.example.test"]
    cases.add("caldavConnectionRequest.origins", "caldavConnectionRequest", origins, "accept", "approved same-origin redirect", canonical=True)
    capabilities = json.loads(families["capabilities"])
    capabilities["providers"] = []
    cases.add("capabilities.providers.empty", "capabilities", capabilities, "accept", "no providers", canonical=True)
    capabilities["providers"] = ["google", "caldav", "google"]
    cases.add("capabilities.providers.duplicate", "capabilities", capabilities, "reject", "providers are unique")
    # Google availability: the non-secret Desktop-app client ID is present exactly
    # when the Node has a configured client.
    capabilities = json.loads(families["capabilities"])
    unconfigured = copy.deepcopy(capabilities)
    unconfigured["google"] = {"clientID": None, "configured": False}
    cases.add("capabilities.google.unconfigured", "capabilities", unconfigured, "accept", "Node without a Google client", canonical=True)
    for tag, google, reason in [
        ("configuredWithoutClient", {"clientID": None, "configured": True}, "a configured client names its client ID"),
        ("unconfiguredWithClient", {"clientID": "client", "configured": False}, "an unconfigured Node names no client ID"),
        ("emptyClient", {"clientID": "", "configured": True}, "client ID is an identifier"),
        ("missingClient", {"configured": False}, "client ID member is always present"),
        ("missingConfigured", {"clientID": None}, "configured member is always present"),
        ("unknownField", {"clientID": None, "clientSecret": "secret", "configured": False}, "no secret or other member is carried"),
        ("configuredString", {"clientID": None, "configured": "false"}, "configured is a boolean"),
    ]:
        doc = copy.deepcopy(capabilities)
        doc["google"] = google
        cases.add("capabilities.google." + tag, "capabilities", doc, "reject", reason)
    operation = json.loads(families["operationReadResult"])
    operation["unknownOperationIDs"] = []
    cases.add("operationReadResult.noUnknown", "operationReadResult", operation, "accept", "all requested operations known", canonical=True)
    operation["receipts"] = []
    operation["unknownOperationIDs"] = ["operation-001"]
    cases.add("operationReadResult.onlyUnknown", "operationReadResult", operation, "accept", "definitive not-received signal", canonical=True)
    invitation = json.loads(families["invitationReadResult"])
    for field in ["start", "end", "meetingURL", "calendarEventID"]:
        doc = copy.deepcopy(invitation)
        del doc["invitations"][1][field]
        cases.add("invitationReadResult.nullable.%s.missing" % field, "invitationReadResult", doc, "reject", "nullable members are always present")
    collection = json.loads(families["connectionsResult"])
    collection["connections"][0]["calendars"][0]["timezone"] = ""
    cases.add("connectionsResult.calendars.timezone.unset", "connectionsResult", collection, "accept", "collection without an IANA zone", canonical=True)


if __name__ == "__main__":
    sys.exit(main())
