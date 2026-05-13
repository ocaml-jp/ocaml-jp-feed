open! Core
open! Async

let model = "anthropic/claude-sonnet-4.6"
let tool_name = "classify_post"

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

let tool : Openrouter_api.Completions.Tool.t =
  Openrouter_api.Completions.Tool.create
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
                      , `String "true if the post is about OCaml; false otherwise" )
                    ] )
              ] )
        ; "required", `Array [ `String "ocaml_related" ]
        ])
    ()
;;

let request ~user_prompt : Openrouter_api.Completions.Request.t =
  let module R = Openrouter_api.Completions.Request in
  { model
  ; messages = [ R.Message.system system_prompt; R.Message.user user_prompt ]
  ; tools = [ tool ]
  ; tool_choice = Some (Openrouter_api.Completions.Tool_choice.force_function tool_name)
  ; stream = false
  ; reasoning = None
  ; parallel_tool_calls = None
  ; plugins = []
  ; temperature = None
  ; top_p = None
  ; top_k = None
  ; min_p = None
  ; top_a = None
  ; max_tokens = None
  ; max_completion_tokens = None
  ; seed = None
  ; stop = None
  ; frequency_penalty = None
  ; presence_penalty = None
  ; repetition_penalty = None
  ; logit_bias = None
  ; logprobs = None
  ; top_logprobs = None
  ; verbosity = None
  ; response_format = None
  ; modalities = None
  ; stream_options = None
  ; service_tier = None
  ; models = []
  ; transforms = []
  }
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

let classify ~api_key ~entry =
  let user_prompt = user_prompt_for entry in
  let%bind.Deferred.Or_error response =
    Openrouter_api.Completions.create ~api_key (request ~user_prompt)
    |> Deferred.Or_error.tag ~tag:"openrouter classify call"
  in
  let%map.Deferred.Or_error verdict = extract_verdict response |> Deferred.return in
  { Feed_state.Classification.verdict; user_prompt }
;;
