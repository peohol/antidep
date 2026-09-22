-- Migrasjon 013u — modellnavnet er proveniens, ikke adgangskontroll
--
-- 013t flyttet separasjonen mellom agentleddene fra modellidentitet til rolle og
-- kjøring. Ett sted ble igjen på den gamle regelen: importen av et eksternt
-- agentsvar krevde at svarets `identity` var *nøyaktig* den modellen rollen var
-- tildelt, og avviste svaret ellers.
--
-- Den kontrollen er nå prøvd i drift, og den gjorde det motsatte av det den så
-- ut til å gjøre. Den autonome Workspace Agent-en for `source_discovery` fikk
-- de tre første oppgavene avvist: tildelingen sa `gpt-5.6-sol`, agenten
-- rapporterte `GPT-5`, og begge var sanne. Plattformen forteller ikke en agent
-- hvilken modellvekt den kjører på — den viser navnet i menyen — og
-- `platform_model_disclosure = not_exposed` er nettopp det normaltilfellet
-- Antidep selv har sagt at det er.
--
-- ----------------------------------------------------------------------------
-- Hvorfor en likhetskontroll på modellnavn ikke er en sikkerhetsgrense
--
-- Fordi den ene siden av sammenligningen er noe modellen skriver selv. En
-- kontroll et svar kan bestå ved å skrive det Antidep vil se, kontrollerer
-- ingenting — den *lærer* bare den som skriver svaret, hvilken streng som er
-- nøkkelen inn. Og den koster: det eneste den faktisk avviser, er en agent som
-- svarer ærlig om et navn den ikke kan vite (ANTIDEP_CONSTITUTION.md regel 3).
--
-- Enda verre var utveien den framprovoserte. En agentinstruks som hardkodet
-- `gpt-5.6-sol` i svarmalen, ville fått kontrollen til å passere hver gang uten
-- å bevise noe som helst — og Antidep ville da registrert et modellnavn ingen
-- hadde observert, som proveniens. Det er den ene feilen som er verre enn å
-- mangle opplysningen (regel 4).
--
-- ----------------------------------------------------------------------------
-- Hva som blir stående, og som er de reelle grensene
--
--   * Tilkoblingen er bundet til ett agentledd. Rollen er tilkoblingens egen,
--     registrert av et menneske, og den er ingen parameter modellen kan sette.
--   * Hvert uttak er én oppgave i nettopp det leddet, og svaret leveres under
--     det uttaket. Et foreldet håndtak avvises før noe skrives.
--   * `request_digest` og de øvrige bindingsverdiene kontrolleres like strengt
--     som før, mot oppgaven slik databasen bygger den nå.
--   * Svaret går gjennom nøyaktig den samme autoritative skriveveien et
--     opplastet `svar.json` gjør. MCP-veien får ingen ny fullmakt.
--   * Egenverifikasjon er fortsatt forbudt: en kontroll kan ikke være den samme
--     kjøringen som laget det den kontrollerer, og ikke det samme
--     registreringsleddet. En dekningskontroll må fortsatt ha søkt selv.
--   * Tildelingen er fortsatt en attestert redaktøravgjørelse, den inngår i
--     bindingen, og et bytte gir hver utestående oppgave et nytt avtrykk.
--
-- Det som faller bort, er bare påstanden om at Antidep kan se hvilken modellvekt
-- som svarte. Den kunne det aldri.
--
-- ----------------------------------------------------------------------------
-- Hva proveniensen sier etterpå
--
-- `provenance.agent_runs.semantic_*` bærer nå den tildelte tjenesten — den
-- attesterte avgjørelsen om hvor arbeidet ble satt ut — og ikke lenger et
-- selvutsagn som var kontrollert mot den. Selvutsagnet tas vare på der det
-- hører hjemme: `input_manifest -> 'handoff' -> 'self_reported_identity'`,
-- merket som agentens eget ord, og `null` når plattformen ikke ga den noe å si.
-- Den formen er sannferdig begge veier, og ingen av delene er adgangskontroll.

-- ----------------------------------------------------------------------------
-- 1. Tildelingen kreves, svarets identitet sammenlignes ikke
--
-- Funksjonen gjorde to ting: krevde at rollen hadde en semantisk tildeling, og
-- sammenlignet svarets identitet med den. Det første er en reell forutsetning —
-- et ledd uten tildeling har ingen semantisk proveniens å registrere kjøringen
-- med. Det andre er regelen som fjernes.
--
-- Parameteren forsvinner derfor med sammenligningen. En ubrukt jsonb-parameter
-- ville sett ut som en kontroll som fortsatt fantes.
-- ----------------------------------------------------------------------------
drop function provenance.require_semantic_model_assignment(provenance.agent_role, jsonb);

create function provenance.require_semantic_model_assignment(
  p_agent_role provenance.agent_role
)
  returns provenance.role_model_assignments
  language plpgsql
  stable
  set search_path = ''
as $$
declare
  v_current provenance.role_model_assignments;
begin
  v_current := provenance.current_semantic_model(p_agent_role);

  if v_current.id is null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Ingen KI-tjeneste er tildelt agentleddet %L, og et svar kan ikke registreres.',
        p_agent_role
      ),
      hint = 'Hvilken tjeneste et ledd settes ut til, er en avgjørelse den som eier innholdet tar på forhånd, og den er den semantiske proveniensen kjøringen registreres med. Velg tjenesten for leddet med api.assign_agent_role_model(...) og hent oppgaven på nytt (ANTIDEP_CONSTITUTION.md regel 3).';
  end if;

  return v_current;
end;
$$;

comment on function provenance.require_semantic_model_assignment(provenance.agent_role) is
  'Krever at agentleddet har en gyldig semantisk modelltildeling før et eksternt agentsvar kan registreres, og registrerer ingenting (ANTIDEP_CONSTITUTION.md regel 3). Tildelingen er en attestert redaktøravgjørelse om hvilken tjeneste leddet settes ut til, tatt før oppgaven hentes ut, og den er den semantiske proveniensen kjøringen føres med. Fra migrasjon 013u sammenlignes den IKKE med identiteten svaret oppgir om seg selv: den ene siden av en slik sammenligning er noe modellen skriver selv, så den kan bestås ved å skrive det Antidep vil se, og det eneste den faktisk avviser er en agent som svarer ærlig om et navn plattformen ikke lar den vite. Modellnavnet er proveniens, ikke adgangskontroll.';

revoke execute on function provenance.require_semantic_model_assignment(provenance.agent_role) from public;

