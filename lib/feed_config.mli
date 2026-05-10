(** Loads [feeds.json]: the list of RSS/Atom sources to poll.

    Each feed carries an explicit [slug] which becomes the on-disk state filename
    ([state/<slug>.json]); slugs must be unique and filename-safe.

    [mixed_content] feeds carry posts that aren't all OCaml-related — each new entry is
    classified by an LLM before posting. Defaults to [false]. *)

open! Core
open! Async

module Feed : sig
  type t =
    { slug : string
    ; name : string
    ; url : string
    ; mixed_content : bool
    }
  [@@deriving fields ~getters, jsonaf]
end

type t = { feeds : Feed.t list } [@@deriving jsonaf]

val load : string -> t Deferred.Or_error.t
