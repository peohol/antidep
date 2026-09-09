// ============================================================================
// Veien til kilden, alltid ett klikk unna
//
// En kontroll er en sammenligning mot kilden selv. Adressen skal derfor være
// trykkbar overalt der den vises, og ikke bare stå som tekst
// (MVP_IMPLEMENTATION_PLAN.md §15, ANTIDEP_CONSTITUTION.md §11).
//
// `rel="noopener noreferrer"` fordi målet er en fremmed adresse, og `target`
// fordi kontrolløren skal kunne bla i kilden uten å miste økten sin.
// ============================================================================

import { describeSourceAddress } from '../lib/source-address'

export function SourceAddressLink({
  retrievedFrom,
  label,
}: {
  readonly retrievedFrom: string | null
  /** Teksten på lenken. Adressen selv står under, slik at den kan leses og kopieres. */
  readonly label: string
}) {
  const address = describeSourceAddress(retrievedFrom)

  if (address === null) {
    return (
      <p className="source-address source-address--absent">
        Ingen henteadresse er registrert for denne kildeversjonen. Finn kilden fram på egen hånd før
        du svarer.
      </p>
    )
  }

  if (address.kind === 'text') {
    return (
      <p className="source-address source-address--plain">
        Kilden er registrert hentet fra{' '}
        <span className="source-address__value">{address.text}</span>. Adressen kan ikke åpnes
        direkte herfra.
      </p>
    )
  }

  return (
    <p className="source-address">
      <a
        className="source-address__link"
        href={address.href}
        rel="noopener noreferrer"
        target="_blank"
      >
        {label}
      </a>
      <span className="source-address__value">{address.text}</span>
    </p>
  )
}
