#!/usr/bin/env python3
"""SOCIAL81+ tracked short-link generator.

Builds a campaign-specific UTM URL and registers it with is.gd using
its public API. No API key is required. The generated JSON can be used
by SOCIAL81+ publishing workflows.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from urllib.parse import urlencode, urlsplit, urlunsplit, parse_qsl
from urllib.request import Request, urlopen

DEFAULT_DESTINATION = "https://corsi.elearningsicurezza.com/pid/2377/"
ISGD_API = "https://is.gd/create.php"


def tracked_url(destination: str, source: str, medium: str, campaign: str, content: str) -> str:
    parts = urlsplit(destination)
    query = dict(parse_qsl(parts.query, keep_blank_values=True))
    query.update({
        "utm_source": source,
        "utm_medium": medium,
        "utm_campaign": campaign,
        "utm_content": content,
    })
    return urlunsplit((parts.scheme, parts.netloc, parts.path, urlencode(query), parts.fragment))


def shorten(url: str) -> str:
    # logstats=1 enables the provider's statistics page for this URL.
    endpoint = ISGD_API + "?" + urlencode({"format": "simple", "url": url, "logstats": "1"})
    req = Request(endpoint, headers={"User-Agent": "SOCIAL81+/1.0"})
    with urlopen(req, timeout=20) as response:
        result = response.read().decode("utf-8").strip()
    if not result.startswith("https://is.gd/"):
        raise RuntimeError(f"Unexpected is.gd response: {result}")
    return result


def main() -> int:
    now = datetime.now(timezone.utc)
    parser = argparse.ArgumentParser()
    parser.add_argument("--destination", default=os.getenv("SOCIAL81_DESTINATION", DEFAULT_DESTINATION))
    parser.add_argument("--source", default=os.getenv("SOCIAL81_SOURCE", "social81"))
    parser.add_argument("--medium", default=os.getenv("SOCIAL81_MEDIUM", "social"))
    parser.add_argument("--campaign", default=os.getenv("SOCIAL81_CAMPAIGN", "free_courses"))
    parser.add_argument("--content", default=os.getenv("SOCIAL81_CONTENT", now.strftime("%Y%m%d_%H%M")))
    parser.add_argument("--output", default=os.getenv("SOCIAL81_OUTPUT", "social81/output/latest-link.json"))
    args = parser.parse_args()

    long_url = tracked_url(args.destination, args.source, args.medium, args.campaign, args.content)
    short_url = shorten(long_url)
    payload = {
        "created_at": now.isoformat(),
        "destination": args.destination,
        "tracked_url": long_url,
        "short_url": short_url,
        "provider": "is.gd",
        "analytics_url": short_url + "-",
        "utm": {"source": args.source, "medium": args.medium, "campaign": args.campaign, "content": args.content},
    }
    os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(json.dumps(payload, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"SOCIAL81 short-link error: {exc}", file=sys.stderr)
        raise SystemExit(1)
