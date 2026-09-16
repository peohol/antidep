// ============================================================================
// Protected Resource Metadata (/.well-known/oauth-protected-resource, RFC 9728)
//
// Adapteren er tynn med vilje: den sier hvilken rute forespørselen traff, og
// ingenting annet. Hele appen ligger i src/mcp og kan prøves uten en server.
// ============================================================================

import { serveMcpRoute } from '../../src/mcp/index.ts'

export default {
  fetch(request: Request): Promise<Response> {
    return serveMcpRoute('protected-resource-metadata', request, process.env)
  },
}
