// ============================================================================
// Grunnlaget en reviewer kontrollerer en ekstraksjon mot
//
// Panelene her viser hva som er registrert om ett evidensfunn: kilden og dens
// status, kildeversjonen med adresse og fingeravtrykk, hele den strukturerte
// ekstraksjonen felt for felt, den rå ekstraksjonen ordrett, hvilke felter som
// må være kontrollert mot hvilke som per nå er dekket, kontrollene som allerede
// finnes, og hvilke påstander funnet allerede bærer.
//
// Ingen av dem tar en beslutning, og ingen av dem regner ut om ekstraksjonen «er
// i orden». Feltdekningen kommer fra publiseringsgatens egne funksjoner
// (`workflow.required_check_fields` og `workflow.covered_check_fields`), og
// differansen mellom de to er ren mengdelære over det databasen har levert.
//
// ----------------------------------------------------------------------------
// To regler går igjen i hvert panel
//
//   * Fravær vises som fravær, aldri som en nullverdi. «Ingen registrert
//     kontroll» er ikke «kontrollen var negativ», og «ikke rapportert i kilden»
//     er ikke «null» (ANTIDEP_CONSTITUTION.md §6, §17).
//   * Farge er aldri eneste bærer. Hver tilstand står med ord, og klassenavnene
//     er tillegg for øyet (§2, WCAG).
// ============================================================================

import { Detail, DetailList, DetailNote } from './DetailList'
import {
  COMPARATOR_KIND_LABELS,
  EVIDENCE_CHECK_FIELD_LABELS,
  EXTRACTION_METHOD_LABELS,
  MEASURE_LABELS,
  REPORTED_DIRECTION_LABELS,
  SOURCE_STATUS_LABELS,
  SOURCE_TYPE_LABELS,
  STUDY_DESIGN_LABELS,
  UNIT_LABELS,
  VALUE_AVAILABILITY_LABELS,
  VERIFICATION_OUTCOME_LABELS,
  VERIFICATION_SOURCE_ACCESS_LABELS,
  termText,
} from './vocabulary-labels'
import {
  readComparatorKind,
  readEffectMeasure,
  readEstimateUnit,
  readEvidenceCheckField,
  readExtractionMethod,
  readReportedDirection,
  readSourceStatus,
  readSourceType,
  readStudyDesign,
  readValueAvailability,
  readVerificationOutcome,
  readVerificationSourceAccess,
} from '../lib/evidence-item'
import { formatTimestampWithClock } from '../lib/norwegian-format'
import { uncoveredCheckFields } from '../lib/extraction-review'
import type {
  ExtractionReviewItem,
  ExtractionVerificationRecord,
  LinkedClaimRevision,
} from '../lib/extraction-review'
import type { VerificationItem } from '../agents/verification-input'

/** En verdi som ikke er registrert. Aldri en tom celle. */
function Absent({ children }: { readonly children: string }) {
  return <span className="review-absent">{children}</span>
}

function availabilityText(value: string): string {
  return termText(readValueAvailability(value), VALUE_AVAILABILITY_LABELS, 'tilgjengelighet')
}

function checkFieldText(value: string): string {
  return termText(readEvidenceCheckField(value), EVIDENCE_CHECK_FIELD_LABELS, 'kontrollfelt')
}

function whenText(raw: string): string {
  return formatTimestampWithClock(raw).text
}

/**
 * En verdi som bare finnes når kilden faktisk oppgir den.
 *
 * Mangler verdien, vises grunnen — aldri en tom streng og aldri en null. De fire
 * fraværsgrunnene er egenskaper ved forskjellige ting, og ingen av dem betyr
 * null (ANTIDEP_CONSTITUTION.md §6).
 */
function ValueOrReason({
  value,
  availability,
}: {
  readonly value: string | null
  readonly availability: string
}) {
  return value === null || value.length === 0 ? (
    <Absent>{availabilityText(availability)}</Absent>
  ) : (
    <>
      {value}
      <DetailNote>{availabilityText(availability)}</DetailNote>
    </>
  )
}

// ----------------------------------------------------------------------------
// Kilden og kildeversjonen
// ----------------------------------------------------------------------------

