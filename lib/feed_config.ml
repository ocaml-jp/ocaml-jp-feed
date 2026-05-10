open! Core
open! Async
open Jsonaf.Export

module Feed = struct
  type t =
    { slug : string
    ; name : string
    ; url : string
    }
  [@@deriving fields ~getters, jsonaf]
end

type t = { feeds : Feed.t list } [@@deriving jsonaf]

let load path =
  Deferred.Or_error.try_with (fun () ->
    let%map contents = Reader.file_contents path in
    contents |> Jsonaf.parse |> Or_error.ok_exn |> [%of_jsonaf: t])
;;
