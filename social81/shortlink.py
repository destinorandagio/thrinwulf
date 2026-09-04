#!/usr/bin/env python3
"""SOCIAL81+ resilient tracked-link generator.

Creates campaign UTM URLs and tries multiple no-key shortening providers.
If all external shorteners fail, it still emits the tracked destination so
publishing never loses attribution.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone
from urllib.parse import urlencode, urlsplit, urlunsplit, parse_qsl
from urllib.request import Request, urlopen

DEFAULT_DESTINATION = "https://corsi.elearningsicurezza.com/pid/2377/"
USER_AGENT = "Mozilla/5.0 (compatible; SOCIAL81-LinkEngine/1.1; +https://github.com/destinorandagio/thrinwulf)"


def tracked_url(destination: str, source: str, medium: str, campaign: str, content: str) -> str:
    parts = urlsplit(destination)
    if parts.scheme not in {"http", "https"} or not parts.netloc:
        raise ValueError("destination must be an absolute http(s) URL")
    query = dict(parse_qsl(parts.query, keep_blank_values=True))
    query.update({
        "utm_source": source,
        "utm_medium": medium,
        "utm_campaign": campaign,
        "utm_content": content,
    })
    return urlunsplit((parts.scheme, parts.netloc, parts.path, urlencode(query), parts.fragment))


def get_text(endpoint: str) -> str:
    req = Request(endpoint, headers={"User-Agent": USER_AGENT, "Accept": "text/plain,*/*"})
    with urlopen(req, timeout=20) as response:
        return response.read().decode("utf-8").strip()


def provider_isgd(url: str) -> dict:
    endpoint = "https://is.gd/create.php?" + urlencode({"format": "simple", "url": url, "logstats": "1"})
    result = get_text(endpoint)
    if not result.startswith("https://is.gd/"):
        raise RuntimeError(result)
    return {"short_url": result, "provider": "is.gd", "analytics_url": result + "-"}


def provider_vgd(url: str) -> dict:
    endpoint = "https://v.gd/create.php?" + urlencode({"format": "simple", "url": url, "logstats": "1"})
    result = get_text(endpoint)
    if not result.startswith("https://v.gd/"):
        raise RuntimeError(result)
    return {"short_url": result, "provider": "v.gd", "analytics_url": result + "-"}


def provider_tinyurl(url: str) -> dict:
    endpoint = "https://tinyurl.com/api-create.php?" + urlencode({"url": url})
    result = get_text(endpoint)
    if not result.startswith("https://tinyurl.com/"):
        raise RuntimeError(result)
    return {"short_url": result, "provider": "tinyurl", "analytics_url": None}


def shorten_with_fallback(url: str) -> tuple[dict, list[dict]]:
    errors = []
    for name, fn in (("is.gd", provider_isgd), ("v.gd", provider_vgd), ("tinyurl", provider_tinyurl)):
        for attempt in range(1, 3):
            try:
                return fn(url), errors
            except Exception as exc:
                errors.append({"provider": name, "attempt": attempt, "error": str(exc)[:300]})
                if attempt == 1:
                    time.sleep(2)
    # Safe degradation: keep the UTM URL usable instead of failing the post.
    return {"short_url": url, "provider": "utm-direct-fallback", "analytics_url": None}, errors


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
    link, errors = shorten_with_fallback(long_url)
    payload = {
        "created_at": now.isoformat(),
        "destination": args.destination,
        "tracked_url": long_url,
        **link,
        "shortened": link["provider"] != "utm-direct-fallback",
        "provider_errors": errors,
        "utm": {"source": args.source, "medium": args.medium, "campaign": args.campaign, "content": args.content},
    }
    os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(json.dumps(payload, ensure_ascii=False))
    if not payload["shortened"]:
        print("WARNING: all shorteners failed; using direct UTM URL", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"SOCIAL81 link-engine fatal error: {exc}", file=sys.stderr)
        raise SystemExit(1)