-- ----------------------------------------------------------------------------
-- 2. Importen: selvutsagnet er valgfritt, og det kontrolleres ikke mot noe
--
-- Den ene autoritative skriveveien for et eksternt agentsvar, uendret bortsett
-- fra identitetsleddet. Den manuelle opplastingen og den autonome MCP-kjøreren
-- går begge gjennom den, og skal derfor ha den samme regelen: en redaktør som
-- limer inn fra et chatvindu, har nøyaktig den samme opplysningen som agenten
-- selv — modellens eget ord.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION workflow.record_agent_handoff_answer(p_pipeline_job_id uuid, p_answer jsonb, p_actor_id uuid, p_runner_connection_id uuid, p_lease_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_actor_id uuid;
  v_attempt integer;
  v_job workflow.pipeline_jobs;
  v_problem text;
  v_task jsonb;
  v_binding jsonb;
  v_input jsonb;
  v_answer_digest text;
  v_existing workflow.agent_handoff_imports;
  v_identity jsonb;
  v_self_identity jsonb;
  v_hashed_answer jsonb;
  v_provider text;
  v_model text;
  v_model_version text;
  v_disclosure provenance.model_version_disclosure;
  v_answered_at timestamptz;
  v_result jsonb;
  v_unknown text;
  v_agent_identity provenance.agent_identities;
  v_agent_actor_id uuid;
  v_registration provenance.role_model_assignments;
  v_semantic provenance.role_model_assignments;
  v_lease uuid;
  v_run_id uuid;
  v_outcome jsonb;
  v_extraction jsonb;
  v_claim jsonb;
  v_assessment jsonb;
  v_evidence_item_id uuid;
  v_ids uuid[];
  v_id uuid;
begin
  -- Kalleren har allerede fastslått hvem dette er: en redaktør med mandat i den
  -- manuelle veien, eller den registrerte kjørertilkoblingens egen registrant i
  -- den autonome. Autentiseringen hører i api-funksjonen, arbeidet her.
  v_actor_id := p_actor_id;

  select j.* into v_job
  from workflow.pipeline_jobs j
  where j.id = p_pipeline_job_id
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = format('Det finnes ingen agentoppgave med id %L.', p_pipeline_job_id);
  end if;

  -- ------------------------------------------------------------------
  -- Gjentakelsen først, før alt annet
  --
  -- Det samme svaret sendt inn igjen — et dobbeltklikk, en gjenopptatt
  -- økt — skal svare med det som allerede ble registrert, framfor å lage
  -- et nytt klinisk objekt. Et *annet* svar på en jobb som allerede er
  -- besvart, er ikke en gjentakelse, og avvises.
  --
  -- Avtrykket tas av svaret slik kontrakten leser det, og ikke slik det tilfeldig
  -- ble serialisert. Kontrakten sier at et utelatt `identity` og `identity: null`
  -- er den samme opplysningen (se «Hvem som svarte» under), og da må de være det
  -- samme svaret også her. Ellers ville et nytt forsøk som skrev den andre av de
  -- to formene, blitt lest som «et annet svar på en besvart oppgave» og avvist —
  -- og gjentakelsesregelen ville sviktet nøyaktig der den finnes for å holde:
  -- ved et nytt forsøk fra en modell som ikke gjentar seg ordrett.
  --
  -- Kanoniseringen dekker de likhetene kontrakten selv erklærer, og bare dem.
  -- Et selvutsagn som *finnes*, er en del av svaret: to forskjellige selvutsagn
  -- er to forskjellige svar.
  --
  -- Ett tilfelle holdes bevisst utenfor: `answered_at` leses som et tidspunkt,
  -- så «...Z» og «...+00:00» er det samme øyeblikket — men å normalisere dem
  -- ville måttet rendre en timestamptz tilbake til tekst, og den rendringen
  -- følger sesjonens TimeZone. Da ville det samme svaret fått forskjellig
  -- avtrykk i to sesjoner, som er verre enn det dette retter.
  v_hashed_answer := p_answer;

  -- Et utelatt felt og et felt som er JSON null, er den samme opplysningen for
  -- begge de to valgfrie feltene. Parseren på flaten leser dem likt, og da må
  -- avtrykket gjøre det også.
  if jsonb_typeof(v_hashed_answer -> 'identity') = 'null' then
    v_hashed_answer := v_hashed_answer - 'identity';
  end if;
  if jsonb_typeof(v_hashed_answer -> 'answered_at') = 'null' then
    v_hashed_answer := v_hashed_answer - 'answered_at';
  end if;

  -- Inne i et selvutsagn erklærer kontrakten to likheter til: en utelatt
  -- eksponeringsgrad er «exact», og en utelatt versjon under «not_exposed» er
  -- den kanoniske verdien. Begge går gjennom den ene funksjonen som eier den
  -- lesningen, slik at avtrykket og kontrollen ikke kan bli uenige om hva som
  -- er det samme selvutsagnet.
  --
  -- Et selvutsagn som ikke lar seg kanonisere, hashes som det er. Det er
  -- ugyldig og blir avvist av kontrollen lenger nede, med den setningen som
  -- forklarer hva som er galt — og den feilen skal meldes der, ikke som en
  -- avvikende gjentakelse her.
  if jsonb_typeof(v_hashed_answer -> 'identity') = 'object' then
    begin
      v_hashed_answer := jsonb_set(
        v_hashed_answer,
        '{identity}',
        provenance.canonical_model_identity(
          v_hashed_answer -> 'identity' ->> 'provider',
          v_hashed_answer -> 'identity' ->> 'model',
          v_hashed_answer -> 'identity' ->> 'model_version',
          coalesce(v_hashed_answer -> 'identity' ->> 'model_version_disclosure', 'exact')
        )
      );
    exception
      when others then
        null;
    end;
  end if;

  v_answer_digest := 'sha256:' || encode(sha256(convert_to(v_hashed_answer::text, 'UTF8')), 'hex');

  select i.* into v_existing
  from workflow.agent_handoff_imports i
  where i.pipeline_job_id = p_pipeline_job_id;

  if found then
    if v_existing.answer_digest = v_answer_digest then
      return jsonb_build_object(
        'imported', false,
        'already_imported', true,
        'delivered_by', case when v_existing.runner_connection_id is null
                             then 'manual' else 'autonomous_runner' end,
        'pipeline_job_id', p_pipeline_job_id,
        'agent_role', v_existing.agent_role::text,
        'agent_run_id', v_existing.agent_run_id,
        'outcome', v_existing.outcome
      );
    end if;
    raise exception using
      errcode = 'unique_violation',
      message = 'Denne agentoppgaven har allerede tatt imot et annet svar.',
      hint = 'Ett svar per oppgave. To svar ville gitt to kliniske objekter for det samme arbeidet, og ingen ville kunnet si hvilket som gjaldt (ANTIDEP_CONSTITUTION.md regel 4). Skal arbeidet gjøres om igjen, er det en ny oppgave.';
  end if;

  if v_job.state = 'succeeded' then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Agentoppgaven er allerede fullført.',
      hint = 'Jobben har et registrert utfall fra før. Skal arbeidet gjøres om igjen, er det en ny oppgave.';
  end if;
  -- Uttaket, før alt annet som handler om jobbens tilstand.
  --
  -- Den manuelle veien tar selv et uttak, som før. Den autonome kommer med et
  -- uttak den allerede holder, og det uttaket er svarets eneste adgangstegn: et
  -- håndtak som ikke er jobbens gjeldende leie, er et foreldet svar fra en
  -- kjøring som er overtatt eller har løpt ut, og det skal avvises før noe
  -- skrives (ANTIDEP_CONSTITUTION.md regel 4, 7).
  if p_lease_token is not null then
    if v_job.state <> 'leased'
       or v_job.lease_token is distinct from p_lease_token
       or v_job.lease_expires_at is null
       or v_job.lease_expires_at <= statement_timestamp() then
      raise exception using
        errcode = 'restrict_violation',
        message = 'Uttaket dette svaret ble gjort under, gjelder ikke lenger.',
        hint = 'Leien er løpt ut eller overtatt av en annen kjøring. Hent arbeid på nytt framfor å levere et svar på et uttak som ikke er ditt; et svar fra et foreldet uttak ville kunnet skrive over arbeidet en annen kjøring nettopp gjorde.';
    end if;
    v_attempt := v_job.attempts;
    v_lease := p_lease_token;
  else
    if v_job.attempts >= v_job.max_attempts then
      raise exception using
        errcode = 'restrict_violation',
        message = 'Agentoppgaven har brukt opp forsøkene sine og blir stående.',
        hint = 'En oppbrukt jobb skal ikke se ut som en jobb som fortsatt er underveis (ANTIDEP_CONSTITUTION.md regel 4). Legg inn oppgaven på nytt dersom den skal forsøkes igjen.';
    end if;
    v_attempt := v_job.attempts + 1;
    v_lease := gen_random_uuid();
  end if;

  v_problem := workflow.agent_task_problem(v_job, p_lease_token);
  if v_problem is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = v_problem;
  end if;

  -- ------------------------------------------------------------------
  -- Formen på svaret, og bindingen
  -- ------------------------------------------------------------------
  if p_answer is null or jsonb_typeof(p_answer) <> 'object' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Svaret er ikke et JSON-objekt.';
  end if;

  select string_agg(quote_literal(k.value), ', ' order by k.value) into v_unknown
  from jsonb_object_keys(p_answer) as k(value)
  where k.value not in (
    'answer_version', 'task_version', 'role', 'job_key', 'request_digest',
    'output_schema_version', 'identity', 'answered_at', 'result'
  );
  if v_unknown is not null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Svaret har felter denne kontrakten ikke kjenner: %s.', v_unknown),
      hint = 'Ukjente felter avvises framfor å ignoreres: et felt med skrivefeil ville ellers sett ut som en utelatt opplysning, og et felt ingen leser, ville vært en påstand uten virkning.';
  end if;

  v_task := workflow.agent_task(v_job);
  v_binding := v_task -> 'binding';
  v_input := v_binding -> 'input';

  if p_answer ->> 'answer_version' is distinct from workflow.agent_handoff_answer_version() then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Svaret er skrevet mot %L, men Antidep leser %L.',
        p_answer ->> 'answer_version', workflow.agent_handoff_answer_version());
  end if;
  if p_answer ->> 'task_version' is distinct from workflow.agent_handoff_task_version() then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Svaret gjelder oppgaveformen %L, men denne oppgaven er %L.',
        p_answer ->> 'task_version', workflow.agent_handoff_task_version());
  end if;
  if p_answer ->> 'role' is distinct from v_job.agent_role::text then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Svaret er avgitt i rollen %L, mens oppgaven gjelder rollen %L.',
        p_answer ->> 'role', v_job.agent_role::text),
      hint = 'Rollen avgjør hva svaret får lov til å registrere. Et svar fra ett ledd skal ikke kunne lukkes inn i et annet.';
  end if;
  if p_answer ->> 'job_key' is distinct from v_job.job_key then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Svaret gjelder en annen agentoppgave enn den det importeres på.';
  end if;
  if p_answer ->> 'output_schema_version' is distinct from (v_task ->> 'output_schema_version') then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Svaret er skrevet mot svarformen %L, mens oppgaven krever %L.',
        p_answer ->> 'output_schema_version', v_task ->> 'output_schema_version');
  end if;
  if p_answer ->> 'request_digest' is distinct from (v_task ->> 'request_digest') then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format(
        'Svaret er avgitt på forespørselen %s, mens oppgaven nå er %s.',
        coalesce(p_answer ->> 'request_digest', '(mangler)'), v_task ->> 'request_digest'),
      hint = 'Avtrykket dekker rollen, oppgaven, promptmalen, svarformen og hele grunnlaget oppgaven ble bygget av. Er noe av det endret siden oppgaven ble hentet ut, gjelder ikke det gamle svaret lenger. Hent oppgaven på nytt og be om et nytt svar (ANTIDEP_CONSTITUTION.md regel 2, 4).';
  end if;

  v_result := p_answer -> 'result';
  if v_result is null or jsonb_typeof(v_result) <> 'object' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Svaret har ingen result som er et JSON-objekt.';
  end if;

  -- ------------------------------------------------------------------
  -- Hvem som svarte
  --
  -- Modellnavnet er proveniens, ikke adgangskontroll.
  --
  -- Hvilken KI-tjeneste leddet settes ut til, er redaktørens attesterte
  -- tildeling. Den er tatt på forhånd, den ligger i bindingen avtrykket er
  -- regnet av, og det er den som registreres på kjøringen. Svarets egen
  -- `identity` er noe annet: agentens eget ord om seg selv, lagt ved når
  -- plattformen faktisk viser den hvilken modell den kjører.
  --
  -- Fram til migrasjon 013u ble de to sammenlignet, og et avvik avviste
  -- svaret. Den kontrollen er borte, fordi den ikke kunne gjøre det den så ut
  -- til å gjøre. En ChatGPT Workspace Agent får ikke vite hvilken modellvekt
  -- den kjører på; den rapporterer det menyen kaller den. Tildelingen sier
  -- «gpt-5.6-sol», svaret sier «GPT-5», og begge er sanne. Likhetskontrollen
  -- avviste da nøyaktig de svarene som var riktige — og det den lærte agenten,
  -- var at én bestemt streng er nøkkelen inn. Et navn en modell kan skrive
  -- selv, er ingen grense: den eneste måten å bestå på var å skrive det
  -- Antidep ville se, og en kontroll som består på den måten, har ikke
  -- kontrollert noe (ANTIDEP_CONSTITUTION.md regel 3).
  --
  -- Det som faktisk holder leddene fra hverandre, står urørt: rollen er
  -- tilkoblingens og ikke noe modellen velger, ett uttak gjelder ett agentledd,
  -- hver kjøring er sin egen, request_digest binder svaret til nøyaktig ett
  -- grunnlag, og en kontroll kan ikke være den samme kjøringen som laget det
  -- den kontrollerer.
  --
  -- Formen på et vedlagt selvutsagn kontrolleres fortsatt: en versjon under
  -- not_exposed, eller «exact» uten versjon, er en usann proveniens uansett
  -- hvem som skrev den. Det er en formkontroll og ikke en adgangskontroll —
  -- den avviser et selvmotsigende utsagn, aldri et bestemt modellnavn.
  -- ------------------------------------------------------------------
  v_identity := p_answer -> 'identity';
  -- Et utelatt felt og `identity: null` er den samme opplysningen: plattformen
  -- ga ingen runtime-modellidentitet. Å skille dem ville vært en forskjell uten
  -- innhold, og ville tvunget agenten til å velge mellom to former for taushet.
  if v_identity is not null and jsonb_typeof(v_identity) = 'null' then
    v_identity := null;
  end if;

  if v_identity is not null then
    if jsonb_typeof(v_identity) <> 'object' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'identity er ikke et JSON-objekt.',
        hint = 'Feltet er valgfritt. Viser plattformen deg ingen modell, utelat det framfor å skrive noe annet enn et objekt i det. Gjett aldri (ANTIDEP_CONSTITUTION.md regel 4).';
    end if;

    select string_agg(quote_literal(k.value), ', ' order by k.value) into v_unknown
    from jsonb_object_keys(v_identity) as k(value)
    where k.value not in ('provider', 'model', 'model_version', 'model_version_disclosure');
    if v_unknown is not null then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('identity har felter denne kontrakten ikke kjenner: %s.', v_unknown);
    end if;

    -- Den samme lesningen tildelingen ble gjort med, slik at et selvutsagn og
    -- en tildeling står på den samme formen og kan leses ved siden av hverandre.
    -- Standardverdien er «exact», som på flaten (`model-identity.ts`): et
    -- selvutsagn skrevet før eksponeringsgraden fantes, leses som det det var —
    -- en erklæring om en versjon noen faktisk oppga. Uten coalesce her ville
    -- databasen lest et utelatt felt som ingen eksponeringsgrad i det hele tatt,
    -- og de to sidene vært uenige om den samme filen.
    v_self_identity := provenance.canonical_model_identity(
      v_identity ->> 'provider',
      v_identity ->> 'model',
      v_identity ->> 'model_version',
      coalesce(v_identity ->> 'model_version_disclosure', 'exact')
    );
  end if;

  -- Tildelingen er fortsatt påkrevd, og det er ikke den gamle regelen i ny
  -- form: den kontrollerer ingenting ved svaret, og et svar kan ikke bestå
  -- eller stryke på den. Den er redaktørens avgjørelse om hvilken tjeneste
  -- leddet settes ut til — tatt før oppgaven hentes ut, en del av bindingen, og
  -- den semantiske proveniensen kjøringen registreres med. Et ledd uten den
  -- ville tatt imot arbeid ingen hadde tatt stilling til, og kjøringen ville
  -- stått uten en semantisk modell i det hele tatt.
  v_semantic := provenance.require_semantic_model_assignment(v_job.agent_role);
  v_provider := v_semantic.provider;
  v_model := v_semantic.model;
  v_model_version := v_semantic.model_version;
  v_disclosure := v_semantic.model_version_disclosure;

  if p_answer ->> 'answered_at' is not null then
    begin
      v_answered_at := (p_answer ->> 'answered_at')::timestamptz;
    exception
      when others then
        raise exception using
          errcode = 'invalid_parameter_value',
          message = format('answered_at er %L, som ikke er et tidspunkt.', p_answer ->> 'answered_at');
    end;

    -- Et svar kan ikke være avgitt i framtiden. Slakken finnes fordi agenten
    -- kjører på en annen maskin med en annen klokke, og et tidspunkt avrundet
    -- til nærmeste minutt ikke er en usann påstand; uten den ville en riktig
    -- import blitt stoppet av tre sekunder, og kontrollen blitt skrudd av
    -- framfor fulgt. Samme regel og samme slakk som i den filbaserte kjøringen.
    if v_answered_at > statement_timestamp() + interval '5 minutes'
       or v_answered_at < v_job.enqueued_at - interval '5 minutes' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format(
          'answered_at er %L, som ligger utenfor oppgaven: den ble lagt inn %L og importeres nå.',
          v_answered_at, v_job.enqueued_at
        ),
        hint = 'Tidspunktet registreres som da agenten svarte. Et svar avgitt før oppgaven fantes, eller inn i framtiden, er ikke en unøyaktighet — det er en usann proveniens (ANTIDEP_CONSTITUTION.md regel 4). La feltet stå tomt om du er usikker.';
    end if;
  end if;

  -- ------------------------------------------------------------------
  -- Uttaket og kjøringen
  --
  -- Importen gjør det en kjører ville gjort: tar ut jobben med en leie i
  -- rollens egen agentidentitet, åpner kjøringen for nettopp det uttaket, og
  -- melder utfallet. Da gjelder de samme bindingene og de samme reglene som
  -- for et automatisert ledd — inkludert at kjøringen ikke kan gjenbrukes på
  -- en annen jobb.
  -- ------------------------------------------------------------------
  select ai.* into v_agent_identity
  from provenance.agent_identities ai
  where ai.agent_role = v_job.agent_role
    and ai.valid_from <= statement_timestamp()
    and (ai.valid_to is null or ai.valid_to > statement_timestamp())
  order by ai.valid_from
  limit 1;

  if v_agent_identity.id is null then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Rollen %L har ingen gyldig agentidentitet å registrere kjøringen under.', v_job.agent_role);
  end if;
  v_agent_actor_id := v_agent_identity.actor_id;

  v_registration := provenance.current_role_model(v_job.agent_role);
  if v_registration.id is null then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Rollen %L har ingen gyldig modelltildeling for registreringsleddet.', v_job.agent_role);
  end if;

  -- Den manuelle veien tar uttaket her; den autonome tok det da den hentet
  -- arbeidet, og skal ikke ta det en gang til — et nytt uttak ville talt et
  -- forsøk som aldri fant sted, og byttet ut nøkkelen midt i sitt eget svar.
  if p_lease_token is null then
    update workflow.pipeline_jobs
    set state = 'leased',
        attempts = v_attempt,
        leased_by_agent_identity_id = v_agent_identity.id,
        lease_expires_at = statement_timestamp() + interval '15 minutes',
        lease_token = v_lease,
        -- Uttaket er et menneskes. Sto det en kjører på raden fra et uttak som
        -- rakk å løpe ut, er den ikke lenger holderen, og skal ikke bli stående
        -- som om den var det.
        runner_connection_id = null,
        -- En jobb som sto som failed, bærer et fullføringstidspunkt. Uttaket er
        -- et nytt forsøk, og et forsøk som pågår, er ikke fullført.
        completed_at = null
    where id = v_job.id;

    perform workflow.record_pipeline_job_event(
      v_job.id, v_job.state, 'leased'::workflow.pipeline_job_state,
      v_attempt, v_actor_id, null,
      'Uttak for import av et eksternt agentsvar.'
    );
  end if;

  insert into provenance.agent_runs (
    agent_identity_id, actor_id, agent_role,
    provider, model, model_version, model_version_disclosure,
    semantic_provider, semantic_model, semantic_model_version,
    semantic_model_version_disclosure,
    prompt_template_version, pipeline_version,
    status, input_manifest, input_source_version_id
  )
  values (
    v_agent_identity.id, v_agent_actor_id, v_job.agent_role,
    v_registration.provider, v_registration.model, v_registration.model_version,
    v_registration.model_version_disclosure,
    v_provider, v_model, v_model_version, v_disclosure,
    v_task ->> 'prompt_template_version', 'antidep-evidence/1',
    'running',
    jsonb_build_object('handoff', jsonb_build_object(
      'task_version', v_task ->> 'task_version',
      'answer_version', v_task ->> 'answer_version',
      'request_digest', v_task ->> 'request_digest',
      'output_schema_version', v_task ->> 'output_schema_version',
      'answer_digest', v_answer_digest,
      'answered_at', v_answered_at,
      'imported_by_actor_id', v_actor_id,
      'binding', v_binding,
      -- Agentens eget ord om seg selv, når plattformen ga den noe å si. NULL er
      -- den sanne verdien når den ikke gjorde det, og ikke en mangel som skjules.
      'self_reported_identity', v_self_identity
    )),
    case when v_job.agent_role = 'evidence_extraction'
         then (v_input ->> 'source_version_id')::uuid end
  )
  returning id into v_run_id;

  insert into workflow.pipeline_job_runs (agent_run_id, pipeline_job_id, lease_token, attempt)
  values (v_run_id, v_job.id, v_lease, v_attempt);

  -- ------------------------------------------------------------------
  -- Arbeidet, gjennom de samme skriveveiene som agentkjørerne bruker
  -- ------------------------------------------------------------------
  if v_job.agent_role = 'evidence_extraction' then
    v_extraction := v_result -> 'extraction';
    if v_extraction is null or jsonb_typeof(v_extraction) <> 'object' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret har ingen extraction som er et JSON-objekt.';
    end if;

    -- Katalogen er redaktørens avgrensning, og modellen velger innenfor den.
    -- En id utenfor oppgaven ville flyttet funnet til et annet virkestoff eller
    -- et naboendepunkt, og den ordrette kontrollen kontrollerer utdrag — ikke
    -- avgrensning.
    v_ids := workflow.manifest_uuids(v_input, 'drug_ids');
    v_id := workflow.manifest_uuid(v_extraction, 'intervention_drug_id');
    if v_id is null or not (v_id = any (v_ids)) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret oppgir et virkestoff som ikke står blant virkestoffene i oppgaven.';
    end if;
    v_id := workflow.manifest_uuid(v_extraction, 'comparator_drug_id');
    if v_extraction ->> 'comparator_drug_id' is not null and (v_id is null or not (v_id = any (v_ids))) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret oppgir et komparatorvirkestoff som ikke står blant virkestoffene i oppgaven.';
    end if;
    v_ids := workflow.manifest_uuids(v_input, 'outcome_concept_ids');
    v_id := workflow.manifest_uuid(v_extraction, 'outcome_concept_id');
    if v_id is null or not (v_id = any (v_ids)) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret oppgir et endepunkt som ikke står blant endepunktene i oppgaven.';
    end if;
    v_ids := coalesce(workflow.manifest_uuids(v_input, 'population_ids'), array[]::uuid[]);
    v_id := workflow.manifest_uuid(v_extraction, 'population_id');
    if v_extraction ->> 'population_id' is not null and (v_id is null or not (v_id = any (v_ids))) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret oppgir en populasjon som ikke står blant populasjonene i oppgaven.';
    end if;

    v_evidence_item_id := knowledge.record_evidence_item(
      (v_input ->> 'source_id')::uuid,
      v_extraction ->> 'design_code',
      v_extraction ->> 'population_availability',
      v_extraction ->> 'population_detail',
      v_extraction ->> 'sample_size_availability',
      (v_extraction ->> 'intervention_drug_id')::uuid,
      v_extraction ->> 'comparator_kind',
      (v_extraction ->> 'outcome_concept_id')::uuid,
      v_extraction ->> 'outcome_detail',
      v_extraction ->> 'timepoint_availability',
      v_extraction ->> 'reported_direction',
      v_extraction ->> 'estimate_availability',
      v_extraction ->> 'confidence_interval_availability',
      v_extraction ->> 'source_locator',
      (v_input ->> 'source_version_id')::uuid,
      workflow.manifest_uuid(v_extraction, 'population_id'),
      (v_extraction ->> 'sample_size')::integer,
      v_extraction ->> 'intervention_detail',
      workflow.manifest_uuid(v_extraction, 'comparator_drug_id'),
      v_extraction ->> 'comparator_detail',
      v_extraction ->> 'timepoint_min',
      v_extraction ->> 'timepoint_max',
      v_extraction ->> 'effect_measure',
      (v_extraction ->> 'estimate')::numeric,
      v_extraction ->> 'estimate_unit',
      (v_extraction ->> 'ci_lower')::numeric,
      (v_extraction ->> 'ci_upper')::numeric,
      (v_extraction ->> 'ci_level_percent')::numeric,
      v_extraction ->> 'limitations_text',
      v_extraction ->> 'source_quote',
      v_result -> 'field_groundings',
      'ai_assisted',
      v_agent_actor_id,
      v_run_id
    );

    perform workflow.assert_extraction_fully_grounded(v_evidence_item_id);
    v_outcome := jsonb_build_object('evidence_item_id', v_evidence_item_id);

  elsif v_job.agent_role = 'claim_synthesis' then
    v_claim := v_result -> 'claim';
    if v_claim is null or jsonb_typeof(v_claim) <> 'object' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret har ingen claim som er et JSON-objekt.';
    end if;

    -- Evidenssettet er oppgavens, ikke svarets. En lenke til et funn utenfor
    -- oppgaven ville gitt en påstand som hvilte på noe ingen hadde avgrenset.
    if exists (
      select 1
      from jsonb_array_elements(coalesce(v_result -> 'evidence_links', '[]'::jsonb)) as link(value)
      where workflow.manifest_uuid(link.value, 'evidence_item_id') is null
         or not (workflow.manifest_uuid(link.value, 'evidence_item_id') = any (
              select (e.value ->> 'evidence_item_id')::uuid
              from jsonb_array_elements(v_input -> 'evidence') as e(value)))
    ) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret lenker til et evidensfunn som ikke står i oppgaven.',
        hint = 'Hvilke funn en syntese kan bygge på, er en faglig avgrensning som ligger i oppgaven. En modell som fikk velge fritt, ville kunnet bygge påstanden på noe ingen hadde tatt stilling til.';
    end if;

    -- Og hele settet, ikke en delmengde av det. Et svar som utelot et funn som
    -- MOTSIER påstanden, ville gitt en syntese som hvilte på et annet grunnlag
    -- enn det redaktøren avgrenset — og uenigheten ville vært borte uten at noe
    -- i kjeden sa fra (ANTIDEP_CONSTITUTION.md regel 4).
    if exists (
      select 1
      from jsonb_array_elements(v_input -> 'evidence') as assigned(value)
      where not exists (
        select 1
        from jsonb_array_elements(coalesce(v_result -> 'evidence_links', '[]'::jsonb)) as link(value)
        where link.value ->> 'evidence_item_id' = assigned.value ->> 'evidence_item_id'
      )
    ) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret dekker ikke alle evidensfunnene oppgaven avgrenset.',
        hint = 'Hvert funn i oppgaven skal ha en relasjon til påstanden — også et funn som motsier den, som da føres som contradicts. Et utelatt funn ville gjort grunnlaget til et annet enn det som finnes.';
    end if;

    -- Populasjonen er redaktørens avgrensning, som katalogen i et
    -- ekstraksjonsoppdrag. En id kopiert ut av dossieret ville passert
    -- fremmednøkkelen og flyttet påstanden til en annen populasjon.
    v_ids := coalesce(workflow.manifest_uuids(v_input, 'population_ids'), array[]::uuid[]);
    v_id := workflow.manifest_uuid(v_claim, 'population_id');
    if v_claim ->> 'population_id' is not null and (v_id is null or not (v_id = any (v_ids))) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret oppgir en populasjon som ikke står blant populasjonene i oppgaven.';
    end if;

    v_outcome := knowledge.record_agent_claim_synthesis(
      v_run_id,
      v_agent_actor_id,
      (v_input ->> 'topic_concept_id')::uuid,
      (v_input ->> 'subject_drug_id')::uuid,
      v_claim ->> 'statement',
      v_claim ->> 'scope',
      v_claim ->> 'comparator_kind',
      v_claim ->> 'uncertainty_summary',
      v_result -> 'evidence_links',
      workflow.manifest_uuid(v_input, 'claim_id'),
      workflow.manifest_uuid(v_claim, 'population_id'),
      v_claim ->> 'timeframe_min',
      v_claim ->> 'timeframe_max',
      workflow.manifest_uuid(v_claim, 'comparator_drug_id'),
      v_claim ->> 'direction',
      v_claim ->> 'magnitude_measure',
      (v_claim ->> 'magnitude_value')::numeric,
      v_claim ->> 'magnitude_unit',
      v_claim ->> 'qualifiers'
    );

  elsif v_job.agent_role = 'monograph_answer' then
    v_outcome := workflow.record_monograph_answer_handoff(
      v_job, v_input, v_result, v_run_id, v_agent_actor_id);

  elsif v_job.agent_role in ('source_discovery', 'source_quality_assessment') then
    v_outcome := workflow.record_monograph_discovery_answer(
      v_job, v_input, v_result, v_run_id, v_agent_actor_id);

  elsif v_job.agent_role = 'evidence_assessment' then
    v_assessment := v_result -> 'assessment';
    if v_assessment is null or jsonb_typeof(v_assessment) <> 'object' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret har ingen assessment som er et JSON-objekt.';
    end if;

    v_outcome := knowledge.record_evidence_assessment_row(
      v_run_id,
      v_agent_actor_id,
      (v_input ->> 'claim_revision_id')::uuid,
      -- Avtrykket av evidenssettet er oppgavens eget, ikke svarets: oppgaven
      -- viste nøyaktig det settet, og request_digest dekker det allerede. En
      -- verdi fra svaret ville vært en påstand om hva agenten så.
      v_input ->> 'evidence_set_digest',
      v_assessment ->> 'framework',
      v_assessment ->> 'certainty_level',
      v_assessment ->> 'rationale',
      v_assessment ->> 'risk_of_bias',
      v_assessment ->> 'inconsistency',
      v_assessment ->> 'indirectness',
      v_assessment ->> 'imprecision',
      v_assessment ->> 'publication_bias',
      v_assessment ->> 'other_considerations',
      v_assessment ->> 'evidence_gap'
    );

  else
    -- Uttømmende over rollene. En rolle uten en gren ville ellers fått
    -- oppgaven registrert som fullført uten at noe klinisk arbeid ble skrevet.
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Rollen %s har ingen skrivevei for et eksternt agentsvar.',
                       v_job.agent_role);
  end if;

  -- ------------------------------------------------------------------
  -- Utfallet
  -- ------------------------------------------------------------------
  update provenance.agent_runs
  set status = 'succeeded', completed_at = now(), output_manifest = v_outcome
  where id = v_run_id;

  update workflow.pipeline_jobs
  set state = 'succeeded',
      agent_run_id = v_run_id,
      output_manifest = v_outcome,
      completed_at = now(),
      failure_reason = null
  where id = v_job.id;

  perform workflow.record_pipeline_job_event(
    v_job.id, 'leased'::workflow.pipeline_job_state, 'succeeded'::workflow.pipeline_job_state,
    v_attempt, v_actor_id, null,
    case when p_runner_connection_id is null
      then 'Eksternt agentsvar importert og registrert.'
      else 'Eksternt agentsvar levert av en autonom kjører og registrert.' end
  );

  insert into workflow.agent_handoff_imports (
    pipeline_job_id, agent_role, request_digest, answer_digest,
    agent_run_id, imported_by_actor_id, answered_at, outcome,
    runner_connection_id
  )
  values (
    v_job.id, v_job.agent_role, v_task ->> 'request_digest', v_answer_digest,
    v_run_id, v_actor_id, v_answered_at, v_outcome,
    p_runner_connection_id
  );

  return jsonb_build_object(
    'imported', true,
    'already_imported', false,
    'delivered_by', case when p_runner_connection_id is null then 'manual' else 'autonomous_runner' end,
    'pipeline_job_id', v_job.id,
    'agent_role', v_job.agent_role::text,
    'agent_run_id', v_run_id,
    'request_digest', v_task ->> 'request_digest',
    'model', jsonb_build_object(
      'provider', v_provider, 'model', v_model,
      'model_version', v_model_version,
      'model_version_disclosure', v_disclosure::text),
    'self_reported_model', v_self_identity,
    'outcome', v_outcome
  );
