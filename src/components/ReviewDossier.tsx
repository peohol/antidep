// ============================================================================
// Grunnlaget en reviewer faktisk vurderer
//
// Panelene her viser hva som er registrert — påstanden ordrett og strukturert,
// hver evidenslenke med funnet, kilden, kildeversjonen og den gjeldende
// ekstraksjonskontrollen, registrert evidens som ikke er lenket, evidensvurderingen,
// de kontrollene og beslutningene som allerede finnes, og hva publiseringsgaten
// svarer.
//
// Ingen av dem tar en beslutning, og ingen av dem regner ut om påstanden «er
// klar». Blokkeringen kommer fra publiseringsgaten selv
// (`api.claim_review_workspace`), og panelet gjengir gatens egen setning.
//
// ----------------------------------------------------------------------------
// To regler går igjen i hvert panel
//
//   * Fravær vises som fravær, aldri som en nullverdi. «Ingen registrert
//     kontroll» er ikke «kontrollen var negativ», og «ingen registrert
//     motstridende evidens» er ikke «det finnes ingen»
//     (ANTIDEP_CONSTITUTION.md §6, §17).
//   * Farge er aldri eneste bærer. Hver tilstand står med ord, og
//     klassenavnene er tillegg for øyet (§2, WCAG).
// ============================================================================

import { Detail, DetailList, DetailNote } from './DetailList'
import {
  CLAIM_CHECKPOINTS,
  CERTAINTY_LEVEL_LABELS,
  GRADE_DOMAIN_LABELS,
  KNOWLEDGE_TYPE_LABELS,
  REVIEW_OUTCOME_LABELS,
  SOURCE_STATUS_LABELS,
  SOURCE_TYPE_LABELS,
  VERIFICATION_CHECK_RESULT_LABELS,
  VERIFICATION_OUTCOME_LABELS,
  VERIFICATION_SOURCE_ACCESS_LABELS,
  stanceText,
  termText,
} from './vocabulary-labels'
import {
  describeEvidenceStance,
  readCertaintyLevel,
  readGradeDomainRating,
  readKnowledgeType,
  readReviewOutcome,
  readSourceStatus,
  readSourceType,
  readVerificationCheckResult,
  readVerificationOutcome,
  readVerificationSourceAccess,
} from '../lib/evidence-item'
import { formatTimestampWithClock } from '../lib/norwegian-format'
import type { ClaimEvidenceLink, ClaimRevisionInput } from '../agents/claim-verification-input'
import type {
  ClaimVerificationRecord,
  EvidenceAssessmentRecord,
  PublicationGateState,
  ReviewDecisionRecord,
} from '../lib/review-workspace'

/** En verdi som ikke er registrert. Aldri en tom celle. */
function Absent({ children }: { readonly children: string }) {
  return <span className="review-absent">{children}</span>
}

function checkResultText(value: string): string {
  return termText(readVerificationCheckResult(value), VERIFICATION_CHECK_RESULT_LABELS, 'resultat')
}

function sourceAccessText(value: string): string {
  return termText(
    readVerificationSourceAccess(value),
    VERIFICATION_SOURCE_ACCESS_LABELS,
    'kildetilgang',
  )
}

function outcomeText(value: string): string {
  return termText(readVerificationOutcome(value), VERIFICATION_OUTCOME_LABELS, 'utfall')
}

/** Et tidspunkt der klokkeslettet hører med: to kontroller samme dag er to kontroller. */
function whenText(raw: string): string {
  return formatTimestampWithClock(raw).text
}

// ----------------------------------------------------------------------------
// Påstanden
// ----------------------------------------------------------------------------

