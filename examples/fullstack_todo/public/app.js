const list = document.getElementById("list");
const form = document.getElementById("add");
const title = document.getElementById("title");

async function refresh() {
  const res = await fetch("/api/todos");
  const todos = await res.json();
  list.innerHTML = "";
  for (const t of todos) {
    const li = document.createElement("li");
    if (t.done) li.className = "done";
    const box = document.createElement("input");
    box.type = "checkbox";
    box.checked = t.done;
    box.onchange = async () => {
      await fetch(`/api/todos/${t.id}/toggle`, { method: "PATCH" });
      refresh();
    };
    const span = document.createElement("span");
    span.textContent = t.title;
    const del = document.createElement("button");
    del.textContent = "×";
    del.onclick = async () => {
      await fetch(`/api/todos/${t.id}`, { method: "DELETE" });
      refresh();
    };
    li.append(box, span, del);
    list.append(li);
  }
}

form.onsubmit = async (e) => {
  e.preventDefault();
  if (!title.value.trim()) return;
  await fetch("/api/todos", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ title: title.value.trim() }),
  });
  title.value = "";
  refresh();
};

refresh();
