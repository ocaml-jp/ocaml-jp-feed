(** Top-level polling logic for one feed. *)

open! Core
open! Async

(** Fetch the feed; on first run (no state file), seed all current entry IDs with no
    posts. Otherwise, post every new entry to Discord oldest-first and update the state
    file. The state is saved even if a later post fails, so we never double-post. *)
val process_feed : webhook_url:string -> Feed_config.Feed.t -> unit Deferred.Or_error.t

(** Re-post the last [n] entries from a feed. Does not touch the state file. Used for
    testing the wiring end-to-end. *)
val replay_feed
  :  webhook_url:string
  -> n:int
  -> Feed_config.Feed.t
  -> unit Deferred.Or_error.t

(** Delete [state/*.json] files whose slug isn't in [active_slugs]. *)
val prune_orphans : active_slugs:String.Set.t -> unit Deferred.Or_error.t
