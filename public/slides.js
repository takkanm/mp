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
