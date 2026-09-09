// ============================================================================
// Kontrolløkten: fra delsvar til de utfallene databasen skal ha
//
// Den menneskelige kontrollen er delt i mange små spørsmål med tre svar hver:
// stemmer det, stemmer det ikke, eller lar det seg ikke avgjøre. Databasen skal
// fortsatt ha nøyaktig de radene den alltid har hatt — én
// `workflow.evidence_verifications`-rad med sitt samlede utfall, én
// `workflow.claim_verifications`-rad med sine sju kontrollpunkter.
//
// Denne modulen er broen mellom de to, og den er ren: den tar delsvarene og
// regner ut utfallet. Ingen nettverkskall, ingen React, ingen skjønn.
//
// ----------------------------------------------------------------------------
// Hvorfor utfallet utledes framfor å velges
//
// Et samlet utfall er ikke en selvstendig vurdering. Det *følger* av
// delkontrollene: en kontroll der alt stemte, er bekreftet; en der noe var galt,
// må rettes; en der noe ikke lot seg avgjøre, er uavklart. Å be kontrolløren om
// å velge det til slutt er å be om den samme vurderingen en gang til — og å
// åpne for at valget og delsvarene sier forskjellige ting.
//
// Reglene her er de samme som databasens egne, uttrykt framover framfor som en
// avvisning:
//
//   * `evidence_verifications_source_access_check` og
//     `claim_verifications_source_access_check` forbyr `verified` på et avledet
//     sammendrag alene. Derfor er «bare et sammendrag» aldri nok til å bekrefte.
//   * `claim_verifications_verified_requires_all_ok_check` krever at alle sju
//     punktene er `ok`. Derfor kan ett ubedømt punkt ikke gi `verified`.
//   * `*_findings_required_check` krever et funn når utfallet ikke er
//     `verified`. Derfor bygges funnteksten alltid når utfallet ikke er det.
//
// Databasen er fortsatt fasiten. Dette er ikke en kopi av gaten, men den samme
// slutningen tatt før den, slik at kontrolløren aldri sender noe som må avvises.
//
// ----------------------------------------------------------------------------
// `rejected` er ikke et utfall denne modulen kan gi
//
// Vokabularet har fire verdier. `rejected` betyr at objektet ikke holder i det
// hele tatt, og det er en annen og sterkere konklusjon enn «noe må rettes» — den
// hører til en beslutning om innholdet, ikke til en sum av delkontroller. Å la
// et visst antall avvik tippe over i `rejected` ville vært en terskel ingen har
// bestemt. Avvisning uttrykkes der den hører hjemme: i publiseringsbeslutningen.
//
// ----------------------------------------------------------------------------
// Foreldet grunnlag rammer det steget som faktisk endret seg
//
// `retainAnswers` sammenligner avtrykket av det hvert steg viste, før og etter
// en ny henting, og beholder svarene på stegene som er uendret. Det er en
// bekvemmelighet i flaten og ikke en garanti: garantien er
// `workflow.assert_extraction_unchanged(uuid, text)` og
// `workflow.assert_evidence_set_unchanged(uuid, text)`, som avviser
// registreringen om noe som helst i grunnlaget er endret. Denne funksjonen
// avgjør bare hvor mye arbeid kontrolløren må gjøre om igjen etterpå.
// ============================================================================

import {
  CLAIM_CHECKPOINTS,
  EVIDENCE_CHECK_FIELD_LABELS,
  VERIFICATION_SOURCE_ACCESS_LABELS,
  termText,
  type ClaimCheckpointKey,
} from '../components/vocabulary-labels'
import { readEvidenceCheckField } from './evidence-item'

/** De tre svarene et delspørsmål kan få. */
export type ControlAnswer = 'yes' | 'no' | 'cannot_determine'

/** Ett valg i et svarsett, slik svarknappene tar imot det. */
export interface ControlChoiceOption {
  readonly value: string
  readonly label: string
}

/**
 * De tre svarene på en delkontroll, i den rekkefølgen de skal leses.
 *
 * «Kan ikke avgjøre» står sist og er alltid med. Uten den ville en kontrollør
 * som ikke fant grunnlaget, måttet velge mellom å bekrefte noe hen ikke så, og å
 * melde et avvik som ikke er observert (ANTIDEP_CONSTITUTION.md §6).
 */
