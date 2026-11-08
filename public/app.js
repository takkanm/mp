"use strict";

const stage = document.getElementById("stage");
const notesPanel = document.getElementById("notes");
const helpPanel = document.getElementById("help");
const wsBase = `ws://${location.host}${location.pathname}_mp/`;

let deck = null;
let slides = [];
let current = 0;
let terminals = new Map(); // embed id -> { term, socket, fit, host, slot, font }
let scale = 1;
let startedAt = null;
const slideSpent = new Map(); // ページ番号 -> そのページで使った時間(ミリ秒)。戻っても続きから数える
let enteredAt = Date.now();
const timer = document.createElement("div");
timer.id = "timer";
timer.innerHTML = `<span class="timer-pages"></span><span class="timer-slide"><small>ページ</small><b></b></span><span class="timer-total"><small>全体</small><b></b></span>`;
let activeTerminal = null;
let digits = "";

async function loadDeck() {
  for (const { socket, term, host } of terminals.values()) {
    socket.onclose = null;
    socket.close();
    term.dispose();
    host.remove();
  }
  terminals = new Map();
  activeTerminal = null;

  deck = await MpSlides.load(stage);
  slides = [...stage.querySelectorAll(":scope > section.slide")];
  startedAt = deck.startedAt;
  stage.append(timer); // スライドと一緒に拡大縮小させる
  stage.classList.toggle("timed", !!deck.duration);
  renderTimer();
  layout();
  show(Math.min(Number(location.hash.slice(1) || 1) - 1, slides.length - 1), { fragments: "none" });
}

// 開始前は数えない
function spentOnCurrent(now = Date.now()) {
  return startedAt ? (slideSpent.get(current) ?? 0) + (now - enteredAt) : 0;
}

// 待っている表紙には持ち時間がない
function slideTimed() {
  return !(current === 0 && MpSlides.coverFirst(deck));
}

function slideBudget() {
  return MpSlides.slideBudget(deck, MpSlides.timedSlideCount(deck));
}

// 表紙の次へ進んだら(表紙がなければ最初から)タイマーを始める
function maybeStartTimer() {
  if (deck?.duration && !startedAt && slideTimed() && events.readyState === WebSocket.OPEN) {
    events.send(JSON.stringify({ type: "timer-start" }));
  }
}

function renderTimer() {
  timer.hidden = !deck?.duration || !slides.length;
  if (timer.hidden) return;
  const total = MpSlides.remaining(deck, startedAt);
  const budget = slideBudget();
  const slide = MpSlides.slideRemaining(budget, spentOnCurrent());
  timer.querySelector(".timer-pages").textContent = `${current + 1} / ${slides.length}`;
  timer.querySelector(".timer-slide").hidden = !slideTimed();
  timer.querySelector(".timer-slide b").textContent = MpSlides.formatTime(slide);
  timer.querySelector(".timer-slide").dataset.state = MpSlides.slideState(budget, slide);
  timer.querySelector(".timer-total b").textContent = MpSlides.formatTime(total);
  timer.querySelector(".timer-total").dataset.state = MpSlides.timerState(deck, total);
}

function resetTimer(at) {
  startedAt = at;
  slideSpent.clear();
  enteredAt = Date.now();
  renderTimer();
  maybeStartTimer();
  sendState();
}

function layout() {
  if (!deck) return;
  scale = Math.min(innerWidth / deck.size[0], innerHeight / deck.size[1]);
  stage.style.transform = `translate(-50%, -50%) scale(${scale})`;
  placeTerminals();
}

// xterm.js は文字幅を getBoundingClientRect で測るので、transform の中に置くと
// 拡大率が二重に効いて桁数や行数が狂う。ステージの外に置き、埋め込み位置へ重ねる
function placeTerminals() {
  const padding = 12 * scale;
  for (const { term, fit, host, slot, font } of terminals.values()) {
    host.hidden = !slot.closest("section").classList.contains("active");
    if (host.hidden) continue;
    const rect = slot.getBoundingClientRect();
    Object.assign(host.style, {
      left: `${rect.left + padding}px`,
      top: `${rect.top + padding}px`,
      width: `${rect.width - padding * 2}px`,
      height: `${rect.height - padding * 2}px`,
    });
    term.options.fontSize = Math.round(font * scale);
    fit.fit();
  }
}

function fragmentsOf(slide) {
  return [...slide.querySelectorAll(".fragment")];
}