end;
$function$;

-- ----------------------------------------------------------------------------
-- 3. Kommentarene som beskrev den gamle regelen
--
-- En merget migrasjon redigeres aldri (AGENTS.md), så kommentarene settes på
-- nytt her. En kommentar som beskriver en kontroll som ikke lenger finnes, er
-- verre enn ingen kommentar: den er stedet den neste som leser databasen, får
-- vite hva en regel er til for.
-- ----------------------------------------------------------------------------
comment on column provenance.agent_runs.semantic_provider is
  'Leverandøren av den eksterne KI-tjenesten kjøringens agentledd var satt ut til, eller NULL når ingen ekstern modell var involvert. Fra migrasjon 013u er dette den attesterte tildelingen (provenance.role_model_assignments, capacity = semantic) og ikke et selvutsagn fra svaret: en modell får ikke vite hvilken modellvekt den kjører på, så et selvutsagn kunne verken kontrolleres eller kreves. Agentens eget ord om seg selv, når plattformen ga den noe å si, står i input_manifest -> handoff -> self_reported_identity, merket som nettopp det.';
comment on column provenance.agent_runs.semantic_model is
  'Modellnavnet i den attesterte tildelingen for agentleddet kjøringen hører til, eller NULL. Navnet er det redaktøren registrerte da leddet ble satt ut, og Antidep finner ikke på et internt navn på vegne av en leverandør. Fra migrasjon 013u er navnet proveniens og aldri adgangskontroll: et svar sammenlignes ikke med det, fordi den ene siden av en slik sammenligning er noe modellen skriver selv (ANTIDEP_CONSTITUTION.md regel 3).';
