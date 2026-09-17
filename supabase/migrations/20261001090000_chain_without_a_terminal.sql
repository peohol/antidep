-- ============================================================================
-- Migrasjon 012 — resten av terminalen ut av veien fulltekst → kandidat
--
-- Migrasjon 011 (`clinician_work_surface`) tok det siste menneskelige leddet i
-- kildeinngangen ut av terminalen: en redaktør velger riktig PDF, og Antidep
-- binder, kontrollerer, trekker ut teksten, registrerer kildeversjonen og
-- legger ekstraksjonsoppgaven i køen selv — i én transaksjon, uten at noen
-- kjører en kommando.
--
-- Der stoppet det. Kom svaret tilbake fra den planlagte kjøreren, ble det
-- registrert — og så sto kjeden stille, fordi ekstraksjonskontrollen og
-- kildestøttekontrollen bare fantes som kommandoer noen måtte kjøre, og fordi
-- ingen la neste semantiske ledd i køen. Roadmapen kalte det «det som fortsatt
-- krever en terminal» (issue #101).
--
-- Denne migrasjonen fjerner den resten. Den gjør tre ting, og den tredje er
-- grunnen til at de tre hører sammen i én leveranse:
--
--   1. **Kontrolleddene får sine egne jobber, lagt inn av databasen selv.**
--      Et registrert evidensfunn legger ekstraksjonskontrollen i køen; en
--      registrert påstandsrevisjon legger kildestøttekontrollen i køen. Begge
--      som vanlige `workflow.pipeline_jobs` i kontrolleddets egen rolle, med
--      leie, forsøkstelling og append-only spor som alt annet arbeid.
--
--   2. **Neste semantiske ledd legges i køen når kontrollporten foran er
--      bestått.** En bekreftet ekstraksjonskontroll legger synteseoppgaven inn;
--      en bekreftet kildestøttekontroll legger evidensvurderingen inn; en
--      registrert evidensvurdering forsegler kandidaten, slik at det som
--      gjenstår, er den ene handlingen som *skal* være et menneskes: en
--      navngitt fagperson som vurderer det ferdige produktet.
--
--   3. **Overgangen er databasens egen, ikke en kjøreplans.** Hver overgang er
--      en trigger på den raden som utløser den, i den samme transaksjonen som
--      skrev raden. Ingen poller, ingen cron, ingen orkestrator som kan gå ned
--      mellom to ledd. Det er den eneste formen som er sann uansett hvilken
--      skrivevei som kom først — den autonome MCP-kjøreren, recovery-importen
--      eller et menneske med mandat — og den eneste som ikke kan glemmes av en
--      skrivevei som kommer senere (DATABASE_ARCHITECTURE.md §57 sier det samme
--      om de tekniske problemradene, og av nøyaktig samme grunn).
--
-- ----------------------------------------------------------------------------
-- Hvorfor innleggingen ikke går gjennom `api.enqueue_agent_task(...)`
--
-- Den veien krever editor-mandat, og det er riktig for en redaktør som legger
-- inn arbeid. En kjedeovergang har ingen kaller å kreve mandat av: den utløses
-- av en rad som allerede er skrevet gjennom en kontrollert skrivevei, og
-- mandatet ble kontrollert der. Ble overgangen krevd av et mandat, ville
-- kjeden stoppet nettopp når arbeidet kom fra en agentidentitet — altså alltid.
--
-- Innleggingen her tar derfor ingen mandatavgjørelse. Den tar heller ikke imot
-- noe fra en kaller: hvert eneste felt i inndatamanifestet utledes av rader som
-- allerede finnes. Det er hele sikkerhetsargumentet — en vei som ikke kan bære
-- en kallers verdi, kan ikke brukes til å be om noe annet enn det tilstanden
-- allerede tilsier.
--
-- ----------------------------------------------------------------------------
-- Hvorfor ingen overgang kan rulle tilbake det kliniske arbeidet
--
-- En kjedeovergang er *neste* skritt. Svikter den, er det den automatiske
-- oppgaven som har stoppet — ikke registreringen som nettopp lyktes. Rullet
-- overgangen tilbake evidensfunnet eller kontrollraden, ville en feil i
-- transporten blitt til tapt faglig arbeid, og den som leverte svaret ville
-- fått en avvisning for noe som ikke var galt med svaret.
--
-- Hver overgang kjøres derfor i sin egen underblokk. Svikter den, rulles
-- nøyaktig den tilbake, og svikten blir en rad i `workflow.technical_incidents`
-- under `automatic_task` — teknisk observability, som i konstitusjonens regel 4,
-- og aldri en ny menneskeoppgave. Arbeidet står da som stoppet i den åpne
-- oversikten, og `api.resume_chain_transitions(text, text)` tar det opp igjen
-- ved neste kjøring av kontrolleddet.
--
-- Det er ikke en oppmykning av fail-closed. Ingen kontrollport er fjernet, og
-- ingen port er gjort mildere: en overgang som ikke kunne legges inn, betyr at
-- arbeidet *ikke* går videre. Fail-closed er at kjeden stopper, ikke at en
-- registrering kastes.
--
-- ----------------------------------------------------------------------------
-- Hvorfor en overgang aldri kan lage to semantisk like oppgaver
--
-- To lag, og de dekker hver sin form for gjentakelse:
--
--   * `workflow.pipeline_jobs` er unik på `(agent_role, job_key)`, og nøkkelen
--     utledes av hva jobben handler om. Den samme overgangen kjørt om igjen —
--     en retry, en omstart, reparasjonsveien — treffer den samme raden og
--     skriver ingenting. Et kappløp der to transaksjoner begge ikke fant raden,
--     ender med at den ene får `unique_violation` og leser den andres rad.
--
--   * For de semantiske oppgavene holder ikke nøkkelen alene: `claim_synthesis`
--     har et evidenssett i manifestet, og et sett som vokser med ett funn ville
--     gitt en ny nøkkel og dermed en ny, nesten identisk oppgave. Overgangen
--     spør derfor først om *subjektet* — virkestoffet og temaet, eller
--     påstandsrevisjonen — allerede har en oppgave i rollen, uansett tilstand
--     og uansett hvem som la den inn. Har det det, gjør overgangen ingenting.
--
-- Det andre laget er også grensen for hva automatikken påtar seg. En påstand
-- som allerede finnes for det samme temaet og virkestoffet, synteseres ikke om
-- igjen av seg selv når et nytt funn kommer til: å revidere en påstand i lys av
-- ny evidens er en redaksjonell avgjørelse om hva påstanden skal si, ikke en
-- transport. Kjeden går så langt arkitekturen tillater, og sier ærlig hvor det
-- går.
--
-- ----------------------------------------------------------------------------
-- Hvorfor kontrolleddet får en lesevei til den registrerte representasjonen
--
-- De deterministiske kontrollene er Antideps egen kode, og de leser artikkelen
-- ordrett: de slår opp hvert kildeutdrag i teksten. Fram til nå har de hentet
-- teksten ut av original-PDF-en i en lokal katalog med den registrerte
-- oppskriften. Det virker på maskinen til den som har filen, og bare der — en
-- planlagt kjøring har ingen slik katalog, og skal ikke ha en: originalfilen
-- ligger varig og privat i `knowledge.source_documents`, og ingen klientrolle
-- kan lese én byte av den.
--
-- `knowledge.source_version_texts` bærer nøyaktig den teksten kildeversjonens
-- fingeravtrykk ble beregnet av, og en trigger på raden regner fingeravtrykket
-- ut på nytt og krever at det er kildeversjonens registrerte. Teksten *er*
-- derfor det `workflow.verification_source_access` kaller
-- `verifiable_representation`: et lagret og etterprøvbart øyeblikksbilde av
-- kildeversjonen. `api.control_source_representation(...)` gir kontrolleddet
-- den — og bare den, og bare til en identitet i et av de to kontrolleddene, med
-- en åpen kjøring som tilhører den.
--
-- Det er en snevrere lesevei enn den som allerede finnes: den samme teksten
-- forlater databasen som en del av hver eneste agentoppgave
-- (`api.agent_task_payload(uuid)`). Den eksterne modellen som skrev utkastet,
-- har altså allerede sett hele artikkelen; kontrollen som skal etterprøve
-- utkastet, er den ene som ikke kunne. Kjøreren regner selv sha256 av teksten
-- den får, og sammenligner med kildeversjonens `content_hash` fra dossieret, så
-- kontrollen hviler ikke på at databasen bekrefter sin egen verdi.
--
-- Originaldokumentet er ikke avløst. Har kjøringen filen, brukes den som før —
-- det er den sterkeste formen, fordi den i tillegg viser at teksten lar seg
-- gjenskape av oppskriften. Den registrerte representasjonen er veien for de
-- kjøringene som ikke har filen, og uten den ville de ikke kontrollert i det
-- hele tatt.
--
-- Styrende dokumenter: AGENTS.md, docs/ANTIDEP_CONSTITUTION.md (regel 3, 4, 7),
-- docs/EVIDENCE_PIPELINE.md, docs/DATABASE_ARCHITECTURE.md, docs/ROADMAP.md.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Innleggingen en trigger kan gjøre
--
-- Den samme raden, det samme sporet og den samme idempotensen som
-- `api.enqueue_pipeline_job(text, text, jsonb)` — uten mandatkontrollen, som
-- ikke har noen kaller å gjelde, og uten en eneste verdi fra utsiden.
-- ----------------------------------------------------------------------------
create function workflow.chain_enqueue_job(
  p_agent_role provenance.agent_role,
  p_job_key text,
  p_input_manifest jsonb,
  p_actor_id uuid,
  p_agent_identity_id uuid,
  p_handoff boolean,
  p_note text
)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_job workflow.pipeline_jobs;
  v_problem text;
begin
  if p_actor_id is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En kjedeovergang må kunne tilskrives en aktør.',
      hint = 'Aktøren er den agentkjøringen eller det mennesket hvis arbeid utløste overgangen. En jobb uten opphav ville vært arbeid ingen kan spore tilbake (ANTIDEP_CONSTITUTION.md regel 7).';
  end if;

  select j.* into v_job
  from workflow.pipeline_jobs j
  where j.agent_role = p_agent_role and j.job_key = p_job_key;

  -- Finnes den, er dette den samme jobben. Ingen sammenligning av manifestet og
  -- ingen avvisning: en kjedeovergang oppgir ikke noe, den utleder alt, og den
  -- eneste grunnen til at den kjøres om igjen er at noe ble prøvd på nytt.
  if found then
    return null;
  end if;

  begin
    insert into workflow.pipeline_jobs
      (agent_role, job_key, input_manifest, enqueued_by_actor_id)
    values
      (p_agent_role, p_job_key, p_input_manifest, p_actor_id)
    returning * into v_job;
  exception
    -- To samtidige overganger om det samme arbeidet er fortsatt ett stykke
    -- arbeid. Den som taper kappløpet, skriver ingenting.
    when unique_violation then
      return null;
  end;

  -- Sporet bærer opphavet: agentidentiteten når arbeidet foran var en
  -- agentkjøring, aktøren ellers. Radens CHECK krever nøyaktig én av dem.
  perform workflow.record_pipeline_job_event(
    v_job.id, null, 'ready'::workflow.pipeline_job_state, 0,
    case when p_agent_identity_id is null then p_actor_id end,
    p_agent_identity_id,
    p_note);

  if p_handoff then
    insert into workflow.agent_handoff_jobs (pipeline_job_id, registered_by_actor_id)
    values (v_job.id, p_actor_id);

    -- Den samme forhåndskontrollen `api.enqueue_agent_task(text, jsonb)` kjører,
    -- med den samme funksjonen. En oppgave som ikke kan bygges av grunnlaget som
    -- faktisk ligger der, skal ikke stå i køen og se ut som noe som venter på en
    -- kjører (ANTIDEP_CONSTITUTION.md regel 4). Kastet fanges av overgangens
    -- egen underblokk, som ruller innleggingen tilbake og lar det kliniske
    -- arbeidet stå.
    v_problem := workflow.agent_task_input_problem(v_job);
    if v_problem is not null then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = v_problem;
    end if;
  end if;

  return v_job.id;
end;
$$;

comment on function workflow.chain_enqueue_job(provenance.agent_role, text, jsonb, uuid, uuid, boolean, text) is
  'Legger inn ett stykke arbeid på vegne av en automatisk kjedeovergang, idempotent på (agent_role, job_key) og uten en eneste verdi fra en kaller: manifestet er utledet av rader som allerede finnes. Skriver det samme sporet og den samme raden som api.enqueue_pipeline_job(text, text, jsonb), og for en ekstern agentoppgave i tillegg workflow.agent_handoff_jobs og den samme forhåndskontrollen av grunnlaget. Svarer NULL når jobben fantes fra før eller tapte et kappløp om nøkkelen. Ingen mandatkontroll, fordi en overgang ikke har noen kaller å kreve mandat av — mandatet ble kontrollert på skriveveien som skrev raden overgangen utløses av. Kalles fra innsiden av en trigger eller en api-funksjon som allerede har fastslått hvem kalleren er, og er derfor ikke SECURITY DEFINER.';

revoke execute on function workflow.chain_enqueue_job(provenance.agent_role, text, jsonb, uuid, uuid, boolean, text) from public;

-- ----------------------------------------------------------------------------
-- Subjektet en ekstern agentoppgave handler om
--
-- Den samme utledningen `api.enqueue_agent_task(text, jsonb)` gjør, løftet ut
-- slik at innleggingen og duplikatkontrollen leser den samme. To formuleringer
-- ville før eller siden gitt en kjedeovergang som ikke kjente igjen oppgaven en
-- redaktør allerede hadde lagt inn — og da ville den lagt inn den samme en gang
-- til, under et annet navn.
-- ----------------------------------------------------------------------------
create function workflow.agent_task_manifest_subject(
  p_agent_role provenance.agent_role,
  p_input_manifest jsonb
)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  select case p_agent_role
    when 'evidence_extraction' then coalesce(p_input_manifest ->> 'source_version_id', '?')
    when 'claim_synthesis' then format('%s+%s',
      coalesce(p_input_manifest ->> 'subject_drug_id', '?'),
      coalesce(p_input_manifest ->> 'topic_concept_id', '?'))
    else coalesce(p_input_manifest ->> 'claim_revision_id', '?')
  end;
$$;

comment on function workflow.agent_task_manifest_subject(provenance.agent_role, jsonb) is
  'Hva en ekstern agentoppgave handler om, i klartekst: kildeversjonen, virkestoffet og temaet, eller påstandsrevisjonen. Den samme utledningen api.enqueue_agent_task(text, jsonb) bruker til å bygge jobbnøkkelen, løftet ut slik at innleggingen og duplikatkontrollen i kjedeovergangene leser nøyaktig den samme — to formuleringer ville latt en overgang legge inn en oppgave som allerede fantes under et annet navn.';

revoke execute on function workflow.agent_task_manifest_subject(provenance.agent_role, jsonb) from public;

create function workflow.agent_task_job_key(
  p_agent_role provenance.agent_role,
  p_input_manifest jsonb
)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  select format('agent-handoff:%s:%s',
    workflow.agent_task_manifest_subject(p_agent_role, p_input_manifest),
    left(encode(sha256(convert_to(p_input_manifest::text, 'UTF8')), 'hex'), 12));
$$;

comment on function workflow.agent_task_job_key(provenance.agent_role, jsonb) is
  'Jobbnøkkelen for én ekstern agentoppgave: subjektet i klartekst, med et kort avtrykk av hele inndatamanifestet bak. Ordrett den samme formen api.enqueue_agent_task(text, jsonb) har bygget siden migrasjon 010c, løftet ut slik at kjedeovergangene ikke kan bygge en annen.';

revoke execute on function workflow.agent_task_job_key(provenance.agent_role, jsonb) from public;

-- ----------------------------------------------------------------------------
-- «Har dette subjektet allerede en oppgave i dette leddet?»
--
-- Spørsmålet nøkkelen alene ikke kan svare på. To avgrensninger av det samme
-- subjektet er to forskjellige nøkler med vilje — det er riktig når en redaktør
-- ber om to forskjellige oppdrag — men en automatisk overgang skal aldri lage
-- det andre. Den spør derfor om subjektet, ikke om nøkkelen.
-- ----------------------------------------------------------------------------
create function workflow.agent_task_subject_queued(
  p_agent_role provenance.agent_role,
  p_subject text
)
  returns boolean
  language sql
  stable
  set search_path = ''
as $$
  select exists (
    select 1
    from workflow.pipeline_jobs j
    where j.agent_role = p_agent_role
      and j.job_key like 'agent-handoff:' || p_subject || ':%'
  );
$$;

comment on function workflow.agent_task_subject_queued(provenance.agent_role, text) is
  'Om det allerede finnes en ekstern agentoppgave om dette subjektet i dette agentleddet, uansett tilstand og uansett hvem som la den inn. Finnes for at en automatisk kjedeovergang ikke skal kunne lage en andre, semantisk lik oppgave når grunnlaget vokser med ett funn: nøkkelen ville da vært en annen, og unikheten på (agent_role, job_key) ville ikke fanget det. Leser jobbnøkkelens eget subjektledd, slik at en oppgave lagt inn av en redaktør og en lagt inn av kjeden er den samme oppgaven. Spørsmålet er bare sant under workflow.lock_chain_subject(provenance.agent_role, text): uten låsen er svaret et øyeblikksbilde to samtidige overganger begge kan lese som nei.';

revoke execute on function workflow.agent_task_subject_queued(provenance.agent_role, text) from public;

-- ----------------------------------------------------------------------------
-- Og låsen som gjør svaret over sant
--
-- Unikheten på `(agent_role, job_key)` serialiserer bare de overgangene som
-- kommer fram til den *samme* nøkkelen. For `claim_synthesis` gjør de ikke det:
-- nøkkelen bærer et avtrykk av hele inndatamanifestet, og manifestet inneholder
-- evidenssettet. To kontroller av *forskjellige* funn på det samme virkestoffet
-- og endepunktet kan derfor kjøre samtidig, begge lese «ingen oppgave» fordi
-- den andres rad ikke er commitet ennå, bygge hvert sitt sett — {A} og {B} —
-- og få hver sin nøkkel. Da fanger unikheten ingenting, og subjektet får to
-- semantisk like oppgaver.
--
-- Låsen gjør spørsmålet og innleggingen til ett udelelig steg per subjekt. Den
-- er en rådgivende transaksjonslås og ikke en radlås, fordi det ikke finnes noen
-- rad å låse: det som skal serialiseres, er *fraværet* av en jobb. Samme grep
-- som `workflow.record_technical_incident(...)` bruker på observasjonsnummeret,
-- og det virker av samme grunn: Data API-et kjører READ COMMITTED, så den som
-- venter på låsen, leser på nytt med et ferskt øyeblikksbilde og ser da raden
-- vinneren commitet.
--
-- Nøkkelrommet er navngitt med rollen foran subjektet, slik at to ledd om det
-- samme subjektet ikke venter på hverandre uten grunn.
-- ----------------------------------------------------------------------------
create function workflow.lock_chain_subject(
  p_agent_role provenance.agent_role,
  p_subject text
)
  returns void
  language sql
  set search_path = ''
as $$
  select pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('antidep:kjede-subjekt:' || p_agent_role::text || ':' || p_subject, 0));
