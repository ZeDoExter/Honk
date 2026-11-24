// Raw Bun.serve contender: manual routing, Response.json, no dependencies.
const port = parseInt(process.argv[2] || "18505");

function badRequest() {
  return new Response("Bad Request", { status: 400 });
}

Bun.serve({
  port,
  async fetch(req) {
    const url = new URL(req.url);
    const path = url.pathname;
    if (req.method === "GET" && path === "/plaintext") {
      return new Response("Hello, World!", { headers: { "Content-Type": "text/plain" } });
    }
    if (req.method === "GET" && path === "/json") {
      return Response.json({ message: "Hello, World!" });
    }
    if (req.method === "GET" && path.startsWith("/users/")) {
      const id = path.slice(7);
      if (id.length === 0 || id.includes("/")) {
        return new Response("Not Found", { status: 404 });
      }
      const role = url.searchParams.get("role") ?? "";
      return Response.json({ id, role }, { headers: { "X-Frame-Bench": "1" } });
    }
    if (req.method === "POST" && path === "/users") {
      let v;
      try {
        v = await req.json();
      } catch {
        return badRequest();
      }
      if (typeof v !== "object" || v === null || Array.isArray(v)) return badRequest();
      const { name, age, active } = v;
      if (typeof name !== "string" || name.length === 0) return badRequest();
      if (typeof age !== "number" || !Number.isInteger(age)) return badRequest();
      if (typeof active !== "boolean") return badRequest();
      return Response.json({ created: true, name, age }, { status: 201 });
    }
    return new Response("Not Found", { status: 404 });
  },
});
console.log(`bun-raw listening on ${port}`);
