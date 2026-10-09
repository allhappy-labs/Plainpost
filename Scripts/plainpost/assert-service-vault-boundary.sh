#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repository_root="$(git -C "$script_directory" rev-parse --show-toplevel 2>/dev/null)" || {
  printf '%s\n' "unable to resolve repository root" >&2
  exit 1
}

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/plainpost-service-vault-boundary.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT

swift_files="$temporary_directory/swift-files"
if ! git -C "$repository_root" ls-files \
  -z --cached --others --exclude-standard \
  -- ':(glob)Sources/**/*.swift' >"$swift_files"
then
  printf '%s\n' "unable to enumerate production Swift files" >&2
  exit 1
fi
if [[ ! -s "$swift_files" ]]; then
  printf '%s\n' "production Swift file enumeration was empty" >&2
  exit 1
fi

manifest_json="$temporary_directory/package.json"
manifest_error="$temporary_directory/package.error"
mkdir -p "$temporary_directory/clang-module-cache" "$temporary_directory/swiftpm-module-cache"
if ! env \
  CLANG_MODULE_CACHE_PATH="$temporary_directory/clang-module-cache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$temporary_directory/swiftpm-module-cache" \
  swift package \
  --disable-sandbox \
  --scratch-path "$temporary_directory/swiftpm-scratch" \
  --package-path "$repository_root" \
  dump-package \
  >"$manifest_json" 2>"$manifest_error"
then
  printf '%s\n' "unable to parse Package.swift" >&2
  cat "$manifest_error" >&2
  exit 1
fi
if [[ ! -s "$manifest_json" ]]; then
  printf '%s\n' "Package.swift parser returned no manifest" >&2
  exit 1
fi

python3 - "$repository_root" "$swift_files" "$manifest_json" <<'PYTHON'
from __future__ import annotations

import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Token:
    value: str
    line: int
    column: int
    string_value: str | None = None


class SwiftLexer:
    def __init__(self, source: str) -> None:
        self.source = source
        self.index = 0
        self.line = 1
        self.column = 1
        self.tokens: list[Token] = []

    def lex(self) -> list[Token]:
        self._lex_code(stop_at_interpolation_end=False)
        return self.tokens

    def _advance(self, count: int = 1) -> None:
        for _ in range(count):
            if self.index >= len(self.source):
                return
            character = self.source[self.index]
            self.index += 1
            if character == "\n":
                self.line += 1
                self.column = 1
            else:
                self.column += 1

    def _starts(self, value: str) -> bool:
        return self.source.startswith(value, self.index)

    def _emit(
        self,
        value: str,
        line: int,
        column: int,
        string_value: str | None = None,
    ) -> None:
        self.tokens.append(
            Token(
                value=value,
                line=line,
                column=column,
                string_value=string_value,
            )
        )

    def _lex_code(self, stop_at_interpolation_end: bool) -> None:
        parenthesis_depth = 1 if stop_at_interpolation_end else 0
        while self.index < len(self.source):
            if self._starts("//"):
                self._skip_line_comment()
                continue
            if self._starts("/*"):
                self._skip_block_comment()
                continue

            raw_hash_count = self._raw_string_hash_count()
            if raw_hash_count is not None:
                self._skip_string(raw_hash_count)
                continue

            character = self.source[self.index]
            if character.isspace():
                self._advance()
                continue

            token_line = self.line
            token_column = self.column
            if character == "`":
                self._advance()
                start = self.index
                while self.index < len(self.source) and self.source[self.index] != "`":
                    self._advance()
                if self.index >= len(self.source):
                    raise ValueError(
                        f"unterminated escaped identifier at {token_line}:{token_column}"
                    )
                value = self.source[start:self.index]
                self._advance()
                self._emit(value, token_line, token_column)
                continue
            if character == "_" or character.isalpha():
                start = self.index
                self._advance()
                while self.index < len(self.source):
                    next_character = self.source[self.index]
                    if next_character == "_" or next_character.isalnum():
                        self._advance()
                    else:
                        break
                self._emit(
                    self.source[start:self.index],
                    token_line,
                    token_column,
                )
                continue

            self._advance()
            self._emit(character, token_line, token_column)
            if stop_at_interpolation_end:
                if character == "(":
                    parenthesis_depth += 1
                elif character == ")":
                    parenthesis_depth -= 1
                    if parenthesis_depth == 0:
                        return

        if stop_at_interpolation_end:
            raise ValueError("unterminated string interpolation")

    def _skip_line_comment(self) -> None:
        self._advance(2)
        while self.index < len(self.source) and self.source[self.index] != "\n":
            self._advance()

    def _skip_block_comment(self) -> None:
        start_line = self.line
        start_column = self.column
        depth = 0
        while self.index < len(self.source):
            if self._starts("/*"):
                depth += 1
                self._advance(2)
            elif self._starts("*/"):
                depth -= 1
                self._advance(2)
                if depth == 0:
                    return
            else:
                self._advance()
        raise ValueError(
            f"unterminated block comment at {start_line}:{start_column}"
        )

    def _raw_string_hash_count(self) -> int | None:
        cursor = self.index
        while cursor < len(self.source) and self.source[cursor] == "#":
            cursor += 1
        if cursor < len(self.source) and self.source[cursor] == '"':
            return cursor - self.index
        return None

    def _skip_string(self, raw_hash_count: int) -> None:
        start_line = self.line
        start_column = self.column
        self._advance(raw_hash_count)
        multiline = self._starts('"""')
        self._advance(3 if multiline else 1)
        closing = ('"""' if multiline else '"') + ("#" * raw_hash_count)
        interpolation = "\\" + ("#" * raw_hash_count) + "("
        literal_parts: list[str] = []
        has_interpolation = False

        while self.index < len(self.source):
            if self._starts(closing):
                self._advance(len(closing))
                self._emit(
                    "<string>",
                    start_line,
                    start_column,
                    string_value=(
                        None if has_interpolation else "".join(literal_parts)
                    ),
                )
                return
            if self._starts(interpolation):
                has_interpolation = True
                self._advance(len(interpolation))
                self._lex_code(stop_at_interpolation_end=True)
                continue
            if raw_hash_count == 0 and self._starts("\\"):
                literal_parts.append(self.source[self.index:self.index + 2])
                self._advance(2)
                continue
            if not multiline and self.source[self.index] == "\n":
                raise ValueError(
                    f"unterminated string literal at {start_line}:{start_column}"
                )
            literal_parts.append(self.source[self.index])
            self._advance()
        raise ValueError(
            f"unterminated string literal at {start_line}:{start_column}"
        )


