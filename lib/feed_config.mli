(** Loads [feeds.json]: the list of RSS/Atom sources to poll.

    Each feed carries an explicit [slug] which becomes the on-disk state filename
    ([state/<slug>.json]); slugs must be unique and filename-safe. *)

open! Core
open! Async

module Feed : sig
  type t =
    { slug : string
    ; name : string
    ; url : string
    }
  [@@deriving fields ~getters, jsonaf]
end

type t = { feeds : Feed.t list } [@@deriving jsonaf]

val load : string -> t Deferred.Or_error.t
