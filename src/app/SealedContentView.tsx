// ============================================================================
// Rendereren for ett forseglet innhold — den samme for klinikeren og for
// sluttkontrolløren
//
// ANTIDEP_CONSTITUTION.md krever at fagpersonen vurderer det ferdige produktet i
// **samme visning** som klinikeren får. Fra publiseringsleveransen er det to
// sider — kandidaten før publisering og det publiserte innholdet etter — og da
// er «samme visning» bare sant hvis det er den samme komponenten. To
// komponenter ville vært en godkjenning av noe annet enn det som vises, uansett
// hvor like de så ut.
//
// ----------------------------------------------------------------------------
// Hva som vises, og hvorfor akkurat det
//
// Påstanden og usikkerheten står øverst, fordi det er produktet. Deretter
// evidensvurderingen med hvert GRADE-domene for seg, kildestøttekontrollen med
// hvert av de sju kontrollpunktene for seg, så kildedekningen, så hvert
// evidensfunn med sine tall og sine ordrette utdrag. Kildedekningen er ikke en
// fotnote: den svarer på hvor mye av det raden påstår, som faktisk er
// kontrollert — og et felt som ingen kontroll dekker, står navngitt framfor å
// være utelatt. Et felt som er borte fra visningen, leses som et felt uten
// avvik (ANTIDEP_CONSTITUTION.md regel 4).
//
// ----------------------------------------------------------------------------
// Hvorfor hele det forseglede innholdet står nederst
//
// Avtrykket dekker hele innholdet — ikke bare de feltene denne komponenten har
// fått en overskrift for. En visning som bare viste et utvalg, ville latt en
// fagperson attestere opplysninger hen aldri så, og avstanden ville vokst hver
// gang `knowledge.candidate_content` fikk et felt til. Innholdet vises derfor
// også i sin helhet, ordrett.
//
// Utrygg inndata: innholdet er data. React escaper all tekst, og ingenting her
// tolker en verdi som markup.
// ============================================================================

import {
  AVAILABILITY_LABELS,
  CHECK_FIELD_LABELS,
  CHECK_RESULT_LABELS,
  CERTAINTY_LABELS,
  GRADE_DOMAIN_LABELS,
  GRADE_RATING_LABELS,
  OUTCOME_LABELS,
  SOURCE_ACCESS_LABELS,
  label,
} from '../lib/vocabulary-view'
import {
  coverageRatio,
  uncoveredCheckFields,
  CITATION_SUPPORT_CHECK_FIELDS,
  GRADE_DOMAIN_FIELDS,
  type CandidateAssessment,
  type CandidateCitationSupportCheck,
  type CandidateEvidence,
  type SealedContent,
} from '../lib/candidate-view'

/**
 * Evidensvurderingen, med hvert GRADE-domene navngitt.
 *
 * Domenene står som egne linjer og ikke som en samlet sikkerhetsgrad: en
 * nedgradering skjuler *hvilket* domene som svikter, og et domene som ikke lot
 * seg vurdere, er ikke et domene uten problem (ANTIDEP_CONSTITUTION.md regel 4).
 */
function AssessmentDomains({
  assessment,
}: {
  readonly assessment: CandidateAssessment
}): React.JSX.Element {
  return (
    <ul>
      {GRADE_DOMAIN_FIELDS.map((field) => {
        const rating = assessment[field]
        return (
          <li key={field}>
            {label(field, GRADE_DOMAIN_LABELS)}:{' '}
            {rating === null
              ? 'ikke vurdert — det finnes ikke noe å gradere ned fra'
              : label(rating, GRADE_RATING_LABELS)}
          </li>
        )
      })}
    </ul>
  )
}