function show(index, { fragments }) {
  if (!slides[index]) index = 0;
  releaseFocus();
  slides[current]?.classList.remove("active");
  slides[current]?.querySelectorAll("iframe").forEach((frame) => frame.blur());
  if (index !== current) {
    if (startedAt) slideSpent.set(current, spentOnCurrent());
    enteredAt = Date.now();
  }
  current = index;
  const slide = slides[current];
  slide.classList.add("active");
  fragmentsOf(slide).forEach((el) => el.classList.toggle("shown", fragments === "all"));
  history.replaceState(null, "", `#${current + 1}`);
  mountEmbeds(slide);
  renderNotes();
  renderTimer();
  maybeStartTimer();
  sendState();
}

// 発表者ビューへ今の表示を伝える
function sendState() {
  if (events.readyState !== WebSocket.OPEN || !slides[current]) return;
  const step = fragmentsOf(slides[current]).filter((el) => el.classList.contains("shown")).length;
  const terminal = currentTerminal();
  events.send(JSON.stringify({
    type: "state", slide: current, step, script: terminal?.script() ?? null, ready: terminal?.ready() ?? false,
    // 発表者ビューはここから経過を数える
    slideSpent: spentOnCurrent(), sentAt: Date.now(), running: !!startedAt,
    slideTimed: slideTimed(), slideBudget: deck?.duration ? slideBudget() : null,
  }));
}

function currentTerminal() {
  const entries = [...slides[current].querySelectorAll(".embed-terminal")].map((el) => terminals.get(el.dataset.embed));
  return entries.find((entry) => entry?.script().length) ?? entries[0];
}

// 発表者ビューの Enter。ターミナルにフォーカスがなくても実行できるようにする
function runTerminal() {
  const terminal = currentTerminal();
  // コマンドを打ち込む前の Enter は空行になるだけなので送らない
  if (terminal && (terminal.ready() || !terminal.script().length)) terminal.term.input("\r");
}

function next() {
  const hidden = fragmentsOf(slides[current]).find((el) => !el.classList.contains("shown"));
  if (hidden) {
    hidden.classList.add("shown");
    sendState();
  } else if (current < slides.length - 1) {
    show(current + 1, { fragments: "none" });
  }
}

function prev() {
  const shown = fragmentsOf(slides[current]).filter((el) => el.classList.contains("shown")).pop();
  if (shown) {
    shown.classList.remove("shown");
    sendState();
  } else if (current > 0) {
    show(current - 1, { fragments: "all" });
  }
}

function mountEmbeds(slide) {
  slide.querySelectorAll(".embed:not(.mounted)").forEach((el) => {
    el.classList.add("mounted");
    const embed = deck.embeds[el.dataset.embed];
    if (embed.type === "terminal") mountTerminal(el, el.dataset.embed, embed);
    else mountWeb(el, embed);
  });
  placeTerminals();
}

function mountTerminal(slot, id, embed) {
  const host = document.createElement("div");
  host.className = "terminal-host";
  document.body.append(host);
  const term = new Terminal({
    fontFamily: 'Menlo, "Hiragino Sans", monospace',
    fontSize: Math.round(embed.font * scale),
    cursorBlink: true,
    theme: { background: "#14161b", foreground: "#e6e6e6" },
  });
  const fit = new FitAddon.FitAddon();
  term.loadAddon(fit);
  term.open(host);
  const script = () => (typed ? [typed, ...queue] : [...queue]);
  const ready = () => typed !== null;
  terminals.set(id, { term, fit, host, slot, font: embed.font, script, ready });
  placeTerminals();

  const socket = new WebSocket(`${wsBase}pty?id=${id}&cols=${term.cols}&rows=${term.rows}`);
  socket.binaryType = "arraybuffer";
  const queue = [...embed.commands];
  let idleTimer = null;
  let waitingToType = queue.length > 0;
  let typed = null; // 入力欄にあって実行待ちのコマンド

  // 台本のコマンドは入力欄に打つだけで実行しない。実行は発表者の Enter に任せる
  const typeNextWhenIdle = () => {
    clearTimeout(idleTimer);
    if (!waitingToType) return;
    idleTimer = setTimeout(() => {
      waitingToType = false;
      if (queue.length) {
        typed = queue.shift();
        send({ input: typed });
        sendState();
      }
    }, 400);
  };
  const send = (message) => {
    if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message));
  };

  socket.onmessage = (event) => {
    term.write(new Uint8Array(event.data));
    typeNextWhenIdle();
  };
  socket.onclose = () => term.write("\r\n\x1b[2m[セッション終了]\x1b[0m\r\n");
  term.onData((data) => {
    send({ input: data });
    if (data.includes("\r")) {
      typed = null;
      if (queue.length) waitingToType = true;
      sendState();
    }
  });
  term.onResize(({ cols, rows }) => send({ resize: [cols, rows] }));
  term.attachCustomKeyEventHandler(() => true);
  term.textarea.addEventListener("focus", () => (activeTerminal = term));
  term.textarea.addEventListener("blur", () => {
    if (activeTerminal === term) activeTerminal = null;
  });

  terminals.get(id).socket = socket;
}