export function ClaimStatementPanel({ revision }: { readonly revision: ClaimRevisionInput }) {
  const { claim } = revision
  return (
    <section className="review-panel">
      <h3>Påstanden</h3>
      <blockquote className="review-statement">{claim.statement}</blockquote>
      <DetailList>
        <Detail label="Kunnskapstype">
          {termText(
            readKnowledgeType(revision.knowledgeType),
            KNOWLEDGE_TYPE_LABELS,
            'kunnskapstype',
          )}
        </Detail>
        <Detail label="Virkestoff">{revision.subjectDrugName}</Detail>
        <Detail label="Tema">{revision.topicLabel}</Detail>
        <Detail label="Revisjon">
          {`Nr. ${String(revision.revisionNumber)}`}
          <DetailNote>
            Vurderingen gjelder nøyaktig denne formuleringen, ikke påstanden generelt.
          </DetailNote>
        </Detail>
        <Detail label="Anvendelsesområde">{claim.scope}</Detail>
        <Detail label="Populasjon">
          {claim.populationLabel ?? <Absent>Ikke avgrenset til en registrert populasjon</Absent>}
        </Detail>
        <Detail label="Tidsrom">
          {claim.timeframeMin === null && claim.timeframeMax === null ? (
            <Absent>Ikke tidsavgrenset</Absent>
          ) : (
            `${claim.timeframeMin ?? '–'} til ${claim.timeframeMax ?? '–'}`
          )}
        </Detail>
        <Detail label="Komparator">{claim.comparatorDrugName ?? claim.comparatorKind}</Detail>
        <Detail label="Retning">
          {claim.direction ?? <Absent>Påstanden uttrykker ingen strukturert retning</Absent>}
        </Detail>
        <Detail label="Størrelse">
          {claim.magnitudeValue === null ? (
            <Absent>Ingen tallfestet størrelse</Absent>
          ) : (
            `${claim.magnitudeValue} ${claim.magnitudeUnit ?? ''} (${claim.magnitudeMeasure ?? 'uoppgitt mål'})`
          )}
        </Detail>
        <Detail label="Forbehold">
          {claim.qualifiers ?? <Absent>Ingen forbehold er registrert</Absent>}
        </Detail>
        <Detail label="Usikkerhet">
          {claim.uncertaintySummary ?? <Absent>Ingen usikkerhet er formulert</Absent>}
        </Detail>
        <Detail label="Formulert av">{revision.createdByActorKey}</Detail>
        <Detail label="Evidenssettets avtrykk">
          <code>{revision.evidenceSetDigest}</code>
          <DetailNote>
            Vurderingen du registrerer, bindes til dette settet. Kommer det en evidenslenke til mens
            du arbeider, avvises registreringen framfor å dekke noe du ikke har sett.
          </DetailNote>
        </Detail>
      </DetailList>
    </section>
  )
}

// ----------------------------------------------------------------------------
// Én evidenslenke
// ----------------------------------------------------------------------------

export function EvidenceLinkPanel({ link }: { readonly link: ClaimEvidenceLink }) {
  const item = link.evidenceItem
  const extraction = item.extraction
  const verification = link.currentExtractionVerification
  return (
    <article className="review-link">
      <h4>{item.sourceTitle}</h4>
      <DetailList>
        <Detail label="Relasjon til påstanden">
          {`${stanceText(
            describeEvidenceStance({
              relationship_type: link.relationshipType,
              directness: link.directness,
            }),
          )} · ${link.directness === 'direct' ? 'treffer påstanden direkte' : 'treffer påstanden indirekte'}`}
          <DetailNote>{link.relevanceNote}</DetailNote>
        </Detail>
        <Detail label="Kilde">
          {`${termText(readSourceType(item.sourceType), SOURCE_TYPE_LABELS, 'dokumenttype')} · ${
            item.sourceAuthorsOrIssuer
          }`}
          <DetailNote>
            {item.sourcePublisherOrJournal ?? 'Ingen utgiver er registrert'}
            {item.sourcePublicationDate === null ? '' : ` · ${item.sourcePublicationDate}`}
          </DetailNote>
        </Detail>
        <Detail label="Kildestatus">
          {termText(readSourceStatus(item.sourceStatus), SOURCE_STATUS_LABELS, 'kildestatus')}
          {item.sourceStatusNote === null ? null : <DetailNote>{item.sourceStatusNote}</DetailNote>}
        </Detail>
        <Detail label="Hvor i kilden">{extraction.sourceLocator}</Detail>
        <Detail label="Kildeversjon">
          {item.sourceVersion === null ? (
            <Absent>
              Ingen registrert kildeversjon. Uten den kan ikke kontrollen din bygge på en
              etterprøvbar representasjon
            </Absent>
          ) : (
            <>
              {item.sourceVersion.retrievedFrom}
              <DetailNote>
                {`Hentet ${whenText(item.sourceVersion.retrievedAt)}. Fingeravtrykk: ${
                  item.sourceVersion.contentHash ?? 'ikke registrert'
                }`}
              </DetailNote>
            </>
          )}
        </Detail>
        <Detail label="Ekstraksjonen">
          {`${extraction.interventionDrugName} · ${extraction.outcomeLabel}`}
          <DetailNote>{extraction.outcomeDetail}</DetailNote>
        </Detail>
        <Detail label="Populasjon i funnet">
          {extraction.populationLabel ?? extraction.populationAvailability}
          <DetailNote>{extraction.populationDetail}</DetailNote>
        </Detail>
        <Detail label="Estimat">
          {extraction.estimate === null ? (
            <Absent>{`Ingen verdi (${extraction.estimateAvailability})`}</Absent>
          ) : (
            `${extraction.estimate} ${extraction.estimateUnit ?? ''} (${
              extraction.effectMeasure ?? 'uoppgitt mål'
            })`
          )}
        </Detail>
        <Detail label="Konfidensintervall">
          {extraction.ciLower === null || extraction.ciUpper === null ? (
            <Absent>{`Ingen verdi (${extraction.confidenceIntervalAvailability})`}</Absent>
          ) : (
            `${extraction.ciLower} til ${extraction.ciUpper} (${
              extraction.ciLevelPercent ?? '?'
            } %)`
          )}
        </Detail>
        <Detail label="Gjeldende ekstraksjonskontroll">
          {verification === null ? (
            <Absent>
              Ingen ekstraksjonskontroll er registrert. Det er ikke det samme som at kontrollen var
              negativ
            </Absent>
          ) : (
            <>
              {`${outcomeText(verification.outcome)} · ${sourceAccessText(
                verification.sourceAccess,
              )}`}
              <DetailNote>
                {`Kontrollerte felter: ${
                  verification.checkedFields.length === 0
                    ? 'ingen'
                    : verification.checkedFields.join(', ')
                }`}
              </DetailNote>
            </>
          )}
        </Detail>
      </DetailList>
    </article>
  )
}

