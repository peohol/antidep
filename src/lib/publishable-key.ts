// ============================================================================
// Vakten mot en nøkkel som gir mer enn kalleren skal ha
//
// service_role omgår RLS og hører verken hjemme i en nettleser eller i
// MCP-appen (DATABASE_ARCHITECTURE.md §49). Vakten er et supplement og ikke
// låsen: den virkelige beskyttelsen er at nøkkelen aldri legges i repoet. Den
// fanger dagen noen likevel kopierer feil verdi inn i et miljø.
//
// Modulen importerer ingenting. Det er ikke tilfeldig: den leses både av
// nettleserklienten og av den serversiden MCP-appen kjører på, og en import av
// noe Vite-spesifikt herfra ville dratt `import.meta.env` inn i et
// Node-bygg som ikke har den.
// ============================================================================

const SECRET_KEY_PREFIX = 'sb_secret_'

/** Rollene en klient har lov til å opptre som (migrasjon 001). */
const CLIENT_ROLES = ['anon', 'authenticated']

/**
 * Leser `role`-claimet fra en legacy Supabase-nøkkel (en JWT).
 *
 * Returnerer `null` når nøkkelen ikke er en JWT vi kan lese. Et ukjent format
 * er ikke bevis på at nøkkelen er hemmelig, og vakten skal ikke blokkere et
 * gyldig nøkkelformat den ikke kjenner.
 */
function jwtRoleClaim(key: string): string | null {
  const segments = key.split('.')
  if (segments.length !== 3) {
    return null
  }
  const payload = segments[1]
  if (payload === undefined || payload.length === 0) {
    return null
  }
  try {
    const base64 = payload.replaceAll('-', '+').replaceAll('_', '/')
    const padded = base64.padEnd(base64.length + ((4 - (base64.length % 4)) % 4), '=')
    const claims: unknown = JSON.parse(atob(padded))
    if (typeof claims !== 'object' || claims === null) {
      return null
    }
    const role = (claims as Record<string, unknown>)['role']
    return typeof role === 'string' ? role : null
  } catch {
    return null
  }
}

/**
 * Avviser nøkler som gir mer enn en klient skal ha.
 *
 * Kontrollen er bevisst positiv for JWT-nøkler: alt annet enn `anon` og
 * `authenticated` avvises, ikke bare `service_role`. En framtidig privilegert
 * rolle skal ikke slippe gjennom fordi vakten bare kjente den ene ved navn.
 */
export function assertPublishableKey(key: string, name = 'VITE_SUPABASE_PUBLISHABLE_KEY'): void {
  if (key.startsWith(SECRET_KEY_PREFIX)) {
    throw new Error(
      `${name} ser ut til å være en secret key ` +
        `(${SECRET_KEY_PREFIX}…). Hemmelige nøkler skal aldri i klientkode eller i repoet. ` +
        'Bruk prosjektets publishable key.',
    )
  }
  const role = jwtRoleClaim(key)
  if (role !== null && !CLIENT_ROLES.includes(role)) {
    throw new Error(
      `${name} har rollen «${role}». En klient skal bare ` +
        `opptre som ${CLIENT_ROLES.join(' eller ')}. En service_role-nøkkel omgår RLS og ` +
        'skal aldri i klientkode eller i repoet.',
    )
  }
}
