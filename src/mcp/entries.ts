// ============================================================================
// App-inngangene: én MCP-adresse per agentledd
//
// ChatGPT knytter én OAuth-forbindelse til én egendefinert app, og en app er en
// adresse. Da flere Workspace Agents la til den samme appen, fikk de derfor den
// samme forbindelsen — og dermed den samme kjøreren og den samme rollen —
// uansett hvilket ledd de var ment for. En ny agent satt opp for
// dekningskontrollen utløste ingen ny tilkobling, og hentet kildeoppdagelsens
// arbeid.
//
// Hvert ledd har derfor sin egen adresse under `/mcp/`, slik at plattformen ser
// seks apper og oppretter seks forbindelser. Bak adressene står den samme
// behandleren, de samme fem verktøyene og den samme databasen.
//
// ----------------------------------------------------------------------------
// Adressen gir ingen fullmakt
//
// Rollen er fortsatt tilkoblingens egen, satt av mennesket som registrerte
// kjøreren, og tokenet er fortsatt den eneste veien til den
// (ANTIDEP_CONSTITUTION.md regel 7). En forespørsel til
// `/mcp/source-quality-assessment` får ikke rollen `source_quality_assessment`
// av at den kom dit. Inngangen gjør to ting, og begge snevrer inn:
//
//   1. Den er publikumet tokenet utstedes for (RFC 8707). Et token utstedt for
//      én inngang autentiserer ikke mot en annen: databasen avviser det i det
//      samme predikatet som kontrollerer tokenet. Det er også det som gjør at en
//      klient som prøver å gjenbruke en forbindelse på tvers av apper, blir bedt
//      om en ny tilkobling framfor å få en.
//   2. Den sier hvilket ledd den tar imot, og avviser en tilkobling for et annet
//      ledd — når koden limes inn, og på hvert kall. Det er et ekstra vern og
//      ikke kilden til rollen: uten det ville tokenet fortsatt bare fått arbeid i
//      sitt eget ledd.
//
// ----------------------------------------------------------------------------
// `/mcp` består
//
// Kildeoppdagelsen har en tilkobling i drift mot `/mcp`, og tokenet den har, er
// utstedt for nettopp den adressen. Adressen består derfor, som inngangen for
// kildeoppdagelsen, med de samme metadataene som før. En ny tilkobling for
// kildeoppdagelsen skal gå mot `/mcp/source-discovery`; den gamle flyttes dit
// først når noen uansett kobler den til på nytt.
// ============================================================================

import { HANDOFF_ROLES, type HandoffRole } from '../agents/agent-task.ts'

/**
 * Navnet hver app skal ha i ChatGPT.
 *
 * `Record` over rollene gjør et nytt agentledd uten et appnavn til en typefeil,
 * framfor et ledd som mangler en inngang ingen merker.
 */
const APP_NAMES: Readonly<Record<HandoffRole, string>> = {
  source_discovery: 'Antidep – Kildeoppdagelse',
  source_quality_assessment: 'Antidep – Dekningskontroll',
  evidence_extraction: 'Antidep – Evidensekstraksjon',
  claim_synthesis: 'Antidep – Påstandssyntese',
  evidence_assessment: 'Antidep – Evidensvurdering',
  monograph_answer: 'Antidep – Monografisvar',
}

/** Én app slik ChatGPT ser den: en adresse, et navn og det ene leddet den tar imot. */
export interface McpAppEntry {
  /** Stien protokollendepunktet står på. Ressursen og metadataene er utledet av den. */
  readonly path: string
  /** Det ene agentleddet inngangen tar imot en tilkobling for. */
  readonly agentRole: HandoffRole
  /** Navnet appen registreres under i ChatGPT. */
  readonly appName: string
  /** `resource_name` i metadatadokumentet (RFC 9728). */
  readonly resourceName: string
}

const MCP_PATH = '/mcp'

