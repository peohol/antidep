// ============================================================================
// Veien til kilden, én gang i økten
//
// Lenken bygges av kildens identifikatorer (`source-links.ts`), ikke av
// henteadressen: den siste er maskinens eksakte adresse — for et EUtils-kall er
// den XML — og er riktig der fingeravtrykket beregnes, men ikke det et menneske
// skal åpne.
//
// Komponenten står i kildetilgangssteget og ingen andre steder. En lenke gjentatt
// i hver feltskuff er støy i nøyaktig det steget som skal inneholde minst mulig
// (ANTIDEP_CONSTITUTION.md §2).
//
// `rel="noopener noreferrer"` fordi målet er en fremmed adresse, og `target`
// fordi kontrolløren skal kunne bla i kilden uten å miste økten sin.
// ============================================================================

import { humanSourceLink } from '../lib/source-links'
import type { SourceIdentifier } from '../agents/verification-input'

export function SourceLink({ identifiers }: { readonly identifiers: readonly SourceIdentifier[] }) {
  const link = humanSourceLink(identifiers)

  if (link.kind === 'none') {
    return (
      <div className="knowledge-notice knowledge-notice--absence" role="note">
        <p className="knowledge-notice__lead">
          Kilden har ingen registrert DOI eller PubMed-ID, så Antidep kan ikke lage en lenke til
          artikkelen.
        </p>
        <p className="knowledge-notice__caveat">
          Finn kilden fram på egen hånd før du svarer. Adressen Antidep hentet representasjonen fra,
          ligger under «Tekniske detaljer»; den peker på maskinens utgave og ikke på artikkelen.
        </p>
      </div>
    )
  }

  return (
    <p className="source-address">
      <a
        className="source-address__link"
        href={link.href}
        rel="noopener noreferrer"
        target="_blank"
      >
        Åpne kilden
      </a>
      <span className="source-address__value">{link.label}</span>
    </p>
  )
}