comment on column provenance.agent_runs.semantic_model_version is
  'Den eksakte versjonen i den attesterte tildelingen, eller den kanoniske «ikke-eksponert» når tjenesten ikke oppgir noen. Aldri en gjetning: en oppdiktet versjon ville sett like troverdig ut som en sann.';
comment on column provenance.agent_runs.semantic_model_version_disclosure is
  'Om semantic_model_version er en oppgitt versjon eller den kanoniske «ikke-eksponert». Settes sammen med de øvrige semantiske feltene, eller ikke i det hele tatt.';

comment on function workflow.record_agent_handoff_answer(uuid, jsonb, uuid, uuid, uuid) is
  'Tar imot ett eksternt agentsvar på én agentoppgave og registrerer resultatet gjennom de samme interne skriveveiene agentkjørerne bruker (ANTIDEP_CONSTITUTION.md regel 3, 4, 7). Begge transportene — nedlast/opplast og den autonome MCP-kjøreren — kaller denne, slik at ingen av dem kan få større faglige skrivefullmakter enn den andre. Bindingen kontrolleres strengt mot oppgaven slik databasen bygger den nå: rolle, jobbnøkkel, svarform, oppgaveform og request_digest. Fra migrasjon 013u er identity valgfri og sammenlignes ikke med rollens tildeling. Et selvrapportert modellnavn er agentens eget ord, plattformen viser ofte ikke modellen i det hele tatt, og en likhetskontroll på et navn modellen selv skriver, avviser bare det ærlige svaret. Formen på et vedlagt selvutsagn kontrolleres fortsatt, fordi en versjon som motsier eksponeringsgraden er usann proveniens uansett hvem som skrev den. Autentiserer ingenting selv og er derfor ikke SECURITY DEFINER: den kalles fra innsiden av en api-funksjon som allerede har fastslått hvem kalleren er.';