export const CONTROL_ANSWER_OPTIONS: readonly ControlChoiceOption[] = [
  { value: 'yes', label: 'Ja' },
  { value: 'no', label: 'Nei' },
  { value: 'cannot_determine', label: 'Kan ikke avgjøre' },
]

/** Ett besvart delspørsmål. `note` er avviksteksten, tom når ingen er skrevet. */
export interface AnsweredCheck {
  readonly answer: ControlAnswer
  readonly note: string
}

/** Utfallene en utledning kan ende i. Se hodekommentaren for hvorfor ikke `rejected`. */
export type DerivedOutcome = 'verified' | 'needs_correction' | 'uncertain'

/** Det databasen skal ha, utledet av delsvarene. */
export interface DerivedVerification {
  readonly outcome: DerivedOutcome
  /** Feltene kontrollen faktisk gikk gjennom. Tom bare når ingenting er besvart. */
  readonly checkedFields: readonly string[]
  /** Deterministisk oppsummering av metoden. Aldri skrevet av kontrolløren. */
  readonly rationale: string
  /** Avvikene og det uavklarte. `null` bare når utfallet er `verified`. */
  readonly findings: string | null
}

/** Antall delsvar av hver art. Brukes i oppsummeringen kontrolløren ser. */
export interface ControlTally {
  readonly total: number
  readonly answered: number
  readonly confirmed: number
  readonly deviations: number
  readonly unresolved: number
}

// `workflow.evidence_verifications.rationale` og `.findings` er begge
// `between 1 and 4000`. Teksten her er kort, men et funn med mange avvik og
// lange notater kan i prinsippet vokse forbi grensen, og en avkorting er bedre
// enn en avvisning kontrolløren ikke kan gjøre noe med.
const DATABASE_TEXT_LIMIT = 4000

function withinDatabaseLimit(text: string): string {
  return text.length <= DATABASE_TEXT_LIMIT ? text : `${text.slice(0, DATABASE_TEXT_LIMIT - 1)}…`
}

function fieldLabel(field: string): string {
  return termText(readEvidenceCheckField(field), EVIDENCE_CHECK_FIELD_LABELS, 'kontrollfelt')
}

function accessLabel(access: string): string {
  return access in VERIFICATION_SOURCE_ACCESS_LABELS
    ? VERIFICATION_SOURCE_ACCESS_LABELS[access as keyof typeof VERIFICATION_SOURCE_ACCESS_LABELS]
    : `ukjent kildetilgang («${access}»)`
}

/**
 * Om kildetilgangen i det hele tatt kan bære en bekreftelse.
 *
 * `derived_summary` kan det ikke, og det er ikke en flateregel:
 * ANTIDEP_CONSTITUTION.md §11 forbyr å godkjenne på et annet ledds sammendrag,
 * og begge verifikasjonstabellene håndhever forbudet med en CHECK.
 */
export function sourceAccessCanConfirm(access: string): boolean {
  return access !== 'derived_summary'
}

/** Fra sterkest til svakest, slik `workflow.source_access_strength(...)` rangerer dem. */
const ACCESS_STRENGTH: Readonly<Record<string, number>> = {
  original_source: 3,
  verifiable_representation: 2,
  derived_summary: 1,
}

/**
 * Den svakeste av flere kildetilganger.
 *
 * En samlet kontroll er aldri sterkere enn sitt svakeste ledd, og databasen
 * utleder den samme verdien selv for claim-kontrollen. Utledningen her finnes
 * for at flaten skal kunne si på forhånd hva som blir resultatet — ikke for å
 * avgjøre det.
 */
export function weakestSourceAccess(accesses: readonly string[]): string | null {
  let weakest: string | null = null
  for (const access of accesses) {
    if (weakest === null) {
      weakest = access
      continue
    }
    // En ukjent verdi regnes som svakest: den kan ikke dokumenteres som sterkere
    // enn den svakeste kjente.
    const current = ACCESS_STRENGTH[access] ?? 0
    const best = ACCESS_STRENGTH[weakest] ?? 0
    if (current < best) {
      weakest = access
    }
  }
  return weakest
}

