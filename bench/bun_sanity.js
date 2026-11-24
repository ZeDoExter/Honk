const port = parseInt(process.argv[2] || "18192", 10);
Bun.serve({
  port,
  fetch() { return new Response("Hello, World!", { headers: { "Content-Type": "text/plain" } }); },
});
