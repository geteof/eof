// Small Express-style handler
const cache = new Map();

export async function greet(req, res) {
  const name = req.query.name ?? "world";
  if (!cache.has(name)) {
    cache.set(name, `Hello, ${name}!`);
  }
  res.json({ message: cache.get(name), cached: cache.size, at: Date.now() });
}

class Counter extends EventTarget {
  #count = 0;
  increment() { return ++this.#count; }
}

export default { greet, Counter };