$$;

comment on function workflow.lock_chain_subject(provenance.agent_role, text) is
  'Serialiserer alle kjedeoverganger om det samme subjektet i det samme agentleddet, slik at spørsmålet workflow.agent_task_subject_queued(provenance.agent_role, text) stiller, og innleggingen som følger, er ett udelelig steg. En rådgivende transaksjonslås og ikke en radlås, fordi det som skal serialiseres er fraværet av en jobb: det finnes ingen rad å låse. Uten den kunne to samtidige kontroller av forskjellige evidensfunn på det samme virkestoffet og endepunktet begge lest «ingen oppgave», bygget hvert sitt evidenssett og fått hver sin jobbnøkkel — og unikheten på (agent_role, job_key) ville ikke fanget det.';

revoke execute on function workflow.lock_chain_subject(provenance.agent_role, text) from public;

-- ----------------------------------------------------------------------------
-- Hvem overgangen tilskrives
--
-- Arbeidet foran er enten en agentkjøring eller et menneske med mandat. Er det
-- en kjøring, bærer sporet agentidentiteten — det er den som faktisk gjorde
-- arbeidet som utløste overgangen. Er det et menneske, bærer det aktøren.
-- ----------------------------------------------------------------------------
create function workflow.chain_origin(
  p_agent_run_id uuid,
  p_fallback_actor_id uuid,
  out actor_id uuid,
  out agent_identity_id uuid
)
  language plpgsql
  stable
  set search_path = ''