/** Kildestøttekontrollen, med hvert av de sju kontrollpunktene for seg. */
function CitationSupportCheck({
  check,
}: {
  readonly check: CandidateCitationSupportCheck
}): React.JSX.Element {
  return (
    <>
      <p>
        Utfall: {label(check.outcome, OUTCOME_LABELS)}. Verifikatoren hadde tilgang til{' '}
        {label(check.sourceAccess, SOURCE_ACCESS_LABELS)}.
      </p>
      <ul>
        {CITATION_SUPPORT_CHECK_FIELDS.map((field) => (
          <li key={field}>
            {label(field, CHECK_FIELD_LABELS)}: {label(check[field], CHECK_RESULT_LABELS)}
          </li>
        ))}
      </ul>
      <p>{check.rationale}</p>
      {check.findings === null ? null : <p className="notice">Funn: {check.findings}</p>}
      <p>
        Kontrollert evidenssett: <code>{check.verifiedEvidenceSetDigest}</code>
      </p>
    </>
  )
}

function EvidenceCard({ evidence }: { readonly evidence: CandidateEvidence }): React.JSX.Element {
  const ratio = coverageRatio(evidence)
  const uncovered = uncoveredCheckFields(evidence)

  return (
    <li>
      <h4>{evidence.sourceTitle}</h4>
      <p>
        {evidence.outcomeDetail} Retning: {evidence.reportedDirection}.
        {evidence.estimate === null
          ? ` Estimat: ${label(evidence.estimateAvailability, AVAILABILITY_LABELS)}.`
          : ` Estimat: ${evidence.estimate}${evidence.estimateUnit === null ? '' : ` ${evidence.estimateUnit}`}${evidence.effectMeasure === null ? '' : ` (${evidence.effectMeasure})`}.`}
      </p>
      <p>
        Design: {evidence.designCode}.{' '}
        {evidence.sampleSize === null
          ? `Antall deltakere: ${label(evidence.sampleSizeAvailability, AVAILABILITY_LABELS)}.`
          : `Antall deltakere: ${String(evidence.sampleSize)}.`}{' '}
        {evidence.ciLower === null || evidence.ciUpper === null
          ? `Konfidensintervall: ${label(evidence.confidenceIntervalAvailability, AVAILABILITY_LABELS)}.`
          : `Konfidensintervall${evidence.ciLevelPercent === null ? '' : ` (${evidence.ciLevelPercent} %)`}: ${evidence.ciLower} til ${evidence.ciUpper}.`}{' '}
        Sted i kilden: {evidence.sourceLocator}.
      </p>
      {evidence.limitations === null ? null : <p>Begrensninger: {evidence.limitations}</p>}
      <p>
        Kontrollert: {String(ratio.covered)} av {String(ratio.required)} felter.{' '}
        {evidence.extractionCheckOutcome === null
          ? 'Ingen ekstraksjonskontroll er registrert.'
          : `Siste ekstraksjonskontroll: ${evidence.extractionCheckOutcome}.`}{' '}
        {evidence.groundingMachineProved
          ? 'Maskinbeviset for kildeforankringen gjelder.'
          : 'Maskinbeviset for kildeforankringen gjelder ikke.'}
      </p>
      {uncovered.length === 0 ? null : (
        <p className="notice">Ikke kontrollerte felter: {uncovered.join(', ')}.</p>
      )}
      {evidence.groundings.length === 0 ? (
        <p className="notice">Ingen ordrette utdrag er registrert for dette funnet.</p>
      ) : (
        <ul>
          {evidence.groundings.map((grounding) => (
            <li key={`${grounding.checkField}:${grounding.sourceExcerpt}`}>
              <strong>{grounding.checkField}</strong> ({grounding.sourceLocator}):{' '}
              <q>{grounding.sourceExcerpt}</q>
            </li>
          ))}
        </ul>
      )}
    </li>
  )
}

export interface SealedContentViewProps {
  readonly content: SealedContent
  /**
   * Hva avtrykket sier at innholdet er, med ord.
   *
   * Sagt av kalleren og ikke utledet her, fordi det er to forskjellige utsagn:
   * en kandidat er et internt utkast som ingen har publisert, og et publisert
   * innhold er noe Antidep faktisk sier nå. En komponent som gjettet, ville
   * kunnet gjette feil på nøyaktig det skillet som betyr mest.
   */
  readonly sealNote: string
}

