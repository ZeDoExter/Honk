// Elysia contender (Bun): TypeBox validation on POST, 201 created, 400 mapped.
import { Elysia, t } from "elysia";

const port = parseInt(process.argv[2] || "18506");
new Elysia({ normalize: false })
  .onError(({ code, error, set }) => {
    if (
      code === "VALIDATION" ||
      code === "PARSE" ||
      (code === "UNKNOWN" && error?.message === "STRICT400")
    ) {
      set.status = 400;
      return "Bad Request";
    }
  })
  .onParse(async ({ request }) => {
    // Strictness guard: Elysia coerces numeric strings ("30" -> 30) with no
    // opt-out, so reject mistyped W4 fields here for cross-framework parity.
    // Native t.Object validation below still runs on every request.
    if (request.method !== "POST") return undefined;
    const text = await request.text();
    let v;
    try {
      v = JSON.parse(text);
    } catch {
      throw new Error("STRICT400");
    }
    if (typeof v !== "object" || v === null || Array.isArray(v)) {
      throw new Error("STRICT400");
    }
    if (typeof v.name !== "string") throw new Error("STRICT400");
    if (typeof v.age !== "number") throw new Error("STRICT400");
    if (typeof v.active !== "boolean") throw new Error("STRICT400");
    return v;
  })
  .get("/plaintext", () => "Hello, World!")
  .get("/json", () => ({ message: "Hello, World!" }))
  .get("/users/:id", ({ params: { id }, query: { role }, set }) => {
    set.headers["X-Frame-Bench"] = "1";
    return { id, role: role ?? "" };
  })
  .post(
    "/users",
    ({ body, set }) => {
      set.status = 201;
      return { created: true, name: body.name, age: body.age };
    },
    {
      body: t.Object({
        name: t.String({ minLength: 1 }),
        age: t.Integer(),
        active: t.Boolean(),
      }),
    }
  )
  .listen(port);

console.log(`elysia listening on ${port}`);