function tally(
  keys: readonly string[],
  answers: Readonly<Record<string, AnsweredCheck>>,
): ControlTally {
  let confirmed = 0
  let deviations = 0
  let unresolved = 0
  let answered = 0
  for (const key of keys) {
    const entry = answers[key]
    if (entry === undefined) {
      continue
    }
    answered += 1
    if (entry.answer === 'yes') {
      confirmed += 1
    } else if (entry.answer === 'no') {
      deviations += 1
    } else {
      unresolved += 1
    }
  }
  return { total: keys.length, answered, confirmed, deviations, unresolved }
}

/** Antallene for én ekstraksjonskontroll, over de feltene kontrolløren får spørsmål om. */
export function extractionTally(
  semanticFields: readonly string[],
  answers: Readonly<Record<string, AnsweredCheck>>,
): ControlTally {
  return tally(semanticFields, answers)
}

function outcomeFrom(counts: ControlTally, accessCanConfirm: boolean): DerivedOutcome {
  if (counts.deviations > 0) {
    return 'needs_correction'
  }
  if (counts.answered < counts.total || counts.unresolved > 0 || !accessCanConfirm) {
    return 'uncertain'
  }
  return 'verified'
}

function findingSentences(
  keys: readonly string[],
  answers: Readonly<Record<string, AnsweredCheck>>,
  label: (key: string) => string,
): readonly string[] {
  const sentences: string[] = []
  for (const key of keys) {
    const entry = answers[key]
    if (entry === undefined) {
      sentences.push(`${label(key)}: ikke besvart i kontrolløkten.`)
      continue
    }
    const note = entry.note.trim()
    if (entry.answer === 'no') {
      sentences.push(
        note.length === 0
          ? `${label(key)}: kontrolløren fant et avvik uten å beskrive det nærmere.`
          : `${label(key)}: ${note}`,
      )
    } else if (entry.answer === 'cannot_determine') {
      sentences.push(
        note.length === 0
          ? `${label(key)}: lot seg ikke avgjøre mot kilden.`
          : `${label(key)}: lot seg ikke avgjøre mot kilden. ${note}`,
      )
    }
  }
  return sentences
}

const SUMMARY_ACCESS_CAVEAT =
  'Kontrolløren hadde bare et sammendrag fra et annet ledd, og en bekreftelse kan ikke hvile på det alene.'

function joinFindings(sentences: readonly string[]): string | null {
  return sentences.length === 0 ? null : withinDatabaseLimit(sentences.join(' '))
}

/**
 * Ekstraksjonskontrollen, utledet av delsvarene.
 *
 * ----------------------------------------------------------------------------
 * `checkedFields` er nøyaktig det mennesket bekreftet — aldri mer
 *
 * Raden er et auditobjekt for én operasjon, og den skal aldri påstå større
 * dekning enn operasjonen faktisk hadde (DATABASE_ARCHITECTURE.md §29). Derfor
 * står bare de semantiske feltene kontrolløren svarte «ja» på: ikke feltene hen
 * ikke kunne avgjøre, og ikke de to provenansfeltene økten aldri stilte
 * spørsmål om.
 *
 * `raw_extraction` og `source_locator` dekkes av maskinens egen rad. Den
 * deterministiske kontrollen fører opp `source_locator` når representasjonen
 * lot seg reprodusere, forankringen er komplett og hvert forankret utdrag ble
 * gjenfunnet ordrett — og `raw_extraction` når radens rå gjengivelse ble
 * gjenfunnet. Publiseringsgatens G5b leser unionen over funnets kontroller
 * (`workflow.covered_check_fields`, migrasjon 005y), så de to leddene dekker
 * til sammen det raden påstår, uten at noen av dem overdriver.
 *
 * At maskinen faktisk har gjort sin del, er ikke et håp: fra migrasjon 005x
 * avviser databasen en menneskelig bekreftelse uten et maskinbevis som gjelder
 * nøyaktig dette grunnlaget, og kontrolløkten stopper før feltskuffene når
 * beviset mangler.
 */