comment on function api.import_agent_answer(uuid, jsonb) is
  'Tar imot ett eksternt agentsvar på én agentoppgave og registrerer resultatet gjennom de samme interne skriveveiene agentkjørerne bruker (ANTIDEP_CONSTITUTION.md regel 3, 4, 7). Svaret er data: ukjente felter avvises, bindingen kontrolleres mot oppgaven slik databasen bygger den nå, og verdiene hentes ut av svaret selv — kalleren kan ikke bytte dem ut underveis. Et svar avgitt på en oppgave som siden har fått et annet grunnlag, har et annet request_digest og avvises. Den semantiske modellproveniensen kjøringen føres med, er rollens attesterte tildeling; fra migrasjon 013u kontrolleres svaret ikke mot den, og et selvrapportert modellnavn er valgfritt og lagres som agentens eget ord. Fra migrasjon 013t kan to roller dele modell, og det er kontrollradenes egen regel som hindrer egenverifikasjon: den samme kjøringen kan ikke attestere sitt eget resultat, og det samme registreringsleddet kan ikke både skrive innholdet og kontrollere det. Importen er idempotent på jobben: det samme svaret sendt inn igjen svarer med det som allerede ble registrert, og et annet svar på en besvart jobb avvises — retries gir aldri doble kliniske artefakter. Den ordrette kontrollen av hvert kildeutdrag ligger der den alltid har ligget: i Antideps egen deterministiske kode før importen, og i den uavhengige ekstraksjonskontrollen etterpå. Krever editor-mandat. SECURITY DEFINER fordi knowledge, workflow og provenance har RLS med default deny; kalleren valideres på funksjonens eget kall (§50).';

