// ============================================================================
// Innledningen til kontrolløkten: hva skal kontrolleres, og mot hvilken kilde
//
// Den første reelle kildekontrollen begynte på spørsmål én — «har du tilgang til
// kilden?» — uten at noe hadde sagt hvilket virkestoff, hvilket endepunkt eller
// hvilken artikkel saken gjaldt. Kontrolløren måtte finne det ut av
// enkeltfeltene underveis, og det er en dårlig måte å møte en kontroll på.
//
// Innledningen svarer på de to spørsmålene før første delkontroll:
//
//   **Hva skal kontrolleres?**  virkestoff, endepunkt og populasjon, som én
//                               setning bygget av den kanoniske raden.
//   **Kilden som er brukt**     hele tittelen, som lenke til artikkelen.
//
// ----------------------------------------------------------------------------
// Bygget av raden, ikke av fri KI-tekst
//
// Setningen kommer fra `controlSubjectStatement()`, som leser kolonnene på
// evidensfunnet (`extraction-statements.ts`). En generert innledning ville vært
// en tekst ingen har kontrollert, plassert øverst i nettopp den flaten som
// finnes for å kontrollere tekst (ANTIDEP_CONSTITUTION.md §4, §12).
//
// ----------------------------------------------------------------------------
// Hvorfor den står på siden og ikke i veiviseren
//
// Veiviseren viser ett steg om gangen, og innledningen skal stå mens hele økten
// pågår. Den er heller ikke en delkontroll: ingenting i den kan besvares, og et
// steg som ikke kan besvares, ville talt med i progresjonen uten å være arbeid.
// ============================================================================

import { SourceTitleLink } from './SourceLink'
import { controlSubjectStatement } from '../lib/extraction-statements'
import type { VerificationItem } from '../agents/verification-input'

export function ExtractionControlIntro({ dossier }: { readonly dossier: VerificationItem }) {
  return (
    <section className="control-intro">
      <h3 className="control-intro__heading">Hva skal kontrolleres?</h3>
      <p className="control-intro__lead">{controlSubjectStatement(dossier.extraction)}</p>

      <h3 className="control-intro__heading">Kilden som er brukt</h3>
      <SourceTitleLink identifiers={dossier.sourceIdentifiers} title={dossier.sourceTitle} />
    </section>
  )
}
