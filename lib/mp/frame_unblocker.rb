# frozen_string_literal: true

module Mp
  # 埋め込みを拒否するレスポンスヘッダだけを取り除く。
  # 本文には触れないので、プロキシと違いページ自体は壊れない。
  class FrameUnblocker
    REQUEST_PATTERNS = [{ urlPattern: "*", resourceType: "Document", requestStage: "Response" }].freeze

    def self.strip_headers(headers)
      changed = false
      result = headers.filter_map do |header|
        case header["name"].downcase
        when "x-frame-options"
          changed = true
          nil
        when "content-security-policy"
          policy = strip_frame_ancestors(header["value"])
          changed ||= policy != header["value"]
          policy.empty? ? nil : header.merge("value" => policy)
        else
          header
        end
      end
      changed ? result : nil
    end

    def self.strip_frame_ancestors(policy)
      # 複数ポリシーがカンマで連結されている場合があるので、ポリシーごとに処理する
      policy.split(",").map { |one|
        one.split(";").reject { |d| d.strip.downcase.start_with?("frame-ancestors") }.join(";").strip
      }.reject(&:empty?).join(", ")
    end

    def initialize(cdp)
      @cdp = cdp
    end

    # ページを開く前に呼ぶこと。遷移後だと最初の iframe のレスポンスに間に合わない
    def attach(page_session)
      @cdp.on("Target.attachedToTarget") { |params, _| prepare_child(params) }
      @cdp.on("Fetch.requestPaused") { |params, session| rewrite(params, session) }
      watch(page_session)
    end

    private

    # サイトをまたぐ iframe は別プロセスの子ターゲットになるので、そちらにも同じ設定をする
    def prepare_child(params)
      session = params["sessionId"]
      watch(session)
      @cdp.call("Runtime.runIfWaitingForDebugger", {}, session_id: session)
    end

    def watch(session)
      @cdp.call("Fetch.enable", { patterns: REQUEST_PATTERNS }, session_id: session)
      @cdp.call("Target.setAutoAttach", { autoAttach: true, waitForDebuggerOnStart: true, flatten: true },
                session_id: session)
    end

    def rewrite(params, session)
      id = params["requestId"]
      headers = params["responseHeaders"] && self.class.strip_headers(params["responseHeaders"])
      unless headers
        @cdp.call("Fetch.continueResponse", { requestId: id }, session_id: session)
        return
      end

      # continueResponse で渡したヘッダは表示上は変わるが、Chrome はパース済みの
      # ポリシーで判定を続ける。fulfillRequest ならレスポンスごと作り直される。
      reply = @cdp.call("Fetch.getResponseBody", { requestId: id }, session_id: session)
      body = reply["base64Encoded"] ? reply["body"] : [reply["body"]].pack("m0")
      @cdp.call("Fetch.fulfillRequest",
                { requestId: id, responseCode: params["responseStatusCode"], responseHeaders: headers, body: body },
                session_id: session)
    end
  end
end
