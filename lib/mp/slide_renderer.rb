# frozen_string_literal: true

require "cgi"
require "kramdown"
require "kramdown-parser-gfm"
require "rouge"

module Mp
  # Rouge の HTML フォーマッタは <span> しか出さないので、<pre> で包む
  class CodeFormatter < Rouge::Formatters::HTML
    def stream(tokens, &block)
      yield %(<pre class="highlight"><code>)
      super
      yield "</code></pre>"
    end
  end

  # 1 スライド分の Markdown を <section> にする。
  class SlideRenderer
    FILTERS = %w[blur brightness contrast drop-shadow grayscale hue-rotate invert opacity saturate sepia].freeze
    FILTER_DEFAULTS = {
      "blur" => "10px", "brightness" => "1.5", "contrast" => "2", "drop-shadow" => "0 5px 10px rgba(0,0,0,.4)",
      "grayscale" => "1", "hue-rotate" => "180deg", "invert" => "1", "opacity" => ".5",
      "saturate" => "2", "sepia" => "1"
    }.freeze
    KRAMDOWN = {
      input: "GFM", auto_ids: false, smart_quotes: "apos,apos,quot,quot",
      syntax_highlighter: "rouge", syntax_highlighter_opts: { formatter: CodeFormatter }
    }.freeze

    def initialize(chunk, index:, total:, directives:, tokens:)
      @chunk = chunk
      @index = index
      @total = total
      @directives = directives
      @tokens = tokens
      @backgrounds = []
      @split = nil
    end

    def render
      source = @chunk.lines.join("\n")
      document = Kramdown::Document.new(source, KRAMDOWN)
      @source_lines = source.split("\n", -1)
      transform(document.root)
      html = scope_styles(restore_tokens(document.to_html))
      html = html.sub(/<h([12])>/, '<h\1 class="fit">') if @chunk.fit

      { html: %(<section class="#{classes}" data-index="#{@index}" style="#{CGI.escapeHTML(style)}">) \
              "#{background_html}#{furniture(:header)}#{html}#{furniture(:footer)}#{page_number}</section>" }
    end

    private

    def transform(element)
      element.children.each { transform(_1) }
      element.children.reject! { |child| background_only?(child) }
      mark_fragments(element) if element.type == :ul
      element.children.each { convert_image(_1) if _1.type == :img }
    end

    def background_only?(element)
      return false unless element.type == :p

      images, rest = element.children.partition { _1.type == :img && keywords(_1).include?("bg") }
      images.each { add_background(_1) }
      element.children.replace(rest)
      !images.empty? && rest.all? { _1.type == :text && _1.value.strip.empty? }
    end

    def keywords(image)
      image.attr["alt"].to_s.split
    end

    def add_background(image)
      size = "cover"
      filters = []
      keywords(image).each do |word|
        name, value = word.split(":", 2)
        case name
        when "left", "right" then @split = [name, value || "50%"]
        when "cover", "contain", "auto" then size = name
        when "fit" then size = "contain"
        when "vertical" then @vertical = true
        when /\A\d+(\.\d+)?%\z/ then size = name
        when *FILTERS then filters << "#{name}(#{value || FILTER_DEFAULTS[name]})"
        end
      end
      @backgrounds << { src: image.attr["src"], size: size, filter: filters.join(" ") }
    end

    # Marp と同じく `*` のリストは 1 項目ずつ表示する
    def mark_fragments(list)
      list.children.each do |item|
        line = @source_lines[item.options[:location].to_i - 1].to_s
        item.attr["class"] = "fragment" if line.lstrip.start_with?("*")
      end
    end

    def convert_image(image)
      return if keywords(image).include?("bg") # 親の段落を処理するときに背景へ移す

      styles = []
      alt = keywords(image).reject do |word|
        name, value = word.split(":", 2)
        case name
        when "w", "width" then styles << "width:#{css_length(value)}"
        when "h", "height" then styles << "height:#{css_length(value)}"
        when *FILTERS then (@image_filters ||= []) << "#{name}(#{value || FILTER_DEFAULTS[name]})"
        else next false
        end
        true
      end
      styles << "filter:#{@image_filters.join(" ")}" if @image_filters
      @image_filters = nil
      image.attr["alt"] = alt.join(" ")
      image.attr["style"] = styles.join(";") unless styles.empty?
    end

    def css_length(value)
      value.to_s.match?(/\A\d+(\.\d+)?\z/) ? "#{value}px" : value.to_s
    end

    def restore_tokens(html)
      html.gsub(%r{<p>(MPTOKEN\d+X)</p>}) { @tokens.fetch(Regexp.last_match(1)) }
          .gsub(/MPTOKEN\d+X/) { |key| @tokens.fetch(key) }
    end

    # <style scoped> はそのスライドだけに効かせる
    def scope_styles(html)
      html.gsub(%r{<style\s+scoped[^>]*>(.*?)</style>}m) do
        %(<style>@scope (section[data-index="#{@index}"]) { #{Regexp.last_match(1)} }</style>)
      end
    end

    def classes
      kind = { cover: "cover", continuation: "continuation" }[@chunk.kind]
      ["slide", kind, *Array(@directives["class"]).flat_map { _1.to_s.split }].compact.join(" ")
    end

    def style
      map = {
        "backgroundColor" => "background-color", "backgroundImage" => "background-image",
        "backgroundPosition" => "background-position", "backgroundRepeat" => "background-repeat",
        "backgroundSize" => "background-size", "color" => "color"
      }
      styles = map.filter_map { |key, css| "#{css}:#{@directives[key]}" if @directives[key] }
      styles << "--split-#{@split[0]}:#{@split[1]}" if @split
      styles.join(";")
    end

    def background_html
      return "" if @backgrounds.empty?

      position = case @split&.first
                 when "left" then "left:0;width:#{@split[1]}"
                 when "right" then "right:0;width:#{@split[1]}"
                 else "left:0;width:100%"
                 end
      images = @backgrounds.map do |bg|
        css = %(background-image:url("#{bg[:src].gsub('"', "%22")}");background-size:#{bg[:size]})
        css += ";filter:#{bg[:filter]}" unless bg[:filter].empty?
        %(<div class="bg-image" style="#{CGI.escapeHTML(css)}"></div>)
      end
      direction = @vertical ? ";flex-direction:column" : ""
      %(<div class="bg-layer" style="#{position}#{direction}">#{images.join}</div>)
    end

    def furniture(name)
      text = @directives[name.to_s]
      return "" if text.to_s.empty?

      inline = Kramdown::Document.new(text.to_s, input: "GFM").to_html.strip.sub(%r{\A<p>(.*)</p>\z}m, '\1')
      "<#{name}>#{inline}</#{name}>"
    end

    def page_number
      show = @directives["paginate"]
      return "" unless show == true && @chunk.kind != :cover

      %(<div class="page-number">#{@index + 1} / #{@total}</div>)
    end
  end
end
