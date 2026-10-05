// Tiny stdio MCP server used by e2e.mjs as the "other MCP server on the friend's PC".
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { ListToolsRequestSchema, CallToolRequestSchema } from '@modelcontextprotocol/sdk/types.js';

import { spawn } from 'node:child_process';
import fs from 'node:fs';
// like uvx/npx: the real work happens in a grandchild; the test checks that stopping the server kills it too
if (process.env.GRANDCHILD_PIDFILE) {
  const g = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], { stdio: 'ignore' });
  fs.writeFileSync(process.env.GRANDCHILD_PIDFILE, String(g.pid));
}
const s = new Server({ name: 'echo', version: '1' }, { capabilities: { tools: {} } });
s.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [{ name: 'say', description: 'echo back', inputSchema: { type: 'object', properties: { msg: { type: 'string' } }, required: ['msg'] } }],
}));
s.setRequestHandler(CallToolRequestSchema, async ({ params }) => ({ content: [{ type: 'text', text: `echo:${params.arguments.msg}` }] }));
await s.connect(new StdioServerTransport());