export function ExtractionSourcePanel({ item }: { readonly item: VerificationItem }) {
  return (
    <section className="review-panel">
      <h3>Kilden kontrollen skal skje mot</h3>
      <p className="review-panel__lead">
        En kontroll er en sammenligning mot kilden selv, ikke mot en beskrivelse av den. Hent kilden
        fram fra adressen under før du svarer.
      </p>
      <DetailList>
        <Detail label="Tittel">{item.sourceTitle}</Detail>
        <Detail label="Dokumenttype">
          {termText(readSourceType(item.sourceType), SOURCE_TYPE_LABELS, 'dokumenttype')}
          <DetailNote>{item.sourceAuthorsOrIssuer}</DetailNote>
        </Detail>
        <Detail label="Utgiver">
          {item.sourcePublisherOrJournal ?? <Absent>Ingen utgiver er registrert</Absent>}
          {item.sourcePublicationDate === null ? null : (
            <DetailNote>{`Publisert ${item.sourcePublicationDate}`}</DetailNote>
          )}
        </Detail>
        <Detail label="Kildestatus">
          {termText(readSourceStatus(item.sourceStatus), SOURCE_STATUS_LABELS, 'kildestatus')}
          {item.sourceStatusNote === null ? null : <DetailNote>{item.sourceStatusNote}</DetailNote>}
        </Detail>
        <Detail label="Hvor i kilden">{item.extraction.sourceLocator}</Detail>
        <Detail label="Kildeversjon">
          {item.sourceVersion === null ? (
            <Absent>
              Ingen registrert kildeversjon. Uten den kan kontrollen din ikke bygge på en
              etterprøvbar representasjon, og «Etterprøvbar representasjon» kan ikke velges
            </Absent>
          ) : (
            <>
              {item.sourceVersion.retrievedFrom}
              <DetailNote>
                {`Hentet ${whenText(item.sourceVersion.retrievedAt)}`}
                {item.sourceVersion.externalVersion === null
                  ? ''
                  : ` · ${item.sourceVersion.externalVersion}`}
              </DetailNote>
            </>
          )}
        </Detail>
        <Detail label="Fingeravtrykk av kildeversjonen">
          {item.sourceVersion === null || item.sourceVersion.contentHash === null ? (
            <Absent>
              Ikke registrert. Uten det er raden et sporet besøk, ikke en etterprøvbar
              representasjon
            </Absent>
          ) : (
            <>
              <code>{item.sourceVersion.contentHash}</code>
              <DetailNote>
                {item.sourceVersion.hasStorageReference
                  ? 'Antidep har en lagret kopi av representasjonen.'
                  : 'Antidep har ingen lagret kopi; adressen og fingeravtrykket er det som gjør den etterprøvbar.'}
              </DetailNote>
            </>
          )}
        </Detail>
        <Detail label="Registrert av">
          {item.createdByActorKey}
          <DetailNote>
            {termText(
              readExtractionMethod(item.extractionMethod),
              EXTRACTION_METHOD_LABELS,
              'ekstraksjonsmetode',
            )}
          </DetailNote>
        </Detail>
      </DetailList>
    </section>
  )
}

// ----------------------------------------------------------------------------
// Den strukturerte ekstraksjonen
// ----------------------------------------------------------------------------

