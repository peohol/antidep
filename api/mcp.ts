// ============================================================================
// Antideps private MCP-endepunkt (/mcp)
//
// Adapteren er tynn med vilje: den sier hvilken rute forespørselen traff, og
// ingenting annet. Hele appen ligger i src/mcp og kan prøves uten en server.
// ============================================================================

import { serveMcpRoute } from '../src/mcp/index.ts'

export default {
  fetch(request: Request): Promise<Response> {
    return serveMcpRoute('mcp', request, process.env)
  },
}
