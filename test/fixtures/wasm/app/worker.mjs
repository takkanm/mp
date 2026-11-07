const ready = WebAssembly.instantiateStreaming(fetch("./add.wasm"));

self.onmessage = async ({ data: [a, b] }) => {
  const { instance } = await ready;
  self.postMessage(instance.exports.add(a, b));
};
