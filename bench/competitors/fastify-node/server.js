// Fastify contender (Node): logger off, JSON-schema validation on POST.
import Fastify from "fastify";

const port = parseInt(process.argv[2] || "18508");
const app = Fastify({ logger: false, ajv: { customOptions: { coerceTypes: false } } });

app.get("/plaintext", async () => "Hello, World!");
app.get("/json", async () => ({ message: "Hello, World!" }));
app.get(
  "/users/:id",
  { preHandler: async (req, reply) => void reply.header("X-Frame-Bench", "1") },
  async (req) => ({ id: req.params.id, role: req.query.role ?? "" })
);
app.post(
  "/users",
  {
    schema: {
      body: {
        type: "object",
        required: ["name", "age", "active"],
        properties: {
          name: { type: "string", minLength: 1 },
          age: { type: "integer" },
          active: { type: "boolean" },
        },
      },
    },
  },
  async (req, reply) => {
    reply.code(201);
    return { created: true, name: req.body.name, age: req.body.age };
  }
);

await app.listen({ port, host: "127.0.0.1" });
console.log(`fastify listening on ${port}`);
