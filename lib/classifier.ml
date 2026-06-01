open! Core
open! Async

let model = "anthropic/claude-sonnet-4.6"
let tool_name = "classify_post"

let system_prompt =
  "You determine whether a blog post is about the OCaml programming language. Use the \
   classify_post tool with your determination."
;;

let request ~user_prompt =
  let module R = Openrouter_api.Completions.Request in
  R.create
    ~model
    ~messages:[ R.Message.system system_prompt; R.Message.user user_prompt ]
    ~tools:
      [ Openrouter_api.Completions.Tool.function_
          ~name:tool_name
          ~description:
            "Record whether the blog post is about the OCaml programming language."
          ~parameters:
            (`Object
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
                ])
          ()
      ]
    ~tool_choice:(Openrouter_api.Completions.Tool_choice.force_function tool_name)
    ()
;;

let extract_verdict (response : Openrouter_api.Completions.Response.t) =
  let%bind.Or_error tool_call =
    match response.choices with
    | { message = { tool_calls = tc :: _; _ }; _ } :: _ -> Ok tc
    | _ -> Or_error.error_string "classifier returned no tool call"
  in
  let%bind.Or_error args_json =
    Jsonaf.parse tool_call.function_.arguments
    |> Or_error.tag ~tag:"parsing tool call arguments"
  in
  Or_error.try_with (fun () ->
    Jsonaf.member_exn "ocaml_related" args_json |> Jsonaf.bool_exn)
  |> Or_error.tag ~tag:"extracting ocaml_related field"
;;

let classify ~api_key ~(entry : Entry.t) =
  let user_prompt =
    let parts =
      [ Some [%string "Title: %{entry.title}"]; Some [%string "Link: %{entry.link}"] ]
      @ [ Option.map entry.description ~f:(fun d -> [%string "Summary: %{d}"]) ]
    in
    List.filter_opt parts |> String.concat ~sep:"\n"
  in
  let%bind.Deferred.Or_error response =
    request ~user_prompt
    |> Openrouter_api.Completions.create ~api_key
    |> Deferred.Or_error.tag ~tag:"openrouter classify call"
  in
  let%map.Deferred.Or_error verdict = extract_verdict response |> Deferred.return in
  { Feed_state.Classification.verdict; user_prompt }
;;
