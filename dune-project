(lang dune 3.22)

(name ocaml_jp_feed)

(package
 (name ocaml_jp_feed)
 (depends
  (ocaml
   (>= 5.4.1))
  ppx_jane
  async
  core
  core_unix
  openrouter_api))