function mountWeb(el, embed) {
  if (!embed.src) {
    el.textContent = "URL が指定されていません";
    return;
  }
  const frame = document.createElement("iframe");
  frame.src = embed.src;
  // サイトが親ページを遷移させる処理(フレーム破壊)を防ぐため top navigation は許可しない
  frame.sandbox = "allow-scripts allow-same-origin allow-forms allow-popups allow-modals allow-downloads";
  frame.allow = "fullscreen";
  if (embed.zoom !== 1) {
    frame.style.width = `${100 / embed.zoom}%`;
    frame.style.height = `${100 / embed.zoom}%`;
    frame.style.transform = `scale(${embed.zoom})`;
    frame.style.transformOrigin = "0 0";
  }
  // iframe にフォーカスが移るとキー操作が届かなくなるので、クリックするまで覆っておく
  const shield = document.createElement("button");
  shield.className = "shield";
  shield.title = "クリックでページを操作";
  shield.addEventListener("click", () => {
    shield.hidden = true;
    frame.focus();
  });
  el.addEventListener("mouseleave", () => {
    shield.hidden = false;
    frame.blur();
    window.focus();
  });
  el.append(frame, shield);
}

function releaseFocus() {
  activeTerminal?.blur();
  activeTerminal = null;
}

function focusTerminal() {
  const el = slides[current].querySelector(".embed-terminal");
  if (el) terminals.get(el.dataset.embed)?.term.focus();
}

function renderNotes() {
  notesPanel.textContent = deck.slides[current].notes || "(ノートなし)";
}

function toggleFullscreen() {
  if (document.fullscreenElement) document.exitFullscreen();
  else document.documentElement.requestFullscreen();
}

window.addEventListener("keydown", (event) => {
  const command = event.metaKey || event.ctrlKey;
  // ターミナル操作中でも効くキー。xterm より先に受けるためキャプチャ段階で処理する
  if (command && (event.key === "ArrowRight" || event.key === "ArrowLeft")) {
    event.preventDefault();
    event.stopPropagation();
    event.key === "ArrowRight" ? next() : prev();
    return;
  }
  if (command && event.key === ".") {
    event.preventDefault();
    event.stopPropagation();
    releaseFocus();
    return;
  }
  if (activeTerminal || command || event.altKey) return;

  const actions = {
    ArrowRight: next, ArrowDown: next, PageDown: next, " ": next,
    ArrowLeft: prev, ArrowUp: prev, PageUp: prev,
    Home: () => show(0, { fragments: "none" }),
    End: () => show(slides.length - 1, { fragments: "all" }),
    f: toggleFullscreen,
    n: () => (notesPanel.hidden = !notesPanel.hidden),
    t: focusTerminal,
    "?": () => (helpPanel.hidden = !helpPanel.hidden),
    p: () => events.send(JSON.stringify({ type: "open-presenter" })),
    q: () => events.send(JSON.stringify({ type: "quit" })),
  };
  if (/^\d$/.test(event.key)) {
    digits += event.key;
  } else if (event.key === "Enter" && digits) {
    show(Math.min(Number(digits), slides.length) - 1, { fragments: "all" });
    digits = "";
  } else if (actions[event.key]) {
    event.preventDefault();
    digits = "";
    actions[event.key]();
  }
}, true);

window.addEventListener("resize", layout);

const commands = {
  next,
  prev,
  run: runTerminal,
  first: () => show(0, { fragments: "none" }),
  last: () => show(slides.length - 1, { fragments: "all" }),
  goto: ({ slide }) => show(Math.min(Math.max(slide, 0), slides.length - 1), { fragments: "all" }),
};

const events = new WebSocket(`${wsBase}events?role=audience`);
events.onopen = () => {
  maybeStartTimer();
  sendState();
};
events.onmessage = (event) => {
  const message = JSON.parse(event.data);
  if (message.type === "reload") loadDeck();
  else if (message.type === "hello") sendState();
  else if (message.type === "timer") resetTimer(message.startedAt);
  else if (message.type === "command") commands[message.cmd]?.(message);
};

setInterval(renderTimer, 250);
loadDeck();
