// Express contender (Node): route middleware, manual W4 validation, 400 errors.
import express from "express";

const port = parseInt(process.argv[2] || "18509");
const app = express();

app.get("/plaintext", (req, res) => res.type("text/plain").send("Hello, World!"));
app.get("/json", (req, res) => res.json({ message: "Hello, World!" }));
const frameBench = (req, res, next) => {
  res.set("X-Frame-Bench", "1");
  next();
};
app.get("/users/:id", frameBench, (req, res) =>
  res.json({ id: req.params.id, role: req.query.role ?? "" })
);
app.post("/users", express.json(), (req, res) => {
  const { name, age, active } = req.body ?? {};
  if (typeof name !== "string" || name.length === 0) {
    return res.status(400).send("Bad Request");
  }
  if (typeof age !== "number" || !Number.isInteger(age)) {
    return res.status(400).send("Bad Request");
  }
  if (typeof active !== "boolean") {
    return res.status(400).send("Bad Request");
  }
  res.status(201).json({ created: true, name, age });
});
// Malformed JSON bodies land here (express.json throws) -> 400, not 500/HTML.
app.use((err, req, res, next) => {
  res.status(400).send("Bad Request");
});

app.listen(port, "127.0.0.1", () => console.log(`express listening on ${port}`));
