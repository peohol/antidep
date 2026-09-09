// ============================================================================
// De to sidene av ett kontrollpunkt
//
// Venstre side er hva Antidep sier i påstanden; høyre side er hva det
// registrerte grunnlaget inneholder. Kontrollen er sammenligningen mellom dem,
// og formen gjør den sammenligningen til det den er — side om side på bred
// skjerm, stablet på smal.
//
// Setningene er ferdig formulert av `claim-checkpoint-context.ts`. Denne
// komponenten avgjør ingenting om innholdet; den stiller det opp.
// ============================================================================

export function CheckpointPanes({
  claimSide,
  evidenceSide,
}: {
  readonly claimSide: readonly string[]
  readonly evidenceSide: readonly string[]
}) {
  return (
    <div className="field-check__panes">
      <div className="field-check__pane">
        <h4 className="field-check__pane-heading">Påstanden</h4>
        {claimSide.map((line) => (
          <p className="field-check__statement" key={line}>
            {line}
          </p>
        ))}
      </div>
      <div className="field-check__pane">
        <h4 className="field-check__pane-heading">Grunnlaget</h4>
        {evidenceSide.length === 0 ? (
          <p className="field-check__detail">Ingen registrerte evidenslenker å sammenligne med.</p>
        ) : (
          evidenceSide.map((line) => (
            <p className="field-check__detail" key={line}>
              {line}
            </p>
          ))
        )}
      </div>
    </div>
  )
}