def verify_lexer_contract() -> None:
    ignored_source = "\n".join(
        [
            "// MacVaultKeyProvider()",
            "/* SQLiteCredentialVaultAssembly(",
            "   /* KeychainCredentialStore */",
            ") */",
            'let ordinary = "MacVaultKeyProvider()"',
            'let raw = #"SQLiteCredentialVaultAssembly()"#',
            'let multiline = """',
            "InheritedCredentialCapability",
            '"""',
            "let liveCode = permittedFactory()",
        ]
    )
    ignored_values = [token.value for token in SwiftLexer(ignored_source).lex()]
    forbidden_ignored_values = {
        "MacVaultKeyProvider",
        "SQLiteCredentialVaultAssembly",
        "KeychainCredentialStore",
        "InheritedCredentialCapability",
    }
    if forbidden_ignored_values.intersection(ignored_values):
        raise ValueError("comments or string literal bodies emitted code tokens")
    if ignored_values[-6:] != [
        "let",
        "liveCode",
        "=",
        "permittedFactory",
        "(",
        ")",
    ]:
        raise ValueError("ordinary Swift code was not tokenized deterministically")

    interpolation_values = [
        token.value
        for token in SwiftLexer(
            'let value = "prefix \\(MacVaultKeyProvider()) suffix"'
        ).lex()
    ]
    if "MacVaultKeyProvider" not in interpolation_values:
        raise ValueError("string interpolation code was not tokenized")

    malformed_sources = (
        "/* unterminated",
        'let value = "unterminated',
        'let value = "\\(unterminated()"',
    )
    for malformed_source in malformed_sources:
        try:
            SwiftLexer(malformed_source).lex()
        except ValueError:
            continue
        raise ValueError("malformed Swift input did not fail closed")


def matching_brace_index(tokens: list[Token], opening_index: int) -> int:
    if tokens[opening_index].value != "{":
        raise ValueError("expected an opening brace")
    depth = 0
    for cursor in range(opening_index, len(tokens)):
        value = tokens[cursor].value
        if value == "{":
            depth += 1
        elif value == "}":
            depth -= 1
            if depth == 0:
                return cursor
            if depth < 0:
                break
    raise ValueError(
        f"unterminated body at "
        f"{tokens[opening_index].line}:{tokens[opening_index].column}"
    )


def nominal_body_range(
    tokens: list[Token],
    declaration_kind: str,
    type_name: str,
) -> range:
    bodies: list[range] = []
    for index in range(len(tokens) - 1):
        if (
            tokens[index].value != declaration_kind
            or tokens[index + 1].value != type_name
        ):
            continue
        opening_index = next(
            (
                cursor
                for cursor in range(index + 2, len(tokens))
                if tokens[cursor].value == "{"
            ),
            None,
        )
        if opening_index is None:
            raise ValueError(f"{declaration_kind} {type_name} has no body")
        closing_index = matching_brace_index(tokens, opening_index)
        bodies.append(range(opening_index + 1, closing_index))
    if len(bodies) != 1:
        raise ValueError(
            f"expected exactly one {declaration_kind} {type_name} body, "
            f"found {len(bodies)}"
        )
    return bodies[0]


