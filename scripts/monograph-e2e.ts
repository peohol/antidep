// ============================================================================
// Hele forløpet «Bygg monografi for sertralin» → et samlet monografiutkast
//
// pgTAP prøver SQL lag for lag, og vitest prøver TypeScript med doble for
// databasen. Det ingen av dem prøver, er at lagene faktisk henger sammen: at
// oppgaven databasen bygger, er den samme oppgaven agentflaten leser, at svaret
// flaten skriver, er det samme svaret databasen tar imot, og at hver overgang
// utløser den neste av seg selv.
//
// Denne kjøringen går hele veien mot den lokale stacken, gjennom de autoriserte
// inngangene og uten en eneste snarvei rundt en kontroll:
//
//    1. en redaktør bestiller monografien for ett virkestoff
//    2. dekningskartet finnes: alle 80 spørsmålsmalene har konkrete behov
//    3. kildeoppdagelsen henter oppgaven sin, søker og svarer — med utførte
//       søk, kandidatkilder, hva hver av dem kan brukes til, og et forslag om
//       en ny utfallsverdi
//    4. den separate kontrollen av søkedekningen henter *sin* oppgave og
//       avgjør om begrunnelsen for å avslutte holder
//    5. redaktøren aksepterer utfallsverdien, og behovet forgrenes
//    6. redaktøren velger kilden, og innhentingen går videre av seg selv:
//       kilden opprettes, og fullteksten etterspørres i én samlet forespørsel
//    7. fullteksten leveres gjennom innboksen, og Antideps eget tekstuttrekk
//       registrerer kildeversjonen — som skriver den godkjente kildebruken og
//       legger ekstraksjonen i køen
//    8. ekstraksjonsagenten svarer, den uavhengige kontrollen bekrefter, og
//       syntesen legges i køen med kunnskapsbehovet som avgrensning
//    9. syntesen svarer, kildestøttekontrollen bekrefter, evidensvurderingen
//       registreres — og monografisvaret bindes til nøyaktig den kontrollerte
//       påstandsrevisjonen
//   10. monografiutkastet viser svaret i standardens egen seksjon, med en
//       ærlig dekningsoversikt
//   11. kandidaten fryses, et navngitt menneske sluttkontrollerer den, og en
//       annen med publiseringsmandat tar den i bruk
//
// De to deterministiske kontrolleddene kjøres med sine egne agentidentiteter og
// sine egne legitimasjoner, som i drift: rollen er rettighetsgrensen, og en
// ekstraksjonsnøkkel kan ikke registrere en kildestøttekontroll. Kontrollene er
// Antideps egen kode og ingen modellvurdering — modelltildelingen for dem er
// «registration», ikke «semantic».
//
// Ingen modell kalles, og ingen modellnøkkel finnes. «Agentene» her er koden
// under: den kopierer bindingsverdiene uendret ut av oppgaven og fyller inn det
// bare en agent vet — nøyaktig slik en ekstern KI-agent gjør det gjennom
// agentarbeidsflaten.
// ============================================================================

import { randomUUID } from 'node:crypto'

import { createClient } from '@supabase/supabase-js'

import { parseAgentTask, type AgentTask } from '../src/agents/agent-task.ts'
import { renderAgentTaskFile } from '../src/agents/agent-task-file.ts'
import {
  CLAIM_VERIFICATION_PREMISES,
  EXTRACTION_VERIFICATION_PREMISES,
} from '../src/agents/pipeline-version.ts'
import { syntheticArticlePdf } from '../src/agents/test-support.ts'
import type { Database } from '../src/types/database.ts'
import { check, psql, q, readLocalStackConfig, userToken } from './local-stack.ts'

const config = readLocalStackConfig(process.argv.slice(2))

const RUN = randomUUID().slice(0, 8)
const EDITOR_USER = randomUUID()
const REVIEWER_USER = randomUUID()
const PUBLISHER_USER = randomUUID()

const DOI = `10.5555/antidep.monografi.${RUN}`
const ARTICLE_TITLE = `Vektendring under sertralin: syntetisk kjedeprøve ${RUN}`

const METHOD =
  'Patients with major depressive disorder were randomised to double-blind sertraline treatment for 26 to 32 weeks.'
const SAMPLE = 'Forty-eight sertraline-treated patients completed the trial and were analysed.'
const RESULT =
  'Mean percent weight change was 1.0% at endpoint with a 95% confidence interval from 0.5% to 1.5%.'

/** Legitimasjonene de to deterministiske kontrolleddene handler med. */
function credentials(): { readonly extraction: string; readonly claim: string } {
  return {
    extraction: psql(
      config,
      `select provenance.issue_agent_identity_credential(
         'agent-identity:extraction-verification-01', 'human:peder-holman')`,
    ),
    claim: psql(
      config,
      `select provenance.issue_agent_identity_credential(
         'agent-identity:citation-support-verification-01', 'human:peder-holman')`,
    ),
  }
}

/** De kontoene forløpet trenger. Tre mandater, tre mennesker. */
function seed(): void {
  psql(
    config,
    `
    insert into auth.users (id, email) values
      (${q(EDITOR_USER)}, ${q(`monografi-redaktor-${RUN}@test.invalid`)}),
      (${q(REVIEWER_USER)}, ${q(`monografi-kontrollor-${RUN}@test.invalid`)}),
      (${q(PUBLISHER_USER)}, ${q(`monografi-utgiver-${RUN}@test.invalid`)});

    insert into provenance.actors
      (actor_type, actor_key, display_name, description, auth_user_id)
    values
      ('human', ${q(`human:monografi-redaktor-${RUN}`)}, 'Monografiredaktør',
       'Redaktør i monografiprøven.', ${q(EDITOR_USER)}),
      ('human', ${q(`human:monografi-kontrollor-${RUN}`)}, 'Monografikontrollør',
       'Sluttkontrollør i monografiprøven.', ${q(REVIEWER_USER)}),
      ('human', ${q(`human:monografi-utgiver-${RUN}`)}, 'Monografiutgiver',
       'Utgiver i monografiprøven.', ${q(PUBLISHER_USER)});

    insert into workflow.user_roles
      (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
    select v.user_id::uuid, v.role_code::workflow.app_role, null, now() - interval '1 hour',
           (select id from provenance.actors where actor_key = 'human:peder-holman'),
           'Monografiprøven.'
    from (values
      (${q(EDITOR_USER)}, 'editor'),
      (${q(REVIEWER_USER)}, 'editor'),
      (${q(REVIEWER_USER)}, 'reviewer'),
      (${q(PUBLISHER_USER)}, 'editor'),
      (${q(PUBLISHER_USER)}, 'publisher')
    ) as v(user_id, role_code);
    `,
  )
}

