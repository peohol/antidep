// ============================================================================
// Den ene siden mennesket ser
//
// Tilkoblingssiden er alt MCP-appen har av flate: et felt der en redaktør limer
// inn engangskoden hen nettopp hentet i Antidep. Den er bevisst uten avhengigheter
// og uten skript — en side som kjørte kode, ville vært en side noen kunne få til
// å kjøre noe annet.
//
// Alt som kommer utenfra, escapes. OAuth-parameterne kommer fra en klient
// Antidep ikke kontrollerer, og de står i skjulte felter på siden.
// ============================================================================

/** Tekst inn i HTML. Escapes alltid, uten unntak. */
export function escapeHtml(value: string): string {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;')
}

export interface ConnectPageFields {
  readonly clientId: string
  readonly redirectUri: string
  readonly codeChallenge: string
  readonly codeChallengeMethod: string
  readonly state: string
  readonly scope: string
  readonly resource: string
}

function hidden(name: string, value: string): string {
  return value.length === 0
    ? ''
    : `      <input type="hidden" name="${escapeHtml(name)}" value="${escapeHtml(value)}" />\n`
}

/** Tilkoblingssiden, med eller uten en feilmelding over feltet. */
export function renderConnectPage(fields: ConnectPageFields, problem: string | null): string {
  const notice =
    problem === null ? '' : `    <p class="problem" role="alert">${escapeHtml(problem)}</p>\n`

  return `<!doctype html>
<html lang="nb">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <meta name="robots" content="noindex, nofollow" />
    <title>Koble Antidep til en agentkjører</title>
    <style>
      :root { color-scheme: light dark; }
      body {
        font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
        margin: 0; padding: 2rem 1rem; line-height: 1.5;
        display: flex; justify-content: center;
      }
      main { max-width: 34rem; width: 100%; }
      h1 { font-size: 1.35rem; margin: 0 0 0.5rem; }
      p { margin: 0 0 1rem; }
      label { display: block; font-weight: 600; margin-bottom: 0.35rem; }
      input[type="text"] {
        width: 100%; box-sizing: border-box; padding: 0.6rem 0.7rem;
        font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
        font-size: 1rem; border: 1px solid currentColor; border-radius: 6px;
        background: transparent; color: inherit;
      }
      button {
        margin-top: 1rem; padding: 0.6rem 1.1rem; font-size: 1rem;
        border-radius: 6px; border: 1px solid currentColor;
        background: transparent; color: inherit; cursor: pointer;
      }
      .problem { border-left: 4px solid currentColor; padding-left: 0.75rem; font-weight: 600; }
      .hint { opacity: 0.8; font-size: 0.92rem; }
    </style>
  </head>
  <body>
    <main>
      <h1>Koble Antidep til en agentkjører</h1>
      <p>
        Lim inn engangskoden du hentet i Antidep under «Autonom kjører» på
        agentarbeidsflaten. Koden gjelder i ti minutter og kan brukes én gang.
      </p>
${notice}      <form method="post">
${hidden('client_id', fields.clientId)}${hidden('redirect_uri', fields.redirectUri)}${hidden('code_challenge', fields.codeChallenge)}${hidden('code_challenge_method', fields.codeChallengeMethod)}${hidden('state', fields.state)}${hidden('scope', fields.scope)}${hidden('resource', fields.resource)}        <label for="pairing_code">Tilkoblingskode</label>
        <input id="pairing_code" name="pairing_code" type="text" autocomplete="off"
               spellcheck="false" autocapitalize="none" required />
        <button type="submit">Koble til</button>
      </form>
      <p class="hint">
        Tilkoblingen gir kjøreren arbeid i nøyaktig ett agentledd. Den gir ingen
        databasetilgang, ingen lesing av andre tabeller og ingen rett til å
        registrere noe uten om Antideps egne kontroller.
      </p>
    </main>
  </body>
</html>
`
}
