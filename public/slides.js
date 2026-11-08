"use strict";

// 聴衆画面と発表者ビューで共通のスライド読み込み
const MpSlides = {
  async load(stage, stages = [stage]) {
    const deck = await (await fetch("_mp/deck.json", { cache: "no-store" })).json();
    document.getElementById("theme").textContent = deck.themeCss;
    document.getElementById("deck-style").textContent = deck.style;
    for (const target of stages) {
      target.style.width = `${deck.size[0]}px`;
      target.style.height = `${deck.size[1]}px`;
      target.innerHTML = deck.slides.map((slide) => slide.html).join("");
      target.querySelectorAll(".math").forEach((el) => {
        katex.render(el.dataset.tex, el, { displayMode: el.dataset.display === "true", throwOnError: false });
      });
    }
    await document.fonts.ready;
    stages.forEach((target) => MpSlides.fitHeadings(target));
    document.title = deck.title;
    return deck;
  },

  // 残り時間。超過すると負になる
  remaining(deck, startedAt, now = Date.now()) {
    return deck.duration - MpSlides.elapsed(startedAt, now);
  },

  // 経過秒。未開始(startedAt が null)なら 0
  elapsed(startedAt, now = Date.now()) {
    return startedAt ? Math.floor((now - startedAt) / 1000) : 0;
  },

  // 最初のスライドが表紙なら、表紙の次へ進むまでタイマーを始めない
  coverFirst(deck) {
    return deck.slides[0]?.kind === "cover";
  },

  // 持ち時間を割り当てるページ数(待っている表紙は除く)
  timedSlideCount(deck) {
    return Math.max(deck.slides.length - (MpSlides.coverFirst(deck) ? 1 : 0), 1);
  },

  formatTime(seconds) {
    const sign = seconds < 0 ? "+" : "";
    const s = Math.abs(seconds);
    const pad = (n) => String(n).padStart(2, "0");
    const hours = Math.floor(s / 3600);
    return `${sign}${hours ? `${hours}:${pad(Math.floor(s / 60) % 60)}` : pad(Math.floor(s / 60))}:${pad(s % 60)}`;
  },

  // 残り 2 分、短いトークでは全体の 2 割を切ったら注意を促す
  timerState(deck, remaining) {
    if (remaining < 0) return "over";
    return remaining <= Math.min(120, deck.duration * 0.2) ? "warn" : "normal";
  },

  // 1 ページの持ち時間(秒)。全体の時間を枚数で均等に割る
  slideBudget(deck, count) {
    return deck.duration / count;
  },

  // そのページで使った時間を引いた残り。持ち時間の 2 割を切ったら注意を促す
  slideRemaining(budget, spentMs) {
    return Math.floor(budget - Math.floor(spentMs / 1000)); // 全体の残りと同じく経過秒で刻む
  },

  slideState(budget, remaining) {
    if (remaining < 0) return "over";
    return remaining <= budget * 0.2 ? "warn" : "normal";
  },

  // `# <!-- fit --> 見出し` を横幅いっぱいにする
  fitHeadings(stage) {
    stage.querySelectorAll(".fit").forEach((heading) => {
      const span = document.createElement("span");
      span.style.whiteSpace = "nowrap";
      span.append(...heading.childNodes);
      heading.append(span);
      const available = heading.clientWidth;
      const size = parseFloat(getComputedStyle(heading).fontSize);
      heading.style.fontSize = `${Math.floor(size * (available / span.offsetWidth) * 0.98)}px`;
    });
  },
};