export function deriveExtractionVerification(input: {
  /** Publiseringsgatens krav: `workflow.required_check_fields(uuid)`. */
  readonly requiredFields: readonly string[]
  /** Feltene kontrolløren faktisk får spørsmål om: `workflow.semantic_check_fields(uuid)`. */
  readonly semanticFields: readonly string[]
  readonly sourceAccess: string
  readonly answers: Readonly<Record<string, AnsweredCheck>>
}): DerivedVerification {
  const counts = extractionTally(input.semanticFields, input.answers)
  const accessCanConfirm = sourceAccessCanConfirm(input.sourceAccess)
  const outcome = outcomeFrom(counts, accessCanConfirm)

  // Begrunnelsen er audittekst, og skal si hvem som kontrollerte hva. Uten den
  // siste setningen ville en leser trodd at mennesket også hadde prøvd
  // utdragene ordrett mot kilden.
  const rationale = withinDatabaseLimit(
    'Kontrollert felt for felt mot kilden i en guidet kontrolløkt. ' +
      `Kildetilgang: ${accessLabel(input.sourceAccess).toLowerCase()}. ` +
      `${String(counts.answered)} av ${String(counts.total)} delkontroller besvart: ` +
      `${String(counts.confirmed)} bekreftet, ${String(counts.deviations)} avvik, ` +
      `${String(counts.unresolved)} kunne ikke avgjøres.` +
      ' Kontrolløren bedømte de semantiske feltene mot hvert felts eget kildeutdrag. ' +
      'At utdragene står ordrett i den registrerte kildeversjonen, er bevist av den ' +
      'deterministiske ekstraksjonskontrollen, som er et eget kontrollobjekt med sin egen ' +
      'dekning.',
  )

  // Bare det som faktisk ble bekreftet. Et felt kontrolløren ikke kunne
  // avgjøre, er ikke kontrollert, og et provenansfelt hen aldri ble spurt om,
  // er det heller ikke.
  const confirmedFields = input.semanticFields.filter(
    (field) => input.answers[field]?.answer === 'yes',
  )

  if (outcome === 'verified') {
    return {
      outcome,
      checkedFields: confirmedFields,
      rationale,
      findings: null,
    }
  }

  const sentences = [...findingSentences(input.semanticFields, input.answers, fieldLabel)]
  if (!accessCanConfirm) {
    sentences.push(SUMMARY_ACCESS_CAVEAT)
  }

  return {
    outcome,
    checkedFields: confirmedFields,
    rationale,
    // Utfallet er ikke `verified`, så databasen krever et funn. Er ingen
    // delkontroll åpen, er det kildetilgangen som er grunnen, og setningen over
    // er da den eneste — men aldri null.
    findings: joinFindings(sentences),
  }
}

// ----------------------------------------------------------------------------
// Øktens tilstand for ett evidensfunn
// ----------------------------------------------------------------------------

/**
 * Kontrollørens svar for ett evidensfunn, slik økten holder dem.
 *
 * Ligger her og ikke i visningen, fordi beskjæringen ved en ny henting
 * (`pruneExtractionSession`) er logikk som skal kunne prøves uten en nettleser.
 */
export interface ExtractionSessionState {
  /** «Har du tilgang til fullteksten?». `null` = ikke besvart. */
  readonly fullText: ControlAnswer | null
  /** Verdien fra `workflow.verification_source_access`. `null` = ikke avgjort. */
  readonly sourceAccess: string | null
  readonly fields: Readonly<Record<string, AnsweredCheck>>
  /** Id-en kontrollen fikk da den ble registrert. `null` = ikke registrert ennå. */
  readonly savedVerificationId: string | null
  readonly saving: boolean
  /** Databasens egen avvisning, ordrett. `null` = ingen. */
  readonly problem: string | null
}

export function emptyExtractionSessionState(): ExtractionSessionState {
  return {
    fullText: null,
    sourceAccess: null,
    fields: {},
    savedVerificationId: null,
    saving: false,
    problem: null,
  }
}

/**
 * Beholder de svarene som fortsatt gjelder etter en ny henting av grunnlaget.
 *
 * Et felt hvis forankring er uendret, viser det samme, og svaret på det står.
 * Er kildeversjonen byttet eller kildens status endret, er kildetilgangen et
 * annet spørsmål, og den delen må gjøres om igjen — men bare den.
 */
