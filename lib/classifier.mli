(** Asks an LLM whether a feed entry is about the OCaml programming language.

    Uses OpenRouter with structured output (a forced tool call) so the response is reliably
    parseable. Returns the parsed verdict alongside the user prompt that produced it — the
    caller is expected to persist this for audit. *)

open! Core
open! Async

val classify
  :  api_key:string
  -> entry:Entry.t
  -> Feed_state.Classification.t Deferred.Or_error.t
