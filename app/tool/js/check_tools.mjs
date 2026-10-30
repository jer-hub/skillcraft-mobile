// Checks the bundled tool servers (assets/tools) in Node against a fake host.
// The real runtime is QuickJS on the phone (integration_test/runtime_test);
// this catches script mistakes without a device.
//
//   node tool/js/check_tools.mjs
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";
import assert from "node:assert/strict";

const toolsDir = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "assets", "tools");

/** Loads the prelude plus one server script with `host` answering __host. */
function load(script, host) {
  const calls = [];
  const ctx = vm.createContext({
    __host: async (name, json) => {
      calls.push(name);
      return host(name, JSON.parse(json));
    },
  });
  for (const f of ["_prelude.js", script]) {
    vm.runInContext(readFileSync(join(toolsDir, f), "utf8"), ctx, { filename: f });
  }
  let id = 0;
  const rpc = (method, params) =>
    vm.runInContext(`__mcp.handle(${JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params })})`, ctx);
  const call = (name, args) => rpc("tools/call", { name, arguments: args });
  return { rpc, call, calls };
}

// Values from the vm context have their own prototypes; compare via JSON.
const same = (a, b) => assert.equal(JSON.stringify(a), JSON.stringify(b));

async function checkLocalDb() {
  const tasks = [];
  const { rpc, call } = load("local_db.js", (name, p) => {
    if (name === "sql.execute" && p.sql.startsWith("INSERT")) {
      tasks.push({ id: tasks.length + 1, title: p.params[0], priority: p.params[1], due_date: p.params[2], status: "pending" });
      return { changes: 1, lastInsertRowId: tasks.length };
    }
    if (name === "sql.execute" && p.sql.startsWith("UPDATE")) {
      const t = tasks.find((x) => x.id === p.params[1]);
      if (t) t.status = p.params[0];
      return { changes: t ? 1 : 0, lastInsertRowId: 0 };
    }
    if (name === "sql.query") return p.params.length ? tasks.filter((t) => t.status === p.params[0]) : tasks;
    throw new Error(`unexpected host call ${name}`);
  });

  same((await rpc("initialize", {})).result.serverInfo.name, "SkillCraft-LocalDB");
  same((await rpc("tools/list")).result.tools.map((t) => t.name), ["save_task_to_db", "list_tasks", "update_task_status"]);

  const saved = await call("save_task_to_db", { title: "Send budget", priority: "high", due_date: "Friday" });
  same(saved.result.content[0].text, "Successfully saved task #1: 'Send budget'");
  assert.equal((await call("save_task_to_db", { title: "x" })).result.isError, true, "missing priority");
  assert.equal((await call("save_task_to_db", { title: "x", priority: "urgent" })).result.isError, true, "bad enum");

  same((await call("update_task_status", { id: 1, status: "done" })).result.content[0].text, "Task #1 marked done");
  assert.equal((await call("update_task_status", { id: 99, status: "done" })).result.isError, true);
  same((await call("list_tasks", { status: "done" })).result.structuredContent.tasks.length, 1);

  same((await call("nope", {})).error.code, -32602);
  same((await rpc("resources/list")).error.code, -32601);
}

async function checkCalendar() {
  const events = [];
  const { rpc, call, calls } = load("calendar.js", (name, p) => {
    if (name === "calendar.insert") {
      events.push(p);
      return { eventId: `evt-${events.length}` };
    }
    if (name === "calendar.list") return [{ title: "Standup", start: p.from }];
    throw new Error(`unexpected host call ${name}`);
  });

  same((await rpc("tools/list")).result.tools.map((t) => t.name), ["create_event", "list_events"]);
  const created = await call("create_event", { title: "Review", start: "2026-11-03T14:00" });
  same(created.result.content[0].text, "Created event 'Review' at 2026-11-03T14:00 (id evt-1)");
  assert.equal((await call("create_event", { title: "x" })).result.isError, true, "missing start");
  same((await call("list_events", { from: "2026-11-01", to: "2026-11-30" })).result.structuredContent.events[0].title, "Standup");
  assert.ok(calls.every((c) => c.startsWith("calendar.")), "calendar server only uses calendar host functions");
}

async function checkNotes() {
  const notes = [];
  const { call } = load("vector.js", (name, p) => {
    if (name === "vec.remember") {
      notes.push(p.text);
      return { id: notes.length };
    }
    if (name === "vec.search") return notes.slice(0, p.k).map((t, i) => ({ id: i + 1, text: t, score: 0.87654, created_at: "x" }));
    throw new Error(`unexpected host call ${name}`);
  });

  same((await call("remember_note", { text: "Gate code is 4412" })).result.content[0].text, "Saved note #1");
  const found = (await call("search_notes", { query: "door code" })).result.structuredContent.notes[0];
  same(found, { id: 1, text: "Gate code is 4412", score: 0.877 });
  assert.equal((await call("search_notes", {})).result.isError, true, "missing query");
}

for (const [name, check] of [["local_db", checkLocalDb], ["calendar", checkCalendar], ["notes", checkNotes]]) {
  await check();
  console.log(`ok  ${name}`);
}
