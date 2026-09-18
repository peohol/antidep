-- Migrasjon 013t — separasjonen hviler på rollen og kjøringen, ikke på modellnavnet
--
-- Fram til nå har regel 3 vært håndhevet på *modellidentitet*: ingen to
-- agentledd kunne dele leverandør, modell og modellversjon i overlappende tid,
-- og ingen kontroll kunne vise til en kjøring med den samme modellen som laget
-- det kontrollerte. Regelen forutsatte at eieren hadde seks forskjellige
-- modeller å fordele.
--
-- Den forutsetningen er ikke sann. Et ChatGPT Business-workspace gir én
-- modellmeny, og den arbeidsformen Antidep faktisk skal ha, er at *den samme*
-- modellen utfører de seks leddene som atskilte kjøringer — hver under sin egen
-- rolle, med den rollens instruks og den rollens legitimasjon. Med den gamle
-- regelen var det umulig å konfigurere: kjeden stoppet på en grense som krevde
-- noe plattformen ikke tilbyr.
--
-- ----------------------------------------------------------------------------
-- Hva som faktisk bar separasjonen, og hva som ikke gjorde det
--
-- Modellnavnet var aldri selve vernet. Det var en *proxy* for vernet, og en
-- svak en: `platform_model_disclosure = not_exposed` er normaltilfellet, og da
-- kunne Antidep uansett ikke se om to navn var den samme modellen eller to
-- forskjellige. Regelen krevde at redaktøren oppga to sanne, forskjellige
-- navn — og kunne ikke kontrollere at de var det.
--
-- Det som *er* kontrollerbart, og som denne migrasjonen flytter regelen over
-- på, er rollen og kjøringen:
--
--   * Hvert ledd er sin egen rolle med sin egen agentidentitet og sin egen
--     legitimasjon (migrasjon 005e). `provenance.authenticate_agent_identity(...)`
--     binder identiteten til rollen, så en kjøring kan ikke opptre i et annet
--     ledd.
--   * Hver kontroll er en *ny kjøring* under kontrollrollens egen instruks og
--     egne premisser. Et svar kan ikke attestere sitt eget resultat.
--
-- Det er en svakere påstand enn «to forskjellige modeller», og den skal stå
-- som det den er: kontrollen er en annen kjøring, i en annen rolle, med en
-- annen instruks — ikke en annen modellvekt. Å hevde to modeller uten å kunne
-- se dem var en sterkere påstand enn systemet noen gang kunne innfri.
--
-- Det motsatte er like galt, og migrasjonen gjør ikke det heller: separasjonen
-- bygges *ikke* opp igjen som et krav om to forskjellige Workspace
-- Agent-konfigurasjoner. Én konfigurasjon som utfører to ledd som to atskilte,
-- riktig rollemerkede kjøringer, er nøyaktig den arbeidsformen dette skal
-- tillate. En regel som forbød det, ville vært den gamle modellregelen i ny
-- drakt — en faglig uavhengighetspåstand forkledd som en teknisk grense.
--
-- ----------------------------------------------------------------------------
-- 1. Registeret: flere ledd kan bruke den samme modellen
--
-- Det som fortsatt er unikt, er leddet: én gyldig tildeling per rolle og
-- kapasitet (`role_model_assignments_one_per_role_capacity_excl` fra 013b står
-- urørt). Modellen er ikke lenger unik på tvers av ledd.
-- ----------------------------------------------------------------------------
alter table provenance.role_model_assignments
  drop constraint role_model_assignments_no_shared_model_excl;

comment on table provenance.role_model_assignments is
  'Hvilken modellidentitet hver agentrolle handler som (ANTIDEP_CONSTITUTION.md regel 3, EVIDENCE_PIPELINE.md). Én exclusion constraint gjør erklæringen til en regel: én gyldig tildeling per rolle og kapasitet om gangen, slik at «hvilken modell handler denne rollen som nå» har ett svar. Flere ledd kan dele modell, og det er tilsiktet fra migrasjon 013t: den samme modellen utfører leddene som atskilte kjøringer, hver under sin egen rolle og sin egen instruks. Separasjonen mellom generator, kildestøttekontroll og evidensvurdering ligger derfor i rollen og i kjøringen — ikke i modellnavnet, og ikke i et krav om to agentkonfigurasjoner. api.begin_agent_run krever fortsatt at kjøringens premisser er nøyaktig den registrerte tildelingen, og en rolle uten gyldig tildeling kan ikke åpne en kjøring i det hele tatt.';

