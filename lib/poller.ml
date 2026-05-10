open! Core
open! Async

let post_interval = Time_float.Span.of_sec 2.
let state_dir = "state"
let state_path slug = state_dir ^/ slug ^ ".json"

let post_entry ~webhook_url ~feed_name (e : Entry.t) =
  Discord.post
    ~webhook_url
    ~feed_name
    ~title:(if String.is_empty e.title then "(no title)" else e.title)
    ~link:e.link
;;

(* Atom/RSS feeds are conventionally newest-first; reverse so we post chronologically. *)
let entries_oldest_first entries = List.rev entries

(* Sequentially post each entry; on failure, save what we already posted (so we never
   double-post) and propagate the error. *)
let rec post_loop ~webhook_url ~feed_name ~save_partial posted entries =
  match (entries : Entry.t list) with
  | [] -> save_partial (List.rev posted)
  | entry :: rest ->
    (match%bind post_entry ~webhook_url ~feed_name entry with
     | Error e ->
       let%bind.Deferred.Or_error () = save_partial (List.rev posted) in
       Deferred.return (Error e)
     | Ok () ->
       let%bind () = Clock.after post_interval in
       post_loop ~webhook_url ~feed_name ~save_partial (entry.id :: posted) rest)
;;

let process_feed ~webhook_url (feed : Feed_config.Feed.t) =
  let%tydi { slug; name; url } = feed in
  let path = state_path slug in
  [%log.global.info "fetching" name url];
  let%bind.Deferred.Or_error entries = Feed_fetch.fetch ~url in
  let entries = entries_oldest_first entries in
  match%bind.Deferred.Or_error Feed_state.load path with
  | None ->
    [%log.global.info
      "first run: seeding (no posts)" name ~count:(List.length entries : int)];
    Feed_state.save path { url; seen_ids = List.map entries ~f:Entry.id }
  | Some state ->
    let seen = String.Set.of_list state.seen_ids in
    let new_entries = List.filter entries ~f:(fun e -> not (Set.mem seen e.id)) in
    [%log.global.info "new items" name ~count:(List.length new_entries : int)];
    let save_partial new_ids =
      match new_ids with
      | [] -> Deferred.Or_error.return ()
      | ids -> Feed_state.save path { url; seen_ids = state.seen_ids @ ids }
    in
    post_loop ~webhook_url ~feed_name:name ~save_partial [] new_entries
;;

let replay_feed ~webhook_url ~n (feed : Feed_config.Feed.t) =
  let%tydi { slug = _; name; url } = feed in
  [%log.global.info "replay: fetching" name url];
  let%bind.Deferred.Or_error entries = Feed_fetch.fetch ~url in
  let recent = List.take entries n |> List.rev in
  [%log.global.info "replay: posting" name ~count:(List.length recent : int)];
  Deferred.Or_error.List.iter ~how:`Sequential recent ~f:(fun e ->
    let%bind.Deferred.Or_error () = post_entry ~webhook_url ~feed_name:name e in
    Clock.after post_interval >>| Or_error.return)
;;

let prune_orphans ~active_slugs =
  Deferred.Or_error.try_with (fun () ->
    match%bind Sys.file_exists_exn state_dir with
    | false -> return ()
    | true ->
      let%bind entries = Sys.readdir state_dir in
      Deferred.Array.iter ~how:`Parallel entries ~f:(fun name ->
        match String.chop_suffix name ~suffix:".json" with
        | None -> return ()
        | Some slug when Set.mem active_slugs slug -> return ()
        | Some _ ->
          let path = state_dir ^/ name in
          [%log.global.info "removing orphan state file" path];
          Unix.unlink path))
;;