export function ExtractionFieldsPanel({ item }: { readonly item: VerificationItem }) {
  const e = item.extraction
  return (
    <section className="review-panel">
      <h3>Ekstraksjonen, felt for felt</h3>
      <p className="review-panel__lead">
        Dette er hva Antidep påstår at kilden rapporterer. Kontrollen din gjelder hvert enkelt felt,
        og også begrunnelsen for de feltene som ikke har en verdi.
      </p>
      <DetailList>
        <Detail label="Studiedesign">
          {termText(readStudyDesign(e.designCode), STUDY_DESIGN_LABELS, 'studiedesign')}
        </Detail>
        <Detail label="Populasjon">
          <ValueOrReason value={e.populationLabel} availability={e.populationAvailability} />
          <DetailNote>{e.populationDetail}</DetailNote>
        </Detail>
        <Detail label="Antall deltakere">
          <ValueOrReason
            value={e.sampleSize === null ? null : String(e.sampleSize)}
            availability={e.sampleSizeAvailability}
          />
        </Detail>
        <Detail label="Behandlingsarm">
          {e.interventionDrugName}
          {e.interventionDetail === null ? null : <DetailNote>{e.interventionDetail}</DetailNote>}
        </Detail>
        <Detail label="Sammenligningsarm">
          {termText(readComparatorKind(e.comparatorKind), COMPARATOR_KIND_LABELS, 'komparatortype')}
          {e.comparatorDrugName === null ? null : <DetailNote>{e.comparatorDrugName}</DetailNote>}
          {e.comparatorDetail === null ? null : <DetailNote>{e.comparatorDetail}</DetailNote>}
        </Detail>
        <Detail label="Endepunkt">
          {e.outcomeLabel}
          <DetailNote>{e.outcomeDetail}</DetailNote>
        </Detail>
        <Detail label="Tidspunkt">
          <ValueOrReason
            value={
              e.timepointMin === null && e.timepointMax === null
                ? null
                : `${e.timepointMin ?? '–'} til ${e.timepointMax ?? '–'}`
            }
            availability={e.timepointAvailability}
          />
        </Detail>
        <Detail label="Retning kilden rapporterer">
          {termText(
            readReportedDirection(e.reportedDirection),
            REPORTED_DIRECTION_LABELS,
            'retning',
          )}
        </Detail>
        <Detail label="Effektmål">
          {e.effectMeasure === null ? (
            <Absent>Ingen effektmål er registrert</Absent>
          ) : (
            termText(readEffectMeasure(e.effectMeasure), MEASURE_LABELS, 'effektmål')
          )}
        </Detail>
        <Detail label="Estimat">
          <ValueOrReason
            value={
              e.estimate === null
                ? null
                : `${e.estimate}${
                    e.estimateUnit === null
                      ? ''
                      : ` ${termText(readEstimateUnit(e.estimateUnit), UNIT_LABELS, 'enhet')}`
                  }`
            }
            availability={e.estimateAvailability}
          />
        </Detail>
        <Detail label="Konfidensintervall">
          <ValueOrReason
            value={
              e.ciLower === null || e.ciUpper === null
                ? null
                : `${e.ciLower} til ${e.ciUpper}${
                    e.ciLevelPercent === null ? '' : ` (${e.ciLevelPercent} %)`
                  }`
            }
            availability={e.confidenceIntervalAvailability}
          />
        </Detail>
        <Detail label="Forbehold">
          {e.limitationsText ?? <Absent>Ingen forbehold er registrert</Absent>}
        </Detail>
      </DetailList>
    </section>
  )
}

// ----------------------------------------------------------------------------
// Den rå ekstraksjonen
// ----------------------------------------------------------------------------

/**
 * Den rå ekstraksjonen, slik den er lagret.
 *
 * Formen er bevisst ikke fastlagt: `knowledge.evidence_items.raw_extraction` er
 * jsonb nettopp fordi variasjonen mellom kildetyper er reell. Et objekt vises
 * derfor som nøkler og verdier, alt annet ordrett. Ingenting forkortes: det er
 * disse utdragene kontrollen faktisk sammenlignes mot.
 */
export function RawExtractionPanel({ raw }: { readonly raw: unknown }) {
  const isPlainObject = typeof raw === 'object' && raw !== null && !Array.isArray(raw)
  return (
    <section className="review-panel">
      <h3>Rå ekstraksjon</h3>
      <p className="review-panel__lead">
        Kildens egne formuleringer, bevart ordrett. Det er disse utdragene kontrollen din
        sammenligner med kilden.
      </p>
      {raw === null || raw === undefined ? (
        <p className="review-absent">
          Ingen rå ekstraksjon er lagret på dette funnet. Det er ikke det samme som at kilden ikke
          sier noe — det betyr at ingen utdrag er bevart, og at kontrollen din må skje mot kilden
          alene.
        </p>
      ) : isPlainObject ? (
        <DetailList>
          {Object.entries(raw as Record<string, unknown>).map(([key, value]) => (
            <Detail key={key} label={key}>
              {typeof value === 'string' ? value : JSON.stringify(value)}
            </Detail>
          ))}
        </DetailList>
      ) : (
        <pre className="raw-extraction">{JSON.stringify(raw, null, 2)}</pre>
      )}
    </section>
  )
}

// ----------------------------------------------------------------------------
// Feltdekningen
// ----------------------------------------------------------------------------

/**
 * Hva som må være kontrollert, og hva som per nå teller som kontrollert.
 *
 * Begge listene kommer fra publiseringsgatens egne funksjoner. Panelet regner
 * ingenting ut på nytt; det trekker den ene fra den andre og sier hva som står
 * igjen.
 */
