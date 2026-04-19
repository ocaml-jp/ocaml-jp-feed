# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "feedparser",
#   "pyyaml",
#   "requests",
# ]
# ///
"""Poll RSS/Atom feeds listed in feeds.yaml and post new items to Discord."""

from __future__ import annotations

import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import feedparser
import requests
import yaml

FEEDS_FILE = Path("feeds.yaml")
STATE_DIR = Path("state")
MAX_SEEN_IDS = 500
DISCORD_POST_INTERVAL_SECONDS = 2.0
HTTP_TIMEOUT = 30
USER_AGENT = "ocaml-jp-feed-poller/1.0"


def slugify(name: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return s or "feed"


def now_iso() -> str:
    return (
        datetime.now(timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def load_feeds() -> list[dict]:
    with FEEDS_FILE.open() as f:
        data = yaml.safe_load(f) or {}
    return data.get("feeds") or []


def load_state(path: Path) -> dict | None:
    if not path.exists():
        return None
    with path.open() as f:
        return json.load(f)


def save_state(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as f:
        json.dump(state, f, indent=2, ensure_ascii=False, sort_keys=True)
        f.write("\n")


def entry_id(entry) -> str:
    return entry.get("id") or entry.get("link") or ""


def fetch_feed(url: str, etag: str | None, last_modified: str | None) -> requests.Response:
    headers = {"User-Agent": USER_AGENT}
    if etag:
        headers["If-None-Match"] = etag
    if last_modified:
        headers["If-Modified-Since"] = last_modified
    return requests.get(url, headers=headers, timeout=HTTP_TIMEOUT)


def post_to_discord(webhook_url: str, feed_name: str, title: str, link: str) -> None:
    content = f"**{feed_name}**: {title}\n{link}"
    for attempt in range(3):
        resp = requests.post(
            webhook_url,
            json={"content": content},
            timeout=HTTP_TIMEOUT,
        )
        if resp.status_code == 429:
            retry_after = float(resp.headers.get("Retry-After", "5"))
            time.sleep(retry_after)
            continue
        resp.raise_for_status()
        return
    raise RuntimeError(f"Discord post failed after retries: {title}")


def replay_feed(feed_cfg: dict, webhook_url: str, n: int) -> None:
    name = feed_cfg["name"]
    url = feed_cfg["url"]
    print(f"[{name}] replay: fetching {url}", flush=True)
    resp = requests.get(url, headers={"User-Agent": USER_AGENT}, timeout=HTTP_TIMEOUT)
    resp.raise_for_status()
    parsed = feedparser.parse(resp.content)
    if parsed.bozo and not parsed.entries:
        raise RuntimeError(f"failed to parse feed: {parsed.bozo_exception}")

    # Feeds are newest-first; take the first N, then post oldest-first.
    recent = list(reversed(parsed.entries[:n]))
    print(f"[{name}] replay: posting {len(recent)} items", flush=True)
    for entry in recent:
        post_to_discord(
            webhook_url,
            name,
            entry.get("title", "(no title)"),
            entry.get("link", ""),
        )
        time.sleep(DISCORD_POST_INTERVAL_SECONDS)


def process_feed(feed_cfg: dict, webhook_url: str) -> None:
    name = feed_cfg["name"]
    url = feed_cfg["url"]
    state_path = STATE_DIR / f"{slugify(name)}.json"
    existing = load_state(state_path)
    is_first_run = existing is None
    state: dict = existing or {
        "url": url,
        "etag": None,
        "last_modified": None,
        "seen_ids": [],
    }

    print(f"[{name}] fetching {url}", flush=True)
    resp = fetch_feed(url, state.get("etag"), state.get("last_modified"))

    if resp.status_code == 304:
        print(f"[{name}] not modified", flush=True)
        state["url"] = url
        state["last_checked"] = now_iso()
        save_state(state_path, state)
        return

    resp.raise_for_status()
    parsed = feedparser.parse(resp.content)
    if parsed.bozo and not parsed.entries:
        raise RuntimeError(f"failed to parse feed: {parsed.bozo_exception}")

    # Feeds are conventionally newest-first; reverse so we post chronologically
    # and so pruning keeps the most recent IDs.
    entries_oldest_first = list(reversed(parsed.entries))
    seen = set(state.get("seen_ids", []))

    if is_first_run:
        seeded = [entry_id(e) for e in entries_oldest_first if entry_id(e)]
        print(f"[{name}] first run: seeding {len(seeded)} items (no posts)", flush=True)
        state["seen_ids"] = seeded[-MAX_SEEN_IDS:]
        state["url"] = url
        state["etag"] = resp.headers.get("ETag")
        state["last_modified"] = resp.headers.get("Last-Modified")
        state["last_checked"] = now_iso()
        save_state(state_path, state)
        return

    new_entries = [e for e in entries_oldest_first if entry_id(e) and entry_id(e) not in seen]
    print(f"[{name}] {len(new_entries)} new items", flush=True)

    posted_ids: list[str] = []
    completed = False
    try:
        for entry in new_entries:
            post_to_discord(
                webhook_url,
                name,
                entry.get("title", "(no title)"),
                entry.get("link", ""),
            )
            posted_ids.append(entry_id(entry))
            time.sleep(DISCORD_POST_INTERVAL_SECONDS)
        completed = True
    finally:
        # Commit whatever we successfully posted so we never double-post,
        # even if a later post or network call fails.
        state["seen_ids"] = (state.get("seen_ids", []) + posted_ids)[-MAX_SEEN_IDS:]
        state["url"] = url
        state["last_checked"] = now_iso()
        if completed:
            state["etag"] = resp.headers.get("ETag")
            state["last_modified"] = resp.headers.get("Last-Modified")
        save_state(state_path, state)


def prune_orphans(active_slugs: set[str]) -> None:
    if not STATE_DIR.exists():
        return
    for path in STATE_DIR.glob("*.json"):
        if path.stem not in active_slugs:
            print(f"[orphan] removing {path}", flush=True)
            path.unlink()


def parse_replay_last() -> int:
    raw = (os.environ.get("REPLAY_LAST") or "").strip()
    if not raw:
        return 0
    try:
        n = int(raw)
    except ValueError:
        print(f"REPLAY_LAST must be a positive integer, got: {raw!r}", file=sys.stderr)
        raise SystemExit(2)
    if n <= 0:
        print(f"REPLAY_LAST must be a positive integer, got: {n}", file=sys.stderr)
        raise SystemExit(2)
    return n


def main() -> int:
    webhook_url = os.environ.get("DISCORD_WEBHOOK_URL")
    if not webhook_url:
        print("DISCORD_WEBHOOK_URL is not set", file=sys.stderr)
        return 1

    replay_n = parse_replay_last()
    feeds = load_feeds()

    failed = 0
    for feed_cfg in feeds:
        try:
            if replay_n:
                replay_feed(feed_cfg, webhook_url, replay_n)
            else:
                process_feed(feed_cfg, webhook_url)
        except Exception as e:
            failed += 1
            print(f"[{feed_cfg.get('name', '?')}] ERROR: {e}", file=sys.stderr, flush=True)

    if not replay_n:
        prune_orphans({slugify(f["name"]) for f in feeds})
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