as $$
begin
  if p_agent_run_id is not null then
    select r.actor_id, r.agent_identity_id
      into actor_id, agent_identity_id
    from provenance.agent_runs r
    where r.id = p_agent_run_id;
    if actor_id is not null then
      return;
    end if;
  end if;
  actor_id := p_fallback_actor_id;
  agent_identity_id := null;
end;
$$;

comment on function workflow.chain_origin(uuid, uuid) is
  'Hvem en automatisk kjedeovergang tilskrives: agentkjøringens egen identitet og aktør når arbeidet foran var en kjøring, og ellers aktøren som skrev raden. Finnes fordi workflow.pipeline_job_events krever nøyaktig én av de to, og fordi «hvem utløste dette» skal være en opplysning og ikke en gjetning.';

revoke execute on function workflow.chain_origin(uuid, uuid) from public;

-- ----------------------------------------------------------------------------
-- 2. Kontrolleddenes egne jobbnøkler
--
-- Ikke `agent-handoff:`-formen, og det er ikke en detalj: en kontrolljobb er
-- Antideps egen deterministiske kode og skal aldri kunne hentes ut på
-- agentflaten. `workflow.agent_handoff_jobs` er det som avgjør det, og
-- kontrolljobbene får ingen slik rad — men to forskjellige nøkkelformer gjør
-- forskjellen lesbar også for et menneske som ser i køen.
-- ----------------------------------------------------------------------------
create function workflow.control_job_key(p_kind text, p_subject uuid)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  select format('kontroll:%s:%s', p_kind, p_subject);
$$;

comment on function workflow.control_job_key(text, uuid) is
  'Jobbnøkkelen for ett deterministisk kontrolledd om én rad. Utledet av hva kontrollen gjelder og ingenting annet, slik at den samme kontrollen lagt inn to ganger er én jobb. Egen form og ikke agent-handoff:, fordi et kontrolledd er Antideps egen kode og aldri en ekstern agentoppgave (ANTIDEP_CONSTITUTION.md regel 3).';

revoke execute on function workflow.control_job_key(text, uuid) from public;

-- ----------------------------------------------------------------------------
-- 3. De fem overgangene
--
-- Hver av dem er en funksjon som svarer på ett spørsmål: «hva er neste skritt
-- for denne raden, og er grunnlaget for det på plass nå?» De kalles to steder —
-- fra triggeren, som er den autoritative overgangen, og fra reparasjonsveien,
-- som tar igjen det en teknisk svikt etterlot. To kopier ville vært to
-- forskjellige kjeder.
-- ----------------------------------------------------------------------------

-- Ekstraksjonskontrollen, av et registrert evidensfunn.
create function workflow.chain_control_for_evidence_item(p_evidence_item_id uuid)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_item knowledge.evidence_items;
  v_origin record;
begin
  select e.* into v_item
  from knowledge.evidence_items e
  where e.id = p_evidence_item_id;

  if not found then
    return null;
  end if;

  -- Et funn som allerede bærer et gjeldende maskinbevis, er kontrollert. En ny
  -- kontroll ville vært en ny rad uten et nytt svar.
  if workflow.grounding_machine_proved(p_evidence_item_id) then
    return null;
  end if;

  v_origin := workflow.chain_origin(v_item.agent_run_id, v_item.created_by_actor_id);

  return workflow.chain_enqueue_job(
    'extraction_verification'::provenance.agent_role,
    workflow.control_job_key('ekstraksjon', p_evidence_item_id),
    jsonb_build_object(
      'evidence_item_id', p_evidence_item_id,
      'source_version_id', v_item.source_version_id),
    v_origin.actor_id,
    v_origin.agent_identity_id,
    false,
    'Ekstraksjonskontrollen lagt i køen av det registrerte evidensfunnet.');
end;
$$;

comment on function workflow.chain_control_for_evidence_item(uuid) is
  'Legger ekstraksjonskontrollen av ett evidensfunn i køen, som en vanlig pipelinejobb i rollen extraction_verification. Idempotent på jobbnøkkelen, og hopper over et funn som allerede bærer et gjeldende maskinbevis. Svarer med jobbens id, eller NULL når ingenting ble lagt inn.';

revoke execute on function workflow.chain_control_for_evidence_item(uuid) from public;

-- Synteseoppgaven, av en bestått ekstraksjonskontroll.
create function workflow.chain_task_for_verified_extraction(p_evidence_item_id uuid)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_item knowledge.evidence_items;
  v_verification workflow.evidence_verifications;
  v_origin record;
  v_manifest jsonb;
  v_subject text;
  v_evidence_ids uuid[];
  v_population_ids uuid[];
