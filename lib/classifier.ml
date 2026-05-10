open! Core
open! Async

(* TODO: switch back to the [openrouter_api] library once it accepts present-as-null for
   [Response.t]'s [system_fingerprint] field. v0.0.1 uses [@jsonaf.option], which only
   handles field-absent — Bedrock-routed responses include the field as null and break
   the parse. *)

let model = "anthropic/claude-sonnet-4.6"
let endpoint = Uri.of_string "https://openrouter.ai/api/v1/chat/completions"
let http_timeout = Time_float.Span.of_sec 30.

let system_prompt =
  "You determine whether a blog post is about the OCaml programming language. Use the \
   classify_post tool with your determination."
;;

let user_prompt_for (entry : Entry.t) =
  let parts =
    [ Some [%string "Title: %{entry.title}"]; Some [%string "Link: %{entry.link}"] ]
    @ [ Option.map entry.description ~f:(fun d -> [%string "Summary: %{d}"]) ]
  in
  List.filter_opt parts |> String.concat ~sep:"\n"
;;

let tool_schema : Jsonaf.t =
  `Object
    [ "type", `String "function"
    ; ( "function"
      , `Object
          [ "name", `String "classify_post"
          ; ( "description"
            , `String "Record whether the blog post is about the OCaml programming language."
            )
          ; ( "parameters"
            , `Object
                [ "type", `String "object"
                ; ( "properties"
                  , `Object
                      [ ( "ocaml_related"
                        , `Object
                            [ "type", `String "boolean"
                            ; ( "description"
                              , `String "true if the post is about OCaml; false otherwise"
                              )
                            ] )
                      ] )
                ; "required", `Array [ `String "ocaml_related" ]
                ] )
          ] )
    ]
;;

let request_body ~user_prompt : Jsonaf.t =
  `Object
    [ "model", `String model
    ; ( "messages"
      , `Array
          [ `Object
              [ "role", `String "system"; "content", `String system_prompt ]
          ; `Object [ "role", `String "user"; "content", `String user_prompt ]
          ] )
    ; "tools", `Array [ tool_schema ]
    ; ( "tool_choice"
      , `Object
          [ "type", `String "function"
          ; ( "function"
            , `Object [ "name", `String "classify_post" ] )
          ] )
    ]
;;

let post ~api_key ~body =
  let headers =
    Cohttp.Header.of_list
      [ "Authorization", "Bearer " ^ api_key
      ; "Content-Type", "application/json"
      ]
  in
  Cohttp_async.Client.post ~headers ~body:(Cohttp_async.Body.of_string body) endpoint
;;

let extract_verdict (response_json : Jsonaf.t) =
  Or_error.try_with (fun () ->
    response_json
    |> Jsonaf.member_exn "choices"
    |> Jsonaf.list_exn
    |> List.hd_exn
    |> Jsonaf.member_exn "message"
    |> Jsonaf.member_exn "tool_calls"
    |> Jsonaf.list_exn
    |> List.hd_exn
    |> Jsonaf.member_exn "function"
    |> Jsonaf.member_exn "arguments"
    |> Jsonaf.string_exn
    |> Jsonaf.parse
    |> Or_error.ok_exn
    |> Jsonaf.member_exn "ocaml_related"
    |> Jsonaf.bool_exn)
  |> Or_error.tag ~tag:"extracting verdict from openrouter response"
;;

let classify ~api_key ~entry =
  let user_prompt = user_prompt_for entry in
  let body = Jsonaf.to_string (request_body ~user_prompt) in
  Deferred.Or_error.try_with_join (fun () ->
    match%bind Clock.with_timeout http_timeout (post ~api_key ~body) with
    | `Timeout ->
      Deferred.return (Or_error.error_string "openrouter classify call timed out")
    | `Result (resp, response_body) ->
      let%bind text = Cohttp_async.Body.to_string response_body in
      let code = Cohttp.Response.status resp |> Cohttp.Code.code_of_status in
      (match code with
       | code when code < 200 || code >= 300 ->
         Deferred.return
           (Or_error.error_s
              [%message "openrouter classify call failed" (code : int) text])
       | _ ->
         let%bind.Deferred.Or_error response_json =
           Jsonaf.parse text
           |> Or_error.tag ~tag:"parsing openrouter response body"
           |> Deferred.return
         in
         let%map.Deferred.Or_error verdict =
           extract_verdict response_json |> Deferred.return
         in
         { Feed_state.Classification.verdict; user_prompt }))
;;
