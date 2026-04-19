# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "feedparser",
#   "pydantic",
#   "pyyaml",
#   "requests",
# ]
# ///
"""Poll RSS/Atom feeds listed in feeds.yaml and post new items to Discord."""

from __future__ import annotations

import logging
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import feedparser
import requests
import yaml
from pydantic import BaseModel, ConfigDict, Field, HttpUrl

FEEDS_FILE = Path("feeds.yaml")
STATE_DIR = Path("state")
MAX_SEEN_IDS = 500
DISCORD_POST_INTERVAL_SECONDS = 2.0
HTTP_TIMEOUT = 30
USER_AGENT = "ocaml-jp-feed-poller/1.0"

logger = logging.getLogger("poll")


def slugify(name: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return s or "feed"


class FeedConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str
    url: HttpUrl

    @property
    def slug(self) -> str:
        return slugify(self.name)

    @property
    def state_path(self) -> Path:
        return STATE_DIR / f"{self.slug}.json"


class FeedsFile(BaseModel):
    model_config = ConfigDict(extra="forbid")

    feeds: list[FeedConfig] = Field(default_factory=list)

    @classmethod
    def load(cls, path: Path) -> FeedsFile:
        with path.open() as f:
            data = yaml.safe_load(f) or {}
        return cls.model_validate(data)


class FeedState(BaseModel):
    """On-disk state for a single feed.

    Date-field formats differ on purpose:
    - ``last_checked`` is minted by us; stored as an aware ``datetime`` and
      serialized by pydantic as ISO 8601.
    - ``last_modified`` is stored verbatim from the feed's HTTP Last-Modified
      header, which RFC 9110 defines as HTTP-date format (e.g.
      "Fri, 17 Apr 2026 09:00:00 GMT"). We pass it back unmodified as
      If-Modified-Since on the next fetch, so we keep it as an opaque str.
    - ``etag`` is likewise kept verbatim (including quotes) — it's opaque to us.
    """

    # ignore unknown fields so we stay forward-compatible with old state files
    model_config = ConfigDict(extra="ignore")

    url: str
    etag: str | None = None
    last_modified: str | None = None
    last_checked: datetime | None = None
    seen_ids: list[str] = Field(default_factory=list)

    @classmethod
    def load(cls, path: Path) -> FeedState | None:
        if not path.exists():
            return None
        return cls.model_validate_json(path.read_text())

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.model_dump_json(indent=2) + "\n")


def now_utc() -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0)


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
    for _ in range(3):
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


def replay_feed(feed_cfg: FeedConfig, webhook_url: str, n: int) -> None:
    name = feed_cfg.name
    url = str(feed_cfg.url)
    logger.info("[%s] replay: fetching %s", name, url)
    resp = requests.get(url, headers={"User-Agent": USER_AGENT}, timeout=HTTP_TIMEOUT)
    resp.raise_for_status()
    parsed = feedparser.parse(resp.content)
    if parsed.bozo and not parsed.entries:
        raise RuntimeError(f"failed to parse feed: {parsed.bozo_exception}")

    # Feeds are newest-first; take the first N, then post oldest-first.
    recent = list(reversed(parsed.entries[:n]))
    logger.info("[%s] replay: posting %d items", name, len(recent))
    for entry in recent:
        post_to_discord(
            webhook_url,
            name,
            entry.get("title", "(no title)"),
            entry.get("link", ""),
        )
        time.sleep(DISCORD_POST_INTERVAL_SECONDS)


def process_feed(feed_cfg: FeedConfig, webhook_url: str) -> None:
    name = feed_cfg.name
    url = str(feed_cfg.url)
    existing = FeedState.load(feed_cfg.state_path)
    is_first_run = existing is None
    state = existing or FeedState(url=url)

    logger.info("[%s] fetching %s", name, url)
    resp = fetch_feed(url, state.etag, state.last_modified)

    if resp.status_code == 304:
        logger.info("[%s] not modified", name)
        state.url = url
        state.last_checked = now_utc()
        state.save(feed_cfg.state_path)
        return

    resp.raise_for_status()
    parsed = feedparser.parse(resp.content)
    if parsed.bozo and not parsed.entries:
        raise RuntimeError(f"failed to parse feed: {parsed.bozo_exception}")

    # Feeds are conventionally newest-first; reverse so we post chronologically
    # and so pruning keeps the most recent IDs.
    entries_oldest_first = list(reversed(parsed.entries))
    seen = set(state.seen_ids)

    if is_first_run:
        seeded = [entry_id(e) for e in entries_oldest_first if entry_id(e)]
        logger.info("[%s] first run: seeding %d items (no posts)", name, len(seeded))
        state.seen_ids = seeded[-MAX_SEEN_IDS:]
        state.url = url
        state.etag = resp.headers.get("ETag")
        state.last_modified = resp.headers.get("Last-Modified")
        state.last_checked = now_utc()
        state.save(feed_cfg.state_path)
        return

    new_entries = [e for e in entries_oldest_first if entry_id(e) and entry_id(e) not in seen]
    logger.info("[%s] %d new items", name, len(new_entries))

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
        state.seen_ids = (state.seen_ids + posted_ids)[-MAX_SEEN_IDS:]
        state.url = url
        state.last_checked = now_utc()
        if completed:
            state.etag = resp.headers.get("ETag")
            state.last_modified = resp.headers.get("Last-Modified")
        state.save(feed_cfg.state_path)


def prune_orphans(active_slugs: set[str]) -> None:
    if not STATE_DIR.exists():
        return
    for path in STATE_DIR.glob("*.json"):
        if path.stem not in active_slugs:
            logger.info("[orphan] removing %s", path)
            path.unlink()


def parse_replay_last() -> int:
    raw = (os.environ.get("REPLAY_LAST") or "").strip()
    if not raw:
        return 0
    try:
        n = int(raw)
    except ValueError:
        logger.error("REPLAY_LAST must be a positive integer, got: %r", raw)
        raise SystemExit(2)
    if n <= 0:
        logger.error("REPLAY_LAST must be a positive integer, got: %d", n)
        raise SystemExit(2)
    return n


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        stream=sys.stderr,
    )

    webhook_url = os.environ.get("DISCORD_WEBHOOK_URL")
    if not webhook_url:
        logger.error("DISCORD_WEBHOOK_URL is not set")
        return 1

    replay_n = parse_replay_last()
    feeds = FeedsFile.load(FEEDS_FILE).feeds

    failed = 0
    for feed_cfg in feeds:
        try:
            if replay_n:
                replay_feed(feed_cfg, webhook_url, replay_n)
            else:
                process_feed(feed_cfg, webhook_url)
        except Exception as e:
            failed += 1
            logger.error("[%s] %s", feed_cfg.name, e)

    if not replay_n:
        prune_orphans({f.slug for f in feeds})
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