export function SealedContentView({
  content,
  sealNote,
}: SealedContentViewProps): React.JSX.Element {
  return (
    <>
      <section aria-labelledby="paastand-title">
        <h2 id="paastand-title">Påstanden</h2>
        <p className="lead">{content.claim.statement}</p>
        <p>
          Virkestoff: {content.claim.subjectDrug}. Tema: {content.claim.topic}.{' '}
          {content.claim.population === null
            ? 'Populasjon er ikke angitt.'
            : `Populasjon: ${content.claim.population}.`}
        </p>
        <p>Avgrensning: {content.claim.scope}</p>
        <p>Usikkerhet: {content.claim.uncertaintySummary}</p>
        {content.claim.qualifiers === null ? null : <p>Forbehold: {content.claim.qualifiers}</p>}
      </section>

      <section aria-labelledby="vurdering-title">
        <h2 id="vurdering-title">Evidensvurdering</h2>
        {content.assessment === null ? (
          <p className="notice">
            Ingen evidensvurdering er registrert. Det er noe annet enn en vurdering som konkluderte
            med lav sikkerhet.
          </p>
        ) : (
          <>
            <p>
              Sikkerhet i grunnlaget ({content.assessment.framework}):{' '}
              {label(content.assessment.certaintyLevel, CERTAINTY_LABELS)}.
            </p>
            <AssessmentDomains assessment={content.assessment} />
            {content.assessment.otherConsiderations === null ? null : (
              <p>Andre hensyn: {content.assessment.otherConsiderations}</p>
            )}
            <p>{content.assessment.rationale}</p>
            {content.assessment.evidenceGap === null ? null : (
              <p>Kunnskapshull: {content.assessment.evidenceGap}</p>
            )}
          </>
        )}
      </section>

      <section aria-labelledby="kildestoette-title">
        <h2 id="kildestoette-title">Kildestøttekontroll</h2>
        {content.citationSupportCheck === null ? (
          <p className="notice">
            Ingen kildestøttekontroll er registrert. Det er noe annet enn en kontroll som ikke fant
            avvik.
          </p>
        ) : (
          <CitationSupportCheck check={content.citationSupportCheck} />
        )}
      </section>

      <section aria-labelledby="dekning-title">
        <h2 id="dekning-title">Kildedekning</h2>
        {content.sourceCoverage.length === 0 ? (
          <p className="notice">Ingen kilder er knyttet til innholdet.</p>
        ) : (
          <ul>
            {content.sourceCoverage.map((source) => (
              <li key={source.sourceId}>
                <strong>{source.title}</strong>: {String(source.evidenceItemCount)} evidensfunn.{' '}
                {source.fullTextInLibrary
                  ? 'Fullteksten ligger i biblioteket.'
                  : 'Fullteksten ligger ikke i biblioteket.'}{' '}
                {source.readabilityChecked
                  ? 'Lesbarheten er kontrollert.'
                  : 'Lesbarheten er ikke kontrollert.'}{' '}
                {source.groundingMachineProved
                  ? 'Kildeforankringen er maskinelt bevist.'
                  : 'Kildeforankringen er ikke maskinelt bevist.'}
              </li>
            ))}
          </ul>
        )}
      </section>

      <section aria-labelledby="evidens-title">
        <h2 id="evidens-title">Evidensgrunnlaget</h2>
        {content.evidence.length === 0 ? (
          <p className="notice">Ingen evidensfunn er lenket til innholdet.</p>
        ) : (
          <ul>
            {content.evidence.map((evidence) => (
              <EvidenceCard evidence={evidence} key={evidence.evidenceItemId} />
            ))}
          </ul>
        )}
      </section>

      <section aria-labelledby="forseglet-title">
        <h2 id="forseglet-title">Alt avtrykket dekker</h2>
        <p>{sealNote}</p>
        <pre>{JSON.stringify(content.sealedContent, null, 2)}</pre>
      </section>
    </>
  )
}
