open! Core
open! Async

let http_timeout = Time_float.Span.of_sec 30.

let try_post ~webhook_url ~content =
  let headers = Cohttp.Header.of_list [ "Content-Type", "application/json" ] in
  let body =
    `Object [ "content", `String content ]
    |> Jsonaf.to_string
    |> Cohttp_async.Body.of_string
  in
  Cohttp_async.Client.post ~headers ~body (Uri.of_string webhook_url)
;;

(* Discord returns Retry-After in seconds; it can be a float. *)
let retry_after_seconds resp =
  match Cohttp.Header.get (Cohttp.Response.headers resp) "Retry-After" with
  | None -> 5.
  | Some s ->
    (match Float.of_string_opt (String.strip s) with
     | Some f when Float.(f > 0.) -> f
     | _ -> 5.)
;;

let post ~webhook_url ~feed_name ~title ~link =
  let content = [%string "**%{feed_name}**: %{title}\n%{link}"] in
  let max_attempts = 3 in
  (* [try_with_join] also catches raises from the HTTP client (e.g. DNS resolution
     failure) which otherwise wouldn't appear as Or_error. *)
  Deferred.Or_error.try_with_join (fun () ->
    Deferred.repeat_until_finished 1 (fun attempt ->
      match%bind Clock.with_timeout http_timeout (try_post ~webhook_url ~content) with
      | `Timeout ->
        return
          (`Finished
            (Or_error.error_s [%message "discord post timed out" title (attempt : int)]))
      | `Result (resp, body) ->
        let%bind () = Cohttp_async.Body.to_string body |> Deferred.ignore_m in
        (match Cohttp.Response.status resp |> Cohttp.Code.code_of_status with
         | 429 when attempt < max_attempts ->
           let%bind () =
             Clock.after (Time_float.Span.of_sec (retry_after_seconds resp))
           in
           return (`Repeat (attempt + 1))
         | code when code >= 200 && code < 300 -> return (`Finished (Ok ()))
         | code ->
           return
             (`Finished
               (Or_error.error_s
                  [%message "discord post failed" title (attempt : int) (code : int)])))))
;;