export function pruneExtractionSession(input: {
  readonly state: ExtractionSessionState
  readonly semanticFields: readonly string[]
  readonly sourceAccessStepId: string
  readonly fieldStepIdFor: (field: string) => string
  readonly previousBasis: Readonly<Record<string, string>>
  readonly nextBasis: Readonly<Record<string, string>>
}): ExtractionSessionState {
  const accessBefore = input.previousBasis[input.sourceAccessStepId]
  const accessAfter = input.nextBasis[input.sourceAccessStepId]
  const accessHolds =
    accessBefore !== undefined && accessAfter !== undefined && accessBefore === accessAfter

  const fields: Record<string, AnsweredCheck> = {}
  for (const field of input.semanticFields) {
    const entry = input.state.fields[field]
    if (entry === undefined) {
      continue
    }
    const stepId = input.fieldStepIdFor(field)
    const before = input.previousBasis[stepId]
    const after = input.nextBasis[stepId]
    if (before !== undefined && after !== undefined && before === after) {
      fields[field] = entry
    }
  }

  return {
    fullText: accessHolds ? input.state.fullText : null,
    sourceAccess: accessHolds ? input.state.sourceAccess : null,
    fields,
    savedVerificationId: input.state.savedVerificationId,
    saving: false,
    problem: input.state.problem,
  }
}

// ----------------------------------------------------------------------------
// Claim-kontrollen
// ----------------------------------------------------------------------------

/** De sju kontrollpunktene, som nøkler. */
export const CLAIM_CHECKPOINT_KEYS: readonly ClaimCheckpointKey[] = CLAIM_CHECKPOINTS.map(
  (checkpoint) => checkpoint.key,
)

const CHECKPOINT_LABELS: Readonly<Record<string, string>> = Object.fromEntries(
  CLAIM_CHECKPOINTS.map((checkpoint) => [checkpoint.key, checkpoint.label]),
)

/** Én evidenslenke, slik kontrolløkten har besvart den. */
export interface AnsweredLink {
  readonly claimEvidenceLinkId: string
  /** Kildetittelen, slik funnteksten kan navngi lenken uten en id. */
  readonly sourceTitle: string
  readonly sourceAccess: string
  readonly answer: ControlAnswer
  readonly note: string
}

/** Svaret på ett delspørsmål, oversatt til `workflow.verification_check_result`. */
export function checkResultFor(answer: ControlAnswer | undefined): string {
  switch (answer) {
    case 'yes':
      return 'ok'
    case 'no':
      return 'deviation'
    default:
      // Ubesvart og «kan ikke avgjøre» er den samme registrerte tilstanden: et
      // punkt som ikke er bedømt. Det er ikke det samme som `ok`
      // (ANTIDEP_CONSTITUTION.md §6).
      return 'not_assessable'
  }
}

/** Antallene for én claim-kontroll, de sju punktene og lenkene sett under ett. */
export function claimTally(
  checkpoints: Readonly<Record<string, AnsweredCheck>>,
  links: readonly AnsweredLink[],
): ControlTally {
  const checkpointCounts = tally(CLAIM_CHECKPOINT_KEYS, checkpoints)
  const linkAnswers: Record<string, AnsweredCheck> = {}
  for (const link of links) {
    linkAnswers[link.claimEvidenceLinkId] = { answer: link.answer, note: link.note }
  }
  const linkCounts = tally(
    links.map((link) => link.claimEvidenceLinkId),
    linkAnswers,
  )
  return {
    total: checkpointCounts.total + linkCounts.total,
    answered: checkpointCounts.answered + linkCounts.answered,
    confirmed: checkpointCounts.confirmed + linkCounts.confirmed,
    deviations: checkpointCounts.deviations + linkCounts.deviations,
    unresolved: checkpointCounts.unresolved + linkCounts.unresolved,
  }
}

/**
 * Claim-kontrollen, utledet av de sju punktene og lenkene.
 *
 * `checkedFields` er tom: en claim-kontroll registrerer ikke feltdekning, den
 * registrerer sju kontrollpunkter og én rad per evidenslenke.
 */