def direct_static_function_body_range(
    tokens: list[Token],
    owner_body: range,
    function_name: str,
) -> range:
    bodies: list[range] = []
    brace_depth = 0
    for index in owner_body:
        value = tokens[index].value
        if value == "{":
            brace_depth += 1
            continue
        if value == "}":
            brace_depth -= 1
            if brace_depth < 0:
                raise ValueError("malformed owner body")
            continue
        if (
            brace_depth != 0
            or value != "func"
            or index == 0
            or tokens[index - 1].value != "static"
            or index + 1 >= len(tokens)
            or tokens[index + 1].value != function_name
        ):
            continue

        opening_index = next(
            (
                cursor
                for cursor in range(index + 2, owner_body.stop)
                if tokens[cursor].value == "{"
            ),
            None,
        )
        if opening_index is None:
            raise ValueError(f"static func {function_name} has no body")
        closing_index = matching_brace_index(tokens, opening_index)
        if closing_index >= owner_body.stop:
            raise ValueError(
                f"static func {function_name} escapes its enclosing type"
            )
        bodies.append(range(opening_index + 1, closing_index))
    if len(bodies) != 1:
        raise ValueError(
            f"expected exactly one {function_name} body, found {len(bodies)}"
        )
    return bodies[0]


def production_body_range(tokens: list[Token]) -> range:
    try:
        composition_body = nominal_body_range(
            tokens,
            "struct",
            "PlainpostServiceComposition",
        )
        return direct_static_function_body_range(
            tokens,
            composition_body,
            "production",
        )
    except ValueError as error:
        raise ValueError(
            "expected exactly one PlainpostServiceComposition.production "
            f"body: {error}"
        ) from error


def worker_launch_body_range(tokens: list[Token]) -> range:
    worker_body = nominal_body_range(
        tokens,
        "class",
        "PackagedOperationWorkerSignal",
    )
    return direct_static_function_body_range(
        tokens,
        worker_body,
        "launch",
    )


def direct_dependency_names(target: dict[str, object]) -> set[str]:
    dependencies = target.get("dependencies")
    if not isinstance(dependencies, list):
        raise ValueError(f"target {target.get('name')!r} has invalid dependencies")
    names: set[str] = set()
    for dependency in dependencies:
        if not isinstance(dependency, dict):
            raise ValueError(
                f"target {target.get('name')!r} has an invalid dependency"
            )
        recognized = False
        for kind in ("byName", "target", "product"):
            payload = dependency.get(kind)
            if payload is None:
                continue
            recognized = True
            if not isinstance(payload, list) or not payload:
                raise ValueError(
                    f"target {target.get('name')!r} has malformed {kind} dependency"
                )
            name = payload[0]
            if not isinstance(name, str) or not name:
                raise ValueError(
                    f"target {target.get('name')!r} has unnamed {kind} dependency"
                )
            names.add(name)
        if not recognized:
            raise ValueError(
                f"target {target.get('name')!r} has an unknown dependency shape"
            )
    return names


repository_root = Path(sys.argv[1])
file_listing = Path(sys.argv[2])
manifest_path = Path(sys.argv[3])
violations: list[str] = []

try:
    verify_lexer_contract()
except ValueError as error:
    print(f"Swift lexer self-check failed: {error}", file=sys.stderr)
    sys.exit(1)

try:
    raw_paths = file_listing.read_bytes().split(b"\0")
except OSError as error:
    print(f"unable to read production Swift file enumeration: {error}", file=sys.stderr)
    sys.exit(1)

paths: list[str] = []
for raw_path in raw_paths:
    if not raw_path:
        continue
    try:
        path = os.fsdecode(raw_path)
    except UnicodeError as error:
        print(f"invalid tracked path encoding: {error}", file=sys.stderr)
        sys.exit(1)
    if not path.startswith("Sources/") or not path.endswith(".swift"):
        print(f"invalid production Swift path: {path}", file=sys.stderr)
        sys.exit(1)
    absolute_path = repository_root / path
    # Git still lists tracked files removed in an uncommitted source move.
    # Validate the current worktree, including the replacement untracked file.
    if not absolute_path.exists():
        continue
    if not absolute_path.is_file() or not os.access(absolute_path, os.R_OK):
        print(f"unreadable production Swift file: {path}", file=sys.stderr)
        sys.exit(1)
    paths.append(path)

if not paths:
    print("production Swift file enumeration was empty", file=sys.stderr)
    sys.exit(1)
if len(paths) != len(set(paths)):
    print("production Swift file enumeration contained duplicates", file=sys.stderr)
    sys.exit(1)

