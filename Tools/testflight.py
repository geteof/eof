#!/usr/bin/env python3
"""After an upload: wait for App Store Connect to process the build, set What to Test, add the build to the
external beta group and submit it for Beta App Review. Internal testers get it on their own.

Usage: testflight.py --key AuthKey_X.p8 --app <app id> --version 1.0.0 --build 26 --group "Public Beta"
                     --notes Release/notes.json
Reads ASC_KEY_ID and ASC_ISSUER_ID from the environment.
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt

API = "https://api.appstoreconnect.apple.com/v1"


class Client:
    def __init__(self, key_path):
        self.key = open(key_path).read()
        self.key_id = os.environ["ASC_KEY_ID"]
        self.issuer = os.environ["ASC_ISSUER_ID"]

    def token(self):
        now = int(time.time())
        return jwt.encode({"iss": self.issuer, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
                          self.key, algorithm="ES256", headers={"kid": self.key_id, "typ": "JWT"})

    def call(self, method, path, query=None, body=None):
        url = API + path + ("?" + urllib.parse.urlencode(query) if query else "")
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, data=data, method=method, headers={
            "Authorization": "Bearer " + self.token(), "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                raw = response.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")
            raise SystemExit(f"{method} {path} failed with {error.code}: {detail}")


def wait_for_build(client, app, version, number):
    # A fresh upload can take a few minutes to appear and longer to process.
    deadline = time.time() + 60 * 60
    while True:
        found = client.call("GET", "/builds", {
            "filter[app]": app, "filter[version]": number, "filter[preReleaseVersion.version]": version,
            "fields[builds]": "processingState,version", "limit": "1"})["data"]
        state = found[0]["attributes"]["processingState"] if found else "NOT_FOUND"
        print(f"build {version} ({number}): {state}", flush=True)
        if state == "VALID":
            return found[0]["id"]
        if state in ("FAILED", "INVALID"):
            raise SystemExit(f"build {number} is {state}")
        if time.time() > deadline:
            raise SystemExit("timed out waiting for the build to process")
        time.sleep(30)


def find_build(client, app, version, number):
    found = client.call("GET", "/builds", {
        "filter[app]": app, "filter[version]": number, "filter[preReleaseVersion.version]": version,
        "fields[builds]": "processingState", "limit": "1"})["data"]
    return found[0] if found else None


def set_what_to_test(client, build, notes):
    # The API calls TestFlight's "What to Test" text `whatsNew`.
    existing = {item["attributes"]["locale"]: item["id"] for item in
                client.call("GET", f"/builds/{build}/betaBuildLocalizations")["data"]}
    for locale, text in notes.items():
        if locale in existing:
            client.call("PATCH", f"/betaBuildLocalizations/{existing[locale]}", body={"data": {
                "type": "betaBuildLocalizations", "id": existing[locale], "attributes": {"whatsNew": text}}})
        else:
            client.call("POST", "/betaBuildLocalizations", body={"data": {
                "type": "betaBuildLocalizations", "attributes": {"locale": locale, "whatsNew": text},
                "relationships": {"build": {"data": {"type": "builds", "id": build}}}}})
        print(f"What to Test set for {locale}")


def add_to_group(client, app, build, name):
    groups = client.call("GET", "/betaGroups", {"filter[app]": app, "filter[name]": name})["data"]
    group = next((g for g in groups if g["attributes"]["name"] == name), None)
    if group is None:
        raise SystemExit(f"no beta group named {name!r}")
    client.call("POST", f"/betaGroups/{group['id']}/relationships/builds",
                body={"data": [{"type": "builds", "id": build}]})
    print(f"added to {name}")


def submit_for_review(client, build):
    state = client.call("GET", f"/builds/{build}/buildBetaDetail")["data"]["attributes"].get("externalBuildState")
    if state in ("WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW", "BETA_APPROVED", "IN_BETA_TESTING"):
        print(f"already {state}; not submitting again")
        return
    client.call("POST", "/betaAppReviewSubmissions", body={"data": {
        "type": "betaAppReviewSubmissions",
        "relationships": {"build": {"data": {"type": "builds", "id": build}}}}})
    print("submitted for Beta App Review")


def main():
    parser = argparse.ArgumentParser()
    for name in ("key", "app", "version", "build"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--group")
    parser.add_argument("--notes")
    parser.add_argument("--exists", action="store_true", help="only print true or false: is this build uploaded")
    args = parser.parse_args()
    client = Client(args.key)
    if args.exists:
        print("true" if find_build(client, args.app, args.version, args.build) else "false")
        return
    notes = json.load(open(args.notes))
    build = wait_for_build(client, args.app, args.version, args.build)
    set_what_to_test(client, build, notes)
    add_to_group(client, args.app, build, args.group)
    submit_for_review(client, build)


if __name__ == "__main__":
    sys.exit(main())