export function deriveClaimVerification(input: {
  readonly checkpoints: Readonly<Record<string, AnsweredCheck>>
  readonly links: readonly AnsweredLink[]
}): DerivedVerification {
  const counts = claimTally(input.checkpoints, input.links)
  const weakest = weakestSourceAccess(input.links.map((link) => link.sourceAccess))
  const accessCanConfirm = weakest !== null && sourceAccessCanConfirm(weakest)
  const outcome = outcomeFrom(counts, accessCanConfirm)

  const rationale = withinDatabaseLimit(
    'Kontrollert punkt for punkt mot det registrerte evidensgrunnlaget i en guidet kontrolløkt. ' +
      `Kildetilgang: ${weakest === null ? 'ingen evidenslenker å kontrollere' : accessLabel(weakest).toLowerCase()}. ` +
      `${String(counts.answered)} av ${String(counts.total)} delkontroller besvart: ` +
      `${String(counts.confirmed)} bekreftet, ${String(counts.deviations)} avvik, ` +
      `${String(counts.unresolved)} kunne ikke avgjøres.`,
  )

  if (outcome === 'verified') {
    return { outcome, checkedFields: [], rationale, findings: null }
  }

  const linkAnswers: Record<string, AnsweredCheck> = {}
  const linkLabels: Record<string, string> = {}
  for (const link of input.links) {
    linkAnswers[link.claimEvidenceLinkId] = { answer: link.answer, note: link.note }
    linkLabels[link.claimEvidenceLinkId] = `Evidenslenken «${link.sourceTitle}»`
  }

  const sentences = [
    ...findingSentences(
      CLAIM_CHECKPOINT_KEYS,
      input.checkpoints,
      (key) => CHECKPOINT_LABELS[key] ?? key,
    ),
    ...findingSentences(
      input.links.map((link) => link.claimEvidenceLinkId),
      linkAnswers,
      (key) => linkLabels[key] ?? 'Evidenslenken',
    ),
  ]
  if (!accessCanConfirm && weakest !== null) {
    sentences.push(SUMMARY_ACCESS_CAVEAT)
  }
  if (weakest === null) {
    sentences.push('Kontrollen har ingen evidenslenker å bygge på.')
  }

  return { outcome, checkedFields: [], rationale, findings: joinFindings(sentences) }
}

// ----------------------------------------------------------------------------
// Foreldet grunnlag
// ----------------------------------------------------------------------------

/** Hva som ble beholdt og hva som må gjøres om igjen etter en ny henting. */
export interface RetainedAnswers<Answer> {
  readonly kept: Record<string, Answer>
  /** Stegene som må besvares på nytt, fordi grunnlaget deres er endret. */
  readonly dropped: readonly string[]
}

/**
 * Beholder svarene på de stegene som viser nøyaktig det samme som før.
 *
 * Et steg hvis avtrykk er uendret, viser det samme grunnlaget, og svaret på det
 * gjelder fortsatt. Et steg som er borte, eller som viser noe annet, må
 * besvares på nytt — og bare det.
 */
export function retainAnswers<Answer>(
  answers: Readonly<Record<string, Answer>>,
  previousBasis: Readonly<Record<string, string>>,
  nextBasis: Readonly<Record<string, string>>,
  /**
   * Fra svarets egen nøkkel til stegets id.
   *
   * Svarene er nøklet på det de handler om — kontrollpunktets navn, lenkens id —
   * mens avtrykket er nøklet på steget. Uten oversettelsen ville hvert oppslag
   * bomme, og *alle* svar blitt kastet ved hver eneste nye henting.
   */
  stepIdFor: (answerKey: string) => string = (answerKey) => answerKey,
): RetainedAnswers<Answer> {
  const kept: Record<string, Answer> = {}
  const dropped: string[] = []
  for (const [answerKey, answer] of Object.entries(answers)) {
    const stepId = stepIdFor(answerKey)
    const before = previousBasis[stepId]
    const after = nextBasis[stepId]
    if (before !== undefined && after !== undefined && before === after) {
      kept[answerKey] = answer
    } else {
      dropped.push(answerKey)
    }
  }
  return { kept, dropped }
}
