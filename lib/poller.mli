(** Top-level polling logic for one feed. *)

open! Core
open! Async

(** Poll a feed:
    - First run (no state file) without [replay_last]: seed all entries without
      classifying or posting (avoids spamming the channel with historical posts).
    - Subsequent runs without [replay_last]: process entries not yet seen. For
      mixed-content feeds each entry is classified via the LLM; only verdict-true
      entries are posted.
    - With [replay_last:n]: process the last [n] entries from the feed regardless of
      whether they're already seen. Cached classifications from state are reused;
      missing ones get filled in. Useful for backfilling classifications.

    Posts within a feed are sequential with a 2s gap. State is saved after each
    successfully processed entry (crash safety).

    [post_target] is interpreted by the poller (no implicit closures): the
    [`Skip_discord_notification] variant logs and returns success without sending
    anything, useful for backfilling classifications.

    [openrouter_api_key] must be [Some _] when any entry from a mixed-content feed
    actually needs classification; otherwise it can be [None]. *)
val process_feed
  :  ?replay_last:int
  -> post_target:[ `Discord_webhook_url of string | `Skip_discord_notification ]
  -> openrouter_api_key:string option
  -> Feed_config.Feed.t
  -> unit Deferred.Or_error.t

(** Delete [state/*.json] files whose slug isn't in [active_slugs]. *)
val prune_orphans : active_slugs:String.Set.t -> unit Deferred.Or_error.t
