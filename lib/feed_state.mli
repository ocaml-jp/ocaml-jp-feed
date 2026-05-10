(** Per-feed on-disk state at [state/<slug>.json]. Only fields that change when users care
    (new items detected) are stored, so no-op polls produce no git diff. *)

open! Core
open! Async

type t =
  { url : string
  ; seen_ids : string list
  }

(** [Ok None] if the file does not exist. *)
val load : string -> t option Deferred.Or_error.t

val save : string -> t -> unit Deferred.Or_error.t
