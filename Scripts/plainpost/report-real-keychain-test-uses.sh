#!/bin/bash
set -euo pipefail

usage() {
  printf 'usage: %s --root <repository-root> --report|--strict\n' "$0" >&2
  exit 64
}

root=""
mode=""
while (($#)); do
  case "$1" in
    --root)
      (($# >= 2)) || usage
      root="$2"
      shift 2
      ;;
    --report|--strict)
      [[ -z "$mode" ]] || usage
      mode="${1#--}"
      shift
      ;;
    *)
      usage
      ;;
  esac
done

[[ -n "$root" && -n "$mode" ]] || usage
[[ -d "$root/Tests" ]] || {
  printf 'missing Tests directory under root: %s\n' "$root" >&2
  exit 66
}

root="$(cd "$root" && pwd -P)"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT
findings="$temporary_directory/findings.txt"
: >"$findings"

# This bounded lexical scanner recognizes direct Security.framework calls and
# forbidden store construction with arbitrary spaces/newlines between tokens.
# Store construction forms:
#   TypeName(...)
#   TypeName.init(...)
#   let value: TypeName = .init(...)
# It masks nested comments and standard/raw single/triple-quoted string text,
# while recursively preserving executable expressions inside balanced Swift
# string interpolation. It intentionally does not parse macro expansions or
# infer contextual `.init` types beyond an immediate explicit type annotation.
# Contract-only hooks are executable paths: discovery receives the repository
# root and writes NUL-delimited relative paths; the scanner receives the root
# and one relative path and writes zero or more formatted findings.
discover_swift_files() {
  local destination="$1"
  local discovery_command="${PLAINPOST_KEYCHAIN_TEST_FILE_DISCOVERY_COMMAND:-}"
  local discovery_status

  if [[ -n "$discovery_command" ]]; then
    [[ -x "$discovery_command" ]] || {
      printf 'configured Swift test file discovery command is unavailable: %s\n' \
        "$discovery_command" >&2
      return 69
    }
    set +e
    "$discovery_command" "$root" >"$destination"
    discovery_status=$?
    set -e
    if ((discovery_status != 0)); then
      printf 'Swift test file discovery failed with status %d\n' \
        "$discovery_status" >&2
      return "$discovery_status"
    fi
    return 0
  fi

  set +e
  (
    cd "$root"
    rg \
      --files \
      --null \
      --glob '*.swift' | \
      perl -0 -ne '
        for my $path (split /\0/, $_, -1) {
          print "$path\0" if $path =~ m{(?:^|/)[^/]*Tests/};
        }
      '
  ) >"$destination"
  discovery_status=$?
  set -e

  # rg uses status 1 for a legitimate no-match result. Anything else nonzero
  # means discovery itself failed and must abort the detector.
  if ((discovery_status != 0 && discovery_status != 1)); then
    printf 'Swift test file discovery failed with status %d\n' \
      "$discovery_status" >&2
    return "$discovery_status"
  fi
}

scan_swift_uses() {
  local matches="$temporary_directory/swift-keychain-uses.txt"
  local file_list="$temporary_directory/swift-test-files.nul"
  local scanner_command="${PLAINPOST_KEYCHAIN_TEST_SCANNER_COMMAND:-}"
  local scanner_status
  local file_matches
  local file_index=0

  discover_swift_files "$file_list"
  if [[ -n "$scanner_command" && ! -x "$scanner_command" ]]; then
    printf 'configured Swift Keychain-use scanner is unavailable: %s\n' \
      "$scanner_command" >&2
    return 69
  fi

  : >"$matches"
  while IFS= read -r -d '' file; do
    file_index=$((file_index + 1))
    file_matches="$temporary_directory/swift-keychain-uses.$file_index.txt"
    set +e
    if [[ -n "$scanner_command" ]]; then
      "$scanner_command" "$root" "$file" >"$file_matches"
    else
      perl -0777 -e '
        use strict;
        use warnings;

        my $input_path = shift @ARGV;
        my $path = shift @ARGV;
        open my $handle, "<", $input_path or die "unable to read $path: $!";
        my $original = <$handle> // "";
        close $handle or die "unable to close $path: $!";
        my $length = length($original);
        my @masked = split //, $original;

        sub mask_range {
          my ($start, $end) = @_;
          for (my $cursor = $start; $cursor < $end; $cursor++) {
            $masked[$cursor] = " " unless $masked[$cursor] eq "\n";
          }
        }

        my ($scan_code, $scan_string);
        $scan_string = sub {
          my ($start, $hash_count, $triple_quoted) = @_;
          my $hashes = "#" x $hash_count;
          my $quotes = $triple_quoted ? "\"\"\"" : "\"";
          my $opening_length = $hash_count + length($quotes);
          my $closing = $quotes . $hashes;
          my $interpolation = "\\" . $hashes . "(";
          my $cursor = $start + $opening_length;
          mask_range($start, $cursor);

          while ($cursor < $length) {
            if (substr($original, $cursor, length($closing)) eq $closing) {
              my $end = $cursor + length($closing);
              mask_range($cursor, $end);
              return $end;
            }

            if (substr($original, $cursor, length($interpolation)) eq $interpolation) {
              my $expression_start = $cursor + length($interpolation);
              mask_range($cursor, $expression_start);
              $cursor = $scan_code->($expression_start, 1);
              next;
            }

            if ($hash_count == 0 && !$triple_quoted && substr($original, $cursor, 1) eq "\\") {
              my $end = $cursor + 2;
              $end = $length if $end > $length;
              mask_range($cursor, $end);
              $cursor = $end;
              next;
            }

            if (!$triple_quoted && substr($original, $cursor, 1) eq "\n") {
              die "unterminated string literal in $path";
            }

            mask_range($cursor, $cursor + 1);
            $cursor++;
          }

          die "unterminated string literal in $path";
        };

        $scan_code = sub {
          my ($cursor, $parenthesis_depth) = @_;
          while ($cursor < $length) {
            if (substr($original, $cursor, 2) eq "//") {
              my $end = index($original, "\n", $cursor + 2);
              $end = $length if $end < 0;
              mask_range($cursor, $end);
              $cursor = $end;
              next;
            }

            if (substr($original, $cursor, 2) eq "/*") {
              my $depth = 1;
              my $end = $cursor + 2;
              while ($end < $length && $depth > 0) {
                if (substr($original, $end, 2) eq "/*") {
                  $depth++;
                  $end += 2;
                } elsif (substr($original, $end, 2) eq "*/") {
                  $depth--;
                  $end += 2;
                } else {
                  $end++;
                }
              }
              die "unterminated block comment in $path" if $depth > 0;
              mask_range($cursor, $end);
              $cursor = $end;
              next;
            }

            my $remaining = substr($original, $cursor);
            if ($remaining =~ /\A(#+)"""/) {
              $cursor = $scan_string->($cursor, length($1), 1);
              next;
            }
            if ($remaining =~ /\A(#+)"/) {
              $cursor = $scan_string->($cursor, length($1), 0);
              next;
            }
            if (substr($original, $cursor, 3) eq "\"\"\"") {
              $cursor = $scan_string->($cursor, 0, 1);
              next;
            }
            if (substr($original, $cursor, 1) eq "\"") {
              $cursor = $scan_string->($cursor, 0, 0);
              next;
            }

            if ($parenthesis_depth > 0) {
              my $character = substr($original, $cursor, 1);
              if ($character eq "(") {
                $parenthesis_depth++;
              } elsif ($character eq ")") {
                $parenthesis_depth--;
                if ($parenthesis_depth == 0) {
                  mask_range($cursor, $cursor + 1);
                  return $cursor + 1;
                }
              }
            }
            $cursor++;
          }
          die "unterminated string interpolation in $path"
            if $parenthesis_depth > 0;
          return $cursor;
        };

        $scan_code->(0, 0);
        my $masked = join "", @masked;
        my $sec_item_function = qr/SecItem(?:Add|CopyMatching|Update|Delete|Import|Export)/;
        my $sec_keychain_function = qr/SecKeychain[A-Za-z0-9_]*/;
        my $sec_access_control_function = qr/SecAccessControl[A-Za-z0-9_]*/;
        my $type = qr/(?:KeychainCredentialStore|KeychainAccountSecretStore|DeviceTransportKeychainStore|DeviceTLSCredentialStore|MacVaultKeyProvider|MobileVaultKeyProvider)/;
        my @rules = (
          ["direct_secitem", qr/(?<![A-Za-z0-9_])$sec_item_function\s*\(/],
          ["direct_seckeychain", qr/(?<![A-Za-z0-9_])$sec_keychain_function\s*\(/],
          ["direct_secaccesscontrol", qr/(?<![A-Za-z0-9_])$sec_access_control_function\s*\(/],
          ["production_store_construction", qr/(?<![A-Za-z0-9_])(?:[A-Za-z_][A-Za-z0-9_]*\s*\.\s*)?($type)\s*(?:\.\s*init\s*)?\(/],
          ["production_store_construction", qr/:\s*($type)\s*[?!]?\s*=\s*\.init\s*\(/]
        );
        my %reported;
        my $call_expression_end = sub {
          my ($open_parenthesis) = @_;
          my $depth = 0;
          for (
            my $cursor = $open_parenthesis;
            $cursor < length($masked);
            $cursor++
          ) {
            my $character = substr($masked, $cursor, 1);
            if ($character eq "(") {
              $depth++;
            } elsif ($character eq ")") {
              $depth--;
              return $cursor + 1 if $depth == 0;
            }
          }
          die "unterminated Security call in $path";
        };
        my $has_top_level_argument_label = sub {
          my ($call, $expected_label) = @_;
          my $parenthesis_depth = 0;
          my $bracket_depth = 0;
          my $brace_depth = 0;

          for (
            my $cursor = 0;
            $cursor < length($call);
            $cursor++
          ) {
            my $character = substr($call, $cursor, 1);
            if ($character eq "(") {
              $parenthesis_depth++;
              next;
            }
            if ($character eq ")") {
              $parenthesis_depth--;
              next;
            }
            if ($character eq "[") {
              $bracket_depth++;
              next;
            }
            if ($character eq "]") {
              $bracket_depth--;
              next;
            }
            if ($character eq "{") {
              $brace_depth++;
              next;
            }
            if ($character eq "}") {
              $brace_depth--;
              next;
            }
            next
              unless $parenthesis_depth == 1
              && $bracket_depth == 0
              && $brace_depth == 0;
            return 1
              if substr($call, $cursor) =~
                /\A\Q$expected_label\E\s*:/s;
          }
          return 0;
        };
        for my $rule (@rules) {
          my ($category, $pattern) = @$rule;
          pos($masked) = 0;
          while ($masked =~ /$pattern/gms) {
            my $start = $-[0];
            next if $reported{"$category:$start"}++;
            my $end = $+[0];
            my $constructed_type =
              $category eq "production_store_construction" ? $1 : undef;
            my $line = 1 + (substr($masked, 0, $start) =~ tr/\n//);
            my $snippet = substr($original, $start, $end - $start);
            $snippet =~ s/\s+/ /g;
            print "$category\t$path:$line:$snippet\n";
          }
        }
      ' "$root/$file" "$file" >"$file_matches"
    fi
    scanner_status=$?
    set -e

    if ((scanner_status != 0)); then
      printf 'unable to scan Swift test source %s (status %d)\n' \
        "$file" "$scanner_status" >&2
      return "$scanner_status"
    fi
    cat "$file_matches" >>"$matches"
  done <"$file_list"

  if [[ -s "$matches" ]]; then
    cat "$matches" >>"$findings"
  fi
}

scan_swift_uses

direct_secitem_count="$(awk -F '\t' '$1 == "direct_secitem" { count++ } END { print count + 0 }' "$findings")"
direct_seckeychain_count="$(awk -F '\t' '$1 == "direct_seckeychain" { count++ } END { print count + 0 }' "$findings")"
direct_secaccesscontrol_count="$(awk -F '\t' '$1 == "direct_secaccesscontrol" { count++ } END { print count + 0 }' "$findings")"
production_store_count="$(awk -F '\t' '$1 == "production_store_construction" { count++ } END { print count + 0 }' "$findings")"
finding_count="$((direct_secitem_count + direct_seckeychain_count + direct_secaccesscontrol_count + production_store_count))"

report_directory="$root/.build/plainpost-migration"
report="$report_directory/keychain-test-use-report.txt"
mkdir -p "$report_directory"

{
  printf 'root=%s\n' "$root"
  printf 'finding_count=%d\n' "$finding_count"
  printf 'category.direct_secitem=%d\n' "$direct_secitem_count"
  printf 'category.direct_seckeychain=%d\n' "$direct_seckeychain_count"
  printf 'category.direct_secaccesscontrol=%d\n' "$direct_secaccesscontrol_count"
  printf 'category.production_store_construction=%d\n' "$production_store_count"
  printf 'findings:\n'
  LC_ALL=C sort "$findings"
} | tee "$report"

if [[ "$mode" == "strict" && "$finding_count" -ne 0 ]]; then
  exit 1
fi