-- ----------------------------------------------------------------------------
-- 2. Forbudet mot egenverifikasjon, sagt om det som faktisk skiller kjøringene
--
-- Funksjonen beholder navn og signatur, så de tre triggerne fra 009c står
-- urørt. Det som endres, er hva den sammenligner.
--
-- Den semantiske modellsammenligningen fra 013b fjernes: den var regelen om at
-- to ledd ikke kan hvile på det samme eksterne modellsvaret, og det er den
-- arbeidsformen som nå er tillatt.
--
-- Igjen står det egenverifikasjon faktisk er:
--
--   1. **Den samme kjøringen.** Et svar kan ikke attestere sitt eget resultat.
--      Dette er regelen i sin reneste form, og den eneste som er sann uansett
--      hvordan modeller, agentkonfigurasjoner og transport er satt opp.
--   2. **Det samme registreringsleddet.** Registreringsidentiteten er Antideps
--      egen deterministiske kode for leddet, og den er én per ledd. Et
--      sammenfall betyr at det samme kodeleddet både skrev innholdet og
--      kontrollerte det.
--
-- Agentidentiteten sammenlignes ikke, og det er med vilje: den er bundet til
-- rollen av `agent_runs_identity_role_fkey`, så to forskjellige roller har
-- alltid to forskjellige identiteter. En sammenligning der ville vært sann uten
-- å bety noe, og ville lest som en uavhengighetsgaranti den ikke er.
-- ----------------------------------------------------------------------------
create or replace function provenance.assert_distinct_model_identity(
  p_checking_run_id uuid,
  p_checked_run_id uuid,
  p_what text
)
  returns void
  language plpgsql
  set search_path = ''
as $$
declare
  v_same_registration boolean;
begin
  if p_checking_run_id is null or p_checked_run_id is null then
    -- Et menneskes registrering har ingen kjøring, og et objekt laget av et
    -- menneske har det heller ikke. Fraværet er ikke et sammenfall.
    return;
  end if;

  -- Regelen i sin reneste form: et svar kan ikke attestere sitt eget resultat.
  if p_checking_run_id = p_checked_run_id then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        '%s er den samme kjøringen som laget det som kontrolleres.',
        p_what
      ),
      hint = 'En kontroll er en ny kjøring under kontrollrollens egen instruks. Et svar som attesterer sitt eget resultat, er ikke en kontroll — det er den samme vurderingen lest to ganger (ANTIDEP_CONSTITUTION.md regel 3).';
  end if;

  select a.provider = b.provider
     and a.model = b.model
     and a.model_version = b.model_version
    into v_same_registration
  from provenance.agent_runs a, provenance.agent_runs b
  where a.id = p_checking_run_id and b.id = p_checked_run_id;

  if coalesce(v_same_registration, false) then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        '%s ble gjort av den samme modellidentiteten som laget det som kontrolleres.',
        p_what
      ),
      hint = 'Registreringsidentiteten er Antideps egen kode for hvert ledd, og den er én per ledd. Et sammenfall betyr at det samme kodeleddet både skrev innholdet og kontrollerte det, og det er egenverifikasjon uansett hvilken modell som gjorde det semantiske arbeidet (ANTIDEP_CONSTITUTION.md regel 3).';
  end if;

end;
$$;

comment on function provenance.assert_distinct_model_identity(uuid, uuid, text) is
  'Avviser en kontroll som ikke er en egen kjøring (ANTIDEP_CONSTITUTION.md regel 3). Sammenligner to ting: om det er den samme kjøringen — et svar kan ikke attestere sitt eget resultat — og registreringsidentiteten, som er Antideps egen kode for leddet og én per ledd. Sammenligner fra migrasjon 013t IKKE lenger den semantiske modellen: flere ledd kan dele modell, fordi den samme modellen utfører dem som atskilte kjøringer under hver sin rolle og hver sin instruks. Det Antidep da hevder, er at kontrollen var en egen kjøring i en egen rolle — ikke at den var en annen modell, og ingen flate skal si noe sterkere. NULL på en av sidene er ikke et sammenfall: et menneskes registrering har ingen agentkjøring.';

