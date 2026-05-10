open! Core
open! Async
open! Ocaml_jp_feed

let env_required_string name =
  match Sys.getenv name |> Option.map ~f:String.strip with
  | Some s when not (String.is_empty s) -> s
  | _ -> raise_s [%message "required environment variable is not set" name]
;;

let env_optional_positive_int name ~default =
  match Sys.getenv name |> Option.map ~f:String.strip with
  | None | Some "" -> default
  | Some raw ->
    (match Int.of_string_opt raw with
     | Some n when n > 0 -> n
     | _ -> raise_s [%message "environment variable must be a positive integer" name raw])
;;

let process_one ~webhook_url ~replay_n (feed : Feed_config.Feed.t) =
  (match replay_n with
   | 0 -> Poller.process_feed ~webhook_url feed
   | n -> Poller.replay_feed ~webhook_url ~n feed)
  |> Deferred.Or_error.tag ~tag:feed.name
;;

let main =
  Command.async_or_error
    ~summary:"Poll RSS/Atom feeds and post new items to Discord"
    (Command.Param.return (fun () ->
       let webhook_url = env_required_string "DISCORD_WEBHOOK_URL" in
       let replay_n = env_optional_positive_int "REPLAY_LAST" ~default:0 in
       let%bind.Deferred.Or_error { feeds } = Feed_config.load "feeds.json" in
       (* Feeds are independent — fetching, parsing, and per-feed posting all run in
          parallel. Posts within a single feed stay sequential (Discord 2s spacing). With
          one shared webhook URL, parallel feeds can collide on Discord's rate limit; the
          per-post 429 retry handles that. Pruning runs concurrently with feeds. *)
       let%map.Deferred.Or_error () =
         Deferred.Or_error.List.iter
           ~how:`Parallel
           feeds
           ~f:(process_one ~webhook_url ~replay_n)
       and () =
         match replay_n with
         | 0 ->
           Poller.prune_orphans
             ~active_slugs:(List.map feeds ~f:Feed_config.Feed.slug |> String.Set.of_list)
         | _ -> Deferred.Or_error.return ()
       in
       ()))
;;

let () = Command_unix.run main
