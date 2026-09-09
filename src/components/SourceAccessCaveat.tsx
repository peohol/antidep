// ============================================================================
// Konsekvensen av å bare ha et sammendrag, sagt før arbeidet gjøres
//
// ANTIDEP_CONSTITUTION.md §11 forbyr å godkjenne på et annet ledds sammendrag,
// og begge verifikasjonstabellene håndhever forbudet med en CHECK. Kontrolløren
// skal vite det *før* hen går gjennom feltene, ikke få det som en avvisning
// etterpå — og merknaden blir stående gjennom hele økten, ikke bare i det ene
// steget der svaret ble gitt.
// ============================================================================

export function SourceAccessCaveat({ sources }: { readonly sources: readonly string[] }) {
  if (sources.length === 0) {
    return null
  }
  return (
    <div className="knowledge-notice knowledge-notice--absence" role="note">
      <p className="knowledge-notice__lead">
        Med bare et sammendrag kan kontrollen ikke ende i en bekreftelse.
      </p>
      <p className="knowledge-notice__caveat">
        Du kan fortsatt gå gjennom feltene og melde fra om avvik. Kontrollen blir registrert som
        uavklart, og det er riktig: en bekreftelse skal hvile på kilden selv.
      </p>
      <p className="knowledge-notice__detail">
        {sources.length === 1
          ? `Dette gjelder ${sources[0] ?? ''}.`
          : `Dette gjelder: ${sources.join('; ')}.`}
      </p>
    </div>
  )
}
