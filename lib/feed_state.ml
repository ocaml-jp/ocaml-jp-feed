open! Core
open! Async
open Jsonaf.Export

module Classification = struct
  type t =
    { verdict : bool
    ; user_prompt : string
    }
  [@@deriving fields ~getters, jsonaf]
end

module Seen = struct
  type t =
    { id : string
    ; classification : Classification.t option [@jsonaf.option]
    }
  [@@deriving fields ~getters, jsonaf]
end

type t =
  { url : string
  ; seen : Seen.t list
  }
[@@deriving fields ~getters, jsonaf]

let load path =
  Deferred.Or_error.try_with (fun () ->
    match%bind Sys.file_exists_exn path with
    | false -> return None
    | true ->
      let%map contents = Reader.file_contents path in
      Some (contents |> Jsonaf.parse |> Or_error.ok_exn |> [%of_jsonaf: t]))
;;

let save path t =
  Deferred.Or_error.try_with (fun () ->
    let%bind () = Unix.mkdir ~p:() (Filename.dirname path) in
    Writer.save path ~contents:(Jsonaf.to_string_hum ([%jsonaf_of: t] t)))
;;