allowed_composition_path = (
    "Sources/PlainpostService/PlainpostServiceComposition.swift"
)
allowed_assembly_handoff_path = (
    "Sources/PlainpostService/PlainpostServiceOperations.swift"
)
restricted_composition_type_names = {
    "MacVaultKeyProvider",
    "SQLiteCredentialVaultAssembly",
}
canonical_type_declaration_paths = {
    "MacVaultKeyProvider": (
        "Sources/PlainpostSecrets/MacVaultKeyProvider.swift"
    ),
    "SQLiteCredentialVaultAssembly": (
        "Sources/PlainpostDB/SQLiteCredentialVaultAssembly.swift"
    ),
}
constructor_counts = {
    name: 0 for name in restricted_composition_type_names
}
assembly_handoff_reference_count = 0
saw_allowed_assembly_handoff_path = False
client_target_prefixes = (
    ("PlainpostApp", "Sources/PlainpostApp/"),
    ("PlainpostUI", "Sources/PlainpostUI/"),
    ("PlainpostCLI", "Sources/PlainpostCLI/"),
    ("PlainpostBackgroundAgent", "Sources/PlainpostBackgroundAgent/"),
    ("PlainpostBrowserBridge", "Sources/PlainpostBrowserBridge/"),
)
service_prefix = "Sources/PlainpostService/"
forbidden_client_secret_identifiers = {
    "CredentialRecordKey",
    "CredentialUnlocker",
    "CredentialVault",
    "CredentialVaultError",
    "EncryptedCredentialVault",
    "InMemoryCredentialVault",
    "KeychainCredentialStore",
    "KeychainCredentialAvailability",
    "KeychainCredentialError",
    "InheritedCredentialCapability",
    "SecItemAdd",
    "SecItemCopyMatching",
    "SecItemUpdate",
    "SecItemDelete",
    "VaultDeviceTransportStore",
    "VaultKeyProvider",
    "VaultSession",
    "VaultSessionState",
    "VaultTLSCredentialStore",
}
forbidden_service_secret_identifiers = {
    "KeychainCredentialStore",
    "InheritedCredentialCapability",
    "SecItemAdd",
    "SecItemCopyMatching",
    "SecItemUpdate",
    "SecItemDelete",
}
allowed_nonservice_process_path = (
    "Sources/PlainpostUI/PackagedOperationWorkerSignal.swift"
)
allowed_design_snapshot_process_path = (
    "Sources/PlainpostDesignSnapshot/main.swift"
)
# This SwiftPM target contains local protocol fixtures and test harnesses. It
# lives under Sources/ for package reuse, but it is not shipped production
# code, so subprocess checks do not apply to it. Other source-level boundary
# checks still inspect these files.
test_support_source_prefix = "Sources/PlainpostTestSupport/"
saw_allowed_nonservice_process_path = False


def exact_direct_construction_at(
    tokens: list[Token],
    index: int,
    type_name: str,
) -> bool:
    return (
        tokens[index].value == type_name
        and index + 1 < len(tokens)
        and tokens[index + 1].value == "("
    )


def sequence_count(tokens: list[Token], values: list[str]) -> int:
    if not values:
        return 0
    return len(sequence_start_indices(tokens, values))


def sequence_start_indices(
    tokens: list[Token],
    values: list[str],
) -> list[int]:
    if not values:
        return []
    return [
        index
        for index in range(len(tokens) - len(values) + 1)
        if [token.value for token in tokens[index:index + len(values)]]
        == values
    ]


def token_contract(
    tokens: list[Token],
    token_range: range | None = None,
) -> list[tuple[str, str | None]]:
    selected_tokens = tokens if token_range is None else [
        tokens[index] for index in token_range
    ]
    return [
        (token.value, token.string_value)
        for token in selected_tokens
    ]


canonical_production_body_source = """
try fileManager.createDirectory(
    at: databaseURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
let store = try SQLiteMailStore(path: databaseURL.path)
try store.migrate()

let provider = MacVaultKeyProvider()
let assembly = SQLiteCredentialVaultAssembly(
    store: store,
    provider: provider
)
let directNotificationAssembly = Self.makeProductionDirectNotificationAssembly(
    store: store,
    databaseURL: databaseURL
)
let mailCredentials = Self.makeMailCredentials(store: store, vault: assembly.vault, bundle: .main)
let directMailDispatcher = ServiceDirectMailDispatcher()
let mailIntentRouter = Self.makeMailIntentRouter(store: store, direct: directMailDispatcher)
let operations = PlainpostServiceOperations(
    applicationSupportURL: databaseURL.deletingLastPathComponent(),
    store: store,
    assembly: assembly,
    notificationDrain: directNotificationAssembly.notificationDrain,
    installNotificationConfiguration: directNotificationAssembly.install,
    credentialResolver: mailCredentials.resolver,
    googleOAuthTokens: mailCredentials.googleOAuthTokens,
    mailIntentRouter: mailIntentRouter
)
directMailDispatcher.bind(operations)
let lifecycle = PlainpostServiceLifecycleCoordinator(
    vaultSession: assembly.session,
    prepareForegroundUnlock: {
        try await assembly.prepareForegroundUnlock()
    },
    archiveCredentialsAfterKeyLoss: {
        try await assembly.archiveRecordsAfterKeyLoss()
    },
    beginVaultLockdown: {
        await operations.beginVaultLockdown()
    },
    confirmVaultLocked: {
        await operations.confirmVaultLocked()
    },
    recoverAfterUnlock: {
        try await assembly.recoverPendingAccountDeletions()
    },
    reopenRuntimeConstruction: {
        await operations.reopenRuntimeConstruction()
    }
)
let nodeSessionBroker = Self.makeNodeSessionBroker()
let nodeMailMirror = Self.makeNodeMailMirror(store: store, broker: nodeSessionBroker)
let nodeReachability = Self.makeNodeReachabilitySupervisor(
    store: store,
    broker: nodeSessionBroker,
    router: mailIntentRouter,
    mirrorLoop: nodeMailMirror,
    operations: operations
)
let listener = PlainpostServiceListener(
    lifecycleCoordinator: lifecycle,
    performForegroundOperation: { operation in
        try await operations.perform(operation)
    },
    processBackgroundJobs: {
        try await operations.processBackgroundJobs()
    },
    performSmartInboxBatch: { request in
        try await operations.performSmartInboxBatch(request)
    },
    sendBrowserApprovedReply: { jobID in
        try await operations.sendBrowserApprovedReply(jobID: jobID)
    },
    syncDraftToServer: { draftID, mailbox in
        try await operations.syncDraftToServer(
            draftID: draftID,
            mailbox: mailbox
        )
    },
    nodeSession: Self.nodeSessionHandlers(broker: nodeSessionBroker, reachability: nodeReachability)
)
return PlainpostServiceComposition(
    listener: listener,
    lifecycle: lifecycle,
    operations: operations,
    store: store,
    nodeMailMirror: nodeMailMirror,
    mailIntentRouter: mailIntentRouter,
    nodeReachability: nodeReachability
)
"""
canonical_production_body_contract = token_contract(
    SwiftLexer(canonical_production_body_source).lex()
)