begin
  select e.* into v_item
  from knowledge.evidence_items e
  where e.id = p_evidence_item_id;

  if not found then
    return null;
  end if;

  -- Den gjeldende kontrollen er den siste. Et senere avvik opphever en tidligere
  -- bekreftelse, og da er porten ikke bestått (ANTIDEP_CONSTITUTION.md regel 4).
  select ev.* into v_verification
  from workflow.evidence_verifications ev
  where ev.evidence_item_id = p_evidence_item_id
  order by ev.registration_ordinal desc
  limit 1;

  if not found or v_verification.outcome <> 'verified' then
    return null;
  end if;

  -- En påstand som allerede finnes for det samme temaet og virkestoffet, er
  -- ikke automatikkens å skrive om. Å revidere en påstand i lys av ny evidens
  -- er en redaksjonell avgjørelse om hva påstanden skal si.
  if exists (
    select 1
    from knowledge.claims c
    where c.topic_concept_id = v_item.outcome_concept_id
      and c.subject_drug_id = v_item.intervention_drug_id
  ) then
    return null;
  end if;

  -- Låsen først, og deretter spørsmålet. Uten den rekkefølgen kan to samtidige
  -- kontroller av forskjellige funn på det samme subjektet begge lese «ingen
  -- oppgave» og legge inn hver sin, fordi evidenssettet — og dermed nøkkelen —
  -- blir forskjellig.
  v_subject := format('%s+%s', v_item.intervention_drug_id, v_item.outcome_concept_id);
  perform workflow.lock_chain_subject('claim_synthesis'::provenance.agent_role, v_subject);

  if workflow.agent_task_subject_queued('claim_synthesis'::provenance.agent_role, v_subject) then
    return null;
  end if;

  -- Hele grunnlaget som er brukbart nå, og ikke bare funnet som utløste
  -- overgangen: en syntese som utelot et funn som motsier påstanden, ville
  -- hvilt på et annet grunnlag enn det som finnes (ANTIDEP_CONSTITUTION.md
  -- regel 4). Settet leses én gang, og jobben lages bare én gang, så manifestet
  -- er stabilt.
  select array_agg(e.id order by e.id), array_agg(distinct e.population_id)
      filter (where e.population_id is not null)
    into v_evidence_ids, v_population_ids
  from knowledge.evidence_items e
  where e.outcome_concept_id = v_item.outcome_concept_id
    and e.intervention_drug_id = v_item.intervention_drug_id
    and workflow.evidence_usable_problem(array[e.id], 'x') is null;

  if v_evidence_ids is null or cardinality(v_evidence_ids) = 0 then
    return null;
  end if;

  v_manifest := jsonb_build_object(
    'topic_concept_id', v_item.outcome_concept_id,
    'subject_drug_id', v_item.intervention_drug_id,
    'evidence_item_ids', to_jsonb(v_evidence_ids));

  if v_population_ids is not null and cardinality(v_population_ids) > 0 then
    v_manifest := v_manifest || jsonb_build_object(
      'population_ids', to_jsonb(workflow.sorted_unique(v_population_ids)));
  end if;

  v_origin := workflow.chain_origin(
    v_verification.agent_run_id, v_verification.verifier_actor_id);

  return workflow.chain_enqueue_job(
    'claim_synthesis'::provenance.agent_role,
    workflow.agent_task_job_key('claim_synthesis'::provenance.agent_role, v_manifest),
    v_manifest,
    v_origin.actor_id,
    v_origin.agent_identity_id,
    true,
    'Synteseoppgaven lagt i køen av den beståtte ekstraksjonskontrollen.');
end;
$$;

comment on function workflow.chain_task_for_verified_extraction(uuid) is
  'Legger synteseoppgaven i køen når ekstraksjonskontrollen av ett evidensfunn er bestått. Grunnlaget er hele settet av brukbare funn på det samme virkestoffet og endepunktet, lest med workflow.evidence_usable_problem(uuid[], text) — den samme funksjonen skriveveien leser — og ikke bare funnet som utløste overgangen. Gjør ingenting når den gjeldende kontrollen ikke bekrefter, når temaet og virkestoffet allerede har en påstand, eller når leddet allerede har en oppgave om det samme subjektet. Svarer med jobbens id, eller NULL.';

revoke execute on function workflow.chain_task_for_verified_extraction(uuid) from public;

-- Kildestøttekontrollen, av en registrert påstandsrevisjon.
create function workflow.chain_control_for_claim_revision(p_claim_revision_id uuid)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_revision knowledge.claim_revisions;
  v_origin record;
begin
  select r.* into v_revision
  from knowledge.claim_revisions r
  where r.id = p_claim_revision_id;

  if not found then
    return null;
  end if;

  -- En revisjon som allerede er kontrollert mot grunnlaget slik det er nå,
  -- trenger ingen ny kontroll. Endrer evidenssettet seg, er den gjeldende
  -- kontrollen foreldet, og porten foran vurderingen sier det selv.
  if exists (
    select 1
    from workflow.claim_verifications cv
    where cv.claim_revision_id = p_claim_revision_id
  ) then
    return null;
  end if;

  v_origin := workflow.chain_origin(v_revision.agent_run_id, v_revision.created_by_actor_id);

  return workflow.chain_enqueue_job(
    'citation_support_verification'::provenance.agent_role,
    workflow.control_job_key('kildestotte', p_claim_revision_id),
    jsonb_build_object('claim_revision_id', p_claim_revision_id),
    v_origin.actor_id,
    v_origin.agent_identity_id,
    false,
    'Kildestøttekontrollen lagt i køen av den registrerte påstandsrevisjonen.');
end;
$$;

comment on function workflow.chain_control_for_claim_revision(uuid) is
  'Legger kildestøttekontrollen av én påstandsrevisjon i køen, som en vanlig pipelinejobb i rollen citation_support_verification. Idempotent på jobbnøkkelen, og hopper over en revisjon som allerede er kontrollert. Svarer med jobbens id, eller NULL.';

revoke execute on function workflow.chain_control_for_claim_revision(uuid) from public;

-- Evidensvurderingen, av en bestått kildestøttekontroll.
create function workflow.chain_task_for_verified_claim(p_claim_revision_id uuid)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_revision knowledge.claim_revisions;
  v_verification workflow.claim_verifications;
  v_origin record;
  v_manifest jsonb;
begin
  select r.* into v_revision
  from knowledge.claim_revisions r
  where r.id = p_claim_revision_id;

  if not found then
    return null;
  end if;

  select cv.* into v_verification
  from workflow.claim_verifications cv
  where cv.claim_revision_id = p_claim_revision_id
  order by cv.registration_ordinal desc
  limit 1;

  if not found or v_verification.outcome <> 'verified' then
    return null;
  end if;

  -- Manifestet her er bare påstandsrevisjonen, så nøkkelen er deterministisk og
  -- unikheten ville fanget et kappløp uansett. Låsen står likevel, av den samme
  -- grunnen som over: invarianten «ett subjekt, én oppgave» skal holde fordi
  -- den er håndhevet, ikke fordi manifestet tilfeldigvis er smalt i dag.
  perform workflow.lock_chain_subject(
    'evidence_assessment'::provenance.agent_role, p_claim_revision_id::text);

  if workflow.agent_task_subject_queued(
       'evidence_assessment'::provenance.agent_role, p_claim_revision_id::text) then
    return null;
  end if;

  v_manifest := jsonb_build_object('claim_revision_id', p_claim_revision_id);
  v_origin := workflow.chain_origin(
    v_verification.agent_run_id, v_verification.verifier_actor_id);

  return workflow.chain_enqueue_job(
    'evidence_assessment'::provenance.agent_role,
    workflow.agent_task_job_key('evidence_assessment'::provenance.agent_role, v_manifest),
    v_manifest,
    v_origin.actor_id,
    v_origin.agent_identity_id,
    true,
    'Evidensvurderingen lagt i køen av den beståtte kildestøttekontrollen.');
end;
$$;

comment on function workflow.chain_task_for_verified_claim(uuid) is
  'Legger evidensvurderingen i køen når kildestøttekontrollen av én påstandsrevisjon er bestått. Selve vilkårene — at kontrollen er gjeldende, bekreftet, gjort med mandat og gjelder nøyaktig det evidenssettet som ligger der nå — leses av workflow.agent_task_input_problem(workflow.pipeline_jobs) i innleggingen, med de samme funksjonene skriveveien bruker. Gjør ingenting når kontrollen ikke bekrefter eller revisjonen allerede har en vurderingsoppgave. Svarer med jobbens id, eller NULL.';

revoke execute on function workflow.chain_task_for_verified_claim(uuid) from public;

-- ----------------------------------------------------------------------------
-- Kandidaten, av en registrert evidensvurdering
--
-- Det siste automatiske skrittet, og grensen mot det som skal være et menneskes.
-- Kandidaten er det ferdige produktet forseglet med sitt eget avtrykk; det som
-- gjenstår etter den, er at en navngitt fagperson vurderer det i den samme
-- visningen klinikeren får (ANTIDEP_CONSTITUTION.md regel 5).
--
-- Byggingen er løftet ut av `api.build_candidate(uuid)` slik at de to veiene —
-- redaktørens kall og kjedeovergangen — bygger nøyaktig det samme innholdet med
-- den samme gaten. En andre byggefunksjon ville vært en andre kandidatform.
-- ----------------------------------------------------------------------------
create function knowledge.build_candidate_row(p_claim_revision_id uuid, p_actor_id uuid)
  returns jsonb
  language plpgsql
  set search_path = ''