export function CheckFieldCoveragePanel({ item }: { readonly item: ExtractionReviewItem }) {
  const outstanding = uncoveredCheckFields(item)
  return (
    <section className="review-panel">
      <h3>Feltdekning</h3>
      <p className="review-panel__lead">
        Publiseringsgaten krever at de registrerte kontrollene til sammen dekker hvert felt funnet
        påstår noe om. En delkontroll er ikke nok, og en kontroll som ikke bekrefter, nullstiller
        dekningen — bekreftelser som ligger foran den, teller ikke lenger.
      </p>
      <DetailList>
        <Detail label="Må være kontrollert">
          <ul className="coverage-list">
            {item.requiredCheckFields.map((field) => (
              <li key={field}>{checkFieldText(field)}</li>
            ))}
          </ul>
        </Detail>
        <Detail label="Teller som kontrollert nå">
          {item.coveredCheckFields.length === 0 ? (
            <Absent>Ingen felter teller som kontrollert</Absent>
          ) : (
            <ul className="coverage-list">
              {item.coveredCheckFields.map((field) => (
                <li key={field}>{checkFieldText(field)}</li>
              ))}
            </ul>
          )}
        </Detail>
        <Detail label="Står igjen">
          {outstanding.length === 0 ? (
            'Ingenting. Dekningen er komplett slik kontrollene står nå.'
          ) : (
            <ul className="coverage-list">
              {outstanding.map((field) => (
                <li key={field}>{checkFieldText(field)}</li>
              ))}
            </ul>
          )}
        </Detail>
      </DetailList>
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
  readonly record: ExtractionVerificationRecord
  readonly isCurrent: boolean
}) {
  return (
    <article className="review-record">
      <h4>
        {`${termText(
          readVerificationOutcome(record.outcome),
          VERIFICATION_OUTCOME_LABELS,
          'utfall',
        )} — ${record.verifierDisplayName}`}
        {isCurrent ? <span className="review-record__current"> (gjeldende)</span> : null}
      </h4>
      <p className="review-record__meta">
        {`${record.verifierActorType === 'agent' ? 'Maskinell kontroll' : 'Menneskelig kontroll'} · ${
          record.verifierActorKey
        } · ${whenText(record.verifiedAt)} · kildetilgang: ${termText(
          readVerificationSourceAccess(record.sourceAccess),
          VERIFICATION_SOURCE_ACCESS_LABELS,
          'kildetilgang',
        )}`}
      </p>
      <ul className="review-record__citations">
        {record.checkedFields.map((field) => (
          <li key={field}>{checkFieldText(field)}</li>
        ))}
      </ul>
      <p className="review-record__rationale">{record.rationale}</p>
      {record.findings === null ? null : (
        <p className="review-record__findings">{`Funn: ${record.findings}`}</p>
      )}
    </article>
  )
}

export function ExtractionVerificationHistoryPanel({
  records,
  currentId,
}: {
  readonly records: readonly ExtractionVerificationRecord[]
  readonly currentId: string | null
}) {
  return (
    <section className="review-panel">
      <h3>Registrerte kontroller av denne ekstraksjonen</h3>
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
              key={record.evidenceVerificationId}
              isCurrent={record.evidenceVerificationId === currentId}
              record={record}
            />
          ))}
        </>
      )}
    </section>
  )
}

// ----------------------------------------------------------------------------
// Påstandene funnet allerede bærer
// ----------------------------------------------------------------------------

export function LinkedClaimsPanel({
  revisions,
  hrefFor,
}: {
  readonly revisions: readonly LinkedClaimRevision[]
  readonly hrefFor: (revision: LinkedClaimRevision) => string
}) {
  return (
    <section className="review-panel">
      <h3>Påstander dette funnet er koblet til</h3>
      {revisions.length === 0 ? (
        <p className="review-absent">
          Ingen påstandsrevisjon er koblet til dette funnet ennå. Kontrollen din er like fullt
          nødvendig: publiseringsgaten krever den for hvert funn en påstand hviler på.
        </p>
      ) : (
        <ul className="review-unlinked">
          {revisions.map((revision) => (
            <li key={revision.claimRevisionId}>
              <a href={hrefFor(revision)}>{revision.statement}</a>
              {` — ${revision.subjectDrugName}, ${revision.topicLabel}, revisjon ${String(
                revision.revisionNumber,
              )}`}
              {revision.isPublishedRevision ? ' · Publisert' : ''}
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}