comment on function api.assign_agent_role_model(text, text, text, text, text, text, text) is
  'Velger hvilken ekstern KI-tjeneste et semantisk agentledd skal utføres av (ANTIDEP_CONSTITUTION.md regel 3). Tildelingen er en attestert avgjørelse tatt av en redaktør med mandat, FØR oppgaven hentes ut, og den inngår i oppgavens binding og dermed i request_digest. Registrerer aldri en modell på grunnlag av et agentsvar: en identitet som fikk registrere seg selv, ville etablert sitt eget premiss, og proveniensen sagt hvilken modell som arbeidet på modellens eget ord. Skriver aldri om en gjeldende tildeling: et bytte krever en begrunnelse, og avslutter da den gjeldende med hvem og hvorfor og registrerer den nye i den samme transaksjonen, slik at leddet aldri står uten modell fordi den nye viste seg å tilhøre et annet ledd. Fra migrasjon 013t kan to ledd godt ha den samme modellen: den utfører dem som atskilte kjøringer under hver sin rolle, og separasjonen ligger i rollen og i kjøringen framfor i modellnavnet. Fra migrasjon 013u er tildelingen proveniens og ikke adgangskontroll: den sier hvor arbeidet ble satt ut, og et agentsvar kontrolleres ikke mot den — plattformen viser sjelden modellen, og et navn modellen selv skriver, er ingen grense. Krever editor-mandat. SECURITY DEFINER fordi provenance har RLS med default deny; kalleren valideres på funksjonens eget kall.';

