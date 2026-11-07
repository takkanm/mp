const result = { origin: self.origin };
try {
  const { instance } = await WebAssembly.instantiateStreaming(fetch("./add.wasm"));
  result.main = instance.exports.add(2, 3);
} catch (e) {
  result.main = `${e.name}: ${e.message}`;
}
try {
  localStorage.setItem("mp", "1");
  result.storage = localStorage.getItem("mp");
} catch (e) {
  result.storage = e.name;
}
// ページの JS から mp のターミナルやデッキへ届かないことを確かめる
const app = new URLSearchParams(location.search).get("app");
if (app) {
  result.deck = await fetch(`${app}_mp/deck.json`).then((r) => `read ${r.status}`, () => "blocked");
  result.pty = await new Promise((resolve) => {
    const socket = new WebSocket(`${app.replace("http", "ws")}_mp/pty?id=e2&cols=80&rows=24`);
    socket.onopen = () => resolve("connected");
    socket.onerror = () => resolve("blocked");
  });
}
const worker = new Worker("./worker.mjs", { type: "module" });
worker.onmessage = ({ data }) => {
  result.worker = data;
  document.getElementById("result").textContent = JSON.stringify(result);
};
worker.onerror = (e) => {
  result.worker = e.message;
  document.getElementById("result").textContent = JSON.stringify(result);
};
worker.postMessage([20, 22]);
