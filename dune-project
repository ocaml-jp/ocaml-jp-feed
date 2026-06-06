(lang dune 3.22)

(name ocaml_jp_feed)

; TODO: Currently openrouter_api v0.0.1 has a bug which prevents it from being
; useful. Pinned to repo which has a fix for this; we should switch back once
; it's fixed.
(pin
 (url "git+https://github.com/mt-caret/openrouter-ocaml.git#fa11be4384446e01b4529ab49d86755cdf4faeba")
 (package
  (name openrouter_api)))

(package
 (name ocaml_jp_feed)
 (depends
  (ocaml
   (>= 5.4.1))
  ppx_jane
  async
  cohttp-async
  core
  core_unix
  jsonaf
  ppx_jsonaf_conv
  syndic
  openrouter_api))
