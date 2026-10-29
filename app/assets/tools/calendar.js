// Device calendar (Android calendar provider via the app).
const mcp = new McpServer("SkillCraft-Calendar");

const ISO = "ISO 8601 local date-time, e.g. 2026-11-03T14:00";

mcp.tool(
  "create_event",
  {
    description: "Creates an event in the device's default calendar.",
    inputSchema: {
      type: "object",
      properties: {
        title: { type: "string" },
        start: { type: "string", description: ISO },
        end: { type: "string", description: `${ISO}; defaults to one hour after start` },
        description: { type: "string" },
      },
      required: ["title", "start"],
    },
  },
  async ({ title, start, end, description }) => {
    const { eventId } = await host.calendar.insert({ title, start, end, description });
    return `Created event '${title}' at ${start} (id ${eventId})`;
  },
);

mcp.tool(
  "list_events",
  {
    description: "Lists calendar events between two date-times.",
    inputSchema: {
      type: "object",
      properties: {
        from: { type: "string", description: ISO },
        to: { type: "string", description: ISO },
      },
      required: ["from", "to"],
    },
  },
  async ({ from, to }) => ({ events: await host.calendar.list(from, to) }),
);
