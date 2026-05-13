(** Per-feed on-disk state at [state/<slug>.json]. Only fields that change when users care
    (new items detected) are stored, so no-op polls produce no git diff. *)

open! Core
open! Async

module Classification : sig
  (** Audit record for a single LLM classification. The static parts (system prompt, model,
      tool schema) live in code; only the per-entry signal is recorded. *)
  type t =
    { verdict : bool
    ; user_prompt : string
    }
  [@@deriving fields ~getters, jsonaf]
end

module Seen : sig
  (** A feed entry we've already processed. [classification] is [Some] iff the entry came
      from a mixed-content feed and went through the LLM. *)
  type t =
    { id : string
    ; classification : Classification.t option
    }
  [@@deriving fields ~getters, jsonaf]
end

type t =
  { url : string
  ; seen : Seen.t list
  }
[@@deriving fields ~getters, jsonaf]

(** [Ok None] if the file does not exist. *)
val load : string -> t option Deferred.Or_error.t

val save : string -> t -> unit Deferred.Or_error.t
