-- Migrasjon 013t — separasjonen hviler på agentidentiteten, ikke på modellnavnet
--
-- Fram til nå har regel 3 vært håndhevet på *modellidentitet*: ingen to
-- agentledd kunne dele leverandør, modell og modellversjon i overlappende tid,
-- og ingen kontroll kunne vise til en kjøring med den samme modellen som laget
-- det kontrollerte. Regelen forutsatte at eieren hadde seks forskjellige
-- modeller å fordele.
--
-- Den forutsetningen er ikke sann. Et ChatGPT Business-workspace gir én
-- modellmeny, og den arbeidsformen Antidep faktisk skal ha, er at *den samme*
-- modellen utfører de seks leddene i atskilte runder — hver med sin egen
-- Workspace Agent, sin egen instruks og sin egen kontekst. Med den gamle
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
-- på, er agentidentiteten:
--
--   * Hvert ledd har sin egen agentidentitet med sin egen legitimasjon
--     (migrasjon 005e). `provenance.authenticate_agent_identity(...)` binder
--     identiteten til rollen, så en kjøring kan ikke opptre i et annet ledd.
--   * Hver autonome kjører er bundet til nøyaktig ett ledd, og den samme
--     Workspace Agent-en kan ikke kjøre to
--     (`agent_runners_platform_agent_reference_excl`, migrasjon 011a).
--
-- Det er en svakere påstand enn «to forskjellige modeller», og den skal stå
-- som det den er: kontrollen er en *annen runde, med en annen instruks, i en
-- annen kontekst, under en annen legitimasjon* — ikke en annen modellvekt.
-- Antidep hevder ikke lenger mer enn det. Å hevde to modeller uten å kunne se
-- dem var en sterkere påstand enn systemet noen gang kunne innfri.
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
  'Hvilken modellidentitet hver agentrolle handler som (ANTIDEP_CONSTITUTION.md regel 3, EVIDENCE_PIPELINE.md). Én exclusion constraint gjør erklæringen til en regel: én gyldig tildeling per rolle og kapasitet om gangen, slik at «hvilken modell handler denne rollen som nå» har ett svar. Flere ledd kan dele modell, og det er tilsiktet fra migrasjon 013t: den samme modellen utfører leddene i atskilte runder med hver sin instruks, sin egen kontekst og sin egen legitimasjon. Separasjonen mellom generator, kildestøttekontroll og evidensvurdering håndheves derfor på agentidentitet — hvert ledd har sin egen identitet, og den samme Workspace Agent-en kan ikke kjøre to. api.begin_agent_run krever fortsatt at kjøringens premisser er nøyaktig den registrerte tildelingen, og en rolle uten gyldig tildeling kan ikke åpne en kjøring i det hele tatt.';

-- ----------------------------------------------------------------------------
-- 2. Forbudet mot egenverifikasjon, sagt om det som faktisk skiller leddene
--
-- Funksjonen beholder navn og signatur, så de tre triggerne fra 009c står
-- urørt. Det som endres, er hva den sammenligner.
--
-- Den semantiske modellsammenligningen fra 013b fjernes: den var nettopp
-- regelen om at to ledd ikke kan hvile på det samme eksterne modellsvaret, og
-- det er den arbeidsformen som nå er tillatt. Registreringsidentiteten
-- sammenlignes fortsatt — den er Antideps egen kode per ledd, og et sammenfall
-- der ville betydd at det samme kodeleddet både skrev og kontrollerte.
--
-- I stedet kommer sammenligningen av *agentidentitet*: to kjøringer på den
-- samme identiteten er det samme leddet med den samme legitimasjonen, og en
-- kontroll derfra er ingen kontroll.
--
-- Det skal sies rett ut hva den kontrollen er verdt i dag: den kan ikke utløses
-- gjennom de tre triggerne. `agent_runs_identity_role_fkey` binder kjøringens
-- identitet til kjøringens rolle, og de to sidene i en kontroll er alltid to
-- forskjellige roller — altså alltid to forskjellige identiteter. Det samme
-- gjelder registreringsidentiteten, som er seedet per ledd.
--
-- Etter denne migrasjonen filtrerer de tre triggerne derfor ingenting i normal
-- drift. De står som en påstand ved skrivestedet om hva som gjør en kontroll
-- uavhengig, og de blir virksomme igjen den dagen en identitet eller en
-- registreringsmodell blir gjenbrukt på tvers av ledd. Det som faktisk holder
-- leddene fra hverandre nå, er strukturen rundt: én rolle per identitet, én
-- identitet per legitimasjon, ett ledd per Workspace Agent — og de faglige
-- kravene som ikke handler om modell i det hele tatt, som at en dekningskontroll
-- må ha søkt selv før den kan godta dekningen (migrasjon 013e).
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
  v_same_identity boolean;
