open! Core

type t =
  { id : string
  ; title : string
  ; link : string
  ; description : string option
  }
[@@deriving fields ~getters]

let create ~id ~title ~link ~description =
  match id, link with
  | "", "" -> None
  | "", _ -> Some { id = link; title; link; description }
  | _ -> Some { id; title; link; description }
;;