def validate_production_composition(
    path: str,
    tokens: list[Token],
    production_body: range,
) -> list[str]:
    if token_contract(tokens, production_body) == canonical_production_body_contract:
        return []
    return [
        f"{path}: production composition token contract must exactly match "
        "the service-owned provider, assembly, lazy runtime, lifecycle, and "
        "listener graph"
    ]


def exact_declaration_body_range(
    tokens: list[Token],
    signature: list[str],
) -> range:
    starts = sequence_start_indices(tokens, signature)
    if len(starts) != 1:
        raise ValueError(
            f"expected exactly one {' '.join(signature)} declaration, "
            f"found {len(starts)}"
        )
    opening_index = starts[0] + len(signature) - 1
    if signature[-1] != "{" or tokens[opening_index].value != "{":
        raise ValueError("exact declaration signature must end at its body")
    closing_index = matching_brace_index(tokens, opening_index)
    return range(opening_index + 1, closing_index)


canonical_worker_initializer_source = """
let candidate = appBundleURL
    .appendingPathComponent("Contents/Library/Helpers", isDirectory: true)
    .appendingPathComponent("PlainpostBackgroundAgent.app", isDirectory: true)
let executableURL = candidate
    .appendingPathComponent("Contents/MacOS/PlainpostBackgroundAgent")
guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
    return nil
}
self.helperExecutableURL = executableURL
self.launcher = launcher
"""
canonical_worker_initializer_contract = token_contract(
    SwiftLexer(canonical_worker_initializer_source).lex()
)
canonical_worker_launch_source = """
#if os(macOS)
let process = Process()
process.executableURL = executableURL
let identifier = ObjectIdentifier(process)
process.terminationHandler = { _ in
    processRegistry.remove(identifier)
    didTerminate()
}
processRegistry.insert(process, identifier: identifier)
do {
    try process.run()
} catch {
    processRegistry.remove(identifier)
    throw error
}
#else
throw PackagedOperationWorkerError.helperUnavailable
#endif
"""
canonical_worker_launch_contract = token_contract(
    SwiftLexer(canonical_worker_launch_source).lex()
)
canonical_design_snapshot_process_source = r"""
let capture = Process()
capture.executableURL = .init(fileURLWithPath: "/usr/sbin/screencapture")
capture.arguments = [
    "-x",
    "-o",
    "-l\(window.windowNumber)",
    destination.path,
]
try capture.run()
capture.waitUntilExit()
guard capture.terminationStatus == 0,
      FileManager.default.fileExists(atPath: destination.path) else {
    throw SnapshotError.couldNotCaptureWindow
}
"""
canonical_design_snapshot_process_tokens = SwiftLexer(
    canonical_design_snapshot_process_source
).lex()
canonical_design_snapshot_process_contract = token_contract(
    canonical_design_snapshot_process_tokens
)
canonical_design_snapshot_capture_offsets = [
    index
    for index, token in enumerate(canonical_design_snapshot_process_tokens)
    if token.value == "capture"
]
canonical_design_snapshot_executable_assignment_offsets = (
    sequence_start_indices(
        canonical_design_snapshot_process_tokens,
        [".", "executableURL", "="],
    )
)
canonical_design_snapshot_assignment_offsets = sequence_start_indices(
    canonical_design_snapshot_process_tokens,
    [
        "capture", ".", "executableURL", "=", ".", "init", "(",
        "fileURLWithPath", ":", "<string>", ")",
    ],
)
canonical_design_snapshot_run_offsets = sequence_start_indices(
    canonical_design_snapshot_process_tokens,
    ["try", "capture", ".", "run", "(", ")"],
)


