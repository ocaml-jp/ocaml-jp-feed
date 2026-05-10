open! Core

type t =
  { id : string
  ; title : string
  ; link : string
  }
[@@deriving fields ~getters]

let create ~id ~title ~link =
  match id, link with
  | "", "" -> None
  | "", _ -> Some { id = link; title; link }
  | _ -> Some { id; title; link }
;;
