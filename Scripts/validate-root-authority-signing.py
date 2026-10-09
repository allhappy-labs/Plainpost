#!/usr/bin/env python3
import hashlib
import plistlib
import sys

APP_ID = "9XN7WN8JN2.com.marynavdovenko.Plainpost"
AUTHORITY_GROUP = "9XN7WN8JN2.com.marynavdovenko.Plainpost.RootAuthority"
CERTIFICATE_SHA1 = "67D0B76B019381B32C7634776FDBBAB98FB35F4B"
TEAM_ID = "9XN7WN8JN2"


def fail(message: str) -> None:
    raise SystemExit(message)


def load(path: str) -> dict:
    with open(path, "rb") as handle:
        value = plistlib.load(handle)
    if not isinstance(value, dict):
        fail("signing plist is not a dictionary")
    return value


def validate_profile(path: str) -> None:
    profile = load(path)
    entitlements = profile.get("Entitlements")
    if profile.get("UUID") != "31d9f3b8-5ffb-441a-b9a0-3992162f67b3":
        fail("profile UUID does not match")
    if profile.get("Name") != "Mac Team Provisioning Profile: com.marynavdovenko.Plainpost":
        fail("profile name does not match")
    expiry = profile.get("ExpirationDate")
    if expiry is None or expiry.strftime("%Y-%m-%dT%H:%M:%SZ") != "2027-09-24T20:34:13Z":
        fail("profile expiry does not match")
    if not isinstance(entitlements, dict) or entitlements.get("com.apple.application-identifier") != APP_ID:
        fail("profile application identifier does not match")
    if entitlements.get("com.apple.developer.team-identifier") != TEAM_ID:
        fail("profile team identifier does not match")
    if "9XN7WN8JN2.*" not in entitlements.get("keychain-access-groups", []):
        fail("profile does not authorize the authority access group")
    certificate_hashes = {
        hashlib.sha1(certificate).hexdigest().upper()
        for certificate in profile.get("DeveloperCertificates", [])
        if isinstance(certificate, bytes)
    }
    if CERTIFICATE_SHA1 not in certificate_hashes:
        fail("profile does not contain the reviewed signing certificate")
    print(CERTIFICATE_SHA1)


def validate_entitlements(path: str) -> None:
    entitlements = load(path)
    expected = {
        "com.apple.application-identifier": APP_ID,
        "com.apple.developer.team-identifier": TEAM_ID,
        "keychain-access-groups": [AUTHORITY_GROUP],
    }
    if entitlements != expected:
        fail("effective helper entitlements are not the exact authority set")


if len(sys.argv) != 3 or sys.argv[1] not in {"profile", "entitlements"}:
    fail("usage: validate-root-authority-signing.py profile|entitlements PLIST")
if sys.argv[1] == "profile":
    validate_profile(sys.argv[2])
else:
    validate_entitlements(sys.argv[2])
