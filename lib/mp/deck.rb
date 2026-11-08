# frozen_string_literal: true

require "cgi/escape"
require "shellwords"
require "yaml"
require_relative "slide_renderer"

module Mp
  # Markdown をスライドへ分割する。
  #
  #   # H1  → 表紙スライド
  #   ## H2 → 通常スライド(H2 がページタイトル)
  #   ---   → タイトルなしの続きスライド
  #
  # kramdown に渡す前に行単位で走査する。kramdown は info 文字列に属性を持つ
  # フェンスを認識せず、`$x$` も扱えないため、独自記法はここでトークンに置換する。
  class Deck
    GLOBAL_DIRECTIVES = %w[theme size style title duration].freeze
    LOCAL_DIRECTIVES = %w[
      paginate header footer class color
      backgroundColor backgroundImage backgroundPosition backgroundRepeat backgroundSize
    ].freeze
    SIZES = { "16:9" => [1280, 720], "4:3" => [960, 720] }.freeze
    FENCE = /\A {0,3}(`{3,}|~{3,})\s*(.*?)\s*\z/
    INLINE = /(?<code>(?<ticks>`+).+?\k<ticks>)|<!--(?<comment>.*?)-->|\$\$(?<display>.+?)\$\$|(?<![\\\w$])\$(?=\S)(?<math>[^$\n]+?)(?<=\S)\$(?![\d$])/
    CSS_LENGTH = /\A\d+(\.\d+)?(%|px)?\z/

    Chunk = Struct.new(:kind, :title, :lines, :comments, :fit, keyword_init: true)

    attr_reader :slides, :globals, :embeds, :base_dir

    def self.load(path)
      new(File.read(path, encoding: "UTF-8"), base_dir: File.dirname(File.expand_path(path)))
    end

    def initialize(source, base_dir: Dir.pwd)
      @base_dir = base_dir
      @globals = {}
      @embeds = {}
      @tokens = {}
      body, front = split_front_matter(source.gsub("\r\n", "\n"))
      @state = {}
      apply_directives(front, {})
      @slides = build_slides(scan(body))
    end

    def size
      SIZES.fetch(@globals["size"].to_s, SIZES["16:9"])
    end

    # トークの想定時間(秒)。数値は分として扱い、"20:00" "90s" "20m" も受け付ける
    def duration
      seconds = case (value = @globals["duration"])
                when Numeric then value * 60
                when /\A\s*(\d+):([0-5]\d)\s*\z/ then (Regexp.last_match(1).to_i * 60) + Regexp.last_match(2).to_i
                when /\A\s*(\d+(?:\.\d+)?)\s*(?:m|min|分)?\s*\z/ then Regexp.last_match(1).to_f * 60
                when /\A\s*(\d+)\s*(?:s|sec|秒)\s*\z/ then Regexp.last_match(1).to_i
                end
      seconds.round if seconds&.positive?
    end

    def title
      @globals["title"] || @slides.find { _1[:kind] == :cover }&.fetch(:title) || "mp"
    end

    # ブラウザへ渡す情報。cwd はサーバ側だけで使うので含めない
    def to_h
      {
        title: title,
        size: size,
        duration: duration,
        style: @globals["style"].to_s,
        slides: @slides.map { _1.slice(:html, :notes, :kind) },
        embeds: @embeds.transform_values { _1.except(:cwd) }
      }
    end

    private

    def split_front_matter(source)
      match = source.match(/\A---[ \t]*\n(.*?)^---[ \t]*(\n|\z)/m)
      return [source, {}] unless match

      front = load_yaml(match[1]) || {}
      [match.post_match, front.is_a?(Hash) ? front : {}]
    end

    # YAML 1.1 では `4:3` や `20:00` が 60 進数の数値になるので、文字列のまま読ませる
    def load_yaml(text)
      YAML.safe_load(text.gsub(/^(\s*_?(?:size|duration):\s*)(\d+:\d+)\s*(#.*)?$/, '\1"\2"'))
    end

    def scan(body)
      chunks = [Chunk.new(kind: :preamble, lines: [], comments: [])]
      lines = body.split("\n", -1)
      index = 0
      while index < lines.length
        line = lines[index]
        if (fence = line.match(FENCE))
          index = read_fence(lines, index, fence, chunks.last)
        elsif line.match?(/\A\s*\$\$\s*\z/)
          index = read_math_block(lines, index, chunks.last)
        else
          index = read_line(lines, index, chunks)
        end
      end
      chunks
    end

    def read_fence(lines, index, fence, chunk)
      marker = fence[1]
      close = /\A {0,3}#{Regexp.escape(marker[0])}{#{marker.length},}\s*\z/
      stop = (index + 1...lines.length).find { lines[_1].match?(close) } || lines.length
      inner = lines[index + 1...stop]
      name, *attrs = Shellwords.split(fence[2]) rescue [fence[2].split.first]
      if %w[terminal web].include?(name)
        chunk.lines.push("", embed_token(name, parse_attrs(attrs), inner), "")
      else
        # kramdown は言語名だけを受け付ける
        chunk.lines.push("#{marker}#{name}", *inner, marker)
      end
      stop + 1
    end

    def read_math_block(lines, index, chunk)
      stop = (index + 1...lines.length).find { lines[_1].match?(/\A\s*\$\$\s*\z/) } || lines.length
      chunk.lines.push("", math_token(lines[index + 1...stop].join("\n"), true), "")
      stop + 1
    end

    def read_line(lines, index, chunks)
      line, index = strip_inline(lines, index, chunks.last)
      following = lines[index]
      if (heading = line.match(/\A {0,3}(#{"#"}{1,2})\s+(.*?)\s*#*\s*\z/))
        start_chunk(chunks, heading[1].length, heading[2], line)
      elsif following&.match?(/\A {0,3}(=+|-+)\s*\z/) && !line.strip.empty? && !line.match?(/\A\s*[-*+>|#]/)
        start_chunk(chunks, following.lstrip.start_with?("=") ? 1 : 2, line.strip, "#{line}\n#{following}")
        return index + 1
      elsif line.match?(/\A {0,3}(-{3,}|\*{3,}|_{3,})\s*\z/)
        chunks << Chunk.new(kind: :continuation, lines: [], comments: [])
      else
        chunks.last.lines << line
      end
      index
    end

    def start_chunk(chunks, level, title, source)
      fit = @pending_fit
      @pending_fit = false
      chunks << Chunk.new(kind: level == 1 ? :cover : :slide, title: title, lines: [source], comments: [], fit: fit)
      # 見出し行より前に読んだコメントは前のチャンクに残るので、見出し行の分だけ移す
      chunks.last.comments.concat(@heading_comments)
    end

    # コメントと数式を行から抜き出す。次に読むべき行番号も返す
    def strip_inline(lines, index, chunk)
      @heading_comments = []
      heading = lines[index].match?(/\A {0,3}\#{1,2}\s/)
      line = lines[index].gsub(INLINE) do
        match = Regexp.last_match
        if match[:code] then match[:code]
        elsif match[:comment]
          text = match[:comment].strip
          if heading && text == "fit" then @pending_fit = true
          elsif heading then @heading_comments << text
          else chunk.comments << text
          end
          ""
        elsif match[:display] then math_token(match[:display], true)
        else math_token(match[:math], false)
        end
      end
      index += 1

      # 複数行コメント
      start = line.gsub(/(`+).+?\1/, "").index("<!--") && line.index("<!--")
      return [line, index] unless start

      text = [line[(start + 4)..]]
      line = line[0...start]
      until index >= lines.length || lines[index].include?("-->")
        text << lines[index]
        index += 1
      end
      if index < lines.length
        head, tail = lines[index].split("-->", 2)
        text << head
        line += tail.to_s
        index += 1
      end
      chunk.comments << text.join("\n").strip
      [line, index]
    end

    def parse_attrs(attrs)
      attrs.to_h { |attr| attr.include?("=") ? attr.split("=", 2) : [attr, "true"] }
    end

    def embed_token(type, attrs, inner)
      id = "e#{@embeds.length + 1}"
      style = %w[width height].filter_map { |key|
        value = attrs[key]
        "#{key}:#{value}#{"px" if value.match?(/\A[\d.]+\z/)}" if value&.match?(CSS_LENGTH)
      }
      # 高さを固定するときだけ伸縮を止める。幅だけなら高さは残りの領域を使う
      style << "flex:none" if style.any? { _1.start_with?("height") }
      style = style.join(";")
      @embeds[id] = type == "web" ? web_embed(attrs, inner) : terminal_embed(attrs, inner)
      token(%(<div class="embed embed-#{type}" data-embed="#{id}" style="#{CGI.escapeHTML(style)}"></div>))
    end

    def terminal_embed(attrs, inner)
      {
        type: "terminal",
        cwd: resolve_cwd(attrs["cwd"]),
        commands: inner.map(&:strip).reject(&:empty?),
        font: attrs["font"].to_i.positive? ? attrs["font"].to_i : 18
      }
    end

    def web_embed(attrs, inner)
      src = inner.map(&:strip).reject(&:empty?).first.to_s
      src = "" if src.match?(/\A[a-z][a-z0-9+.-]*:/i) && !src.match?(%r{\Ahttps?://}i)
      { type: "web", src: src, zoom: attrs["zoom"].to_f.positive? ? attrs["zoom"].to_f : 1.0 }
    end

    def resolve_cwd(cwd)
      path = File.expand_path(cwd.to_s, @base_dir)
      File.directory?(path) ? path : @base_dir
    end

    def math_token(tex, display)
      token(%(<span class="math" data-tex="#{CGI.escapeHTML(tex)}" data-display="#{display}"></span>))
    end

    def token(html)
      key = "MPTOKEN#{@tokens.length}X"
      @tokens[key] = html
      key
    end

    def parse_directive(comment)
      data = load_yaml(comment)
      return unless data.is_a?(Hash) && !data.empty?

      known = GLOBAL_DIRECTIVES + LOCAL_DIRECTIVES
      data if data.keys.all? { known.include?(_1.to_s.delete_prefix("_")) }
    rescue Psych::Exception
      nil
    end

    def apply_directives(data, spot)
      data.each do |key, value|
        key = key.to_s
        if GLOBAL_DIRECTIVES.include?(key) then @globals[key] = value
        elsif key.start_with?("_") then spot[key.delete_prefix("_")] = value
        else @state[key] = value
        end
      end
    end

    def build_slides(chunks)
      chunks = chunks.reject { |chunk|
        # `---` の直後に見出しが来る書き方でも空のスライドを作らない
        next false unless %i[preamble continuation].include?(chunk.kind) && chunk.lines.all? { _1.strip.empty? }

        chunk.comments.each { |comment| parse_directive(comment)&.then { apply_directives(_1, {}) } }
        true
      }
      total = chunks.length
      chunks.each_with_index.map do |chunk, index|
        spot = {}
        notes = chunk.comments.reject do |comment|
          directive = parse_directive(comment)
          apply_directives(directive, spot) if directive
          directive
        end
        SlideRenderer.new(chunk, index:, total:, directives: @state.merge(spot), tokens: @tokens)
                     .render.merge(kind: chunk.kind, title: chunk.title, notes: notes.join("\n\n"))
      end
    end
  end
end