def validate_packaged_worker(
    path: str,
    tokens: list[Token],
) -> list[str]:
    worker_violations: list[str] = []
    prefix = (
        f"{path}: PackagedOperationWorkerSignal must contain exactly one "
    )
    try:
        launch_body = worker_launch_body_range(tokens)
    except ValueError as error:
        return [prefix + f"canonical static launch body: {error}"]

    initializer_signature = [
        "init", "?", "(", "appBundleURL", ":", "URL", ",", "launcher", ":",
        "@", "escaping", "Launcher", ")", "{",
    ]
    try:
        initializer_body = exact_declaration_body_range(
            tokens,
            initializer_signature,
        )
    except ValueError as error:
        worker_violations.append(
            prefix + f"canonical designated initializer: {error}"
        )
    else:
        if (
            token_contract(tokens, initializer_body)
            != canonical_worker_initializer_contract
        ):
            worker_violations.append(
                prefix
                + "exact helper-path designated initializer token contract"
            )
    if token_contract(tokens, launch_body) != canonical_worker_launch_contract:
        worker_violations.append(
            prefix + "exact canonical static launch token contract"
        )

    process_contracts = (
        (
            ["let", "process", "=", "Process", "(", ")"],
            3,
        ),
        (
            [
                "processes", ":", "[", "ObjectIdentifier", ":", "Process",
                "]", "=", "[", ":", "]",
            ],
            5,
        ),
        (
            [
                "func", "insert", "(", "_", "process", ":", "Process", ",",
                "identifier", ":", "ObjectIdentifier", ")",
            ],
            6,
        ),
    )
    allowed_process_indices: set[int] = set()
    process_contract_is_exact = True
    for values, process_offset in process_contracts:
        starts = sequence_start_indices(tokens, values)
        if len(starts) != 1:
            process_contract_is_exact = False
            continue
        allowed_process_indices.add(starts[0] + process_offset)
    process_indices = [
        index for index, token in enumerate(tokens)
        if token.value == "Process"
    ]
    direct_process_starts = sequence_start_indices(
        tokens,
        ["let", "process", "=", "Process", "(", ")"],
    )
    if (
        not process_contract_is_exact
        or set(process_indices) != allowed_process_indices
        or len(direct_process_starts) != 1
        or direct_process_starts[0] + 3 not in launch_body
    ):
        worker_violations.append(
            prefix
            + "exact Process type contract with one direct process binding "
            + "inside the canonical static launch body"
        )

    executable_assignments = sequence_start_indices(
        tokens,
        [".", "executableURL", "="],
    )
    if (
        len(executable_assignments) != 1
        or sequence_count(
            tokens,
            ["process", ".", "executableURL", "=", "executableURL"],
        ) != 1
    ):
        worker_violations.append(
            prefix
            + "exclusive Process executableURL assignment from the validated "
            + "helper executable URL"
        )
    run_calls = [
        index
        for index in sequence_start_indices(tokens, [".", "run", "("])
    ]
    if (
        len(run_calls) != 1
        or sequence_count(
            tokens,
            ["try", "process", ".", "run", "(", ")"],
        ) != 1
    ):
        worker_violations.append(
            prefix
            + "exclusive direct run of the validated background-agent Process()"
        )
    launcher_calls = [
        index
        for index, token in enumerate(tokens[:-1])
        if token.value == "launcher"
        and tokens[index + 1].value == "("
    ]
    if (
        len(launcher_calls) != 1
        or sequence_count(
            tokens,
            ["try", "launcher", "(", "helperExecutableURL", ")", "{"],
        ) != 1
        or sequence_count(
            tokens,
            [
                "self", ".", "helperExecutableURL", "=", "executableURL",
            ],
        ) != 1
    ):
        worker_violations.append(
            prefix
            + "exclusive launcher handoff of the canonical helper executable URL"
        )

    string_values = [
        token.string_value
        for token in tokens
        if token.string_value is not None
    ]
    canonical_strings = (
        "Contents/Library/Helpers",
        "PlainpostBackgroundAgent.app",
        "Contents/MacOS/PlainpostBackgroundAgent",
    )
    if string_values != list(canonical_strings):
        worker_violations.append(
            prefix + "canonical background-agent bundle and executable target"
        )
    candidate_path = [
        "let", "candidate", "=", "appBundleURL", ".",
        "appendingPathComponent", "(", "<string>", ",",
        "isDirectory", ":", "true", ")", ".",
        "appendingPathComponent", "(", "<string>", ",",
        "isDirectory", ":", "true", ")",
    ]
    executable_path = [
        "let", "executableURL", "=", "candidate", ".",
        "appendingPathComponent", "(", "<string>", ")",
    ]
    if (
        sequence_count(tokens, candidate_path) != 1
        or sequence_count(tokens, executable_path) != 1
        or sum(
            token.value == "appendingPathComponent"
            for token in tokens
        ) != 3
        or any(
            token.value in {"NSURL", "fileURLWithPath"}
            or (
                token.value == "URL"
                and index + 1 < len(tokens)
                and tokens[index + 1].value == "("
            )
            for index, token in enumerate(tokens)
        )
    ):
        worker_violations.append(
            prefix
            + "structurally exact and exclusive background-agent executable path"
        )
    return worker_violations


