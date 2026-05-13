open! Core
open! Async
open! Ocaml_jp_feed

let env_required_string name =
  match Sys.getenv name |> Option.map ~f:String.strip with
  | Some s when not (String.is_empty s) -> s
  | _ -> raise_s [%message "required environment variable is not set" name]
;;

let env_optional_string name =
  match Sys.getenv name |> Option.map ~f:String.strip with
  | Some s when not (String.is_empty s) -> Some s
  | _ -> None
;;

let env_optional_positive_int name =
  match Sys.getenv name |> Option.map ~f:String.strip with
  | None | Some "" -> None
  | Some raw ->
    (match Int.of_string_opt raw with
     | Some n when n > 0 -> Some n
     | _ -> raise_s [%message "environment variable must be a positive integer" name raw])
;;

let process_one ~post_target ~replay_last ~openrouter_api_key (feed : Feed_config.Feed.t) =
  Poller.process_feed ?replay_last ~post_target ~openrouter_api_key feed
  |> Deferred.Or_error.tag ~tag:feed.name
;;

let main =
  Command.async_or_error
    ~summary:"Poll RSS/Atom feeds and post new items to Discord"
    (let%map_open.Command no_post =
       flag
         "-no-post"
         no_arg
         ~doc:
           " skip posting to Discord (useful for backfilling classifications without \
            spamming the channel)"
     in
     fun () ->
       let post_target =
         match no_post with
         | true -> `Skip_discord_notification
         | false -> `Discord_webhook_url (env_required_string "DISCORD_WEBHOOK_URL")
       in
       let replay_last = env_optional_positive_int "REPLAY_LAST" in
       let openrouter_api_key = env_optional_string "OPENROUTER_API_KEY" in
       let%bind.Deferred.Or_error { feeds } = Feed_config.load "feeds.json" in
       (* Parallel feeds share one Discord webhook; rate-limit collisions are absorbed
          by [Discord.post]'s 429 retry. *)
       let%map.Deferred.Or_error () =
         Deferred.Or_error.List.iter
           ~how:`Parallel
           feeds
           ~f:(process_one ~post_target ~replay_last ~openrouter_api_key)
       and () =
         match replay_last with
         | None ->
           Poller.prune_orphans
             ~active_slugs:(List.map feeds ~f:Feed_config.Feed.slug |> String.Set.of_list)
         | Some _ -> Deferred.Or_error.return ()
       in
       ())
;;

let () = Command_unix.run main