// ----------------------------------------------------------------------------
// Registrert evidens som ikke er lenket
// ----------------------------------------------------------------------------

export function UnlinkedEvidencePanel({ revision }: { readonly revision: ClaimRevisionInput }) {
  return (
    <section className="review-panel">
      <h3>Registrert evidens som ikke er lenket til påstanden</h3>
      <p className="review-panel__lead">
        Evidensfunn på samme virkestoff og samme endepunkt som ikke er koblet til denne revisjonen.
        Listen er evidens <em>Antidep har registrert</em>, ikke evidensen som finnes: at den er tom,
        betyr aldri at det ikke finnes motstridende forskning.
      </p>
      {revision.unlinkedRelatedEvidence.length === 0 ? (
        <p className="review-absent">
          Ingen registrerte funn står utenfor evidenssettet. Kontrollpunktet om urepresentert
          motstridende evidens må likevel besvares av deg, ikke av denne listen.
        </p>
      ) : (
        <ul className="review-unlinked">
          {revision.unlinkedRelatedEvidence.map((candidate) => (
            <li key={candidate.evidenceItemId}>
              <strong>{candidate.sourceTitle}</strong>
              {` — ${candidate.interventionDrugName}, ${candidate.outcomeLabel}, retning ${candidate.reportedDirection}`}
              {candidate.estimate === null
                ? ''
                : ` (${candidate.estimate} ${candidate.estimateUnit ?? ''})`}
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}

// ----------------------------------------------------------------------------
// Evidensvurderingen
// ----------------------------------------------------------------------------

export function EvidenceAssessmentPanel({
  assessment,
}: {
  readonly assessment: EvidenceAssessmentRecord | null
}) {
  return (
    <section className="review-panel">
      <h3>Evidensvurdering</h3>
      {assessment === null ? (
        <p className="review-absent">
          Ingen evidensvurdering er registrert. En evidenssyntese eller klinisk anbefaling kan ikke
          publiseres uten en, og publiseringsgaten blokkerer på det.
        </p>
      ) : (
        <DetailList>
          <Detail label="Sikkerhet i kunnskapsgrunnlaget">
            {termText(
              readCertaintyLevel(assessment.certaintyLevel),
              CERTAINTY_LEVEL_LABELS,
              'sikkerhetsgrad',
            )}
            <DetailNote>{`Metode: ${assessment.framework}`}</DetailNote>
          </Detail>
          {(
            [
              ['Risiko for systematisk skjevhet', assessment.riskOfBias],
              ['Inkonsistens', assessment.inconsistency],
              ['Indirekthet', assessment.indirectness],
              ['Upresishet', assessment.imprecision],
              ['Publikasjonsskjevhet', assessment.publicationBias],
            ] as const
          ).map(([label, value]) => (
            <Detail key={label} label={label}>
              {value === null ? (
                <Absent>Ikke gradert (ingen vurderbar evidens)</Absent>
              ) : (
                termText(readGradeDomainRating(value), GRADE_DOMAIN_LABELS, 'domenevurdering')
              )}
            </Detail>
          ))}
          <Detail label="Begrunnelse">{assessment.rationale}</Detail>
          <Detail label="Kunnskapshull">
            {assessment.evidenceGap ?? <Absent>Ingen er registrert</Absent>}
          </Detail>
        </DetailList>
      )}
    </section>
  )
}

// ----------------------------------------------------------------------------
// Registrerte kontroller
// ----------------------------------------------------------------------------

function VerificationRecord({
  record,
  isCurrent,
}: {
  readonly record: ClaimVerificationRecord
  readonly isCurrent: boolean
}) {
  return (
    <article className="review-record">
      <h4>
        {`${outcomeText(record.outcome)} — ${record.verifierDisplayName}`}
        {isCurrent ? <span className="review-record__current"> (gjeldende)</span> : null}
      </h4>
      <p className="review-record__meta">
        {`${record.verifierActorType === 'agent' ? 'Maskinell kontroll' : 'Menneskelig kontroll'} · ${
          record.verifierActorKey
        } · ${whenText(record.verifiedAt)} · kildetilgang: ${sourceAccessText(
          record.sourceAccess,
        )}`}
      </p>
      <ul className="review-checkpoints">
        {CLAIM_CHECKPOINTS.map((checkpoint) => (
          <li key={checkpoint.key}>
            <span className="review-checkpoints__label">{checkpoint.label}</span>
            <span className="review-checkpoints__value">
              {checkResultText(record.checks[checkpoint.key])}
            </span>
          </li>
        ))}
      </ul>
      <p className="review-record__rationale">{record.rationale}</p>
      {record.findings === null ? null : (
        <p className="review-record__findings">{`Funn: ${record.findings}`}</p>
      )}
      <ul className="review-record__citations">
        {record.citations.map((citation) => (
          <li key={citation.claimEvidenceLinkId}>
            {`${sourceAccessText(citation.sourceAccess)} · ${checkResultText(
              citation.relationshipSupported,
            )}`}
            {citation.checkedContentHash === null
              ? ''
              : ` · kontrollert mot ${citation.checkedContentHash}`}
            {citation.finding === null ? '' : ` — ${citation.finding}`}
          </li>
        ))}
      </ul>
    </article>
  )
}

export function VerificationHistoryPanel({
  records,
  currentId,
}: {
  readonly records: readonly ClaimVerificationRecord[]
  readonly currentId: string | null
}) {
  return (
    <section className="review-panel">
      <h3>Registrerte kontroller mot grunnlaget</h3>
      {records.length === 0 ? (
        <p className="review-absent">
          Ingen kontroll er registrert ennå. Det er ikke det samme som at en kontroll konkluderte
          negativt.
        </p>
      ) : (
        <>
          <p className="review-panel__lead">
            Den siste registrerte kontrollen er den gjeldende. Tidligere kontroller bevares ved
            siden av den og fjernes aldri.
          </p>
          {records.map((record) => (
            <VerificationRecord
              key={record.claimVerificationId}
              isCurrent={record.claimVerificationId === currentId}
              record={record}
            />
          ))}
        </>
      )}
    </section>
  )
}

// ----------------------------------------------------------------------------
// Registrerte beslutninger
// ----------------------------------------------------------------------------

export function DecisionHistoryPanel({
  records,
  currentId,
}: {
  readonly records: readonly ReviewDecisionRecord[]
  readonly currentId: string | null
}) {
  return (
    <section className="review-panel">
      <h3>Registrerte publiseringsbeslutninger</h3>
      {records.length === 0 ? (
        <p className="review-absent">Ingen beslutning er registrert ennå.</p>
      ) : (
        <ul className="review-decisions">
          {records.map((record) => (
            <li key={record.reviewDecisionId}>
              <strong>
                {termText(
                  readReviewOutcome(record.decision),
                  REVIEW_OUTCOME_LABELS,
                  'reviewbeslutning',
                )}
              </strong>
              {record.reviewDecisionId === currentId ? ' (gjeldende)' : ''}
              {` — ${record.reviewerDisplayName}, ${whenText(record.decidedAt)}`}
              <p className="review-record__rationale">{record.rationale}</p>
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}

// ----------------------------------------------------------------------------
// Publiseringsgaten
// ----------------------------------------------------------------------------

export function PublicationGatePanel({
  gate,
  isPublished,
}: {
  readonly gate: PublicationGateState
  readonly isPublished: boolean
}) {
  if (gate.status === 'passes') {
    return (
      <div className="knowledge-notice knowledge-notice--ok" role="status">
        <p className="knowledge-notice__lead">
          {isPublished
            ? 'Denne revisjonen er publisert, og publiseringsgaten passerer fortsatt.'
            : 'Publiseringsgaten passerer. Alle kravene før publisering er oppfylt.'}
        </p>
        <p className="knowledge-notice__detail">
          Publisering er fortsatt en egen handling med sin egen rettighet: den krever
          publisher-rollen, som er en annen enn den som lar deg godkjenne. Handlingen står nederst
          på siden.
        </p>
      </div>
    )
  }
  return (
    <div className="knowledge-notice knowledge-notice--absence" role="note">
      <p className="knowledge-notice__lead">Publiseringen er blokkert.</p>
      <p className="knowledge-notice__detail">{gate.message}</p>
      {gate.hint === null ? null : <p className="knowledge-notice__caveat">{gate.hint}</p>}
      <p className="knowledge-notice__caveat">
        Gaten stopper på det første kravet som ikke er oppfylt. Er det flere, vises de etter hvert
        som de foregående er på plass.
      </p>
    </div>
  )
}