begin
  if p_checking_run_id is null or p_checked_run_id is null then
    -- Et menneskes registrering har ingen kjøring, og et objekt laget av et
    -- menneske har det heller ikke. Fraværet er ikke et sammenfall.
    return;
  end if;

  select a.provider = b.provider
     and a.model = b.model
     and a.model_version = b.model_version,
       a.agent_identity_id = b.agent_identity_id
    into v_same_registration, v_same_identity
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

  if coalesce(v_same_identity, false) then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        '%s ble gjort av den samme agentidentiteten som laget det som kontrolleres.',
        p_what
      ),
      hint = 'Hvert agentledd har sin egen identitet med sin egen legitimasjon (migrasjon 005e). To kjøringer på den samme identiteten er det samme leddet, ikke to uavhengige runder — og en kontroll derfra er den samme vurderingen gjort to ganger (ANTIDEP_CONSTITUTION.md regel 3).';
  end if;
end;
$$;

comment on function provenance.assert_distinct_model_identity(uuid, uuid, text) is
  'Avviser en kontroll som ikke er en uavhengig runde (ANTIDEP_CONSTITUTION.md regel 3). Sammenligner to ting per kjøring: registreringsidentiteten, som er Antideps egen kode for leddet, og agentidentiteten, som er legitimasjonen runden ble utført under. Sammenligner fra migrasjon 013t IKKE lenger den semantiske modellen: flere ledd kan dele modell, fordi den samme modellen utfører dem i atskilte runder med hver sin instruks og sin egen kontekst. Det Antidep da hevder, er at kontrollen var en annen runde under en annen legitimasjon — ikke at den var en annen modellvekt, og flaten skal ikke si noe annet. NULL på en av sidene er ikke et sammenfall: et menneskes registrering har ingen agentkjøring.';

-- ----------------------------------------------------------------------------
-- 3. Kildeleddene: dekningskontrollen er fortsatt et annet ledd
--
-- 013e ga kildeoppdagelsen og dekningskontrollen hver sin registreringsidentitet
-- nettopp slik at kontrollen ikke kunne være det samme leddet som søkte. Den
-- delingen står, og den er nå den som bærer kravet — sammen med at de to har
-- hver sin agentidentitet.
-- ----------------------------------------------------------------------------
comment on function provenance.current_semantic_model(provenance.agent_role) is
  'Den eksterne KI-agenten rollen er registrert med for det semantiske arbeidet akkurat nå, eller ingen rad. Ingen rad er en reell tilstand og ikke en feil i seg selv: en rolle uten registrert semantisk modell kan ikke ta imot et eksternt agentsvar, og det er riktig utfall — alternativet ville vært å ta imot et svar fra en modell ingen har tatt stilling til (ANTIDEP_CONSTITUTION.md regel 3). Fra migrasjon 013t kan flere roller være registrert med den samme modellen: det er den samme modellen i atskilte runder, og separasjonen ligger i agentidentiteten og i at én Workspace Agent bare kjører ett ledd.';

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
  'Hva tildelingen handler om: registration er Antideps egen deterministiske kode som kontrollerer og skriver raden, semantic er den eksterne KI-agenten som gjør selve det semantiske arbeidet. En rolle har høyst én gyldig tildeling i hver kapasitet om gangen. Fra migrasjon 013t kan flere roller dele modellidentitet: ekstraksjonsutkastet og evidensvurderingen kan komme fra den samme eksterne modellen, i to atskilte runder med hver sin instruks og sin egen kontekst, og separasjonen ligger da i at de to er forskjellige agentidentiteter og forskjellige Workspace Agent-er (ANTIDEP_CONSTITUTION.md regel 3).';

