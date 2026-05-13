open! Core
open! Async

let user_agent = "ocaml-jp-feed-poller/1.0"

let http_get url =
  let headers = Cohttp.Header.of_list [ "User-Agent", user_agent ] in
  let%bind resp, body = Cohttp_async.Client.get ~headers (Uri.of_string url) in
  let%bind body = Cohttp_async.Body.to_string body in
  match Cohttp.Code.code_of_status (Cohttp.Response.status resp) with
  | code when code >= 200 && code < 300 -> return body
  | _ ->
    let status = Cohttp.Response.status resp in
    raise_s [%message "feed fetch failed" url (status : Cohttp.Code.status_code)]
;;

(* Strip Atom <link>text</link> elements with no attributes. Qiita emits these at channel
   level and they violate the Atom spec, which syndic refuses. We can't apply this
   unconditionally — RSS2's <link>text</link> is valid syntax — so it only runs as a final
   fallback. *)
let bare_link_re = Re.Pcre.re "<link>[^<]*</link>" |> Re.compile
let strip_bare_links body = Re.replace_string bare_link_re ~by:"" body

let atom_text_construct (t : Syndic.Atom.text_construct) =
  match t with
  | Text s | Html (_, s) -> Some s
  | Xhtml _ -> None
;;

let atom_description (e : Syndic.Atom.entry) =
  match e.summary with
  | Some s -> atom_text_construct s
  | None ->
    (match e.content with
     | Some (Text s | Html (_, s)) -> Some s
     | Some (Xhtml _ | Mime _ | Src _) | None -> None)
;;

let atom_entry (e : Syndic.Atom.entry) =
  Entry.create
    ~id:(Uri.to_string e.id)
    ~title:(atom_text_construct e.title |> Option.value ~default:"")
    ~link:
      (match e.links with
       | l :: _ -> Uri.to_string l.href
       | [] -> "")
    ~description:(atom_description e)
;;

let rss2_entry (i : Syndic.Rss2.item) =
  let title, description =
    match i.story with
    | All (t, _, d) -> t, Some d
    | Title t -> t, None
    | Description (_, d) -> "", Some d
  in
  Entry.create
    ~id:(Option.value_map i.guid ~default:"" ~f:(fun g -> Uri.to_string g.data))
    ~title
    ~link:(Option.value_map i.link ~default:"" ~f:Uri.to_string)
    ~description
;;

let make_xml body = Xmlm.make_input (`String (0, body))

let try_atom body =
  Or_error.try_with (fun () -> Syndic.Atom.parse (make_xml body))
  |> Or_error.map ~f:(fun feed -> List.filter_map feed.entries ~f:atom_entry)
  |> Or_error.tag ~tag:"atom"
;;

let try_rss2 body =
  Or_error.try_with (fun () -> Syndic.Rss2.parse (make_xml body))
  |> Or_error.map ~f:(fun channel -> List.filter_map channel.items ~f:rss2_entry)
  |> Or_error.tag ~tag:"rss2"
;;

let parse body =
  match try_atom body with
  | Ok entries -> Ok entries
  | Error atom_err ->
    (match try_rss2 body with
     | Ok entries -> Ok entries
     | Error rss_err ->
       (match
          try_atom (strip_bare_links body)
          |> Or_error.tag ~tag:"after stripping bare links"
        with
        | Ok entries -> Ok entries
        | Error patched_err ->
          Or_error.error_s
            [%message
              "failed to parse feed"
                (atom_err : Error.t)
                (rss_err : Error.t)
                (patched_err : Error.t)]))
;;

let fetch ~url =
  Deferred.Or_error.try_with_join (fun () ->
    let%bind body = http_get url in
    return (parse body))
;;