def validate_design_snapshot_process(
    path: str,
    tokens: list[Token],
) -> list[str]:
    process_binding = [
        "let", "capture", "=", "Process", "(", ")",
    ]
    starts = sequence_start_indices(tokens, process_binding)
    process_start = starts[0] if len(starts) == 1 else None
    process_indices = [
        index for index, token in enumerate(tokens)
        if token.value == "Process"
    ]
    capture_indices = [
        index for index, token in enumerate(tokens)
        if token.value == "capture"
    ]
    executable_assignments = sequence_start_indices(
        tokens,
        [".", "executableURL", "="],
    )
    canonical_assignment = [
        "capture", ".", "executableURL", "=", ".", "init", "(",
        "fileURLWithPath", ":", "<string>", ")",
    ]
    canonical_assignment_starts = sequence_start_indices(
        tokens,
        canonical_assignment,
    )
    direct_run_starts = sequence_start_indices(
        tokens,
        ["try", "capture", ".", "run", "(", ")"],
    )
    if (
        process_start is not None
        and token_contract(
            tokens,
            range(
                process_start,
                process_start
                + len(canonical_design_snapshot_process_contract),
            ),
        ) == canonical_design_snapshot_process_contract
        and process_indices == [process_start + 3]
        and capture_indices == [
            process_start + offset
            for offset in canonical_design_snapshot_capture_offsets
        ]
        and executable_assignments == [
            process_start + offset
            for offset
            in canonical_design_snapshot_executable_assignment_offsets
        ]
        and canonical_assignment_starts == [
            process_start + offset
            for offset in canonical_design_snapshot_assignment_offsets
        ]
        and direct_run_starts == [
            process_start + offset
            for offset in canonical_design_snapshot_run_offsets
        ]
    ):
        return []
    return [
        f"{path}: forbidden production subprocess exposure outside the "
        "single canonical screencapture Process sequence"
    ]


for path in sorted(paths):
    try:
        source = (repository_root / path).read_text(encoding="utf-8")
        tokens = SwiftLexer(source).lex()
    except (OSError, UnicodeError, ValueError) as error:
        print(f"unable to scan {path}: {error}", file=sys.stderr)
        sys.exit(1)

    client_target = next(
        (
            target_name
            for target_name, prefix in client_target_prefixes
            if path.startswith(prefix)
        ),
        None,
    )
    is_client = client_target is not None
    is_service = path.startswith(service_prefix)
    allowed_production_body: range | None = None
    if path == allowed_composition_path:
        try:
            allowed_production_body = production_body_range(tokens)
        except ValueError as error:
            print(f"unable to scan {path}: {error}", file=sys.stderr)
            sys.exit(1)
        violations.extend(
            validate_production_composition(
                path,
                tokens,
                allowed_production_body,
            )
        )
    if path == allowed_assembly_handoff_path:
        saw_allowed_assembly_handoff_path = True

    for index, token in enumerate(tokens):
        if token.value in restricted_composition_type_names:
            is_canonical_declaration = (
                path == canonical_type_declaration_paths[token.value]
                and index > 0
                and tokens[index - 1].value in {"class", "struct"}
            )
            is_exact_direct_composition_construction = (
                path == allowed_composition_path
                and allowed_production_body is not None
                and index in allowed_production_body
                and exact_direct_construction_at(
                    tokens,
                    index,
                    token.value,
                )
            )
            is_exact_assembly_handoff_reference = (
                path == allowed_assembly_handoff_path
                and token.value == "SQLiteCredentialVaultAssembly"
                and index >= 2
                and [item.value for item in tokens[index - 2:index]]
                == ["assembly", ":"]
            )
            is_permitted_reference = (
                is_canonical_declaration
                or is_exact_direct_composition_construction
                or is_exact_assembly_handoff_reference
            )
            if not is_permitted_reference:
                if (
                    path == allowed_composition_path
                    and allowed_production_body is not None
                    and index in allowed_production_body
                ):
                    violations.append(
                        f"{path}:{token.line}: {token.value} must be an "
                        "exact direct constructor expression"
                    )
                else:
                    violations.append(
                        f"{path}:{token.line}: {token.value} type reference "
                        "is outside PlainpostServiceComposition.production"
                    )
            elif is_exact_direct_composition_construction:
                constructor_counts[token.value] += 1
            elif is_exact_assembly_handoff_reference:
                assembly_handoff_reference_count += 1

        if (
            is_client
            and token.value == "PlainpostSecrets"
        ):
            violations.append(
                f"{path}:{token.line}: {client_target} may not import "
                "PlainpostSecrets"
            )

        if is_client and token.value in forbidden_client_secret_identifiers:
            violations.append(
                f"{path}:{token.line}: forbidden production client secret "
                f"type {token.value}"
            )

        if (
            is_service
            and token.value in forbidden_service_secret_identifiers
        ):
            violations.append(
                f"{path}:{token.line}: forbidden production secret path "
                f"{token.value}"
            )

        if not path.startswith(test_support_source_prefix):
            is_process_access = token.value in {"Process", "NSTask"}
            is_posix_spawn = token.value.startswith("posix_spawn")
            if is_posix_spawn:
                violations.append(
                    f"{path}:{token.line}: forbidden production subprocess "
                    f"exposure {token.value}"
                )
            elif is_process_access and (
                token.value == "NSTask"
                or path not in {
                    allowed_nonservice_process_path,
                    allowed_design_snapshot_process_path,
                }
            ):
                violations.append(
                    f"{path}:{token.line}: forbidden production subprocess "
                    f"exposure {token.value}"
                )

    if path == allowed_nonservice_process_path:
        saw_allowed_nonservice_process_path = True
        violations.extend(validate_packaged_worker(path, tokens))
    elif path == allowed_design_snapshot_process_path:
        violations.extend(validate_design_snapshot_process(path, tokens))

