// SkillCraft tool-server prelude: a minimal MCP server over JSON-RPC 2.0
// (initialize, tools/list, tools/call), plus `host` helpers. Evaluated before
// each tool script in its own sandboxed QuickJS runtime. The only way out of
// the sandbox is __host(name, payloadJson), provided by the app.

const __call = (name, payload) =>
  __host(name, JSON.stringify(payload === undefined ? null : payload));

globalThis.host = {
  sql: {
    query: (sql, params = []) => __call("sql.query", { sql, params }),
    execute: (sql, params = []) => __call("sql.execute", { sql, params }),
  },
  calendar: {
    insert: (event) => __call("calendar.insert", event),
    list: (from, to) => __call("calendar.list", { from, to }),
  },
  vec: {
    remember: (text) => __call("vec.remember", { text }),
    search: (query, k) => __call("vec.search", { query, k }),
  },
};

globalThis.console = {
  log: (...args) =>
    __call("log", { message: args.map((a) => (typeof a === "string" ? a : JSON.stringify(a))).join(" ") }),
};
console.error = console.warn = console.log;

const PROTOCOL_VERSION = "2025-06-18";

class McpServer {
  constructor(name, version = "1.0.0") {
    this.name = name;
    this.version = version;
    this.tools = new Map();
    globalThis.__mcp = this;
  }

  /** Registers a tool. `handler(args)` may be async; it returns text or JSON. */
  tool(name, { description = "", inputSchema = { type: "object", properties: {} } }, handler) {
    if (this.tools.has(name)) throw new Error(`Duplicate tool: ${name}`);
    this.tools.set(name, { name, description, inputSchema, handler });
  }

  /** Handles one JSON-RPC request object; always resolves to a response. */
  async handle(request) {
    const id = request.id ?? null;
    const ok = (result) => ({ jsonrpc: "2.0", id, result });
    const fail = (code, message) => ({ jsonrpc: "2.0", id, error: { code, message } });
    const params = request.params ?? {};

    switch (request.method) {
      case "initialize":
        return ok({
          protocolVersion: PROTOCOL_VERSION,
          serverInfo: { name: this.name, version: this.version },
          capabilities: { tools: {} },
        });
      case "tools/list":
        return ok({
          tools: [...this.tools.values()].map(({ name, description, inputSchema }) => ({
            name,
            description,
            inputSchema,
          })),
        });
      case "tools/call": {
        const tool = this.tools.get(params.name);
        if (!tool) return fail(-32602, `Unknown tool: ${params.name}`);
        const args = params.arguments ?? {};
        const missing = (tool.inputSchema.required ?? []).filter((k) => args[k] === undefined || args[k] === null);
        if (missing.length) return ok(errorResult(`Missing required argument(s): ${missing.join(", ")}`));
        try {
          return ok(toResult(await tool.handler(args)));
        } catch (e) {
          // Tool failures are results the model can read, not protocol errors.
          return ok(errorResult(e instanceof Error ? e.message : String(e)));
        }
      }
      default:
        return fail(-32601, `Method not found: ${request.method}`);
    }
  }
}
globalThis.McpServer = McpServer;

function toResult(value) {
  if (typeof value === "string") return { content: [{ type: "text", text: value }] };
  const json = value === undefined ? null : value;
  return { content: [{ type: "text", text: JSON.stringify(json) }], structuredContent: json };
}

function errorResult(message) {
  return { content: [{ type: "text", text: message }], isError: true };
}
