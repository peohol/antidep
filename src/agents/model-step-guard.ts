// ============================================================================
// Vakten som holder modell-leddet uten legitimasjon — også i praksis
//
// EVIDENCE_PIPELINE.md §63 sier at et ledd som leser utrygt eksternt innhold,
// ikke samtidig skal ha unødvendig tilgang til hemmeligheter. Modell-leddet er
// nettopp det leddet, og det har ingen kode som leser en agenthemmelighet —
// `drafting-no-write-path.test.ts` kontrollerer at importgrafen ikke engang når
// fram til modulen som kunne.
//
// Men en importgraf er en påstand om koden, ikke om prosessen. En kjører startet
// i et skall der agenthemmeligheten er eksportert, har hemmeligheten i miljøet
// sitt uansett hva koden gjør med den — og det er den tilstanden §63 handler om.
// Vakten under er derfor prosessens halvdel av den samme regelen: er en
// agenthemmelighet i miljøet, kjører modell-leddet ikke.
//
// ----------------------------------------------------------------------------
// Hvorfor et mønster og ikke en liste
//
// Navnene på legitimasjonsvariablene står i `agent-environment.ts`, og den
// modulen kan ikke importeres herfra: den er selve modulen modell-leddet ikke
// skal nå. En kopi av listen ville drevet fra originalen i stillhet, og et nytt
// agentledd ville fått en hemmelighet vakten ikke kjente.
//
// Mønsteret gjelder derfor formen på navnet, og `model-step-guard.test.ts`
// kontrollerer at hver legitimasjon som faktisk finnes, treffes av det. Da er
// det originalen som holder kopien i sjakk, og ikke omvendt.
// ============================================================================

/** Formen på navnet en agenthemmelighet har. */
const SECRET_NAME = /^ANTIDEP_[A-Z0-9_]*SECRET$/

/** Miljøet slik en kjører leser det. `process.env` passer formen. */
export type ProcessEnv = Readonly<Record<string, string | undefined>>

/** Navnene på agenthemmelighetene som faktisk står i miljøet, i sortert rekkefølge. */
export function agentSecretsInEnvironment(env: ProcessEnv): readonly string[] {
  return Object.keys(env)
    .filter((name) => SECRET_NAME.test(name) && (env[name] ?? '').trim().length > 0)
    .sort()
}

/**
 * Kaster dersom modell-leddet ville kjørt med en agenthemmelighet i miljøet.
 *
 * Meldingen er den kommandoen som løser det, og ikke bare en beskrivelse av
 * problemet: alternativet er at en kjører står fast på en regel den ikke kan
 * gjøre noe med, og da blir regelen slått av framfor fulgt.
 */
export function assertNoAgentCredentials(env: ProcessEnv, command: string): void {
  const present = agentSecretsInEnvironment(env)
  if (present.length === 0) {
    return
  }
  const unset = present.map((name) => `-u ${name}`).join(' ')
  throw new Error(
    `Modell-leddet skal ikke kjøre med agentlegitimasjon i miljøet, og disse står der: ` +
      `${present.join(', ')}.\n\n` +
      'Leddet leser en artikkel Antidep ikke kontrollerer, og et ledd som gjør det, skal ikke ' +
      'samtidig ha tilgang til hemmeligheten som kan skrive en rad (EVIDENCE_PIPELINE.md §63). ' +
      'Registreringen er en egen kommando, med sin egen identitet, og den skal kjøres for seg.\n\n' +
      `Kjør modell-leddet uten dem:\n\n  env ${unset} ${command}\n`,
  )
}