-- ----------------------------------------------------------------------------
-- 4. Kontraktversjonene: svarformen og promptmalene er blitt andre
--
-- To ting i denne migrasjonen endrer det agenten faktisk ser og får levere, og
-- begge har en versjon som finnes nettopp for å si at de er endret.
--
-- **Svarformen.** `identity` gikk fra påkrevd til valgfri. Det er ikke en
-- presisering: et `@1`-svar uten `identity` *var* en feil, mens et `@2`-svar
-- uten er den sanne formen. Versjonen er det som hindrer at en annen svarform
-- leses med de samme standardene — sto de to under det samme navnet, ville
-- navnet sluttet å si noe.
--
-- **Promptmalene.** Den delte delen av oppgaveteksten er skrevet om for alle
-- seks rollene: svarmalen har ikke lenger et `identity`-felt, og teksten sier nå
-- at feltet skal utelates med mindre plattformen faktisk viser modellen. En
-- `prompt_template_version` som dekket både den gamle og den nye instruksen,
-- ville ikke kunnet si hvilken av dem en registrert kjøring faktisk fikk — og
-- den strengen er det eneste proveniensen har å svare med.
--
-- Svarstrukturene (`output_schema_version`) står urørt. `result` er nøyaktig det
-- samme som før, og en versjon som beveget seg uten at formen gjorde det, ville
-- vært like misvisende som en som sto stille mens formen endret seg.
--
-- Utestående oppgaver får et nytt `request_digest`, fordi promptmalversjonen er
-- en del av bindingen. Det er riktig utfall: en oppgave hentet ut under den
-- gamle instruksen skal ikke kunne besvares som om den var hentet under den nye.
-- ----------------------------------------------------------------------------
create or replace function workflow.agent_handoff_answer_version()
  returns text language sql immutable set search_path = ''