-- ----------------------------------------------------------------------------
-- 3. Kildeleddene: dekningskontrollen er fortsatt en egen kjøring
--
-- 013e ga kildeoppdagelsen og dekningskontrollen hver sin registreringsidentitet
-- nettopp slik at kontrollen ikke kunne være det samme leddet som søkte. Den
-- delingen står. Det som faller bort, er kravet om at de to måtte ha
-- forskjellige *eksterne modeller* — se seksjon 7.
-- ----------------------------------------------------------------------------
comment on function provenance.current_semantic_model(provenance.agent_role) is
  'Den eksterne KI-agenten rollen er registrert med for det semantiske arbeidet akkurat nå, eller ingen rad. Ingen rad er en reell tilstand og ikke en feil i seg selv: en rolle uten registrert semantisk modell kan ikke ta imot et eksternt agentsvar, og det er riktig utfall — alternativet ville vært å ta imot et svar fra en modell ingen har tatt stilling til (ANTIDEP_CONSTITUTION.md regel 3). Fra migrasjon 013t kan flere roller være registrert med den samme modellen: det er den samme modellen i atskilte kjøringer, og separasjonen ligger i rollen og i kjøringen.';

-- ----------------------------------------------------------------------------
-- 4. Kommentarene som beskrev den gamle regelen
--
-- En merget migrasjon redigeres aldri (AGENTS.md), så kommentarene settes på
-- nytt her. De er ikke pynt: de er stedet en som leser databasen, får vite hva
-- en regel er til for, og en kommentar som beskriver en regel som ikke lenger
-- finnes, er verre enn ingen kommentar.
-- ----------------------------------------------------------------------------
comment on function provenance.unexposed_model_version() is
  'Den kanoniske verdien provenance.agent_runs.model_version og provenance.role_model_assignments.model_version bærer når model_version_disclosure er not_exposed. Kanonisk og ikke fri tekst, fordi modellidentiteten sammenlignes som en streng: med én verdi er to ukjente versjoner av den samme modellen den samme identiteten, som er sant, framfor to forskjellige, som ville gjort proveniensen usann (ANTIDEP_CONSTITUTION.md regel 3).';

comment on column provenance.role_model_assignments.capacity is
  'Hva tildelingen handler om: registration er Antideps egen deterministiske kode som kontrollerer og skriver raden, semantic er den eksterne KI-agenten som gjør selve det semantiske arbeidet. En rolle har høyst én gyldig tildeling i hver kapasitet om gangen. Fra migrasjon 013t kan flere roller dele modellidentitet: ekstraksjonsutkastet og evidensvurderingen kan komme fra den samme eksterne modellen, som to atskilte kjøringer under hver sin rolle og hver sin instruks. Separasjonen ligger da i rollen og i kjøringen — ikke i at de to er forskjellige agentidentiteter eller forskjellige Workspace Agent-er (ANTIDEP_CONSTITUTION.md regel 3).';

comment on function provenance.require_semantic_model_assignment(provenance.agent_role, jsonb) is
  'Krever at et eksternt agentsvar kommer fra den modellen agentleddet er tildelt, og registrerer ingenting (ANTIDEP_CONSTITUTION.md regel 3). Skiller seg fra en tildeling som registrerte seg selv ved første svar: der ville svaret etablert sitt eget premiss, og proveniensen sagt hvilken modell som arbeidet på modellens eget ord. En rolle uten tildeling avvises her, og meldingen sier hva som må gjøres.';

comment on function api.assign_agent_role_model(text, text, text, text, text, text, text) is
  'Velger hvilken ekstern KI-tjeneste et semantisk agentledd skal utføres av (ANTIDEP_CONSTITUTION.md regel 3). Tildelingen er en attestert avgjørelse tatt av en redaktør med mandat, FØR oppgaven hentes ut, og den inngår i oppgavens binding og dermed i request_digest. Registrerer aldri en modell på grunnlag av et agentsvar: en identitet som fikk registrere seg selv, ville etablert sitt eget premiss, og proveniensen sagt hvilken modell som arbeidet på modellens eget ord. Skriver aldri om en gjeldende tildeling: et bytte krever en begrunnelse, og avslutter da den gjeldende med hvem og hvorfor og registrerer den nye i den samme transaksjonen, slik at leddet aldri står uten modell fordi den nye viste seg å tilhøre et annet ledd. Fra migrasjon 013t kan to ledd godt ha den samme modellen: den utfører dem som atskilte kjøringer under hver sin rolle, og separasjonen ligger i rollen og i kjøringen framfor i modellnavnet. Krever editor-mandat. SECURITY DEFINER fordi provenance har RLS med default deny; kalleren valideres på funksjonens eget kall.';

