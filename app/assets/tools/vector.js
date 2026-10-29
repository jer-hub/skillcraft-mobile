// Personal notes with semantic search (sqlite-vec + on-device embeddings).
const mcp = new McpServer("SkillCraft-Notes");

mcp.tool(
  "remember_note",
  {
    description: "Saves a note so it can be found later by meaning.",
    inputSchema: {
      type: "object",
      properties: { text: { type: "string", description: "The note to save." } },
      required: ["text"],
    },
  },
  async ({ text }) => {
    const { id } = await host.vec.remember(text);
    return `Saved note #${id}`;
  },
);

mcp.tool(
  "search_notes",
  {
    description: "Finds saved notes related in meaning to a query.",
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string" },
        k: { type: "integer", description: "How many notes to return (default 5)." },
      },
      required: ["query"],
    },
  },
  async ({ query, k }) => {
    const hits = await host.vec.search(query, k ?? 5);
    return {
      notes: hits.map((h) => ({ id: h.id, text: h.text, score: Math.round(h.score * 1000) / 1000 })),
    };
  },
);