as $$
declare
  v_content jsonb;
  v_digest text;
  v_evidence_digest text;
  v_candidate knowledge.candidates;
  v_built boolean := false;
begin
  -- Den samme gaten publiseringen bruker. Kandidaten forsegler et ferdig
  -- agentresultat, og et resultat som ikke er ferdig — uten kontroll, uten
  -- dekning, uten vurdering, uten mandat — skal ikke kunne forsegles og se
  -- ferdig ut (ANTIDEP_CONSTITUTION.md regel 4).
  perform knowledge.assert_claim_revision_ready_for_approval(p_claim_revision_id);

  v_content := knowledge.candidate_content(p_claim_revision_id);
  v_digest := knowledge.source_version_content_hash(v_content::text);
  v_evidence_digest := knowledge.claim_evidence_set_digest(p_claim_revision_id);

  select c.* into v_candidate
  from knowledge.candidates c
  where c.claim_revision_id = p_claim_revision_id and c.candidate_digest = v_digest;

  if not found then
    insert into knowledge.candidates
      (claim_revision_id, candidate_digest, evidence_set_digest, content, built_by_actor_id)
    values (p_claim_revision_id, v_digest, v_evidence_digest, v_content, p_actor_id)
    returning * into v_candidate;
    v_built := true;
  end if;

  return jsonb_build_object(
    'candidate_id', v_candidate.id,
    'claim_revision_id', v_candidate.claim_revision_id,
    'candidate_digest', v_candidate.candidate_digest,
    'evidence_set_digest', v_candidate.evidence_set_digest,
    'built', v_built
  );
end;
$$;

comment on function knowledge.build_candidate_row(uuid, uuid) is
  'Forsegler kandidatinnholdet for én påstandsrevisjon og svarer med kandidaten. Kroppen er ordrett den api.build_candidate(uuid) hadde i migrasjon 009e, med aktøren som parameter framfor hentet av mandatkontrollen: de to veiene inn — redaktørens kall og den automatiske kjedeovergangen etter en registrert evidensvurdering — skal bygge nøyaktig det samme innholdet og kjøre nøyaktig den samme gaten. Idempotent: uendret innhold gir den samme kandidaten og skriver ingen ny rad. Autentiserer ingenting selv og er derfor ikke SECURITY DEFINER; den kalles fra innsiden av en funksjon eller en trigger som allerede har fastslått opphavet.';

revoke execute on function knowledge.build_candidate_row(uuid, uuid) from public;

create or replace function api.build_candidate(p_claim_revision_id uuid)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
begin
  v_actor_id := knowledge.assert_editor_authorized();
  return knowledge.build_candidate_row(p_claim_revision_id, v_actor_id);
end;
$$;

comment on function api.build_candidate(uuid) is
  'Forsegler det agentferdige kandidatinnholdet for én påstandsrevisjon (ANTIDEP_CONSTITUTION.md regel 5, DATABASE_ARCHITECTURE.md §43). Krever en registrert, aktiv aktør med gyldig editor-rolle og bygger gjennom knowledge.build_candidate_row(uuid, uuid), som er den samme veien den automatiske kjedeovergangen etter en registrert evidensvurdering går: gaten, innholdet og avtrykket er identiske uansett hvem som utløste byggingen. Idempotent: uendret innhold gir den samme kandidaten og skriver ingen ny rad, mens endret innhold gir en ny kandidat med et nytt avtrykk. Publiserer ingenting. SECURITY DEFINER med tomt search_path fordi knowledge, workflow og provenance har RLS med default deny (§50).';

create function workflow.chain_candidate_for_assessment(p_claim_revision_id uuid)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_assessment knowledge.evidence_assessments;
  v_origin record;
  v_result jsonb;
begin
  select a.* into v_assessment
  from knowledge.evidence_assessments a
  where a.claim_revision_id = p_claim_revision_id
  order by a.created_at desc
  limit 1;

  if not found then
    return null;
  end if;

  -- Låsene i den rekkefølgen DATABASE_ARCHITECTURE.md §49 fastsetter: påstand →
  -- revisjon → kandidat, med delt lås på hvert lenket evidensfunn og hver kilde
  -- under dem. Skriveveien som skrev vurderingen, har allerede tatt revisjonen;
  -- her kommer kandidatsiden, i den samme rekkefølgen, slik at ingen
  -- ekstraksjonskontroll eller tilbaketrukket kilde kan commite i vinduet
  -- mellom regningen av avtrykket og raden.
  perform knowledge.lock_candidate_inputs(p_claim_revision_id);

  v_origin := workflow.chain_origin(
    v_assessment.agent_run_id, v_assessment.created_by_actor_id);

  v_result := knowledge.build_candidate_row(p_claim_revision_id, v_origin.actor_id);
  return (v_result ->> 'candidate_id')::uuid;
end;
$$;

comment on function workflow.chain_candidate_for_assessment(uuid) is
  'Forsegler kandidaten når evidensvurderingen av én påstandsrevisjon er registrert, gjennom knowledge.build_candidate_row(uuid, uuid) og dermed gjennom den samme gaten api.build_candidate(uuid) kjører. Tar låsene i den rekkefølgen DATABASE_ARCHITECTURE.md §49 fastsetter. Kaster når gaten ikke holder — da er kjeden ikke ferdig, og overgangens egen underblokk lar det kliniske arbeidet stå. Svarer med kandidatens id.';

revoke execute on function workflow.chain_candidate_for_assessment(uuid) from public;

-- ----------------------------------------------------------------------------
-- 4. Innkapslingen: en overgang som svikter, stopper arbeidet og ikke svaret
--
-- `when others` er ellers forbudt i dette repoet, og med god grunn: en
-- programmeringsfeil som blir til «grunnlaget er ikke klart», er en teknisk feil
-- forkledd som en faglig tilstand (ANTIDEP_CONSTITUTION.md regel 4). Her er
-- bruken den motsatte. Ingenting gjøres om til en faglig tilstand: svikten blir
-- nøyaktig det den er — et teknisk problem, registrert som teknisk problem, med
-- arbeidet stående. Alternativet ville vært å rulle tilbake et registrert
-- agentsvar fordi neste skritt ikke lot seg legge inn.
--
-- Diagnosen er Antideps egen setning og bærer SQLSTATE og ikke feilteksten:
-- en videreformidlet melding kan navngi en påstand eller et kildeutdrag, og den
-- hører ikke hjemme i en teknisk logg (DATABASE_ARCHITECTURE.md §57).
-- ----------------------------------------------------------------------------
create function workflow.chain_step_signature(p_step text)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  select 'kjede:' || p_step;
$$;

comment on function workflow.chain_step_signature(text) is
  'Signaturen et stoppet kjedeledd får i workflow.technical_incidents. Per ledd og ikke per rad: «overgangen til kildestøttekontroll har stoppet fjorten ganger» er opplysningen en drift trenger, mens fjorten rader om hver sin påstandsrevisjon ville vært fjorten lamper for det samme problemet.';

revoke execute on function workflow.chain_step_signature(text) from public;

create function workflow.chain_note_failure(p_step text, p_subject uuid, p_sqlstate text)
  returns void
  language plpgsql
  set search_path = ''
as $$
begin
  perform workflow.record_technical_incident(
    'automatic_task'::workflow.technical_area,
    workflow.chain_step_signature(p_step),
    format(
      'Den automatiske overgangen %s stoppet for %s med SQLSTATE %s. Arbeidet står, og '
      'api.resume_chain_transitions(text, text) tar det opp igjen ved neste kjøring av '
      'kontrolleddet. Selve registreringen foran overgangen er uberørt.',
      p_step, p_subject, p_sqlstate));
end;
$$;

comment on function workflow.chain_note_failure(text, uuid, text) is
  'Registrerer at en automatisk kjedeovergang stoppet, som et teknisk problem under området automatic_task. Diagnosen er Antideps egen setning med leddet, raden og SQLSTATE — aldri den videreformidlede feilteksten, som kan navngi en påstand eller et kildeutdrag (DATABASE_ARCHITECTURE.md §57). En stoppet overgang er teknisk observability og aldri en ny menneskeoppgave (ANTIDEP_CONSTITUTION.md regel 4).';

revoke execute on function workflow.chain_note_failure(text, uuid, text) from public;

create function workflow.chain_resolve_step(p_step text)
  returns void
  language plpgsql
  set search_path = ''
as $$
begin
  perform workflow.resolve_technical_incident(
    'automatic_task'::workflow.technical_area, workflow.chain_step_signature(p_step));
end;
$$;

