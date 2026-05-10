(** Posts a single message to a Discord webhook. The message body is
    [**<feed_name>**: <title>\n<link>].

    Honours the [Retry-After] header on HTTP 429 responses; retries up to 3 times total
    before returning [Error]. Returns [Error] on any other non-2xx response or if the
    request times out. *)

open! Core
open! Async

val post
  :  webhook_url:string
  -> feed_name:string
  -> title:string
  -> link:string
  -> unit Deferred.Or_error.t
