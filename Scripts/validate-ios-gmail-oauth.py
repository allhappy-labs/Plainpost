#!/usr/bin/env python3
"""Opt-in package gate for an iOS candidate intended to support native Gmail.

Run immediately before installing the already signature-verified candidate.
The registration file must contain only the two public native client settings;
neither settings nor plist values are emitted. This does not verify signing,
provider availability, saved credentials, or successful account synchronization.
"""
import argparse
import json
from pathlib import Path
import plistlib
import re
from xml.parsers.expat import ExpatError


CLIENT_KEY = "PLAINPOST_GOOGLE_IOS_OAUTH_CLIENT_ID"
CALLBACK_KEY = "PLAINPOST_GOOGLE_IOS_OAUTH_CALLBACK_SCHEME"
BUNDLE_ID = "com.marynavdovenko.Plainpost.iOS"


class InvalidInput(Exception):
    pass


def callback_for(client):
    # Matches GoogleOAuthPublicClient.init's ASCII prefix and byte bound.
    if not isinstance(client, str) or len(client.encode("utf-8")) > 512:
        return None
    match = re.fullmatch(r"([A-Za-z0-9_-]+)\.apps\.googleusercontent\.com", client)
    return "com.googleusercontent.apps." + match[1] if match else None


def read_registration(path):
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        raise InvalidInput("registration_input_unreadable") from None
    settings = {}
    for line in lines:
        line = line.strip()
        if not line or line.startswith("//"):
            continue
        key, separator, value = line.partition("=")
        key = key.strip()
        if not separator or key not in (CLIENT_KEY, CALLBACK_KEY) or key in settings:
            raise InvalidInput("registration_not_two_public_assignments")
        settings[key] = value.strip()
    if set(settings) != {CLIENT_KEY, CALLBACK_KEY}:
        raise InvalidInput("registration_not_two_public_assignments")
    callback = callback_for(settings[CLIENT_KEY])
    if callback is None:
        raise InvalidInput("registration_native_client_invalid")
    if settings[CALLBACK_KEY] != callback:
        raise InvalidInput("registration_native_callback_mismatch")
    return settings[CLIENT_KEY], callback


def contains_client_secret(value):
    if isinstance(value, dict):
        return any("clientsecret" in re.sub(r"[^a-z]", "", key.lower())
                   or contains_client_secret(item) for key, item in value.items())
    if isinstance(value, list):
        return any(contains_client_secret(item) for item in value)
    return False


def validate(app, registration):
    client, callback = read_registration(registration)
    try:
        info = plistlib.loads((app / "Info.plist").read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException, OverflowError, ExpatError):
        raise InvalidInput("package_input_unreadable") from None
    if not isinstance(info, dict):
        raise InvalidInput("package_input_unreadable")
    if contains_client_secret(info):
        raise InvalidInput("packaged_client_secret_forbidden")
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        raise InvalidInput("packaged_bundle_identifier_mismatch")
    packaged_client = info.get("PlainpostGoogleIOSOAuthClientID")
    if callback_for(packaged_client) is None:
        raise InvalidInput("packaged_native_client_invalid")
    if packaged_client != client:
        raise InvalidInput("packaged_native_client_mismatch")
    types = info.get("CFBundleURLTypes")
    if not isinstance(types, list):
        raise InvalidInput("packaged_callback_structure_invalid")
    schemes = []
    for entry in types:
        values = entry.get("CFBundleURLSchemes") if isinstance(entry, dict) else None
        if not isinstance(values, list) or not all(isinstance(item, str) for item in values):
            raise InvalidInput("packaged_callback_structure_invalid")
        schemes.extend(values)
    if callback not in schemes:
        raise InvalidInput("packaged_native_callback_missing")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--registration", required=True, type=Path)
    args = parser.parse_args()
    try:
        validate(args.app, args.registration)
    except InvalidInput as error:
        print(json.dumps({"status": "failed", "reason": str(error)}))
        return 1
    print(json.dumps({"status": "passed", "reason": "native_gmail_registration_matches"}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