comment on function workflow.chain_resolve_step(text) is
  'Lukker det tekniske problemet for ett kjedeledd. Kalles bare fra rekonsilieringen i api.resume_chain_transitions(text, text), og bare når den gikk gjennom *hele* leddet uten en eneste teknisk svikt. Aldri fra en overgang som lyktes: signaturen er per ledd og ikke per rad, så en overgang som lyktes for subjekt B sier ingenting om den som fortsatt svikter for subjekt A — og et «løst» som hvilte på det, ville vært usant. Et problem som ikke lenger består, lukkes ved neste kontrollkjøring, som uansett går hvert kvarter.';

revoke execute on function workflow.chain_resolve_step(text) from public;

-- ----------------------------------------------------------------------------
-- 5. Triggerne
--
-- På tabellene og ikke på skriveveiene. En trigger kan ikke glemmes slik et
-- kall kan, og den gjelder derfor like mye for den autonome MCP-kjøreren, for
-- recovery-importen og for et menneske med mandat — tre veier inn som ellers
-- måtte huske det samme skrittet hver for seg.
-- ----------------------------------------------------------------------------
create function workflow.chain_after_evidence_item()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
declare
  v_state text;
begin
  begin
    perform workflow.chain_control_for_evidence_item(new.id);
  exception
    -- Grunnlaget er ikke klart. Kjeden står, og det er porten som gjør jobben
    -- sin — ikke en teknisk svikt. Nøyaktig de tre klassene
    -- workflow.evidence_usable_problem(uuid[], text) fanger, og av samme grunn.
    when restrict_violation or no_data_found or invalid_parameter_value then
      null;
    when others then
      get stacked diagnostics v_state = returned_sqlstate;
      perform workflow.chain_note_failure('ekstraksjonskontroll', new.id, v_state);
  end;
  return null;
end;
$$;

comment on function workflow.chain_after_evidence_item() is
  'Legger ekstraksjonskontrollen i køen i det samme kallet som registrerte evidensfunnet. Svikter innleggingen, blir det et teknisk problem under automatic_task og aldri en avvist registrering: neste skritt som ikke lot seg legge inn, er ikke en grunn til å kaste det faglige arbeidet som nettopp ble gjort.';

revoke execute on function workflow.chain_after_evidence_item() from public;

create trigger evidence_items_queue_extraction_control
  after insert on knowledge.evidence_items
  for each row execute function workflow.chain_after_evidence_item();

create function workflow.chain_after_evidence_verification()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
declare
  v_state text;
begin
  if new.outcome <> 'verified' then
    return null;
  end if;

  begin
    perform workflow.chain_task_for_verified_extraction(new.evidence_item_id);
  exception
    -- Grunnlaget er ikke klart. Kjeden står, og det er porten som gjør jobben
    -- sin — ikke en teknisk svikt. Nøyaktig de tre klassene
    -- workflow.evidence_usable_problem(uuid[], text) fanger, og av samme grunn.
    when restrict_violation or no_data_found or invalid_parameter_value then
      null;
    when others then
      get stacked diagnostics v_state = returned_sqlstate;
      perform workflow.chain_note_failure('syntese', new.evidence_item_id, v_state);
  end;
  return null;
end;
$$;

comment on function workflow.chain_after_evidence_verification() is
  'Legger synteseoppgaven i køen når en ekstraksjonskontroll bekrefter funnet. Bare verified utløser noe: et avvik er et resultat kjeden skal stoppe på, ikke gå videre fra (ANTIDEP_CONSTITUTION.md regel 4). Ligger på tabellen og gjelder derfor både den deterministiske kontrollen og en menneskelig kildekontroll.';

revoke execute on function workflow.chain_after_evidence_verification() from public;

create trigger evidence_verifications_queue_synthesis
  after insert on workflow.evidence_verifications
  for each row execute function workflow.chain_after_evidence_verification();

create function workflow.chain_after_claim_revision()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
declare
  v_state text;
begin
  begin
    perform workflow.chain_control_for_claim_revision(new.id);
  exception
    -- Grunnlaget er ikke klart. Kjeden står, og det er porten som gjør jobben
    -- sin — ikke en teknisk svikt. Nøyaktig de tre klassene
    -- workflow.evidence_usable_problem(uuid[], text) fanger, og av samme grunn.
    when restrict_violation or no_data_found or invalid_parameter_value then
      null;
    when others then
      get stacked diagnostics v_state = returned_sqlstate;
      perform workflow.chain_note_failure('kildestottekontroll', new.id, v_state);
  end;
  return null;
end;
$$;

comment on function workflow.chain_after_claim_revision() is
  'Legger kildestøttekontrollen i køen i det samme kallet som registrerte påstandsrevisjonen. Samme innkapsling som de øvrige overgangene: en svikt stopper arbeidet og ikke registreringen.';

revoke execute on function workflow.chain_after_claim_revision() from public;

create trigger claim_revisions_queue_citation_control
  after insert on knowledge.claim_revisions
  for each row execute function workflow.chain_after_claim_revision();

create function workflow.chain_after_claim_verification()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
declare
  v_state text;
begin
  if new.outcome <> 'verified' then
    return null;
  end if;

  begin
    perform workflow.chain_task_for_verified_claim(new.claim_revision_id);
  exception
    -- Grunnlaget er ikke klart. Kjeden står, og det er porten som gjør jobben
    -- sin — ikke en teknisk svikt. Nøyaktig de tre klassene
    -- workflow.evidence_usable_problem(uuid[], text) fanger, og av samme grunn.
    when restrict_violation or no_data_found or invalid_parameter_value then
      null;
    when others then
      get stacked diagnostics v_state = returned_sqlstate;
      perform workflow.chain_note_failure('evidensvurdering', new.claim_revision_id, v_state);
  end;
  return null;
end;
$$;

comment on function workflow.chain_after_claim_verification() is
  'Legger evidensvurderingen i køen når kildestøttekontrollen bekrefter påstanden. Bare verified utløser noe, av samme grunn som på ekstraksjonssiden.';

revoke execute on function workflow.chain_after_claim_verification() from public;

create trigger claim_verifications_queue_assessment
  after insert on workflow.claim_verifications
  for each row execute function workflow.chain_after_claim_verification();

create function workflow.chain_after_evidence_assessment()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
declare
  v_state text;
begin
  begin
    perform workflow.chain_candidate_for_assessment(new.claim_revision_id);
  exception
    -- Grunnlaget er ikke klart. Kjeden står, og det er porten som gjør jobben
    -- sin — ikke en teknisk svikt. Nøyaktig de tre klassene
    -- workflow.evidence_usable_problem(uuid[], text) fanger, og av samme grunn.
    when restrict_violation or no_data_found or invalid_parameter_value then
      null;
    when others then
      get stacked diagnostics v_state = returned_sqlstate;
      perform workflow.chain_note_failure('kandidat', new.claim_revision_id, v_state);
  end;
  return null;
end;
$$;

comment on function workflow.chain_after_evidence_assessment() is
  'Forsegler kandidaten når evidensvurderingen er registrert, og fører dermed kjeden helt fram til den ene handlingen som skal være et menneskes: en navngitt fagpersons sluttkontroll av det ferdige produktet (ANTIDEP_CONSTITUTION.md regel 5). Holder gaten ikke, er kandidaten ikke klar, og overgangen stopper uten å røre vurderingen som nettopp ble registrert.';

revoke execute on function workflow.chain_after_evidence_assessment() from public;

create trigger evidence_assessments_build_candidate
  after insert on knowledge.evidence_assessments
  for each row execute function workflow.chain_after_evidence_assessment();

