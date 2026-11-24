// Hono contender (Bun): scoped middleware, manual W4 validation.
import { Hono } from "hono";

const app = new Hono();

app.get("/plaintext", (c) => c.text("Hello, World!"));
app.get("/json", (c) => c.json({ message: "Hello, World!" }));
app.use("/users/:id", async (c, next) => {
  await next();
  c.header("X-Frame-Bench", "1");
});
app.get("/users/:id", (c) =>
  c.json({ id: c.req.param("id"), role: c.req.query("role") ?? "" })
);
app.post("/users", async (c) => {
  let v;
  try {
    v = await c.req.json();
  } catch {
    return c.text("Bad Request", 400);
  }
  if (typeof v !== "object" || v === null || Array.isArray(v)) {
    return c.text("Bad Request", 400);
  }
  const { name, age, active } = v;
  if (typeof name !== "string" || name.length === 0) return c.text("Bad Request", 400);
  if (typeof age !== "number" || !Number.isInteger(age)) return c.text("Bad Request", 400);
  if (typeof active !== "boolean") return c.text("Bad Request", 400);
  return c.json({ created: true, name, age }, 201);
});

const port = parseInt(process.argv[2] || "18507");
Bun.serve({ port, fetch: app.fetch });
console.log(`hono listening on ${port}`);
