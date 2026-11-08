"use strict";

const $ = (id) => document.getElementById(id);
const FRAME_INTERVAL = 250;

let deck = null;
let state = { slide: 0, step: 0, script: null, ready: false };
let digits = "";
let startedAt = Date.now(); // サーバの開始時刻を受け取るまでの仮の値
let noteSize = 26;
let mirrorRunning = false;
let mirrorSlide = null;

const socket = new WebSocket(`ws://${location.host}${location.pathname.replace(/presenter$/, "")}_mp/events?role=presenter`);
const send = (message) => {
  if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message));
};
const command = (cmd, args = {}) => send({ type: "command", cmd, ...args });

async function loadDeck() {
  deck = await MpSlides.load($("current"), [$("current"), $("next")]);
  startedAt = deck.startedAt;
  document.title = `発表者ビュー - ${deck.title}`;
  for (const stage of [$("current"), $("next")]) {
    stage.querySelectorAll(".embed").forEach(describeEmbed);
  }
  layout();
  render();
  send({ type: "hello" });
}

// ターミナルや Web は聴衆画面にだけ実体があるので、ここでは内容の説明を出す
function describeEmbed(el) {
  const embed = deck.embeds[el.dataset.embed];
  const text = document.createElement("pre");
  text.className = "embed-summary";
  text.textContent = embed.type === "terminal" ? ["ターミナル", ...embed.commands.map((c) => `$ ${c}`)].join("\n") : `Web\n${embed.src}`;
  el.append(text);
}

function layout() {
  if (!deck) return;
  for (const [stage, frame] of [[$("current"), $("current-frame")], [$("next"), $("next-frame")]]) {
    const box = frame.getBoundingClientRect();
    const scale = Math.min(box.width / deck.size[0], box.height / deck.size[1]);
    stage.style.transform = `translate(${(box.width - deck.size[0] * scale) / 2}px, ${(box.height - deck.size[1] * scale) / 2}px) scale(${scale})`;
  }
}

function showOn(stage, slide, step) {
  [...stage.children].forEach((el, index) => {
    el.classList.toggle("active", index === slide);
    if (index === slide) {
      el.querySelectorAll(".fragment").forEach((item, i) => item.classList.toggle("shown", i < step));
    }
  });
}

function render() {
  if (!deck) return;
  const { slide, step, script, ready } = state;
  const stage = $("current");
  const section = stage.children[slide];
  if (!section) return;
  showOn(stage, slide, step);

  // 表示されていない項目が残っていれば、次に見えるのは同じスライドの次の項目
  const fragments = section.querySelectorAll(".fragment").length;
  const last = slide === deck.slides.length - 1;
  const done = last && step >= fragments;
  if (step < fragments) showOn($("next"), slide, step + 1);
  else if (!last) showOn($("next"), slide + 1, 0);
  $("next").hidden = done;
  $("end").hidden = !done;

  $("page").textContent = `${slide + 1} / ${deck.slides.length}`;
  $("speaker-notes").textContent = deck.slides[slide].notes;
  renderScript(script, ready);
  updateMirror(section);
}

function renderScript(script, ready) {
  $("script").hidden = script === null;
  if (script === null) return;
  if (!script.length) $("script").textContent = "台本のコマンドはすべて実行しました";
  else $("script").textContent = `${ready ? "Enter で実行" : "入力待ち"}: ${script[0]}`;
}

// 実体のある埋め込みは、聴衆画面をそのまま映す
function updateMirror(section) {
  const hasEmbed = !!section.querySelector(".embed");
  if (mirrorSlide !== state.slide) $("mirror").hidden = true; // 前のスライドの画面を残さない
  mirrorSlide = hasEmbed ? state.slide : null;
  if (hasEmbed && !mirrorRunning) {
    mirrorRunning = true;
    send({ type: "frame" });
  }
}

function onFrame(data) {
  mirrorRunning = false;
  if (mirrorSlide === null) return;
  $("mirror").src = `data:image/jpeg;base64,${data}`;
  $("mirror").hidden = false;
  setTimeout(() => {
    if (mirrorSlide !== null && !mirrorRunning) {
      mirrorRunning = true;
      send({ type: "frame" });
    }
  }, FRAME_INTERVAL);
}

function tick() {
  $("elapsed").textContent = MpSlides.formatTime(Math.floor((Date.now() - startedAt) / 1000));
  $("clock").textContent = new Date().toLocaleTimeString("ja-JP", { hour: "2-digit", minute: "2-digit" });
  $("remaining").hidden = $("slide-remaining").hidden = !deck?.duration;
  if (!deck?.duration) return;
  const remaining = MpSlides.remaining(deck, startedAt);
  $("remaining").textContent = remaining < 0 ? `超過 ${MpSlides.formatTime(-remaining)}` : `残り ${MpSlides.formatTime(remaining)}`;
  $("remaining").dataset.state = MpSlides.timerState(deck, remaining);

  // 聴衆画面が送った使用時間に、送ってからの経過を足す
  const budget = MpSlides.slideBudget(deck, deck.slides.length);
  const slide = MpSlides.slideRemaining(budget, (state.slideSpent ?? 0) + (Date.now() - (state.sentAt ?? Date.now())));
  $("slide-remaining").textContent = `このページ ${slide < 0 ? `超過 ${MpSlides.formatTime(-slide)}` : MpSlides.formatTime(slide)}`;
  $("slide-remaining").dataset.state = MpSlides.slideState(budget, slide);
}

function setNoteSize(size) {
  noteSize = Math.min(Math.max(size, 14), 60);
  $("speaker-notes").style.fontSize = `${noteSize}px`;
}

window.addEventListener("keydown", (event) => {
  if (event.metaKey || event.ctrlKey || event.altKey) return;
  const actions = {
    ArrowRight: () => command("next"), ArrowDown: () => command("next"), PageDown: () => command("next"), " ": () => command("next"),
    ArrowLeft: () => command("prev"), ArrowUp: () => command("prev"), PageUp: () => command("prev"),
    Home: () => command("first"),
    End: () => command("last"),
    r: () => send({ type: "timer-reset" }), // 聴衆画面のタイマーも一緒に戻す
    "+": () => setNoteSize(noteSize + 2),
    "=": () => setNoteSize(noteSize + 2),
    "-": () => setNoteSize(noteSize - 2),
    q: () => send({ type: "quit" }),
  };
  if (/^\d$/.test(event.key)) {
    digits += event.key;
  } else if (event.key === "Enter") {
    event.preventDefault();
    if (digits) command("goto", { slide: Number(digits) - 1 });
    else command("run");
    digits = "";
  } else if (actions[event.key]) {
    event.preventDefault();
    digits = "";
    actions[event.key]();
  }
});

socket.onopen = () => send({ type: "hello" });
socket.onmessage = (event) => {
  const message = JSON.parse(event.data);
  if (message.type === "state") {
    state = message;
    render();
    tick();
  } else if (message.type === "frame") {
    onFrame(message.data);
  } else if (message.type === "timer") {
    startedAt = message.startedAt;
    tick();
  } else if (message.type === "reload") {
    loadDeck();
  }
};

window.addEventListener("resize", layout);
setInterval(tick, 1000);
tick();
setNoteSize(noteSize);
loadDeck();
