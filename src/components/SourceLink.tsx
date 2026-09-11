// ============================================================================
// Veien til kilden, én gang i økten
//
// Lenken bygges av kildens identifikatorer (`source-links.ts`), ikke av
// henteadressen: den siste er maskinens eksakte adresse — for et EUtils-kall er
// den XML — og er riktig der fingeravtrykket beregnes, men ikke det et menneske
// skal åpne.
//
// ----------------------------------------------------------------------------
// To former, ett sted
//
// `SourceTitleLink` er kilden slik kontrolløren kjenner den igjen: hele
// tittelen, som lenke. Den står i innledningen til økten, der spørsmålet er
// «hvilken artikkel er dette?».
//
// `SourceLink` er den samme adressen uten tittelen, til steget som bare spør om
// kontrolløren har tilgang til fullteksten. Der er tittelen allerede lest, og en
// gjentakelse er støy.
//
// Identifikatorverdien — «DOI 10.4088/jcp.v61n1109» — står ingen av stedene.
// Den er maskinens navn på kilden, ikke kontrollørens, og den hører til under
// «Tekniske detaljer» sammen med henteadressen og fingeravtrykket
// (ANTIDEP_CONSTITUTION.md §2).
//
// `rel="noopener noreferrer"` fordi målet er en fremmed adresse, og `target`
// fordi kontrolløren skal kunne bla i kilden uten å miste økten sin.
// ============================================================================

import { humanSourceLink } from '../lib/source-links'
import type { SourceIdentifier } from '../agents/verification-input'

/** Setningen som står i stedet for en lenke når kilden ikke kan lenkes. */
function NoLinkNotice() {
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

export function SourceLink({ identifiers }: { readonly identifiers: readonly SourceIdentifier[] }) {
  const link = humanSourceLink(identifiers)

  if (link.kind === 'none') {
    return <NoLinkNotice />
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
    </p>
  )
}

/**
 * Hele kildetittelen som lenke til artikkelen.
 *
 * Tittelen står uansett, også når ingen lenke kan bygges: kontrolløren skal
 * kunne se hvilken kilde dette er, og fraværet av en lenke er ikke en grunn til
 * å utelate kilden. Forklaringen på hvorfor lenken mangler, står én gang — i
 * kildetilgangssteget, der den faktisk trengs — og gjentas ikke her.
 */
export function SourceTitleLink({
  identifiers,
  title,
}: {
  readonly identifiers: readonly SourceIdentifier[]
  readonly title: string
}) {
  const link = humanSourceLink(identifiers)

  if (link.kind === 'none') {
    return <p className="source-title">{title}</p>
  }

  return (
    <p className="source-title">
      <a
        className="source-address__link"
        href={link.href}
        rel="noopener noreferrer"
        target="_blank"
      >
        {title}
      </a>
    </p>
  )
}
