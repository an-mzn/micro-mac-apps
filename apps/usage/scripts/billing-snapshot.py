#!/usr/bin/env python3
"""Fetch provider billing amounts and write a credential-free Usage snapshot."""

import argparse
import datetime
import getpass
import json
import math
import os
from pathlib import Path
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def fetch(url, token, github=False):
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
    if github:
        headers.update({"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2026-03-10"})
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.build_opener(NoRedirect()).open(request, timeout=25) as response:
        return json.loads(response.read(4_194_305))


def amount(label, value):
    if isinstance(value, bool):
        raise ValueError("Invalid amount")
    value = float(value)
    if not math.isfinite(value) or value < 0:
        raise ValueError("Invalid amount")
    return {"label": label, "value": value}


def snapshot(args):
    if args.provider == "deepseek":
        token = os.environ.get("DEEPSEEK_API_KEY") or getpass.getpass("DeepSeek API key: ")
        response = fetch("https://api.deepseek.com/user/balance", token)
        records = response["balance_infos"]
        return [amount(f"{row['currency']} balance", row["total_balance"]) for row in records
                if row["currency"] in {"USD", "CNY"}]

    token = os.environ.get("GH_TOKEN") or getpass.getpass("GitHub fine-grained token: ")
    now = datetime.datetime.now(datetime.timezone.utc)
    period = urllib.parse.urlencode({"year": now.year, "month": now.month})
    user = urllib.parse.quote(args.username, safe="")
    kind = "premium_request" if args.premium_requests else "ai_credit"
    url = f"https://api.github.com/users/{user}/settings/billing/{kind}/usage?{period}"
    response = fetch(url, token, github=True)
    total = sum(amount("", row["grossQuantity"])["value"] for row in response["usageItems"]
                if row.get("product", "").lower() == "copilot")
    unit = "Requests" if args.premium_requests else "AI credits"
    return [amount(f"{unit} used · {now:%b %Y}", total)]


def write_snapshot(path, provider, amounts):
    if not 1 <= len(amounts) <= 12:
        raise ValueError("No usable billing readings")
    path = Path(path).expanduser()
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".usage-")
    try:
        with os.fdopen(fd, "w") as output:
            json.dump({"provider": provider, "amounts": amounts}, output, allow_nan=False)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("provider", choices=["copilot", "deepseek"])
    parser.add_argument("destination")
    parser.add_argument("--username", help="GitHub username for a personal Copilot plan")
    parser.add_argument("--premium-requests", action="store_true", help="Use the legacy Copilot premium request report")
    args = parser.parse_args()
    if args.provider == "copilot" and not args.username:
        parser.error("copilot requires --username")
    try:
        write_snapshot(args.destination, args.provider, snapshot(args))
    except urllib.error.HTTPError as error:
        print(f"Provider request failed (HTTP {error.code}). Existing snapshot kept.", file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, TypeError):
        print("Could not save a valid billing snapshot. Existing snapshot kept.", file=sys.stderr)
        return 1
    print("Usage snapshot saved.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
