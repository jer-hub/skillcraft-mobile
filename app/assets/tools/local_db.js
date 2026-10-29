// Local task database (the spec's SkillCraft-LocalDB server).
const mcp = new McpServer("SkillCraft-LocalDB");

const PRIORITIES = ["high", "medium", "low"];
const STATUSES = ["pending", "done"];

mcp.tool(
  "save_task_to_db",
  {
    description: "Inserts an extracted task directly into the local SQLite task table.",
    inputSchema: {
      type: "object",
      properties: {
        title: { type: "string" },
        priority: { type: "string", enum: PRIORITIES },
        due_date: { type: "string" },
      },
      required: ["title", "priority"],
    },
  },
  async ({ title, priority, due_date }) => {
    if (!PRIORITIES.includes(priority)) throw new Error(`priority must be one of ${PRIORITIES.join(", ")}`);
    const { lastInsertRowId } = await host.sql.execute(
      "INSERT INTO tasks (title, priority, due_date, status) VALUES (?, ?, ?, 'pending')",
      [title, priority, due_date ?? null],
    );
    return `Successfully saved task #${lastInsertRowId}: '${title}'`;
  },
);

mcp.tool(
  "list_tasks",
  {
    description: "Lists saved tasks, optionally filtered by status.",
    inputSchema: {
      type: "object",
      properties: { status: { type: "string", enum: STATUSES } },
    },
  },
  async ({ status }) => {
    const rows = status
      ? await host.sql.query(
          "SELECT id, title, priority, due_date, status FROM tasks WHERE status = ? ORDER BY id",
          [status],
        )
      : await host.sql.query("SELECT id, title, priority, due_date, status FROM tasks ORDER BY id");
    return { tasks: rows };
  },
);

mcp.tool(
  "update_task_status",
  {
    description: "Marks a task as pending or done.",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "integer" },
        status: { type: "string", enum: STATUSES },
      },
      required: ["id", "status"],
    },
  },
  async ({ id, status }) => {
    if (!STATUSES.includes(status)) throw new Error(`status must be one of ${STATUSES.join(", ")}`);
    const { changes } = await host.sql.execute("UPDATE tasks SET status = ? WHERE id = ?", [status, id]);
    if (changes === 0) throw new Error(`No task with id ${id}`);
    return `Task #${id} marked ${status}`;
  },
);