/** Stien til leddets egen inngang: rollen, med bindestrek slik en adresse skrives. */
export function entryPathFor(role: HandoffRole): string {
  return `${MCP_PATH}/${role.replaceAll('_', '-')}`
}

/** De seks inngangene, én per agentledd som kan settes ut. */
export const MCP_APP_ENTRIES: readonly McpAppEntry[] = HANDOFF_ROLES.map((role) => ({
  path: entryPathFor(role),
  agentRole: role,
  appName: APP_NAMES[role],
  resourceName: APP_NAMES[role],
}))

/**
 * Den opprinnelige adressen, som kildeoppdagelsens inngang.
 *
 * Metadataene er de samme som før inngangene fantes, navnet medregnet, slik at
 * ingenting klienten allerede har lest om den, er blitt et annet.
 */
export const LEGACY_MCP_ENTRY: McpAppEntry = {
  path: MCP_PATH,
  agentRole: 'source_discovery',
  appName: APP_NAMES.source_discovery,
  resourceName: 'Antidep agentarbeid',
}

const ALL_ENTRIES: readonly McpAppEntry[] = [LEGACY_MCP_ENTRY, ...MCP_APP_ENTRIES]

/**
 * Den kanoniske adressen tokenet utstedes for (RFC 8707, RFC 9728).
 *
 * Det er denne `resource` må navngi hele veien gjennom OAuth-flyten, og den
 * samme serveren kontrollerer at et access-token faktisk ble utstedt for, før
 * det slipper inn. Uten bindingen kunne et token utstedt for en helt annen
 * MCP-server — eller for en annen av Antideps egne apper — blitt brukt her.
 */
export function canonicalResource(baseUrl: string, entry: McpAppEntry): string {
  return `${baseUrl}${entry.path}`
}

/** Inngangen en `resource`-parameter navngir, eller `null` når den ikke er en av dem. */
export function entryForResource(baseUrl: string, resource: string): McpAppEntry | null {
  return ALL_ENTRIES.find((entry) => canonicalResource(baseUrl, entry) === resource) ?? null
}

/**
 * Inngangen en sti til protokollendepunktet navngir.
 *
 * `/api/mcp` er den samme funksjonen sett direkte, uten omskrivingen foran, og
 * har alltid svart som `/mcp`. Den gjør det fortsatt.
 */
export function entryForMcpPath(pathname: string): McpAppEntry | null {
  const path = pathname.replace(/^\/api(?=\/mcp(?:\/|$))/, '')
  return ALL_ENTRIES.find((entry) => entry.path === path) ?? null
}

const PROTECTED_RESOURCE_METADATA = '/oauth-protected-resource'

/**
 * Inngangen et metadatadokument (RFC 9728) gjelder for.
 *
 * Dokumentet for en ressurs med sti står på `/.well-known/oauth-protected-resource`
 * etterfulgt av ressursens sti — `…/mcp/source-discovery` for
 * `/mcp/source-discovery`. Uten sti er det den opprinnelige adressens dokument,
 * som før. En sti som ikke er en av inngangene, har intet dokument: et
 * dokument som svarte for den, ville beskrevet en ressurs som ikke finnes.
 */
export function entryForMetadataPath(pathname: string): McpAppEntry | null {
  const at = pathname.indexOf(PROTECTED_RESOURCE_METADATA)
  if (at === -1) {
    return null
  }
  const resourcePath = pathname.slice(at + PROTECTED_RESOURCE_METADATA.length)
  if (resourcePath.length === 0) {
    return LEGACY_MCP_ENTRY
  }
  return ALL_ENTRIES.find((entry) => entry.path === resourcePath) ?? null
}

/** Hvor metadatadokumentet for en inngang står (RFC 9728 §3.1). */
export function metadataUrlFor(baseUrl: string, entry: McpAppEntry): string {
  return `${baseUrl}/.well-known${PROTECTED_RESOURCE_METADATA}${entry.path}`
}