if not saw_allowed_nonservice_process_path:
    violations.append(
        f"{allowed_nonservice_process_path}: "
        "PackagedOperationWorkerSignal must contain exactly one canonical "
        "background-agent launch file"
    )

if (
    saw_allowed_assembly_handoff_path
    and assembly_handoff_reference_count != 2
):
    violations.append(
        f"{allowed_assembly_handoff_path}: expected exactly two "
        "SQLiteCredentialVaultAssembly handoff references, found "
        f"{assembly_handoff_reference_count}"
    )

for constructor_name, count in sorted(constructor_counts.items()):
    if count != 1:
        violations.append(
            f"{allowed_composition_path}: expected exactly one "
            f"{constructor_name} construction, found {count}"
        )

try:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError) as error:
    print(f"unable to parse Package.swift JSON: {error}", file=sys.stderr)
    sys.exit(1)
if not isinstance(manifest, dict):
    print("Package.swift parser returned a non-object manifest", file=sys.stderr)
    sys.exit(1)
targets = manifest.get("targets")
if not isinstance(targets, list) or not targets:
    print("Package.swift parser returned no targets", file=sys.stderr)
    sys.exit(1)

targets_by_name: dict[str, dict[str, object]] = {}
try:
    for target in targets:
        if not isinstance(target, dict):
            raise ValueError("Package.swift contains an invalid target")
        name = target.get("name")
        if not isinstance(name, str) or not name:
            raise ValueError("Package.swift contains an unnamed target")
        if name in targets_by_name:
            raise ValueError(f"Package.swift contains duplicate target {name}")
        targets_by_name[name] = target

    client_targets = (
        "PlainpostUI",
        "PlainpostApp",
        "PlainpostCLI",
        "PlainpostBackgroundAgent",
        "PlainpostBrowserBridge",
    )
    for target_name in client_targets:
        target = targets_by_name.get(target_name)
        if target is None:
            raise ValueError(f"Package.swift is missing target {target_name}")
        dependencies = direct_dependency_names(target)
        if "PlainpostSecrets" in dependencies:
            violations.append(
                f"Package.swift: target {target_name} directly depends on "
                "PlainpostSecrets"
            )
        if "PlainpostServiceIPC" not in dependencies:
            violations.append(
                f"Package.swift: target {target_name} is missing direct "
                "PlainpostServiceIPC dependency"
            )

    service_target = targets_by_name.get("PlainpostService")
    if service_target is None:
        raise ValueError("Package.swift is missing target PlainpostService")
    if "PlainpostServiceIPC" not in direct_dependency_names(service_target):
        violations.append(
            "Package.swift: target PlainpostService is missing direct "
            "PlainpostServiceIPC dependency"
        )

    # The full repository has PlainpostSecretsTests; the reduced adversarial
    # fixtures intentionally do not. In the full tree, provider contracts use
    # injected operations in their owning test targets. Disposable Keychain
    # and legacy credential acceptance files must not be reintroduced.
    if "PlainpostSecretsTests" in targets_by_name:
        if "PlainpostSecurityAcceptanceTests" in targets_by_name:
            violations.append(
                "Package.swift: retired PlainpostSecurityAcceptanceTests target is present"
            )

        secrets_tests = targets_by_name["PlainpostSecretsTests"]
        if "PlainpostSecrets" not in direct_dependency_names(secrets_tests):
            violations.append(
                "Package.swift: target PlainpostSecretsTests is "
                "missing direct PlainpostSecrets dependency"
            )

        canonical_contract_files = {
            "MacVaultKeyProviderContractTests.swift":
                "Tests/PlainpostSecretsTests/MacVaultKeyProviderContractTests.swift",
        }
        for filename, expected_relative_path in canonical_contract_files.items():
            matches = sorted(
                path.relative_to(repository_root).as_posix()
                for path in (repository_root / "Tests").rglob(filename)
                if path.is_file()
            )
            if matches != [expected_relative_path]:
                violations.append(
                    f"{expected_relative_path}: expected the sole {filename} "
                    f"injected contract, found {matches}"
                )

        retired_acceptance_files = (
            "DisposableKeychain.swift",
            "DisposableKeychainTests.swift",
            "LegacyCredentialStoreAcceptanceTests.swift",
        )
        for filename in retired_acceptance_files:
            matches = sorted(
                path.relative_to(repository_root).as_posix()
                for path in (repository_root / "Tests").rglob(filename)
                if path.is_file()
            )
            if matches:
                violations.append(
                    f"Tests: retired {filename} acceptance contract is present "
                    f"at {matches}"
                )
except ValueError as error:
    print(f"unable to parse Package.swift targets: {error}", file=sys.stderr)
    sys.exit(1)

if violations:
    print("Plainpost service vault boundary violations:")
    for violation in sorted(set(violations)):
        print(f"- {violation}")
    sys.exit(1)

print(
    "Plainpost service vault boundary: ok "
    f"({len(paths)} production Swift files; "
    "one service-owned provider and assembly)"
)
PYTHON
