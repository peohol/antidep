// ============================================================================
// Antideps diagnostikk-inngang (/diagnostics)
//
// Adapteren er tynn med vilje, som `api/mcp.ts`: hele ruten ligger i
// src/diagnostics og kan prøves uten en server.
// ============================================================================

import { serveDiagnostics } from '../src/diagnostics/route.ts'

export default {
  fetch(request: Request): Promise<Response> {
    return serveDiagnostics(request, process.env)
  },
}
