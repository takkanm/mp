# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/mp"

class DeckTest < Minitest::Test
  def deck(source, **opts) = Mp::Deck.new(source, **opts)
  def html(source, index = 0) = deck(source).slides[index][:html]

  def test_h1_is_cover_and_h2_is_slide
    slides = deck("# Title\n\nsub\n\n## One\n\nbody\n\n## Two\n").slides
    assert_equal %i[cover slide slide], slides.map { _1[:kind] }
    assert_equal ["Title", "One", "Two"], slides.map { _1[:title] }
    assert_includes slides[0][:html], "<h1>Title</h1>"
    assert_includes slides[0][:html], "sub"
    assert_includes slides[1][:html], "<h2>One</h2>"
    assert_includes slides[0][:html], 'class="slide cover"'
  end

  def test_h3_does_not_split
    assert_equal 1, deck("## A\n\n### B\n\ntext\n").slides.length
  end

  def test_headings_in_fences_do_not_split
    slides = deck("## A\n\n```md\n## not a slide\n---\n```\n").slides
    assert_equal 1, slides.length
    assert_includes slides[0][:html], "not a slide"
  end

  def test_setext_headings
    assert_equal %i[cover slide], deck("Title\n=====\n\nOne\n---\n\nbody\n").slides.map { _1[:kind] }
  end

  def test_horizontal_rule_starts_continuation
    slides = deck("## A\n\nx\n\n---\n\ny\n").slides
    assert_equal %i[slide continuation], slides.map { _1[:kind] }
  end

  def test_rule_before_heading_does_not_make_empty_slide
    assert_equal %i[slide slide], deck("## A\n\n---\n\n## B\n").slides.map { _1[:kind] }
  end

  def test_front_matter_is_not_a_slide
    d = deck("---\ntheme: dark\ntitle: T\npaginate: true\n---\n\n## A\n")
    assert_equal 1, d.slides.length
    assert_equal "dark", d.globals["theme"]
    assert_equal "T", d.title
    assert_includes d.slides[0][:html], "1 / 1"
  end

  def test_directives_persist_and_spot_directives_do_not
    slides = deck("## A\n\n<!-- class: lead -->\n<!-- _backgroundColor: red -->\n\n## B\n").slides
    assert_includes slides[0][:html], "slide lead"
    assert_includes slides[0][:html], "background-color:red"
    assert_includes slides[1][:html], "slide lead"
    refute_includes slides[1][:html], "background-color"
  end

  def test_other_comments_become_notes
    slide = deck("## A\n\n<!-- remember this -->\n\ntext <!-- and: that -->\n").slides[0]
    assert_includes slide[:notes], "remember this"
    assert_includes slide[:notes], "and: that"
    refute_includes slide[:html], "remember"
  end

  def test_multiline_comment_with_heading_inside
    d = deck("## A\n\n<!--\n## hidden\n-->\n\nafter\n")
    assert_equal 1, d.slides.length
    assert_includes d.slides[0][:notes], "## hidden"
    assert_includes d.slides[0][:html], "after"
  end

  def test_terminal_embed
    Dir.mktmpdir do |dir|
      Dir.mkdir(File.join(dir, "sub"))
      d = deck("## A\n\n```terminal cwd=./sub height=60% font=20\nls -la\n\nnpm test\n```\n", base_dir: dir)
      embed = d.embeds.fetch("e1")
      assert_equal ["ls -la", "npm test"], embed[:commands]
      assert_equal File.join(dir, "sub"), embed[:cwd]
      assert_equal 20, embed[:font]
      assert_includes d.slides[0][:html], 'class="embed embed-terminal" data-embed="e1"'
      assert_includes d.slides[0][:html], "height:60%"
      refute d.to_h[:embeds]["e1"].key?(:cwd), "cwd はブラウザに渡さない"
    end
  end

  def test_terminal_cwd_falls_back_to_deck_dir
    Dir.mktmpdir do |dir|
      assert_equal dir, deck("```terminal cwd=./missing\n```\n", base_dir: dir).embeds["e1"][:cwd]
    end
  end

  def test_web_embed
    d = deck("## A\n\n```web zoom=1.5\nhttps://example.com\n```\n")
    assert_equal({ type: "web", src: "https://example.com", zoom: 1.5 }, d.embeds["e1"])
  end

  def test_web_embed_rejects_other_schemes
    assert_equal "", deck("```web\njavascript:alert(1)\n```\n").embeds["e1"][:src]
    assert_equal "", deck("```web\nfile:///etc/passwd\n```\n").embeds["e1"][:src]
    assert_equal "./local.html", deck("```web\n./local.html\n```\n").embeds["e1"][:src]
  end

  def test_embed_attr_style_is_validated
    assert_equal "", deck("```web height=1px;background:url(x)\nhttps://a\n```\n").slides[0][:html][/data-embed="e1" style="([^"]*)"/, 1]
  end

  def test_code_highlight
    out = html("## A\n\n```ruby\nputs 1\nputs 2\n```\n")
    assert_match %r{<pre class="highlight"><code>.*puts.*\n.*puts.*</code></pre>}m, out
  end

  def test_image_size
    out = html("![w:200 h:100 logo](a.png)\n")
    assert_includes out, "width:200px;height:100px"
    assert_includes out, 'alt="logo"'
  end

  def test_background_image
    out = html("## A\n\n![bg](a.png)\n\ntext\n")
    assert_includes out, "bg-layer"
    assert_includes out, "a.png"
    refute_includes out, "<img"
    refute_includes out, "<p></p>"
  end

  def test_split_background_and_filter
    out = html("## A\n\n![bg left:33% contain blur:5px](a.png)\n")
    assert_includes out, "--split-left:33%"
    assert_includes out, "left:0;width:33%"
    assert_includes out, "background-size:contain"
    assert_includes out, "filter:blur(5px)"
  end

  def test_multiple_backgrounds
    assert_equal 2, html("![bg](a.png)\n![bg](b.png)\n").scan("bg-image").length
  end

  def test_star_list_is_fragmented_but_dash_list_is_not
    assert_equal 2, html("* a\n* b\n").scan('class="fragment"').length
    assert_equal 0, html("- a\n- b\n").scan('class="fragment"').length
  end

  def test_math
    out = html("Inline $a_1 * b_2$ and\n\n$$\nx^2\n$$\n")
    assert_includes out, 'data-tex="a_1 * b_2" data-display="false"'
    assert_includes out, 'data-tex="x^2" data-display="true"'
  end

  def test_dollar_amounts_are_not_math
    refute_includes html("costs $100 and $200 total\n"), "math"
  end

  def test_code_span_keeps_comment_and_math
    out = html("`<!-- x -->` and `$a$`\n")
    assert_includes out, "&lt;!-- x --&gt;"
    assert_includes out, "$a$"
  end

  def test_fit_heading
    assert_includes html("# <!-- fit --> Big\n"), '<h1 class="fit">'
  end

  def test_scoped_style
    out = html("## A\n\n<style scoped>h2 { color: red; }</style>\n\n## B\n")
    assert_includes out, %(@scope (section[data-index="0"]))
  end

  def test_header_and_footer
    out = html("---\nheader: '**H**'\nfooter: F\n---\n\n## A\n")
    assert_includes out, "<header><strong>H</strong></header>"
    assert_includes out, "<footer>F</footer>"
  end

  def test_size
    assert_equal [960, 720], deck("---\nsize: 4:3\n---\n## A\n").size
  end

  def test_front_matter_does_not_load_arbitrary_objects
    assert_raises(Psych::Exception) { deck("---\na: !ruby/object:Object {}\n---\n") }
  end
end
