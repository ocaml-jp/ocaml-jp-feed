open! Core
open! Async

let post_interval = Time_float.Span.of_sec 2.
let state_dir = "state"
let state_path slug = state_dir ^/ slug ^ ".json"

let post_entry ~post_target ~feed_name (e : Entry.t) =
  let title = if String.is_empty e.title then "(no title)" else e.title in
  match post_target with
  | `Discord_webhook_url webhook_url ->
    Discord.post ~webhook_url ~feed_name ~title ~link:e.link
  | `Skip_discord_notification ->
    [%log.global.info "skipping post" feed_name title ~link:e.link];
    Deferred.Or_error.return ()
;;

(* Atom/RSS feeds are conventionally newest-first; reverse so we post chronologically. *)
let entries_oldest_first entries = List.rev entries

let classify_entry ~openrouter_api_key (feed : Feed_config.Feed.t) (entry : Entry.t) =
  match feed.mixed_content with
  | false -> Deferred.Or_error.return None
  | true ->
    let api_key =
      match openrouter_api_key with
      | Some k -> k
      | None ->
        raise_s
          [%message
            "OPENROUTER_API_KEY is required to classify entries from a mixed-content feed"
              ~feed:(feed.name : string)]
    in
    let%map.Deferred.Or_error c = Classifier.classify ~api_key ~entry in
    Some c
;;

let process_entries
      ~post_target
      ~openrouter_api_key
      ~path
      (feed : Feed_config.Feed.t)
      (state : Feed_state.t)
      entries
  =
  let%map.Deferred.Or_error _final =
    Deferred.Or_error.List.fold entries ~init:state ~f:(fun state (entry : Entry.t) ->
      let cached_classification =
        List.find state.seen ~f:(fun s -> String.equal (Feed_state.Seen.id s) entry.id)
        |> Option.bind ~f:Feed_state.Seen.classification
      in
      let%bind.Deferred.Or_error classification =
        match cached_classification with
        | Some _ as c -> Deferred.Or_error.return c
        | None -> classify_entry ~openrouter_api_key feed entry
      in
      let%bind.Deferred.Or_error () =
        match Option.map classification ~f:Feed_state.Classification.verdict with
        | Some false -> Deferred.Or_error.return ()
        | None | Some true ->
          let%bind.Deferred.Or_error () =
            post_entry ~post_target ~feed_name:feed.name entry
          in
          Clock.after post_interval >>| Or_error.return
      in
      let updated_seen =
        let new_entry = { Feed_state.Seen.id = entry.id; classification } in
        let others =
          List.filter state.seen ~f:(fun s ->
            not (String.equal (Feed_state.Seen.id s) entry.id))
        in
        others @ [ new_entry ]
      in
      let updated = { state with seen = updated_seen } in
      let%map.Deferred.Or_error () = Feed_state.save path updated in
      updated)
  in
  ()
;;

let process_feed ?replay_last ~post_target ~openrouter_api_key (feed : Feed_config.Feed.t)
  =
  let%tydi { slug; name; url; mixed_content = _ } = feed in
  let path = state_path slug in
  [%log.global.info "fetching" name url];
  let%bind.Deferred.Or_error all_entries = Feed_fetch.fetch ~url in
  let%bind.Deferred.Or_error existing_state = Feed_state.load path in
  match replay_last, existing_state with
  | None, None ->
    let entries = entries_oldest_first all_entries in
    [%log.global.info
      "first run: seeding (no posts)" name ~count:(List.length entries : int)];
    let seen =
      List.map entries ~f:(fun e -> { Feed_state.Seen.id = e.id; classification = None })
    in
    Feed_state.save path { url; seen }
  | None, Some state ->
    let already_seen = String.Set.of_list (List.map state.seen ~f:Feed_state.Seen.id) in
    let new_entries =
      entries_oldest_first all_entries
      |> List.filter ~f:(fun e -> not (Set.mem already_seen e.id))
    in
    [%log.global.info "new items" name ~count:(List.length new_entries : int)];
    process_entries ~post_target ~openrouter_api_key ~path feed state new_entries
  | Some n, existing_state ->
    let state = Option.value existing_state ~default:{ Feed_state.url; seen = [] } in
    let recent = List.take all_entries n |> List.rev in
    [%log.global.info "replay: processing" name ~count:(List.length recent : int)];
    process_entries ~post_target ~openrouter_api_key ~path feed state recent
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