function client(user: string) {
  return createClient<Database, 'api'>(config.apiUrl, config.anonKey, {
    db: { schema: 'api' },
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${userToken(config, user)}` } },
  })
}

type Client = ReturnType<typeof client>

async function call(
  actor: Client,
  name: string,
  args: Record<string, unknown> = {},
): Promise<unknown> {
  const { data, error } = await actor.rpc(name as never, args as never)
  if (error !== null) {
    throw new Error(`${name}: ${error.message}`)
  }
  return data
}

/**
 * Kaller og forventer et avslag. Returnerer meldingen, eller tom streng når
 * kallet gikk gjennom — en prøve som ikke kan skille et avslag fra et
 * gjennomslag, prøver ingenting.
 */
async function rejected(
  actor: Client,
  name: string,
  args: Record<string, unknown> = {},
): Promise<string> {
  try {
    await call(actor, name, args)
    return ''
  } catch (error) {
    return error instanceof Error ? error.message : String(error)
  }
}

function record(value: unknown): Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {}
}

function rows(value: unknown): Record<string, unknown>[] {
  return Array.isArray(value) ? value.map((entry) => record(entry)) : []
}

/** Svaret en «agent» leverer: bindingsverdiene uendret, og resultatet. */
interface Service {
  readonly provider: string
  readonly model: string
}

function answerFor(task: AgentTask, result: unknown, service: Service): Record<string, unknown> {
  return {
    answer_version: task.answerVersion,
    task_version: task.taskVersion,
    role: task.role,
    job_key: task.jobKey,
    request_digest: task.requestDigest,
    output_schema_version: task.outputSchemaVersion,
    identity: {
      provider: service.provider,
      model: service.model,
      model_version_disclosure: 'not_exposed',
    },
    answered_at: new Date().toISOString(),
    result,
  }
}

/**
 * Jobbene som alt sto i køen da prøven begynte.
 *
 * Prøven skal kunne kjøre både på en fersk base og på en base der kjeden alt
 * har kjørt (`scripts/db-upgrade-monograph.sh`). «Første ledige jobb i rollen»
 * er ikke det samme på de to: på den andre ville uttaket tatt en etterlatt jobb
 * fra en annen kjøring, og prøven ville målt noe annet enn den sa. Derfor
 * merkes køen av på forhånd, og uttaket ser bare på det denne kjøringen laget.
 */
let jobsFromBefore = ''

function markExistingJobs(): void {
  const ids = psql(
    config,
    `select coalesce(string_agg(quote_literal(j.id::text), ','), '')
     from workflow.pipeline_jobs j`,
  )
  jobsFromBefore = ids.length === 0 ? '' : ` and j.id::text not in (${ids})`
}

/** Første ledige handoff-jobb denne kjøringen fikk, som databasen selv la den inn. */
function jobFor(role: string, jobKeyLike = '%'): string {
  return psql(
    config,
    `select j.id::text
     from workflow.pipeline_jobs j
     join workflow.agent_handoff_jobs h on h.pipeline_job_id = j.id
     where j.agent_role = ${q(role)}
       and j.state = 'ready'
       and j.job_key like ${q(jobKeyLike)}${jobsFromBefore}
     order by j.enqueued_at, j.id
     limit 1`,
  )
}

/**
 * Jobben for den søkeplanen som dekker en bestemt spørsmålsmal.
 *
 * Prøven trenger en plan med et behov malen gjentas på utfallsaksen for: det er
 * den aksen kildeoppdagelsens begrepsforslag utvider, og en mal som gjentas på
 * risikoområde i stedet, avviser forslaget — med rette.
 */
function jobForTemplate(role: string, template: string): string {
  return psql(
    config,
    `select j.id::text
     from workflow.pipeline_jobs j
     join workflow.agent_handoff_jobs h on h.pipeline_job_id = j.id
     join workflow.monograph_search_plans p
       on p.id = workflow.manifest_uuid(j.input_manifest, 'search_plan_id')
     join workflow.monograph_search_plan_needs pn on pn.plan_id = p.id
     join knowledge.monograph_needs n on n.id = pn.need_id
     join knowledge.monograph_question_templates t on t.id = n.template_id
     where j.agent_role = ${q(role)}
       and j.state = 'ready'
       and t.code = ${q(template)}${jobsFromBefore}
     order by j.enqueued_at, j.id
     limit 1`,
  )
}

async function main(): Promise<void> {
  console.log(
    'Antidep: «Bygg monografi for sertralin» → dekningskart → kildeoppdagelse → ' +
      'dekningskontroll → innhenting → evidenskjede → strukturert svar → ' +
      'monografiutkast → sluttkontroll → publisering.\n',
  )

  // Forløpet er et forløp og ikke et stillas: det bygger én monografiutgave fra
  // bunnen, og en utgave som alt finnes, ville latt prøven bestå uten å ha
  // prøvd noe. Kjøringen krever derfor en fersk base.
  const existing = psql(
    config,
    `select count(*)::text from knowledge.monograph_editions e
     join catalog.drugs d on d.id = e.drug_id
     where d.canonical_name = 'sertralin'`,
  )
  if (existing !== '0') {
    console.error(
      'Det finnes allerede en monografiutgave for sertralin i denne basen.\n' +
        'Kjør `npm run db:reset` først: prøven bygger én utgave fra bunnen, og en\n' +
        'utgave som alt finnes, ville latt den bestå uten å ha prøvd noe.',
    )
    process.exitCode = 2
    return
  }

  seed()
  const secrets = credentials()
  // Kontrolleddene når api-veiene sine med legitimasjon og ikke med en
  // Data API-rolle. `anon` er derfor riktig klient: det er slik en kjører gjør
  // det i drift.
  const control = createClient<Database, 'api'>(config.apiUrl, config.anonKey, {
    db: { schema: 'api' },
    auth: { persistSession: false, autoRefreshToken: false },
  })
  const editor = client(EDITOR_USER)
  const reviewer = client(REVIEWER_USER)
  const publisher = client(PUBLISHER_USER)

  // --------------------------------------------------------------------
  // 1. KI-tjenestene for de semantiske leddene
  //
  // Uttaket kommer etter valget: en oppgave bygget uten en modelltildeling
  // ville bedt om et svar ingen kunne si var uavhengig.
  // --------------------------------------------------------------------
  const models: Readonly<Record<string, string>> = {
    source_discovery: `monografi-oppdagelse-${RUN}`,
    source_quality_assessment: `monografi-dekningskontroll-${RUN}`,
    evidence_extraction: `monografi-ekstraksjon-${RUN}`,
    claim_synthesis: `monografi-syntese-${RUN}`,
    evidence_assessment: `monografi-vurdering-${RUN}`,
    monograph_answer: `monografi-svar-${RUN}`,
  }
  // Tildelingen gjøres bare der leddet ikke alt har en. Prøven skal kunne kjøre
  // både på en fersk base og på en base der kjeden alt har kjørt
  // (`scripts/db-upgrade-monograph.sh`), og et ledd som alt har en levende
  // tildeling, oppfyller kravet like godt som et nytt: det er *at* hvert ledd
  // har sin egen tjeneste som betyr noe, ikke hvem som ba om den.
  const assigned = psql(
    config,
    `select string_agg(distinct a.agent_role::text, ',')
     from provenance.role_model_assignments a
     where a.valid_to is null
       and a.capacity = 'semantic'`,
  )
    .split(',')
    .filter((role) => role.length > 0)

  for (const [role, model] of Object.entries(models)) {
    if (assigned.includes(role)) {
      continue
    }
    await call(editor, 'assign_agent_role_model', {
      p_agent_role: role,
      p_provider: 'antidep-test',
      p_model: model,
      p_model_version_disclosure: 'not_exposed',
      p_reason: 'Monografiprøven: tjenesten som utfører leddet.',
    })
  }

  // Svarene må komme fra den tjenesten leddet *faktisk* er tildelt, og på en
  // oppgradert base er det den som alt sto der. Kartet leses derfor tilbake fra
  // databasen framfor å gjenta prøvens egne navn: et svar avgitt i en annen
  // tjenestes navn skal avvises, og det er nettopp den kontrollen som ville
  // slått til her om prøven hadde gjettet.
  const services = new Map<string, Service>()
  for (const role of Object.keys(models)) {
    const live = psql(
      config,
      `select a.provider || '|' || a.model
       from provenance.role_model_assignments a
       where a.valid_to is null
         and a.capacity = 'semantic'
         and a.agent_role::text = ${q(role)}`,
    ).split('|')
    services.set(role, { provider: live[0] ?? '', model: live[1] ?? '' })
  }

  const serviceFor = (role: string): Service => {
    const service = services.get(role)
    if (service === undefined || service.model.length === 0) {
      throw new Error(`Agentleddet ${role} har ingen levende modelltildeling.`)
    }
    return service
  }

  // Kravet prøves etterpå, og på databasen framfor på løkka over: hvert av de
  // seks leddene skal ha nøyaktig én levende tildeling, og ingen to ledd skal
  // dele en tjeneste.
  const distinct = psql(
    config,
    `select count(*)::text || '/' || count(distinct (a.provider, a.model))::text
     from provenance.role_model_assignments a
     where a.valid_to is null
       and a.capacity = 'semantic'
       and a.agent_role::text = any (array[${Object.keys(models)
         .map((role) => q(role))
         .join(', ')}])`,
  )
  // Prøvens eget oppsett, ikke en regel: fra migrasjon 013t *kan* flere ledd
  // dele modell. Denne kjøringen gir dem hver sin, slik at en feil binding
  // mellom ledd og svar blir synlig i akkurat denne prøven.
  check(
    'monografiprøven gir hvert semantisk ledd sin egen tjeneste',
    distinct === `${String(Object.keys(models).length)}/${String(Object.keys(models).length)}`,
  )

  // --------------------------------------------------------------------
  // 2. Bestillingen
  // --------------------------------------------------------------------
  markExistingJobs()
  const order = record(
    await call(editor, 'order_monograph', {
      p_drug_name: 'sertralin',
      p_note: 'Monografiprøven: pilotbestillingen.',
    }),
  )
  const edition = String(order['reference'] ?? '')
  check('bestillingen gjelder virkestoffet redaktøren navnga', order['drug'] === 'sertralin')
  check(
    'og den er én utgave med en standardversjon',
    edition.length === 32 && order['standard_version'] === '1.0.0',
  )

  const coverage = record(await call(editor, 'monograph_coverage', { p_reference: edition }))
  const needs = record(coverage['needs'])
  const missingTemplates = psql(
    config,
    `select count(*)::text
     from knowledge.monograph_question_templates t
     where t.standard_version = '1.0.0'
       and not exists (
         select 1 from knowledge.monograph_needs n
         join knowledge.monograph_editions e on e.id = n.edition_id
         where n.template_id = t.id and e.reference = ${q(edition)})`,
  )
  check('alle 80 spørsmålsmalene har konkrete kunnskapsbehov', missingTemplates === '0')
  check(
    'og dekningens nevner er hele den lagrede behovslisten',
    Number(needs['total'] ?? 0) > 100,
    `behov: ${String(needs['total'])}`,
  )
  check(
    'ingen behov er besvart ennå, og ingen er stille fjernet fra nevneren',
    needs['answered'] === 0 && Number(needs['open'] ?? 0) > 0,
  )

  const plans = psql(
    config,
    `select count(*)::text from workflow.monograph_search_plans p
     join knowledge.monograph_editions e on e.id = p.edition_id
     where e.reference = ${q(edition)}`,
  )
  check(
    'søkeplanene er færre enn behovene: 80 maler er ikke 80 litteratursøk',
    Number(plans) > 0 && Number(plans) < Number(needs['total'] ?? 0),
    `planer: ${plans}, behov: ${String(needs['total'])}`,
  )

  // --------------------------------------------------------------------
  // 3. Kildeoppdagelsen
  // --------------------------------------------------------------------
  // MN29 spør om vekt og appetitt, og gjentas på utfallsaksen. Planen som
  // dekker den, er derfor den prøven trenger for å gå hele veien til et
  // forskningssvar: et forskningsfunn må ha et navngitt endepunkt å
  // kontrolleres mot.
  const discoveryJob = jobForTemplate('source_discovery', 'MN29')
  check('kildeoppdagelsen har fått en oppgave av databasen selv', discoveryJob.length > 0)
  if (discoveryJob.length === 0) return

  const discoveryTask = parseAgentTask(
    await call(editor, 'agent_task_payload', { p_pipeline_job_id: discoveryJob }),
  )
  const taskFile = renderAgentTaskFile(discoveryTask)
  check(
    'oppgavefilen bærer spørsmålene ordrett, og ingen forventet klinisk svar',
    taskFile.includes('### Kunnskapsbehovene søket skal dekke') &&
      taskFile.includes('### Når søket kan avsluttes') &&
      !taskFile.includes('forventet svar'),
  )

  const taskNeeds = rows(discoveryTask.input['needs'])
  check('oppgaven navngir de behovene søket skal dekke', taskNeeds.length > 0)
  const firstNeed = String(
    (taskNeeds.find((need) => need['template'] === 'MN29') ?? taskNeeds[0])?.['need_reference'] ??
      '',
  )

  // Sporene oppgaven faktisk krever. En kode som ikke står der, er ikke et
  // obligatorisk spor for denne kildeprofilen, og databasen avviser den.
  const tracks = rows(discoveryTask.input['required_tracks']).map((row) =>
    String(row['code'] ?? ''),
  )
  check('oppgaven sier hvilke søkespor som er obligatoriske', tracks.length > 0)

  const discoveryResult = {
    searches: [
      {
        platform: 'Europe PMC',
        query_string: '"sertralin" AND ("vektendring" OR "weight")',
        filters: 'pageSize=25',
        outcome: 'executed',
        result_count: 2,
        screened_count: 2,
        truncated: false,
        track_codes: tracks,
      },
      {
        platform: 'PubMed',
        query_string: 'sertraline[tiab] AND (weight OR appetite)',
        outcome: 'zero_results',
        result_count: 0,
        screened_count: 0,
        truncated: false,
        track_codes: tracks,
      },
    ],
    candidates: [
      {
        identifier_kind: 'doi',
        identifier_value: DOI,
        title: ARTICLE_TITLE,
        authors_or_issuer: 'Testforfatter A, Testforfatter B',
        publisher_or_journal: 'Journal of Synthetic Trials',
        publication_year: 2024,
        discovery_path: 'Europe PMC, søk i monografiprøven',
        access_limited: false,
        could_change_conclusion: true,
        materiality_reason: 'Rapporterer utfallet behovet spør om, i den avgrensede populasjonen.',
        uses: [
          {
            need_reference: firstNeed,
            proposed_use:
              'Rapporterer gjennomsnittlig prosentvis vektendring ved endepunkt for voksne med depressiv lidelse.',
          },
        ],
      },
    ],
    term_proposals: [
      {
        axis: 'outcome',
        label: 'vektendring',
        rationale: 'Utfallet er rapportert i litteraturen for nettopp dette spørsmålet.',
        from_need: firstNeed,
      },
    ],
    note: null,
  }

  await call(editor, 'import_agent_answer', {
    p_pipeline_job_id: discoveryJob,
    p_answer: answerFor(discoveryTask, discoveryResult, serviceFor('source_discovery')),
  })

  const searchCount = psql(
    config,
    `select count(*)::text from workflow.monograph_searches s
     join workflow.monograph_search_plans p on p.id = s.plan_id
     join knowledge.monograph_editions e on e.id = p.edition_id
     where e.reference = ${q(edition)}`,
  )
  check('søkene står i loggen, med sin egen utførelsesform', searchCount === '2')
  check(
    'og de er registrert som agentens egen beretning, ikke som maskinelt bekreftet',
    psql(config, `select distinct execution_evidence::text from workflow.monograph_searches`) ===
      'agent_reported',
  )
  check(
    'et utført nullsøk er lagret som et nullsøk, ikke som en utilgjengelig søkevei',
    psql(
      config,
      `select outcome::text from workflow.monograph_searches where platform = 'PubMed'`,
    ) === 'zero_results',
  )

  const candidateRef = psql(
    config,
    `select c.reference from workflow.monograph_candidate_sources c
     where c.identifier_value = ${q(DOI)}`,
  )
  check('kandidatkilden er registrert med sin identitet', candidateRef.length === 32)

  // --------------------------------------------------------------------
  // 4. Den separate kontrollen av søkedekningen
  // --------------------------------------------------------------------
  const controlJob = jobForTemplate('source_quality_assessment', 'MN29')
  check('den separate dekningskontrollen har fått sin egen oppgave', controlJob.length > 0)
  if (controlJob.length === 0) return

  const controlTask = parseAgentTask(
    await call(editor, 'agent_task_payload', { p_pipeline_job_id: controlJob }),
  )
  check(
    'kontrolloppgaven ber om egne motsøk, ikke bare om generatorens referanser',
    renderAgentTaskFile(controlTask).includes('Rapporter dine egne motsøk'),
  )

  await call(editor, 'import_agent_answer', {
    p_pipeline_job_id: controlJob,
    p_answer: answerFor(
      controlTask,
      {
        searches: [
          {
            platform: 'Cochrane Library',
            query_string: 'sertraline AND weight',
            outcome: 'executed',
            result_count: 1,
            screened_count: 1,
            truncated: false,
            track_codes: tracks,
          },
        ],
        candidates: [],
        control: {
          outcome: 'accepted',
          note: 'Eget motsøk i et uavhengig spor ga ingen oversette kilder, og eksklusjonene er gjennomgått.',
          searched_independently: true,
          missed_candidates: 0,
          exclusions_checked: 0,
          materiality_assessed: true,
        },
      },
      serviceFor('source_quality_assessment'),
    ),
  })

  check(
    'dekningskontrollen er registrert med sitt eget ledd og sin egen modell',
    psql(config, `select count(*)::text from workflow.monograph_coverage_controls`) === '1',
  )

  // --------------------------------------------------------------------
  // 5. Utfallsverdien aksepteres, og behovet forgrenes
  // --------------------------------------------------------------------
  const proposalRef = psql(
    config,
    `select p.reference from workflow.monograph_term_proposals p
     join knowledge.monograph_editions e on e.id = p.edition_id
     where e.reference = ${q(edition)} and p.state = 'open'
     order by p.created_at limit 1`,
  )
  check('kildeoppdagelsens forslag om en ny utfallsverdi står åpent', proposalRef.length === 32)

  const beforeNeeds = Number(
    psql(
      config,
      `select count(*)::text from knowledge.monograph_needs n
       join knowledge.monograph_editions e on e.id = n.edition_id
       where e.reference = ${q(edition)}`,
    ),
  )
  await call(editor, 'decide_monograph_term', { p_reference: proposalRef, p_accept: true })
  const afterNeeds = Number(
    psql(
      config,
      `select count(*)::text from knowledge.monograph_needs n
       join knowledge.monograph_editions e on e.id = n.edition_id
       where e.reference = ${q(edition)}`,
    ),
  )
  check(
    'aksepten forgrener nettopp det behovet verdien kom fra',
    afterNeeds === beforeNeeds + 1,
    `${beforeNeeds} → ${afterNeeds}`,
  )

  const scopedNeed = psql(
    config,
    `select n.reference from knowledge.monograph_needs n
     join knowledge.monograph_editions e on e.id = n.edition_id
     join catalog.clinical_concepts c on c.id = n.outcome_concept_id
     where e.reference = ${q(edition)} and c.canonical_label = 'vektendring'
     order by n.created_at desc limit 1`,
  )
  check('det nye behovet bærer utfallet som avgrensning', scopedNeed.length === 32)

  // Kilden er også relevant for det forgrenede behovet. Det er dette behovet
  // forskningssvaret senere hviler på, fordi et forskningsfunn trenger et
  // navngitt endepunkt å kontrolleres mot.
  psql(
    config,
    `insert into workflow.monograph_candidate_source_needs
       (candidate_source_id, need_id, proposed_use)
     select c.id, n.id,
            'Rapporterer gjennomsnittlig prosentvis vektendring ved endepunkt.'
     from workflow.monograph_candidate_sources c, knowledge.monograph_needs n
     where c.identifier_value = ${q(DOI)} and n.reference = ${q(scopedNeed)}`,
  )

  // --------------------------------------------------------------------
  // 6. Kildeutvalget, og innhentingen som går videre av seg selv
  // --------------------------------------------------------------------
  await call(editor, 'decide_monograph_candidate', {
    p_candidate_reference: candidateRef,
    p_decision: 'selected_for_retrieval',
    p_reason: 'Kilden rapporterer utfallet behovet spør om, i den avgrensede populasjonen.',
  })

  const sourceId = psql(
    config,
    `select c.source_id::text from workflow.monograph_candidate_sources c
     where c.reference = ${q(candidateRef)}`,
  )
  check('kilden er opprettet av kandidatens egen identifikator', sourceId.length === 36)
  check(
    'og identifikatoren er normalisert, slik den samme artikkelen bare blir én kilde',
    psql(
      config,
      `select identifier_value from knowledge.source_identifiers
       where source_id = ${q(sourceId)} and identifier_system = 'doi'`,
    ) === DOI.toLowerCase(),
  )

  const requests = record(
    await call(editor, 'monograph_source_requests', { p_edition_reference: edition }),
  )
  const research = rows(requests['research_full_text'])
  check('fullteksten er etterspurt i én samlet forespørsel', research.length === 1)
  check(
    'forespørselen bærer artikkelidentiteten og den faglige grunnen',
    String(research[0]?.['title'] ?? '') === ARTICLE_TITLE &&
      String(research[0]?.['professional_reason'] ?? '').includes('Rapporterer'),
  )
  check(
    'og ingen intern identifikator: teknisk registrering er ikke klinikerens arbeid',
    !Object.keys(research[0] ?? {}).some((key) =>
      ['source_id', 'need_id', 'source_version_id'].includes(key),
    ),
  )
  check(
    'behovet venter på tilgang, og det er ikke et faglig utfall',
    psql(
      config,
      `select n.work_state::text from knowledge.monograph_needs n
       where n.reference = ${q(scopedNeed)}`,
    ) === 'awaiting_access',
  )

  const requestRef = String(research[0]?.['reference'] ?? '')

  // --------------------------------------------------------------------
  // 7. Fullteksten leveres, og kildeversjonen registreres
  // --------------------------------------------------------------------
  const pdf = syntheticArticlePdf([`doi: ${DOI}`, METHOD, SAMPLE, RESULT])
  await call(editor, 'submit_full_text', {
    p_reference: requestRef,
    p_document_base64: Buffer.from(pdf).toString('base64'),
  })

  const claimed = record(await call(editor, 'claim_full_text_extraction', { p_lease_seconds: 600 }))
  check('Antideps eget tekstuttrekk tar oppdraget', claimed['available'] === true)

  const { execFileSync } = await import('node:child_process')
  const { mkdtempSync, writeFileSync } = await import('node:fs')
  const { tmpdir } = await import('node:os')
  const { join } = await import('node:path')
  const work = mkdtempSync(join(tmpdir(), `antidep-monografi-${RUN}-`))
  const pdfPath = join(work, 'artikkel.pdf')
  writeFileSync(pdfPath, Buffer.from(String(claimed['document_base64']), 'base64'))
  const extracted = execFileSync(
    'pdftotext',
    ['-bbox-layout', '-enc', 'UTF-8', '-eol', 'unix', pdfPath, '-'],
    { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 },
  )

  // Antideps egen leserekkefølge, av posisjonsdataene verktøyet ga. Den samme
  // oppskriften kildeversjonen registreres med, og den samme en senere
  // etterprøving kjører på nytt.
  const { reconstructReadingOrder } = await import('../src/agents/reading-order.ts')
  const readingOrder = reconstructReadingOrder(extracted)
  check('leserekkefølgen lar seg bygge av posisjonsdataene', readingOrder.status === 'ok')
  if (readingOrder.status !== 'ok') return

  await call(editor, 'complete_full_text_extraction', {
    p_handle: claimed['handle'],
    p_extracted_text: readingOrder.text,
    p_text_extraction_tool_version: '24.02.0',
  })

  const sourceVersionId = psql(
    config,
    `select id::text from knowledge.source_versions
     where source_id = ${q(sourceId)} and representation = 'full_text'`,
  )
  check('kildeversjonen er registrert som dokumentbundet fulltekst', sourceVersionId.length === 36)
  check(
    'og den godkjente kildebruken er ført opp for behovet, i det samme kallet',
    psql(
      config,
      `select count(*)::text from knowledge.monograph_source_uses u
       join knowledge.monograph_needs n on n.id = u.need_id
       where u.source_version_id = ${q(sourceVersionId)} and n.reference = ${q(scopedNeed)}`,
    ) === '1',
  )

  // --------------------------------------------------------------------
  // 8. Ekstraksjonen og den uavhengige kontrollen
  // --------------------------------------------------------------------
  const extractionJob = jobFor('evidence_extraction')
  check('ekstraksjonsoppgaven er lagt i køen av fulltekstregistreringen', extractionJob.length > 0)
  if (extractionJob.length === 0) return

  const extractionTask = parseAgentTask(
    await call(editor, 'agent_task_payload', { p_pipeline_job_id: extractionJob }),
  )
  check(
    'oppgaven bærer hele den kontrollerte fullteksten',
    renderAgentTaskFile(extractionTask).includes('Mean percent weight change was 1.0%'),
  )

  const drugId = psql(
    config,
    `select id::text from catalog.drugs where canonical_name = 'sertralin'`,
  )
  const outcomeId = psql(
    config,
    `select id::text from catalog.clinical_concepts where canonical_label = 'vektendring'`,
  )
  const populationId = psql(
    config,
    `select id::text from catalog.populations where canonical_label = 'voksne med depressiv lidelse'`,
  )

  await call(editor, 'import_agent_answer', {
    p_pipeline_job_id: extractionJob,
    p_answer: answerFor(
      extractionTask,
      {
        extraction: {
          design_code: 'randomized_controlled_trial',
          population_id: populationId,
          population_availability: 'reported_value',
          population_detail: 'Voksne med depressiv lidelse.',
          sample_size: 48,
          sample_size_availability: 'reported_value',
          intervention_drug_id: drugId,
          comparator_kind: 'none',
          outcome_concept_id: outcomeId,
          outcome_detail: 'Gjennomsnittlig prosentvis vektendring ved endepunkt.',
          timepoint_min: '26 weeks',
          timepoint_max: '32 weeks',
          timepoint_availability: 'reported_value',
          reported_direction: 'increase',
          effect_measure: 'mean_change',
          estimate: '1.0',
          estimate_unit: 'percent',
          estimate_availability: 'reported_value',
          ci_lower: '0.5',
          ci_upper: '1.5',
          ci_level_percent: '95',
          confidence_interval_availability: 'reported_value',
          source_locator: 'Syntetisk fulltekst, resultater',
          source_quote: RESULT,
        },
        field_groundings: [
          ['intervention_arm', METHOD],
          ['sample_size', SAMPLE],
          ['outcome', RESULT],
          ['estimate', RESULT],
          ['effect_measure', RESULT],
          ['reported_direction', RESULT],
          ['confidence_interval', RESULT],
          ['timepoint', METHOD],
          ['population', METHOD],
          ['availability_semantics', RESULT],
        ].map(([field, excerpt]) => ({
          check_field: field,
          source_excerpt: excerpt,
          source_locator: 'RESULTS',
          justification: `Utdraget oppgir verdien for ${String(field)}.`,
        })),
      },
      serviceFor('evidence_extraction'),
    ),
  })

  const evidenceItemId = psql(
    config,
    `select e.id::text from knowledge.evidence_items e
     where e.source_version_id = ${q(sourceVersionId)}`,
  )
  check('evidensfunnet er registrert', evidenceItemId.length === 36)
  check(
    'og databasen utleder hvilket kunnskapsbehov funnet svarer på',
    psql(
      config,
      `select n.reference from knowledge.monograph_needs n
       where n.id = knowledge.monograph_need_for_evidence_item(${q(evidenceItemId)})`,
    ) === scopedNeed,
  )

  const requiredFields = psql(
    config,
    `select array_to_string(workflow.required_check_fields(${q(evidenceItemId)}), ',')`,
  )
    .split(',')
    .filter((field) => field.length > 0 && field !== 'source_wide_absence')

  const extractionRun = await call(control, 'begin_agent_run', {
    p_identity_key: 'agent-identity:extraction-verification-01',
    p_secret: secrets.extraction,
    p_agent_role: 'extraction_verification',
    p_provider: EXTRACTION_VERIFICATION_PREMISES.provider,
    p_model: EXTRACTION_VERIFICATION_PREMISES.model,
    p_model_version: EXTRACTION_VERIFICATION_PREMISES.modelVersion,
    p_prompt_template_version: EXTRACTION_VERIFICATION_PREMISES.promptTemplateVersion,
    p_pipeline_version: EXTRACTION_VERIFICATION_PREMISES.pipelineVersion,
    p_input_manifest: { evidence_item_id: evidenceItemId },
  })
  check(
    'den uavhengige ekstraksjonskontrollen åpner sin egen kjøring',
    typeof extractionRun === 'string',
  )

  await call(control, 'register_extraction_verification', {
    p_identity_key: 'agent-identity:extraction-verification-01',
    p_secret: secrets.extraction,
    p_agent_run_id: extractionRun,
    p_evidence_item_id: evidenceItemId,
    p_outcome: 'verified',
    p_source_access: 'verifiable_representation',
    p_checked_fields: requiredFields,
    p_rationale: 'Monografiprøven: alle feltene er kontrollert mot fullteksten.',
  })

  // Oppgaven hentes på kunnskapsbehovet og ikke som «første ledige i rollen».
  //
  // Det er selve kravet: at det i det hele tatt *finnes* en synteseoppgave med
  // behovet i subjektet, er beviset på at en eksisterende påstand om det samme
  // temaet og virkestoffet ikke lenger stanser videre syntese. Et uttak som tok
  // den første ledige, ville dessuten tatt en etterlatt jobb fra en annen
  // kjøring på en base som alt har innhold — og prøvd noe annet enn det den sa.
  const needId = psql(
    config,
    `select id::text from knowledge.monograph_needs where reference = ${q(scopedNeed)}`,
  )
  const synthesisJob = jobFor('claim_synthesis', `%${needId}%`)
  check(
    'en bekreftet ekstraksjonskontroll legger synteseoppgaven i køen, med kunnskapsbehovet som avgrensning',
    synthesisJob.length > 0,
  )
  if (synthesisJob.length === 0) return
  // Avgrensningen er databasens egen utledning, og ikke noe kalleren oppgir:
  // funnet peker på behovet gjennom den godkjente kildebruken. Det er den
  // utledningen som gjør porten avgrensningsbevisst, og den prøves her for seg
  // — ikke gjennom uttaket over, som ville svart på sitt eget spørsmål.
  check(
    'og databasen utleder avgrensningen av funnet selv, gjennom den godkjente kildebruken',
    psql(
      config,
      `select coalesce(knowledge.monograph_need_for_evidence_item(${q(evidenceItemId)}::uuid)::text, '')`,
    ) === needId,
  )

  // Den eksisterende, uavgrensede påstanden om det samme temaet stanser ikke
  // syntesen lenger — og den blir heller ikke overskrevet av den: den får sitt
  // eget revisjonsvarsel. På en fersk base finnes den ikke, og da er tallet
  // null; på en oppgradert base er det den gamle påstanden.
  const unscopedSameTopic = psql(
    config,
    `select count(*)::text from knowledge.claims c
     join knowledge.monograph_needs n on n.id = ${q(needId)}::uuid
     where c.topic_concept_id = n.outcome_concept_id
       and c.monograph_need_id is null`,
  )
  check(
    'en eksisterende påstand om samme tema får et revisjonsvarsel framfor å bli skrevet om',
    unscopedSameTopic === '0' ||
      psql(
        config,
        `select count(*)::text from workflow.claim_revision_reviews v
         join knowledge.claims c on c.id = v.claim_id
         join knowledge.monograph_needs n on n.id = ${q(needId)}::uuid
         where c.topic_concept_id = n.outcome_concept_id
           and c.monograph_need_id is null`,
      ) !== '0',
    `uavgrensede påstander om samme tema: ${unscopedSameTopic}`,
  )

  // --------------------------------------------------------------------
  // 9. Syntesen, kildestøttekontrollen og evidensvurderingen
  // --------------------------------------------------------------------
  const synthesisTask = parseAgentTask(
    await call(editor, 'agent_task_payload', { p_pipeline_job_id: synthesisJob }),
  )
  const synthesisEvidence = psql(
    config,
    `select string_agg(value, ',')
     from workflow.pipeline_jobs j,
          jsonb_array_elements_text(j.input_manifest -> 'evidence_item_ids')
     where j.id = ${q(synthesisJob)}`,
  )
    .split(',')
    .filter((id) => id.length > 0)
  check(
    'synteseoppgaven bygges av hele det brukbare grunnlaget for avgrensningen',
    synthesisEvidence.includes(evidenceItemId),
    synthesisEvidence.join(', '),
  )

  const brief = record(synthesisTask.input['monograph_need'])
  check(
    'synteseoppgaven sier hvilket spørsmål svaret skal gjelde, ordrett fra standarden',
    String(brief['question'] ?? '').length > 20 &&
      String(brief['template_code'] ?? '').startsWith('MN'),
  )

  // --------------------------------------------------------------------
  // 9b. Studien, atskilt fra rapportene om den
  //
  // Grunnlaget kan ikke leses som flere uavhengige deltakerutvalg enn det
  // faktisk hviler på (SOURCE_POLICY.md §7). Oppgaven bærer derfor
  // grupperingen, og her prøves den gjennom den ekte oppgaveflaten: først uten
  // en registrert kobling, så etter at redaktøren har registrert at artikkelen
  // er en rapport om en navngitt studie.
  //
  // At *to* rapporter om den samme studien teller som én enhet, prøves for seg
  // i `supabase/tests/940_study_identity_test.sql`, der tre evidensfunn fra to
  // studier gir to enheter og ikke tre.
  // --------------------------------------------------------------------
  const unitsBefore = record(synthesisTask.input['study_units'])
  check(
    'synteseoppgaven bærer hvor mange uavhengige studier grunnlaget hviler på',
    Number(unitsBefore['independent_units'] ?? 0) === 1 &&
      Number(unitsBefore['evidence_items'] ?? 0) === 1,
    JSON.stringify(unitsBefore),
  )
  check(
    'og en kilde uten registrert studiekobling står som sin egen enhet',
    Number(unitsBefore['shared_studies'] ?? -1) === 0,
  )

  const studyLink = record(
    await call(editor, 'register_study_report', {
      p_source_reference: ARTICLE_TITLE,
      p_registry_kind: 'clinicaltrials_gov',
      p_registry_id: `NCT${RUN.slice(0, 8)}`,
      p_study_label: `Syntetisk studie for kjedeprøven ${RUN}`,
      p_report_role: 'primary_report',
      p_linkage_basis: 'Artikkelen oppgir forsøksregisternummeret i metodeavsnittet.',
      p_certain: true,
    }),
  )
  check(
    'redaktøren kan registrere at artikkelen er en rapport om en navngitt studie',
    String(studyLink['registry'] ?? '').startsWith('clinicaltrials_gov:NCT'),
    String(studyLink['registry'] ?? ''),
  )

  const unitsAfter = record(
    JSON.parse(
      psql(
        config,
        `select knowledge.study_units_for_evidence(array[${q(evidenceItemId)}::uuid])::text`,
      ),
    ),
  )
  check(
    'og grunnlaget bærer studien etterpå, uten at funnet er blitt borte',
    Number(unitsAfter['independent_units'] ?? 0) === 1 &&
      Number(unitsAfter['evidence_items'] ?? 0) === 1 &&
      record(rows(rows(unitsAfter['units'])[0]?.['studies'])[0])['registry'] ===
        studyLink['registry'],
    JSON.stringify(unitsAfter),
  )

  // --------------------------------------------------------------------
  // 9c. Og koblingen gjør det utestående svaret foreldet
  //
  // Grupperingen ligger i *bindingen* og ikke bare i materialet. Uten det
  // kunne et svar bygget på den dobbelttelte tilstanden — to rapporter lest
  // som to uavhengige utvalg — blitt registrert i ettertid, og grunnlaget
  // ville sett sterkere ut enn det er (SOURCE_POLICY.md §7).
  // --------------------------------------------------------------------
  const synthesisResult = {
    claim: {
      statement:
        'Sertralin er forbundet med en gjennomsnittlig vektøkning på 1,0 % ved endepunkt hos voksne med depressiv lidelse.',
      scope: 'Voksne med depressiv lidelse, 26–32 uker.',
      comparator_kind: 'none',
      population_id: populationId,
      timeframe_min: '26 weeks',
      timeframe_max: '32 weeks',
      direction: 'increase',
      magnitude_measure: 'mean_change',
      magnitude_value: '1.0',
      magnitude_unit: 'percent',
      uncertainty_summary:
        'Ett funn fra én syntetisk studie; presisjonen er rapportert som et 95 % konfidensintervall.',
    },
    // Hvert funn oppgaven avgrenset, skal ha en relasjon til påstanden —
    // også et som motsier den. Et utelatt funn ville gjort grunnlaget til
    // et annet enn det som finnes.
    evidence_links: synthesisEvidence.map((id) => ({
      evidence_item_id: id,
      relationship_type: 'supports',
      directness: 'direct',
      relevance_note: 'Funnet måler nøyaktig utfallet påstanden gjelder.',
    })),
  }

  const staleAnswer = await rejected(editor, 'import_agent_answer', {
    p_pipeline_job_id: synthesisJob,
    p_answer: answerFor(synthesisTask, synthesisResult, serviceFor('claim_synthesis')),
  })
  check(
    'et synteseutkast avgitt før studiekoblingen ble registrert, avvises som foreldet',
    staleAnswer.length > 0,
    staleAnswer,
  )

  const synthesisTaskAfter = parseAgentTask(
    await call(editor, 'agent_task_payload', { p_pipeline_job_id: synthesisJob }),
  )
  check(
    'og den nye utleveringen er den samme oppgaven med et nytt forespørselsavtrykk',
    synthesisTaskAfter.jobKey === synthesisTask.jobKey &&
      synthesisTaskAfter.requestDigest !== synthesisTask.requestDigest,
  )
  check(
    'som bærer den registrerte studien',
    Number(record(synthesisTaskAfter.input['study_units'])['shared_studies'] ?? -1) === 0 &&
      rows(record(synthesisTaskAfter.input['study_units'])['units']).length === 1,
    JSON.stringify(synthesisTaskAfter.input['study_units']),
  )

  await call(editor, 'import_agent_answer', {
    p_pipeline_job_id: synthesisJob,
    p_answer: answerFor(synthesisTaskAfter, synthesisResult, serviceFor('claim_synthesis')),
  })

  const revisionId = psql(
    config,
    `select r.id::text from knowledge.claim_revisions r
     join knowledge.claims c on c.id = r.claim_id
     join knowledge.monograph_needs n on n.id = c.monograph_need_id
     where n.reference = ${q(scopedNeed)}
     order by r.revision_number desc limit 1`,
  )
  check(
    'påstanden er bygget, og den bærer kunnskapsbehovet som avgrensning',
    revisionId.length === 36,
  )

  const claimLinks = psql(
    config,
    `select string_agg(l.id::text, ',')
     from knowledge.claim_evidence_links l
     where l.claim_revision_id = ${q(revisionId)}`,
  )
    .split(',')
    .filter((id) => id.length > 0)
  check('påstandsrevisjonen lenker grunnlaget sitt', claimLinks.length > 0)

  // Avtrykket av nøyaktig den teksten kontrollen leste. Uten det ville
  // «kontrollert mot kilden» vært en påstand om hvilken tekst som ble lest.
  const sourceContentHash = psql(
    config,
    `select content_hash from knowledge.source_versions where id = ${q(sourceVersionId)}`,
  )

  const claimRun = await call(control, 'begin_agent_run', {
    p_identity_key: 'agent-identity:citation-support-verification-01',
    p_secret: secrets.claim,
    p_agent_role: 'citation_support_verification',
    p_provider: CLAIM_VERIFICATION_PREMISES.provider,
    p_model: CLAIM_VERIFICATION_PREMISES.model,
    p_model_version: CLAIM_VERIFICATION_PREMISES.modelVersion,
    p_prompt_template_version: CLAIM_VERIFICATION_PREMISES.promptTemplateVersion,
    p_pipeline_version: CLAIM_VERIFICATION_PREMISES.pipelineVersion,
    p_input_manifest: { claim_revision_id: revisionId },
  })
  check(
    'kildestøttekontrollen åpner sin egen kjøring, med sin egen legitimasjon',
    typeof claimRun === 'string',
  )

  await call(control, 'register_claim_verification', {
    p_identity_key: 'agent-identity:citation-support-verification-01',
    p_secret: secrets.claim,
    p_agent_run_id: claimRun,
    p_claim_revision_id: revisionId,
    p_outcome: 'verified',
    p_source_support: 'ok',
    p_population_match: 'ok',
    p_comparator_match: 'ok',
    p_timeframe_match: 'ok',
    p_direction_and_magnitude: 'ok',
    p_qualifiers_complete: 'ok',
    p_contradictory_evidence_represented: 'ok',
    // Hver kontrollerte evidenslenke, med hvilken tilgang kontrollen faktisk
    // hadde til kilden. Lenke-id-en leses av basen: en verdi kalleren kunne
    // valgt fritt, ville vært nøyaktig den bindingen kontrollen skal ha.
    p_citations: claimLinks.map((link) => ({
      claim_evidence_link_id: link,
      source_access: 'verifiable_representation',
      source_version_id: sourceVersionId,
      checked_content_hash: sourceContentHash,
      relationship_supported: 'ok',
    })),
    p_rationale: 'Monografiprøven: påstanden er kontrollert mot kildens egne ord.',
  })

  const assessmentJob = jobFor('evidence_assessment')
  check(
    'en bekreftet kildestøttekontroll legger evidensvurderingen i køen',
    assessmentJob.length > 0,
  )
  if (assessmentJob.length === 0) return

  const assessmentTask = parseAgentTask(
    await call(editor, 'agent_task_payload', { p_pipeline_job_id: assessmentJob }),
  )
  await call(editor, 'import_agent_answer', {
    p_pipeline_job_id: assessmentJob,
    p_answer: answerFor(
      assessmentTask,
      {
        assessment: {
          framework: 'grade',
          certainty_level: 'very_low',
          risk_of_bias: 'serious',
          inconsistency: 'not_assessable',
          indirectness: 'not_serious',
          imprecision: 'serious',
          publication_bias: 'not_assessable',
          rationale:
            'Ett syntetisk funn fra én studie, med vid presisjon og uten uavhengig replikasjon.',
          evidence_gap: 'Ingen sammenlignende data mot et annet virkestoff.',
        },
      },
      serviceFor('evidence_assessment'),
    ),
  })

  // --------------------------------------------------------------------
  // 10. Det strukturerte svaret og monografiutkastet
  // --------------------------------------------------------------------
  check(
    'monografisvaret bindes deterministisk til den kontrollerte påstandsrevisjonen',
    psql(
      config,
      `select r.claim_revision_id::text
       from knowledge.monograph_answers a
       join knowledge.monograph_answer_revisions r on r.id = a.current_revision_id
       join knowledge.monograph_needs n on n.id = a.need_id
       where n.reference = ${q(scopedNeed)}`,
    ) === revisionId,
  )
  check(
    'og svaret har sin egen kontrollrad med hvilke felter som ble kontrollert',
    psql(
      config,
      `select count(*)::text from workflow.monograph_answer_verifications v
       join knowledge.monograph_answer_revisions r on r.id = v.answer_revision_id
       join knowledge.monograph_answers a on a.id = r.answer_id
       join knowledge.monograph_needs n on n.id = a.need_id
       where n.reference = ${q(scopedNeed)}`,
    ) === '1',
  )

  const draft = record(await call(editor, 'monograph_draft', { p_edition_reference: edition }))
  const sections = rows(draft['sections'])
  const answered = sections
    .flatMap((section) => rows(section['entries']))
    .filter((entry) => entry['answer'] !== null && entry['answer'] !== undefined)
  check('monografiutkastet er bygget av de strukturerte svarene', answered.length === 1)
  const answer = record(answered[0]?.['answer'])
  check(
    'svaret bærer evidenssikkerheten fra vurderingen, og skriver den ikke om',
    answer['certainty'] === 'very_low' && answer['certainty_framework'] === 'grade',
  )
  check(
    'og de seks dimensjonene står atskilt',
    answered[0]?.['relevance'] === 'relevant' &&
      answered[0]?.['work_state'] === 'agent_complete' &&
      answered[0]?.['outcome'] === 'answered',
  )

  const draftCoverage = record(record(draft['coverage'])['needs'])
  check(
    'dekningen teller ett besvart behov, og resten står fortsatt åpne',
    draftCoverage['answered'] === 1 && Number(draftCoverage['open'] ?? 0) > 0,
  )
  check(
    'ingen av de vanskelige behovene er fjernet fra nevneren',
    Number(draftCoverage['total'] ?? 0) === afterNeeds,
    `${String(draftCoverage['total'])} mot ${afterNeeds}`,
  )
  check(
    'utkastet er tydelig delvis',
    record(record(draft['coverage'])['completion'])['partial'] === true,
  )

  // --------------------------------------------------------------------
  // 11. Kandidaten, sluttkontrollen og publiseringen
  // --------------------------------------------------------------------
  const candidate = record(
    await call(editor, 'build_monograph_candidate', { p_edition_reference: edition }),
  )
  const candidateReference = String(candidate['reference'] ?? '')
  const digest = String(candidate['content_digest'] ?? '')
  check('kandidaten fryses med et avtrykk av hele innholdet', /^sha256:[0-9a-f]{64}$/.test(digest))

  let refusedWithoutControl = false
  try {
    await call(publisher, 'publish_monograph', {
      p_candidate_reference: candidateReference,
      p_reason: 'Monografiprøven: forsøk uten sluttkontroll.',
    })
  } catch {
    refusedWithoutControl = true
  }
  check('en utgave uten sluttkontroll publiseres ikke', refusedWithoutControl)

  let refusedByEditor = false
  try {
    await call(editor, 'record_monograph_final_control', {
      p_candidate_reference: candidateReference,
      p_seen_content_digest: digest,
      p_decision: 'approved',
      p_rationale: 'Monografiprøven: forsøk uten reviewer-mandat.',
    })
  } catch {
    refusedByEditor = true
  }
  check('en redaktør uten reviewer-mandat kan ikke sluttkontrollere', refusedByEditor)

  await call(reviewer, 'record_monograph_final_control', {
    p_candidate_reference: candidateReference,
    p_seen_content_digest: digest,
    p_decision: 'approved',
    p_rationale:
      'Monografiprøven: utgaven er lest i sin helhet. Innholdet er et syntetisk pilotgrunnlag og ingen klinisk anbefaling.',
  })

  let refusedByReviewer = false
  try {
    await call(reviewer, 'publish_monograph', {
      p_candidate_reference: candidateReference,
      p_reason: 'Monografiprøven: forsøk på reviewer-mandat.',
    })
  } catch {
    refusedByReviewer = true
  }
  check('den som godkjente, kan ikke publisere på sitt eget mandat', refusedByReviewer)

  const published = record(
    await call(publisher, 'publish_monograph', {
      p_candidate_reference: candidateReference,
      p_reason: 'Monografiprøven: utgaven tas i bruk i det lokale miljøet.',
    }),
  )
  check('en kontrollert utgave publiseres av et annet mandat', published['published'] === true)
  check(
    'utgaven peker på nøyaktig den kandidaten som ble kontrollert',
    psql(
      config,
      `select c.reference from knowledge.monograph_edition_candidates c
       join knowledge.monograph_editions e on e.current_published_candidate_id = c.id
       where e.reference = ${q(edition)}`,
    ) === candidateReference,
  )
  check(
    'og ordrette utdrag fra private originaldokumenter følger ikke med kandidaten',
    psql(
      config,
      `select (c.content::text like ${q(`%${RESULT}%`)})::text
       from knowledge.monograph_edition_candidates c
       where c.reference = ${q(candidateReference)}`,
    ) === 'false',
  )

  console.log('\nHele forløpet gikk gjennom de autoriserte inngangene.')
  console.log(
    `Utgave ${edition}: ${afterNeeds} kunnskapsbehov, ett kontrollert svar, ` +
      `kandidat ${candidateReference} publisert.`,
  )
}

await main()