comment on function api.import_agent_answer(uuid, jsonb) is
  'Tar imot ett eksternt agentsvar på én agentoppgave og registrerer resultatet gjennom de samme interne skriveveiene agentkjørerne bruker (ANTIDEP_CONSTITUTION.md regel 3, 4, 7). Svaret er data: ukjente felter avvises, bindingen kontrolleres mot oppgaven slik databasen bygger den nå, og verdiene hentes ut av svaret selv — kalleren kan ikke bytte dem ut underveis. Et svar avgitt på en oppgave som siden har fått et annet grunnlag, har et annet request_digest og avvises. Modellidentiteten registreres på kjøringen og kontrolleres mot rollens registrerte semantiske modell. Fra migrasjon 013t kan to roller dele modell, og det er kontrollradenes egen regel som hindrer egenverifikasjon: den samme kjøringen kan ikke attestere sitt eget resultat, og det samme registreringsleddet kan ikke både skrive innholdet og kontrollere det. Importen er idempotent på jobben: det samme svaret sendt inn igjen svarer med det som allerede ble registrert, og et annet svar på en besvart jobb avvises — retries gir aldri doble kliniske artefakter. Den ordrette kontrollen av hvert kildeutdrag ligger der den alltid har ligget: i Antideps egen deterministiske kode før importen, og i den uavhengige ekstraksjonskontrollen etterpå. Krever editor-mandat. SECURITY DEFINER fordi knowledge, workflow og provenance har RLS med default deny; kalleren valideres på funksjonens eget kall (§50).';