-- ----------------------------------------------------------------------------
-- 6. Kontrollkjørerens lesevei til den registrerte representasjonen
--
-- Teksten kildeversjonens fingeravtrykk ble beregnet av, og ingenting annet.
-- Ikke originalfilen: den blir liggende der den er, utilgjengelig for enhver
-- klientrolle. Se hodekommentaren for hvorfor dette er den samme formen for
-- kildegrunnlag som en gjenskapning fra dokumentet gir.
-- ----------------------------------------------------------------------------
create function api.control_source_representation(
  p_identity_key text,
  p_secret text,
  p_agent_run_id uuid,
  p_source_version_id uuid
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_identity provenance.agent_identities;
  v_identity_id uuid;
  v_version knowledge.source_versions;
  v_text text;
begin
  -- Rollen er ikke en parameter: identiteten bærer den, og bare de to
  -- deterministiske kontrolleddene kan lese her. En semantisk rolle har ingen
  -- bruk for veien — den får artikkelen i oppgaven sin — og en rolle som kunne
  -- lese kildeteksten uten en oppgave, ville vært en vei utenom avgrensningen.
  select i.* into v_identity
  from provenance.agent_identities i
  where i.identity_key = p_identity_key;

  if not found or v_identity.agent_role not in
       ('extraction_verification'::provenance.agent_role,
        'citation_support_verification'::provenance.agent_role) then
    raise exception using
      errcode = 'insufficient_privilege',
      message = 'Den registrerte representasjonen leses bare av de deterministiske kontrolleddene.',
      hint = 'Kildeteksten forlater databasen som en del av en agentoppgave, eller til ekstraksjonskontrollen og kildestøttekontrollen. Ingen annen rolle har en vei hit.';
  end if;

  v_identity_id := provenance.authenticate_agent_identity(
    p_identity_key, p_secret, v_identity.agent_role);

  -- En åpen kjøring som tilhører nøyaktig denne identiteten. Den samme
  -- bindingen api.extraction_verification_input(text, text, uuid, uuid) krever,
  -- og av samme grunn: en lesning av kildeteksten skal etterlate seg en
  -- proveniensrad, ikke bare et vellykket kall.
  perform provenance.assert_agent_run_open(p_agent_run_id, v_identity_id);

  select sv.* into v_version
  from knowledge.source_versions sv
  where sv.id = p_source_version_id;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Kildeversjonen finnes ikke.';
  end if;

  v_text := knowledge.source_version_text(p_source_version_id);

  return jsonb_build_object(
    'source_version_id', v_version.id,
    'content_hash', v_version.content_hash,
    'representation', v_version.representation::text,
    -- NULL og ikke en tom streng: en kildeversjon uten lagret representasjon er
    -- en opplysning kontrollen skal handle på — den konkluderer da ikke — og
    -- ikke en tekst uten innhold, som den ville lett forgjeves i.
    'text', v_text);
end;
$$;

comment on function api.control_source_representation(text, text, uuid, uuid) is
  'Den lagrede, etterprøvbare representasjonen av én kildeversjon, til et av de to deterministiske kontrolleddene. Teksten er nøyaktig den kildeversjonens content_hash ble beregnet av — en trigger på knowledge.source_version_texts regner avtrykket ut på nytt og krever at det er kildeversjonens registrerte — og er derfor det workflow.verification_source_access kaller verifiable_representation. Originalfilen forlater aldri databasen her. Krever en identitet i rollen extraction_verification eller citation_support_verification, riktig hemmelighet, og en åpen kjøring som tilhører identiteten, slik at ingen lesning av kildetekst skjer uten en proveniensrad. Svarer med text = null når ingen representasjon er lagret; kontrollen konkluderer da ikke. SECURITY DEFINER fordi knowledge har RLS med default deny; EXECUTE går til anon og authenticated av samme grunn som for de øvrige agentveiene — en agent har ingen brukerkonto, og det er legitimasjonen og ikke Data API-rollen som er kontrollen.';

revoke execute on function api.control_source_representation(text, text, uuid, uuid) from public;
grant execute on function api.control_source_representation(text, text, uuid, uuid) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- 7. Reparasjonsveien
--
-- Triggeren er den autoritative overgangen. Denne er den som tar igjen det en
-- teknisk svikt etterlot — en tapt forbindelse midt i en transaksjon, en
-- kontroll som ikke var ferdig da vurderingen kom, en jobb som ble stående.
--
-- Den er ikke en poller som erstatter en tilstandsovergang: overgangen har
-- allerede skjedd i databasen, og dette er lesningen av hva som *mangler* i
-- forhold til den tilstanden. Den legger aldri inn noe en trigger ikke ville
-- lagt inn, og den tar ikke imot ett eneste felt fra kalleren.
--
-- Den kalles av kontrollkjøreren selv, med kontrolleddets egen legitimasjon,
-- fordi det er den kjøringen som uansett går med jevne mellomrom. Fullmakten
-- veien gir, er nøyaktig «kjeden går videre slik tilstanden allerede tilsier» —
-- ikke mer, fordi ingen verdi utenfra kan nå inn i den.
-- ----------------------------------------------------------------------------
create function api.resume_chain_transitions(p_identity_key text, p_secret text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  -- Hvor mange rader én rekonsiliering ser på per ledd. Grensen er ikke bare en
  -- kostnadsgrense: den avgjør om passeringen *så hele leddet*, og dermed om den
  -- i det hele tatt kan uttale seg om at leddet er friskt igjen.
  v_limit constant integer := 200;
  v_identity provenance.agent_identities;
  v_row record;
  v_state text;
  v_queued integer := 0;
  v_candidates integer := 0;
  v_seen integer;
  v_failed boolean;
begin
  select i.* into v_identity
  from provenance.agent_identities i
  where i.identity_key = p_identity_key;

  if not found or v_identity.agent_role not in
       ('extraction_verification'::provenance.agent_role,
        'citation_support_verification'::provenance.agent_role) then
    raise exception using
      errcode = 'insufficient_privilege',
      message = 'Kjedeoverganger tas opp igjen av de deterministiske kontrolleddene.',
      hint = 'Veien legger aldri inn noe annet enn det databasens egen tilstand allerede tilsier, og tar ikke imot ett eneste felt fra kalleren.';
  end if;

  perform provenance.authenticate_agent_identity(
    p_identity_key, p_secret, v_identity.agent_role);

  -- --------------------------------------------------------------------
  -- Ekstraksjonskontroller som mangler.
  --
  -- Hvert ledd telles og rekonsilieres for seg. `v_failed` er det som avgjør
  -- om leddets tekniske problem kan lukkes, og `v_seen < v_limit` er det som
  -- avgjør om denne passeringen i det hele tatt så hele leddet: en passering
  -- som stoppet på grensen, kan ikke vite om raden bak den fortsatt svikter.
  -- --------------------------------------------------------------------
  v_seen := 0;
  v_failed := false;
  for v_row in
    select e.id
    from knowledge.evidence_items e
    where not exists (
      select 1 from workflow.pipeline_jobs j
      where j.agent_role = 'extraction_verification'::provenance.agent_role
        and j.job_key = workflow.control_job_key('ekstraksjon', e.id))
    order by e.created_at
    limit v_limit
  loop
    v_seen := v_seen + 1;
    begin
      if workflow.chain_control_for_evidence_item(v_row.id) is not null then
        v_queued := v_queued + 1;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('ekstraksjonskontroll', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if not v_failed and v_seen < v_limit then
    perform workflow.chain_resolve_step('ekstraksjonskontroll');
  end if;

  -- Synteseoppgaver som mangler.
  v_seen := 0;
  v_failed := false;
  for v_row in
    select distinct ev.evidence_item_id as id
    from workflow.evidence_verifications ev
    where ev.outcome = 'verified'
    order by 1
    limit v_limit
  loop
    v_seen := v_seen + 1;
    begin
      if workflow.chain_task_for_verified_extraction(v_row.id) is not null then
        v_queued := v_queued + 1;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('syntese', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if not v_failed and v_seen < v_limit then
    perform workflow.chain_resolve_step('syntese');
  end if;

  -- Kildestøttekontroller som mangler.
  v_seen := 0;
  v_failed := false;
  for v_row in
    select r.id
    from knowledge.claim_revisions r
    where not exists (
      select 1 from workflow.pipeline_jobs j
      where j.agent_role = 'citation_support_verification'::provenance.agent_role
        and j.job_key = workflow.control_job_key('kildestotte', r.id))
    order by r.created_at
    limit v_limit
  loop
    v_seen := v_seen + 1;
    begin
      if workflow.chain_control_for_claim_revision(v_row.id) is not null then
        v_queued := v_queued + 1;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('kildestottekontroll', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if not v_failed and v_seen < v_limit then
    perform workflow.chain_resolve_step('kildestottekontroll');
  end if;

  -- Evidensvurderinger som mangler.
  v_seen := 0;
  v_failed := false;
  for v_row in
    select distinct cv.claim_revision_id as id
    from workflow.claim_verifications cv
    where cv.outcome = 'verified'
    order by 1
    limit v_limit
  loop
    v_seen := v_seen + 1;
    begin
      if workflow.chain_task_for_verified_claim(v_row.id) is not null then
        v_queued := v_queued + 1;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('evidensvurdering', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if not v_failed and v_seen < v_limit then
    perform workflow.chain_resolve_step('evidensvurdering');
  end if;

  -- Kandidater som mangler. Gaten avgjør, som i overgangen: en revisjon som
  -- ikke er ferdig, forseglet ikke, og det er ikke en feil — det er kjeden som
  -- ikke er kommet dit ennå. De tre klassene som betyr nettopp det, går derfor
  -- stille; alt annet er en teknisk svikt og skal telles som en, akkurat som i
  -- de fire leddene over. Et `when others` som svelget uten å registrere, ville
  -- gjort den ene svikten som *ikke* har en trigger bak seg, usynlig.
  v_seen := 0;
  v_failed := false;
  for v_row in
    select distinct a.claim_revision_id as id
    from knowledge.evidence_assessments a
    where not exists (
      select 1 from knowledge.candidates c where c.claim_revision_id = a.claim_revision_id)
    order by 1
    limit v_limit
  loop
    v_seen := v_seen + 1;
    begin
      if workflow.chain_candidate_for_assessment(v_row.id) is not null then
        v_candidates := v_candidates + 1;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('kandidat', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if not v_failed and v_seen < v_limit then
    perform workflow.chain_resolve_step('kandidat');
  end if;

  return jsonb_build_object('queued', v_queued, 'candidates_built', v_candidates);
end;
$$;

comment on function api.resume_chain_transitions(text, text) is
  'Tar igjen de automatiske kjedeovergangene en teknisk svikt etterlot, og rekonsilierer samtidig det tekniske bildet. Leser hva databasens egen tilstand tilsier og legger inn nøyaktig det triggerne ville lagt inn — de samme funksjonene, de samme portene, den samme idempotensen — og tar ikke imot ett eneste felt fra kalleren. Den erstatter ingen tilstandsovergang: overgangen har allerede skjedd, og dette er lesningen av hva som mangler i forhold til den. Hvert ledd rekonsilieres for seg, og leddets tekniske problem lukkes bare når passeringen kom gjennom *hele* leddet uten en eneste teknisk svikt: en overgang som lyktes for ett subjekt, sier ingenting om den som fortsatt svikter for et annet, og en passering som stoppet på grensen, vet ikke hva som står bak den. Krever en identitet i et av de to deterministiske kontrolleddene, fordi det er den kjøringen som uansett går med jevne mellomrom. Svarer med hvor mange jobber som ble lagt inn og hvor mange kandidater som ble forseglet. SECURITY DEFINER fordi knowledge, workflow og provenance har RLS med default deny; EXECUTE går til anon og authenticated av samme grunn som for de øvrige agentveiene.';

revoke execute on function api.resume_chain_transitions(text, text) from public;
grant execute on function api.resume_chain_transitions(text, text) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- 8. Arbeidsoversikten lærer kontrolljobbene å kjenne
--
-- `api.public_work_board()` sier allerede hva slags arbeid en kontrolljobb er —
-- `findings_check` og `claim_check` sto der fra migrasjon 011. Det den ikke
-- kunne, var å si hvilket virkestoff kontrollen gjelder: manifestet peker på et
-- evidensfunn, og oppslaget kjente bare kildeversjonen, syntesen og
-- påstandsrevisjonen. En rad uten virkestoff er ikke feil, men den er mindre
-- verdt for den som leser — og kontrolleddene er nå det som oftest står i køen.
-- ----------------------------------------------------------------------------
create or replace function workflow.work_board_drugs(p_manifest jsonb)
  returns text[]
  language sql
  stable
  set search_path = ''
as $$
  select coalesce(array_agg(name order by name), array[]::text[])
  from (
    select distinct d.canonical_name as name
    from catalog.drugs d
    where d.id = any (coalesce(
          workflow.manifest_uuids(p_manifest, 'drug_ids'), array[]::uuid[]))
       or d.id = workflow.manifest_uuid(p_manifest, 'subject_drug_id')
       or d.id in (
            select r.subject_drug_id
            from knowledge.claim_revisions r
            where r.id = workflow.manifest_uuid(p_manifest, 'claim_revision_id')
          )
       or d.id in (
            select e.intervention_drug_id
            from knowledge.evidence_items e
            where e.id = workflow.manifest_uuid(p_manifest, 'evidence_item_id')
          )
    limit 5
  ) picked;
$$;

comment on function workflow.work_board_drugs(jsonb) is
  'Hvilke virkestoff en pipelinejobb gjelder, lest av jobbens eget inndatamanifest — direkte for en ekstraksjon eller en syntese, gjennom påstandsrevisjonen for en evidensvurdering og for en kildestøttekontroll, og gjennom evidensfunnet for en ekstraksjonskontroll. Finnes for at den åpne arbeidsoversikten skal kunne si noe klinisk meningsfullt uten å navngi artikkelen.';

-- ----------------------------------------------------------------------------
-- 9. Når arbeidet kjeden la i køen, blir kastet
--
-- `knowledge.discard_unpublished_extraction_artifacts(...)` og
-- `knowledge.discard_unpublished_claim_artifacts(...)` sletter upubliserte
-- artefakter etter en eksplisitt avgjørelse. Kontrolljobben kjeden la inn, peker
-- på raden gjennom inndatamanifestet og ikke gjennom en fremmednøkkel, så den
-- blir stående igjen — og ville blitt tatt ut, feilet tre ganger og endt som et
-- uløst teknisk problem om noe som var ment å forsvinne.
--
-- Jobben lukkes derfor her, med en begrunnelse som sier hva som skjedde. Det er
-- riktig tilstand og ikke en opprydding: arbeidet *kommer* aldri til å bli gjort,
-- og `failed` er nettopp «blir stående framfor å prøves i det uendelige». Sporet
-- beholdes, som alle andre overganger.
--
-- Triggeren ligger på tabellene og ikke på slettefunksjonene, av samme grunn som
-- resten: en trigger kan ikke glemmes av en slettevei som kommer senere.
-- ----------------------------------------------------------------------------
create function workflow.chain_close_discarded_job(
  p_agent_role provenance.agent_role,
  p_kind text,
  p_subject uuid
)
  returns void
  language plpgsql
  set search_path = ''
as $$
declare
  v_job workflow.pipeline_jobs;
begin
  select j.* into v_job
  from workflow.pipeline_jobs j
  where j.agent_role = p_agent_role
    and j.job_key = workflow.control_job_key(p_kind, p_subject)
    and j.state in ('ready', 'leased')
  for update;

  if not found then
    return;
  end if;

  update workflow.pipeline_jobs j
  set state = 'failed',
      leased_by_agent_identity_id = null,
      lease_token = null,
      lease_expires_at = null,
      completed_at = now(),
      failure_reason = 'Raden kontrollen gjaldt, er kastet. Arbeidet kommer ikke til å bli gjort.'
  where j.id = v_job.id;

  perform workflow.record_pipeline_job_event(
    v_job.id, v_job.state, 'failed'::workflow.pipeline_job_state, v_job.attempts,
    v_job.enqueued_by_actor_id, null,
    'Kontrollen ble lukket fordi raden den gjaldt, ble kastet.');

  -- `workflow.track_pipeline_job_incident()` åpner et teknisk problem for hver
  -- jobb som går til `failed`. Det er riktig for en jobb som ga opp, og feil
  -- for denne: ingenting er teknisk galt, og en lampe her ville bedt en admin
  -- se på noe som var ment å skje. Episoden lukkes derfor med det samme, og
  -- står igjen i sporet som den korte hendelsen den var.
  perform workflow.resolve_technical_incident(
    'automatic_task'::workflow.technical_area, 'pipeline-job:' || v_job.id::text);
end;
$$;

comment on function workflow.chain_close_discarded_job(provenance.agent_role, text, uuid) is
  'Lukker den kontrolljobben kjeden la inn for en rad som siden er kastet. Jobben peker på raden gjennom inndatamanifestet og ikke gjennom en fremmednøkkel, så uten dette ville den blitt tatt ut, feilet til forsøkene var brukt opp og endt som et uløst teknisk problem om noe som var ment å forsvinne. Tilstanden blir failed, fordi arbeidet aldri kommer til å bli gjort, og det tekniske problemet den overgangen ellers åpner, lukkes med det samme: ingenting er teknisk galt her.';

revoke execute on function workflow.chain_close_discarded_job(provenance.agent_role, text, uuid) from public;

create function workflow.chain_after_evidence_item_discarded()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  perform workflow.chain_close_discarded_job(
    'extraction_verification'::provenance.agent_role, 'ekstraksjon', old.id);
  return null;
end;
$$;

comment on function workflow.chain_after_evidence_item_discarded() is
  'Lukker ekstraksjonskontrollen i køen når evidensfunnet den gjaldt, kastes.';

revoke execute on function workflow.chain_after_evidence_item_discarded() from public;

create trigger evidence_items_close_extraction_control
  after delete on knowledge.evidence_items
  for each row execute function workflow.chain_after_evidence_item_discarded();

create function workflow.chain_after_claim_revision_discarded()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  perform workflow.chain_close_discarded_job(
    'citation_support_verification'::provenance.agent_role, 'kildestotte', old.id);
  return null;
end;
$$;

comment on function workflow.chain_after_claim_revision_discarded() is
  'Lukker kildestøttekontrollen i køen når påstandsrevisjonen den gjaldt, kastes.';

revoke execute on function workflow.chain_after_claim_revision_discarded() from public;

create trigger claim_revisions_close_citation_control
  after delete on knowledge.claim_revisions
  for each row execute function workflow.chain_after_claim_revision_discarded();
