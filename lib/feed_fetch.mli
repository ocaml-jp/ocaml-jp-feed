(** Fetches a feed URL over HTTPS and parses it as RSS or Atom into a uniform
    [Entry.t list]. Returns entries in feed order (newest first); the caller is
    responsible for reversing if it wants to process oldest-first.

    Tries Atom first, then RSS2, then a final Atom attempt with bare [<link>text</link>]
    elements stripped (works around Qiita's malformed channel-level link). Returns [Error]
    if all three fail or the HTTP request returns a non-2xx status. *)

open! Core
open! Async

val fetch : url:string -> Entry.t list Deferred.Or_error.t
