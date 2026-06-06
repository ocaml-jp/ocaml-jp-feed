open! Core
open Ocaml_jp_feed

let test body =
  Feed_fetch.For_testing.parse body
  |> ok_exn
  |> List.iter ~f:(fun e -> print_endline (Entry.title e))
;;

(* The Atom <title> has no [type] attribute, so it is a plain-text construct, yet the
   publisher embedded a <code> element inside it. Without title-markup stripping, syndic
   drops the element together with its text and the title loses "match ... with". *)
let%expect_test "inline markup inside a text-typed Atom title is preserved" =
  test
    {|<?xml version='1.0' encoding='UTF-8'?>
<feed xmlns="http://www.w3.org/2005/Atom" xml:lang="en">
  <id>https://blog.anqou.net/rss</id>
  <title>blog.anqou.net</title>
  <updated>2026-05-25T00:00:00+00:00</updated>
  <author><name>anqou</name></author>
  <entry>
    <id>https://blog.anqou.net/2026/05/ocaml-match-with-exception</id>
    <title><code>match ... with</code> の腕で例外を捕捉する</title>
    <updated>2026-05-30T00:00:00+00:00</updated>
    <link href="https://blog.anqou.net/2026/05/ocaml-match-with-exception"/>
  </entry>
</feed>|};
  [%expect {| match ... with の腕で例外を捕捉する |}]
;;

(* A plain-text title with no markup is passed through unchanged. *)
let%expect_test "plain title is unchanged" =
  test
    {|<?xml version='1.0' encoding='UTF-8'?>
<feed xmlns="http://www.w3.org/2005/Atom" xml:lang="en">
  <id>https://blog.anqou.net/rss</id>
  <title>blog.anqou.net</title>
  <updated>2026-05-25T00:00:00+00:00</updated>
  <author><name>anqou</name></author>
  <entry>
    <id>https://blog.anqou.net/2026/05/ocaml-suppress-warning</id>
    <title>OCaml で警告を抑制する</title>
    <updated>2026-05-25T00:00:00+00:00</updated>
    <link href="https://blog.anqou.net/2026/05/ocaml-suppress-warning"/>
  </entry>
</feed>|};
  [%expect {| OCaml で警告を抑制する |}]
;;

(* Nested inline markup is flattened recursively into the title's text. *)
let%expect_test "nested inline markup is flattened" =
  test
    {|<?xml version='1.0' encoding='UTF-8'?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <id>tag:example</id>
  <title>Example</title>
  <updated>2026-05-25T00:00:00+00:00</updated>
  <author><name>anon</name></author>
  <entry>
    <id>tag:example/1</id>
    <title>using <b><code>List.map</code></b> well</title>
    <updated>2026-05-25T00:00:00+00:00</updated>
    <link href="https://example.com/1"/>
  </entry>
</feed>|};
  [%expect {| using List.map well |}]
;;

(* The RSS2 (no-namespace) title path is flattened too. The feed also declares a prefixed
   namespace (content:) on an unrelated element: a faithful round-trip must preserve that
   binding, otherwise xmlm output raises, we fall back to the raw body, and the title would
   revert to "bar". Observing the full title confirms both the flatten and the round-trip. *)
let%expect_test "rss2 title flattened while a prefixed namespace survives" =
  test
    {|<?xml version='1.0' encoding='UTF-8'?>
<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
  <channel>
    <title>Example</title>
    <link>https://example.com</link>
    <description>desc</description>
    <item>
      <title><code>match ... with</code> bar</title>
      <link>https://example.com/p</link>
      <guid>https://example.com/p</guid>
      <content:encoded><![CDATA[<p>body</p>]]></content:encoded>
    </item>
  </channel>
</rss>|};
  [%expect {| match ... with bar |}]
;;

(* Qiita emits a channel-level [<link>text</link>] — an Atom [atom:link] with text content
   and no [href]. That violates the Atom spec (atom:link must be empty with an href), so
   syndic's Atom parser raises and RSS2 parsing fails too. The entry is recovered only by
   the final fallback, which strips such bare links and re-parses as Atom. Without that
   fallback this [parse] returns an error instead of the entry below. *)
let%expect_test "bare channel-level <link> is recovered by the strip-and-retry fallback" =
  test
    {|<?xml version="1.0" encoding="UTF-8"?>
<feed xml:lang="ja-JP" xmlns="http://www.w3.org/2005/Atom">
  <id>tag:qiita.com,2005:/tags/ocaml/feed</id>
  <link rel="alternate" type="text/html" href="https://qiita.com"/>
  <title>OCamlタグが付けられた新着記事 - Qiita</title>
  <updated>2026-04-16T19:57:44+09:00</updated>
  <link>https://qiita.com/tags/ocaml</link>
  <author><name>Qiita</name></author>
  <entry>
    <id>tag:qiita.com,2005:PublicArticle/2193292</id>
    <updated>2026-04-16T20:19:35+09:00</updated>
    <link rel="alternate" type="text/html" href="https://qiita.com/atelier-kame/items/x"/>
    <title>FizzBuzz を実装する</title>
  </entry>
</feed>|};
  [%expect {| FizzBuzz を実装する |}]
;;

(* Entity-escaped angle brackets are character data, not markup: they must survive intact
   and must not trigger flattening. *)
let%expect_test "escaped angle brackets are not treated as markup" =
  test
    {|<?xml version='1.0' encoding='UTF-8'?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <id>tag:example</id>
  <title>Example</title>
  <updated>2026-05-25T00:00:00+00:00</updated>
  <author><name>anon</name></author>
  <entry>
    <id>tag:example/2</id>
    <title>the &lt;list&gt; module</title>
    <updated>2026-05-25T00:00:00+00:00</updated>
    <link href="https://example.com/2"/>
  </entry>
</feed>|};
  [%expect {| the <list> module |}]
;;