as $$ select 'antidep/agent-answer@2'::text $$;

comment on function workflow.agent_handoff_answer_version() is
  'Versjonen av svarformen den eksterne agent-handoffen tar imot. Et svar med en annen versjon avvises framfor å bli lest med standardverdier. @2 fra migrasjon 013u: identity gikk fra påkrevd til valgfri, fordi plattformen sjelden lar en agent vite hvilken modell den kjører — og et @1-svar uten identity var en feil, mens et @2-svar uten er den sanne formen.';

create or replace function workflow.agent_task_contract(p_agent_role provenance.agent_role)
  returns jsonb
  language sql
  immutable
  set search_path = ''
as $$
  select case p_agent_role
    -- Promptmalene står på /2 fra migrasjon 013u: den delte delen av
    -- oppgaveteksten ble skrevet om for alle seks rollene i den samme
    -- endringen. Svarformene er uendret — `result` er det samme som før.
    when 'evidence_extraction' then jsonb_build_object(
      'prompt_template_version', 'evidence-extraction/handoff-drafting/2',
      'output_schema_version', 'antidep/extraction-draft@1'
    )
    when 'claim_synthesis' then jsonb_build_object(
      'prompt_template_version', 'claim-synthesis/handoff-drafting/2',
      'output_schema_version', 'antidep/claim-synthesis-draft@1'
    )
    when 'evidence_assessment' then jsonb_build_object(
      'prompt_template_version', 'evidence-assessment/handoff-drafting/2',
      'output_schema_version', 'antidep/evidence-assessment-draft@1'
    )
    -- Migrasjon 013i hever svarformen til @2: et begrepsforslag kan navngi
    -- behovet verdien ble dokumentert under, slik at aksepten forgrener
    -- nettopp det behovet framfor å utvide utgaven på malenes hovedakse.
    when 'source_discovery' then jsonb_build_object(
      'prompt_template_version', 'source-discovery/handoff-search/2',
      'output_schema_version', 'antidep/source-discovery-draft@2'
    )
    when 'source_quality_assessment' then jsonb_build_object(
      'prompt_template_version', 'source-coverage/handoff-control/2',
      'output_schema_version', 'antidep/source-coverage-control-draft@1'
    )
    -- Migrasjon 013i: svaret på et behov som hviler på et myndighets-,
    -- preparat- eller retningslinjedokument. Den deterministiske
    -- svarkontrollen står bevisst ikke her: den er Antideps egen kode.
    when 'monograph_answer' then jsonb_build_object(
      'prompt_template_version', 'monograph-answer/handoff-fact/2',
      'output_schema_version', 'antidep/monograph-answer-draft@1'
    )
    else null
  end;
$$;
