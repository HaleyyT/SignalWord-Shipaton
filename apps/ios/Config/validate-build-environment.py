#!/usr/bin/env python3
"""Fail closed before compilation and after Info.plist processing. Never log keys."""
import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import re
import sys

EXPECTED_REF = "voepalyamwgenceawdvl"
EXPECTED_ORIGIN = "https://" + EXPECTED_REF + ".supabase.co"
FIELDS = {
    "SIGNALWORD_SUPABASE_URL": "SignalWordSupabaseURL",
    "SIGNALWORD_USER_API_URL": "SignalWordUserAPIURL",
    "SIGNALWORD_SUPABASE_PUBLISHABLE_KEY": "SignalWordSupabasePublishableKey",
}
OPTIONAL_FIELDS = {
    "SIGNALWORD_VERIFICATION_URL": "SignalWordVerificationURL",
    "SIGNALWORD_TURNSTILE_SITE_KEY": "SignalWordTurnstileSiteKey",
    "SIGNALWORD_REVENUECAT_PUBLIC_API_KEY": "SignalWordRevenueCatAPIKey",
}

def validate(plist_path=None):
    values = {name: os.environ.get(name, "") for name in FIELDS}
    for name, value in values.items():
        if not value.strip() or value != value.strip() or "$(" in value or "${" in value:
            raise ValueError(name + " is missing or unresolved; supply the intended xcconfig.")
    if values["SIGNALWORD_SUPABASE_URL"] != EXPECTED_ORIGIN:
        raise ValueError("SIGNALWORD_SUPABASE_URL must use HTTPS and project " + EXPECTED_REF + ".")
    if values["SIGNALWORD_USER_API_URL"] != EXPECTED_ORIGIN + "/functions/v1/user-api":
        raise ValueError("SIGNALWORD_USER_API_URL must match the intended project's user-api endpoint.")
    key = values["SIGNALWORD_SUPABASE_PUBLISHABLE_KEY"]
    # Legacy anon JWTs identify their role/project. New public keys are opaque:
    # their project membership needs hosted verification, not guessed decoding.
    if key.startswith("eyJ"):
        try:
            parts = key.split(".")
            if len(parts) != 3:
                raise ValueError()
            payload = json.loads(base64.urlsafe_b64decode(parts[1] + "=" * (-len(parts[1]) % 4)))
            if not isinstance(payload, dict) or payload.get("role") != "anon" or payload.get("ref") != EXPECTED_REF:
                raise ValueError()
        except (ValueError, TypeError, KeyError, UnicodeError):
            raise ValueError("Supabase JWT must be an anon key for the intended project.") from None
    elif not re.fullmatch(r"sb_publishable_[A-Za-z0-9_-]{20,}", key):
        raise ValueError("Supabase key must be a public publishable key or intended-project anon JWT.")
    if plist_path:
        try:
            with open(plist_path, "rb") as source:
                bundled = plistlib.load(source)
        except (OSError, ValueError, plistlib.InvalidFileException):
            raise ValueError("Cannot read the processed application Info.plist.") from None
        for name, plist_key in {**FIELDS, **OPTIONAL_FIELDS}.items():
            if bundled.get(plist_key, "") != os.environ.get(name, ""):
                raise ValueError(plist_key + " in the app does not match the intended build setting.")
    print("SignalWord configuration verified: " + os.environ.get("CONFIGURATION", "unknown") +
          " / " + EXPECTED_REF + (" / bundled values match" if plist_path else " / build settings"))

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--plist", type=Path)
    args = parser.parse_args()
    try:
        validate(args.plist)
    except ValueError as error:
        print("error: SignalWord build configuration: " + str(error), file=sys.stderr)
        sys.exit(1)