comment on function provenance.require_semantic_model_assignment(provenance.agent_role, jsonb) is
  'Krever at et eksternt agentsvar kommer fra den modellen agentleddet er tildelt, og registrerer ingenting (ANTIDEP_CONSTITUTION.md regel 3). Skiller seg fra en tildeling som registrerte seg selv ved første svar: der ville svaret etablert sitt eget premiss, og proveniensen sagt hvilken modell som arbeidet på modellens eget ord. En rolle uten tildeling avvises her, og meldingen sier hva som må gjøres.';

comment on function api.assign_agent_role_model(text, text, text, text, text, text, text) is
  'Velger hvilken ekstern KI-tjeneste et semantisk agentledd skal utføres av (ANTIDEP_CONSTITUTION.md regel 3). Tildelingen er en attestert avgjørelse tatt av en redaktør med mandat, FØR oppgaven hentes ut, og den inngår i oppgavens binding og dermed i request_digest. Registrerer aldri en modell på grunnlag av et agentsvar: en identitet som fikk registrere seg selv, ville etablert sitt eget premiss, og proveniensen sagt hvilken modell som arbeidet på modellens eget ord. Skriver aldri om en gjeldende tildeling: et bytte krever en begrunnelse, og avslutter da den gjeldende med hvem og hvorfor og registrerer den nye i den samme transaksjonen, slik at leddet aldri står uten modell fordi den nye viste seg å tilhøre et annet ledd. Fra migrasjon 013t kan to ledd godt ha den samme modellen: den utfører dem i atskilte runder, og separasjonen håndheves på agentidentitet framfor på modellnavn. Krever editor-mandat. SECURITY DEFINER fordi provenance har RLS med default deny; kalleren valideres på funksjonens eget kall.';

comment on function api.import_agent_answer(uuid, jsonb) is
  'Tar imot ett eksternt agentsvar på én agentoppgave og registrerer resultatet gjennom de samme interne skriveveiene agentkjørerne bruker (ANTIDEP_CONSTITUTION.md regel 3, 4, 7). Svaret er data: ukjente felter avvises, bindingen kontrolleres mot oppgaven slik databasen bygger den nå, og verdiene hentes ut av svaret selv — kalleren kan ikke bytte dem ut underveis. Et svar avgitt på en oppgave som siden har fått et annet grunnlag, har et annet request_digest og avvises. Modellidentiteten registreres på kjøringen og kontrolleres mot rollens registrerte semantiske modell. Fra migrasjon 013t kan to roller dele modell, og det er kontrollradenes egen regel som hindrer egenverifikasjon: den samme agentidentiteten kan ikke både lage innholdet og kontrollere det. Importen er idempotent på jobben: det samme svaret sendt inn igjen svarer med det som allerede ble registrert, og et annet svar på en besvart jobb avvises — retries gir aldri doble kliniske artefakter. Den ordrette kontrollen av hvert kildeutdrag ligger der den alltid har ligget: i Antideps egen deterministiske kode før importen, og i den uavhengige ekstraksjonskontrollen etterpå. Krever editor-mandat. SECURITY DEFINER fordi knowledge, workflow og provenance har RLS med default deny; kalleren valideres på funksjonens eget kall (§50).';

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
