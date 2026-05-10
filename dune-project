(lang dune 3.22)

(name ocaml_jp_feed)

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