-- ----------------------------------------------------------------------------
-- 5. Tildelingsveien: feilmeldingen som pekte på en regel som ikke finnes
--
-- `api.assign_agent_role_model(...)` fanget `exclusion_violation` og slo opp
-- hvilket *annet* ledd som holdt den samme modellidentiteten. Var det et, sa
-- den at modellen allerede var tildelt og ikke kunne gjøre arbeidet her.
--
-- Etter at regelen er borte, er nettopp det tilfellet lovlig — og grenen ville
-- ikke lenger vært en presis feilmelding, men en usann. Den eneste
-- exclusion-regelen som står igjen, er én tildeling per ledd og kapasitet, og
-- den har allerede sin egen setning.
-- ----------------------------------------------------------------------------
create or replace function api.assign_agent_role_model(
  p_agent_role text,
  p_provider text,
  p_model text,
  p_model_version text default null,
  p_model_version_disclosure text default 'not_exposed',
  p_reason text default null,
  p_replaces_reason text default null
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_role provenance.agent_role;
  v_identity jsonb;
  v_current provenance.role_model_assignments;
  v_valid_from timestamptz;
  v_replaced boolean := false;
  v_assignment provenance.role_model_assignments;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  begin
    v_role := p_agent_role::provenance.agent_role;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke en kjent agentrolle.', p_agent_role);
  end;

  if workflow.agent_task_contract(v_role) is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format(
        'Rollen %L utføres av Antideps egen deterministiske kode, og har ingen ekstern KI-modell å tildele.',
        p_agent_role),
      hint = 'De uavhengige kontrolleddene er Antideps egen kode. En ekstern modell som fikk utføre dem, ville gjort kontrollen til nok en modellvurdering (ANTIDEP_CONSTITUTION.md regel 3).';
  end if;

  v_identity := provenance.canonical_model_identity(
    p_provider, p_model, p_model_version, p_model_version_disclosure);

  v_current := provenance.current_semantic_model(v_role);
  if v_current.id is not null then
    if v_current.provider = (v_identity ->> 'provider')
       and v_current.model = (v_identity ->> 'model')
       and v_current.model_version = (v_identity ->> 'model_version') then
      return jsonb_build_object(
        'agent_role', p_agent_role,
        'assigned', false,
        'already_assigned', true,
        'replaced', false,
        'model', v_identity
      );
    end if;
    -- Byttet er lovlig, men det er en endring av kjedens mest sikkerhetskritiske
    -- innstilling, og det krever derfor en begrunnelse. Uten den ville et bytte
    -- vært en endring uten ansvar — og avslutningen og den nye tildelingen skjer
    -- i den samme transaksjonen, slik at leddet aldri står uten en modell fordi
    -- den nye viste seg å tilhøre et annet ledd.
    if nullif(btrim(coalesce(p_replaces_reason, '')), '') is null then
      raise exception using
        errcode = 'restrict_violation',
        message = format(
          'Agentleddet %L er allerede tildelt %s/%s (%s).',
          p_agent_role, v_current.provider, v_current.model, v_current.model_version),
        hint = 'En tildeling skrives aldri om. Skal leddet bytte tjeneste, oppgi hvorfor: da avsluttes den gjeldende tildelingen med hvem og hvorfor, og den nye registreres i samme transaksjon. Utestående oppgaver får et nytt avtrykk, slik at et svar avgitt under den gamle tildelingen ikke kan registreres på den nye.';
    end if;

    update provenance.role_model_assignments
    set valid_to = statement_timestamp(),
        closed_by_actor_id = v_actor_id,
        close_reason = btrim(p_replaces_reason)
    where id = v_current.id;
    v_replaced := true;
  end if;

  -- Perioden begynner der den forrige sluttet, og aldri før.
  --
  -- Standardverdien for valid_from er now(), altså transaksjonens starttid. En
  -- avslutning og en ny tildeling i den samme transaksjonen ville derfor fått
  -- overlappende perioder, og exclusion-regelen ville avvist en tildeling som er
  -- helt legitim. Perioden regnes derfor av den siste avslutningen som finnes
  -- for dette leddet. Fra 013t ser oppslaget ikke lenger etter den samme
  -- modellidentiteten hos andre ledd: de kan dele modell, så en annen rolles
  -- periode er ikke lenger noe denne tildelingen må vike for.
  select greatest(
           statement_timestamp(),
           coalesce(max(a.valid_to), statement_timestamp()))
    into v_valid_from
  from provenance.role_model_assignments a
  where a.agent_role = v_role and a.capacity = 'semantic';

  begin
    insert into provenance.role_model_assignments (
      agent_role, capacity, provider, model, model_version, model_version_disclosure,
      valid_from, registered_by_actor_id, reason
    )
    values (
      v_role, 'semantic',
      v_identity ->> 'provider', v_identity ->> 'model', v_identity ->> 'model_version',
      (v_identity ->> 'model_version_disclosure')::provenance.model_version_disclosure,
      coalesce(v_valid_from, statement_timestamp()),
      v_actor_id,
      coalesce(
        nullif(btrim(coalesce(p_reason, '')), ''),
        'Valgt av en redaktør med mandat, som den KI-tjenesten dette agentleddet skal utføres av.')
    )
    returning * into v_assignment;
  exception
    when exclusion_violation then
      -- Etter 013t finnes bare én exclusion-regel på registeret: én gyldig
      -- tildeling per ledd og kapasitet. Den gamle grenen her slo opp hvilket
      -- *annet* ledd som holdt den samme modellen, og ville nå sendt eieren
      -- etter en årsak som ikke finnes — at en modell er delt, er tillatt.
      raise exception using
        errcode = 'restrict_violation',
        message = format(
          'Agentleddet %L har en gjeldende modelltildeling i den perioden den nye ville dekket.',
          p_agent_role),
        hint = 'Avslutt den gjeldende tildelingen med api.release_agent_role_model(text, text) før en ny registreres. Én gyldig tildeling per ledd om gangen er regelen som gjør «hvilken modell handler dette leddet som» til et spørsmål med ett svar.';
  end;

  return jsonb_build_object(
    'agent_role', p_agent_role,
    'assigned', true,
    'already_assigned', false,
    'replaced', v_replaced,
    'model', v_identity
  );
end;
$$;

-- ----------------------------------------------------------------------------
-- 6. Én Workspace Agent kan kjøre flere ledd
--
-- `agent_runner_connections_one_role_per_agent_excl` forbød den samme
-- `platform_agent_reference` å ha to gjeldende tilkoblinger. Begrunnelsen som
-- sto i 011a, var «én konfigurasjon er én modellruntime» — altså den samme
-- faglige uavhengighetspåstanden som modellregelen, ett hakk lenger ut.
--
-- Den påstanden er det denne migrasjonen fjerner, og da skal den ikke bli
-- stående i en annen kolonne. Regelen er ikke teknisk nødvendig: hver
-- tilkobling har sin egen nøkkel, sitt eget token og sin egen rolle, og en
-- kjøring er rollemerket av tilkoblingen den kom gjennom. Den samme Workspace
-- Agent-en kan derfor utføre to ledd som to atskilte, korrekt rollemerkede
-- kjøringer — med hver sin instruks — og datamodellen skal ikke forby det.
--
-- `agent_runner_connections_one_live_per_role_excl` står urørt. Den er en
-- transportregel og ikke en uavhengighetspåstand: «hvem henter arbeidet i dette
-- leddet» skal ha ett svar.
-- ----------------------------------------------------------------------------
alter table workflow.agent_runner_connections
  drop constraint agent_runner_connections_one_role_per_agent_excl;

comment on table workflow.agent_runner_connections is
  'Én registrert autonom kjører av eksternt agentarbeid — i praksis én planlagt ChatGPT Workspace Agent koblet til Antideps private MCP-app (ANTIDEP_CONSTITUTION.md regel 3, 7). Registreres av et menneske med editor-mandat og aldri av et agentsvar: en kjører som kunne registrere seg selv, ville etablert premisset som autoriserte den. Bundet til nøyaktig ett agentledd, slik at tokenet aldri kan få annet arbeid enn det leddet. Fra migrasjon 013t kan den samme Workspace Agent-en ha tilkoblinger til flere ledd: hver tilkobling har sin egen nøkkel, sitt eget token og sin egen rolle, og arbeidet utføres som atskilte, rollemerkede kjøringer. Ett ledd har fortsatt høyst én gjeldende kjører — det er en transportregel, ikke en uavhengighetspåstand.';

comment on column workflow.agent_runner_connections.platform_agent_reference is
  'Plattformens eget navn på agentkonfigurasjonen, slik et menneske kjenner den igjen i ChatGPT. En opplysning for gjenfinning og feilsøking, og fra migrasjon 013t ikke en uavhengighetsgaranti: den samme konfigurasjonen kan kjøre flere ledd, som atskilte kjøringer under hver sin rolle.';

-- ----------------------------------------------------------------------------
-- 7. Dekningskontrollen: en egen kjøring, ikke en annen modell
--
-- 013e la en egen sperre i `workflow.record_monograph_coverage_control(...)`:
-- den slo opp de to kildeleddenes semantiske tildelinger og avviste kontrollen
-- dersom de var den samme modellen. Det er den samme regelen denne migrasjonen
-- fjerner, og den kan ikke bli stående her.
--
-- I stedet gjelder den regelen som er sann: kontrollen kan ikke være den samme
-- *kjøringen* som søkte. Uavhengigheten som betyr noe faglig, ligger uendret i
-- porten ved siden av — en dekningskontroll må ha søkt selv og vurdert
-- vesentligheten før en dekning kan godtas.
-- ----------------------------------------------------------------------------
create or replace function workflow.record_monograph_coverage_control(
  p_plan_id uuid,
  p_outcome workflow.monograph_coverage_outcome,
  p_note text,
  p_searched_independently boolean,
  p_missed_candidates integer,
  p_exclusions_checked integer,
  p_materiality_assessed boolean,
  p_agent_run_id uuid,
  p_actor_id uuid
)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_plan workflow.monograph_search_plans;
  v_id uuid;
begin
  select p.* into v_plan
  from workflow.monograph_search_plans p
  where p.id = p_plan_id
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Søkeplanen finnes ikke.';
  end if;

  -- Sammenligningen av de to kildeleddenes semantiske *tildelinger* er borte:
  -- den krevde to forskjellige modeller, og det er ikke lenger en regel Antidep
  -- kan eller skal hevde. Dekningskontrollen er et eget ledd med sin egen rolle,
  -- sin egen instruks og sin egen kjøring, og den kan godt kjøre den samme
  -- modellen som kildeoppdagelsen.
  --
  -- Her kommer ingen kjøringssammenligning i stedet, og det er en avlesning og
  -- ikke en forglemmelse. Kontrollen *skal* søke selv, og de motsøkene
  -- registreres på den samme planen, med kontrollens egen kjøring. Den siste
  -- kjøringen som søkte på planen, er derfor som regel kontrollens egen — en
  -- sammenligning der ville avvist nettopp den kontrollen som gjorde arbeidet
  -- riktig. Og det finnes ingen ett-til-ett «kjøringen som laget det som
  -- kontrolleres» å peke på: en plan bærer søk fra flere kjøringer.
  --
  -- Uavhengigheten her bæres av porten ved siden av, uendret siden 013e: en
  -- dekning kan bare godtas av en kontroll som søkte selv
  -- (`searched_independently`) og vurderte vesentligheten. Det er en faglig
  -- forskjell en delt modell ikke kan gå rundt, og den er sterkere enn noen
  -- sammenligning av identiteter ville vært.
  insert into workflow.monograph_coverage_controls (
    plan_id, plan_version, outcome, note,
    searched_independently, missed_candidates, exclusions_checked,
    materiality_assessed, agent_run_id, recorded_by_actor_id
  )
  values (
    p_plan_id, v_plan.plan_version, p_outcome, btrim(p_note),
    coalesce(p_searched_independently, false),
    coalesce(p_missed_candidates, 0), coalesce(p_exclusions_checked, 0),
    coalesce(p_materiality_assessed, false), p_agent_run_id, p_actor_id
  )
  on conflict (plan_id, plan_version) do nothing
  returning id into v_id;

  if v_id is null then
    raise exception using
      errcode = 'unique_violation',
      message = 'Denne planversjonen har allerede en dekningskontroll.',
      hint = 'Én kontroll per planversjon. Skal dekningen kontrolleres på nytt, er planen blitt en annen, og det er en ny planversjon.';
  end if;

  return v_id;
end;
$$;

comment on function workflow.record_monograph_coverage_control(uuid, workflow.monograph_coverage_outcome, text, boolean, integer, integer, boolean, uuid, uuid) is
  'Registrerer én dekningskontroll av én søkeplan, i den versjonen planen har nå (SOURCE_POLICY.md §4.4, ANTIDEP_CONSTITUTION.md regel 3). Fra migrasjon 013t er det ikke lenger et krav at kontrollen er en annen modell enn kildeoppdagelsen: den er et eget ledd med sin egen rolle, sin egen instruks og sin egen kjøring. Ingen kjøringssammenligning tok plassen, fordi kontrollen selv skal søke og registrerer de motsøkene på den samme planen — den siste kjøringen som søkte, er som regel kontrollens egen. Uavhengigheten ligger derfor i porten: en dekning kan bare godtas av en kontroll som søkte selv og vurderte vesentligheten. Én kontroll per plan og planversjon.';

-- ----------------------------------------------------------------------------
-- 8. Registreringsveien for kjørere
--
-- `api.register_agent_runner(...)` fanget `exclusion_violation` og slo opp
-- hvilket annet ledd den samme Workspace Agent-en kjørte. Etter seksjon 6 er
-- det lovlig, og grenen ville gitt en usann feilmelding. Den er fjernet, og
-- periodeberegningen viker ikke lenger for agentens andre tilkoblinger.
-- ----------------------------------------------------------------------------
create or replace function api.register_agent_runner(
  p_connection_key text,
  p_display_name text,
  p_agent_role text,
  p_platform_agent_reference text,
  p_platform_model_disclosure text,
  p_reason text default null
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_role provenance.agent_role;
  v_disclosure workflow.runner_model_disclosure;
  v_connection workflow.agent_runner_connections;
  v_valid_from timestamptz;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  begin
    v_role := p_agent_role::provenance.agent_role;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke en kjent agentrolle.', p_agent_role);
  end;

  -- En kjører kan bare få arbeid i et ledd som faktisk kan settes ut. De
  -- uavhengige kontrolleddene er Antideps egen deterministiske kode, og en
  -- ekstern modell som fikk utføre dem, ville gjort kontrollen til nok en
  -- modellvurdering (ANTIDEP_CONSTITUTION.md regel 3).
  if workflow.agent_task_contract(v_role) is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format(
        'Rollen %L utføres av Antideps egen deterministiske kode, og kan ikke settes ut til en autonom kjører.',
        p_agent_role);
  end if;

  begin
    v_disclosure := p_platform_model_disclosure::workflow.runner_model_disclosure;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format(
          '%L sier ikke om plattformen pinner modellen. Gyldige verdier er platform_pinned og not_exposed.',
          p_platform_model_disclosure),
        hint = 'Pinner Workspace Agent-en en bestemt modell som plattformen viser, er verdien platform_pinned. Gjør den ikke det, er den not_exposed — og det er en sann opplysning framfor en mangel: separasjonen hviler da på modelltildelingen, ikke på plattformen (ANTIDEP_CONSTITUTION.md regel 3, 4).';
  end;

  -- Perioden begynner der den forrige sluttet, og aldri før.
  --
  -- Standardverdien for valid_from er now(), altså transaksjonens starttid. En
  -- tilbaketrekking og en ny registrering i den samme transaksjonen ville derfor
  -- fått overlappende perioder, og exclusion-reglene ville avvist en
  -- registrering som er helt legitim. Samme regning, og samme begrunnelse, som i
  -- api.assign_agent_role_model.
  -- Fra 013t teller bare de to reglene som står igjen: ett gjeldende ledd, og
  -- én gjeldende nøkkel. Den samme Workspace Agent-en kan være registrert på
  -- flere ledd samtidig, så dens perioder er ikke lenger noe denne
  -- registreringen må vike for.
  select greatest(
           statement_timestamp(),
           coalesce(max(c.valid_to), statement_timestamp()))
    into v_valid_from
  from workflow.agent_runner_connections c
  where c.agent_role = v_role
     or c.connection_key = btrim(coalesce(p_connection_key, ''));

  begin
    insert into workflow.agent_runner_connections (
      connection_key, display_name, agent_role,
      platform_agent_reference, platform_model_disclosure,
      valid_from, registered_by_actor_id, registration_reason
    )
    values (
      btrim(coalesce(p_connection_key, '')),
      btrim(coalesce(p_display_name, '')),
      v_role,
      btrim(coalesce(p_platform_agent_reference, '')),
      v_disclosure,
      coalesce(v_valid_from, statement_timestamp()),
      v_actor_id,
      coalesce(
        nullif(btrim(coalesce(p_reason, '')), ''),
        'Registrert av en redaktør med mandat som den planlagte eksterne kjøreren av dette agentleddet.')
    )
    returning * into v_connection;
  exception
    when exclusion_violation then
      -- Etter 013t finnes to exclusion-regler på tilkoblingene, og begge er
      -- transportregler: én gjeldende kjører per ledd, og én gjeldende
      -- tilkobling per nøkkel. Grenen som slo opp hvilket *annet* ledd den
      -- samme Workspace Agent-en kjørte, er borte sammen med regelen den
      -- forklarte — at den samme agenten kjører flere ledd, er tillatt.
      if exists (
        select 1 from workflow.agent_runner_connections c
        where c.connection_key = btrim(coalesce(p_connection_key, ''))
          and c.valid_to is null
      ) then
        raise exception using
          errcode = 'restrict_violation',
          message = format('Nøkkelen %L tilhører allerede en gjeldende kjører.', p_connection_key),
          hint = 'Trekk den gjeldende tilbake med api.revoke_agent_runner(text, text) først. Den samme nøkkelen kan brukes på nytt etterpå: unikheten gjelder de gjeldende tilkoblingene, ikke historikken.';
      end if;

      raise exception using
        errcode = 'restrict_violation',
        message = format('Agentleddet %L har allerede en gjeldende autonom kjører.', p_agent_role),
        hint = 'Trekk den gjeldende tilbake med api.revoke_agent_runner(text, text) før en ny registreres. Ett ledd med to kjørere ville gjort «hvem henter arbeidet her» til et spørsmål med to svar.';
  end;

  return jsonb_build_object(
    'registered', true,
    'connection_key', v_connection.connection_key,
    'display_name', v_connection.display_name,
    'agent_role', v_connection.agent_role::text,
    'platform_agent_reference', v_connection.platform_agent_reference,
    'platform_model_disclosure', v_connection.platform_model_disclosure::text
  );
end;
$$;

comment on function api.register_agent_runner(text, text, text, text, text, text) is
  'Registrerer én autonom kjører av eksternt agentarbeid — i praksis én planlagt ChatGPT Workspace Agent (ANTIDEP_CONSTITUTION.md regel 3, 7). Tilkoblingen bindes til nøyaktig ett agentledd, slik at tokenet aldri kan få annet arbeid enn det leddet. Fra migrasjon 013t kan den samme Workspace Agent-en registreres på flere ledd: arbeidet utføres da som atskilte, rollemerkede kjøringer med hver sin instruks, og det er den separasjonen Antidep hevder — ikke at leddene kjører hver sin modell. Ett ledd har fortsatt høyst én gjeldende kjører, og én nøkkel høyst én gjeldende tilkobling; begge er transportregler. Gir ingen tilgang i seg selv — den kommer først når en tilkoblingskode innløses. Krever editor-mandat. SECURITY DEFINER fordi workflow har RLS med default deny; kalleren valideres på funksjonens eget kall.';
