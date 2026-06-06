(** A feed entry, normalised across Atom and RSS2.

    [id] is non-empty by construction: [create] falls back to the link when the source's
    id/guid is missing, and returns [None] when both are absent (the entry is then
    unrecoverable for deduplication and we drop it). *)

open! Core

type t = private
  { id : string
  ; title : string
  ; link : string
  ; description : string option
  }
[@@deriving fields ~getters, sexp_of]

val create
  :  id:string
  -> title:string
  -> link:string
  -> description:string option
  -> t option
