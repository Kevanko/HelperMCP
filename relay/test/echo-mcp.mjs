// Tiny stdio MCP server used by e2e.mjs as the "other MCP server on the friend's PC".
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { ListToolsRequestSchema, CallToolRequestSchema } from '@modelcontextprotocol/sdk/types.js';

const s = new Server({ name: 'echo', version: '1' }, { capabilities: { tools: {} } });
s.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [{ name: 'say', description: 'echo back', inputSchema: { type: 'object', properties: { msg: { type: 'string' } }, required: ['msg'] } }],
}));
s.setRequestHandler(CallToolRequestSchema, async ({ params }) => ({ content: [{ type: 'text', text: `echo:${params.arguments.msg}` }] }));
await s.connect(new StdioServerTransport());
