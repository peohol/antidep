-- ============================================================================
-- Migrasjon 005n — mennesket får den skriveveien maskinen allerede har
--
-- `workflow.claim_verifier_has_mandate(uuid, uuid, timestamptz)` (migrasjon
-- 005j) har fra første stund hatt to grener: en agent med rollen
-- citation_support_verification, og **et menneske med gyldig reviewer-rolle for
-- innholdsområdet**. Bare den første har hatt en skrivevei. Den andre grenen har
-- vært håndhevet, prøvd og dokumentert — men uadresserbar, fordi den eneste
-- api-funksjonen inn i tabellen krever agentlegitimasjon og en åpen agentkjøring.
--
-- Det er nettopp den grenen ANTIDEP_CONSTITUTION.md §12 hviler på. Den
-- deterministiske kontrollen kan per konstruksjon ikke gi `verified`: tre av de
-- sju kontrollpunktene krever språkforståelse eller kunnskap om evidens som
-- ikke er registrert (MVP_IMPLEMENTATION_PLAN.md §74.35), og
-- `claim_verifications_verified_requires_all_ok_check` krever at alle sju
-- holder. Uten denne migrasjonen kan ingen påstand noensinne komme forbi G9.
--
-- ----------------------------------------------------------------------------
-- Hva som IKKE er nytt her, og det er poenget
--
-- Ingen regel er lagt til, myket opp eller omgått. Mandatet er det samme
-- uttrykket, dekningskontrollen den samme funksjonen, `verified`-kravet den
-- samme CHECK-en, append-only den samme triggeren, og selvverifikasjon den samme
-- constrainten. Den nye api-funksjonen legger til nøyaktig én ting maskinveien
-- ikke trenger: at revieweren må oppgi avtrykket av det evidenssettet hen
-- faktisk så, slik at en lenke som kommer til mens vurderingen pågår, avviser
-- registreringen framfor å bli stilltiende dekket av den.
--
-- ----------------------------------------------------------------------------
-- Hvorfor selve registreringen flyttes ut i én funksjon
--
-- Fra nå av finnes det to skriveveier inn i workflow.claim_verifications. De
-- skal håndheve nøyaktig de samme invariantene — hvilke lenker som er lovlige,
-- at kildetilgangen er den svakeste av lenkenes, at evidensfunnet leses fra
-- lenken og ikke fra kalleren, at dekningen kontrolleres umiddelbart. Skrevet to
-- ganger ville de kunnet komme i utakt, og da ville den ene veien sluppet
-- gjennom det den andre stengte. Samme begrunnelse som mandatet selv har for å
-- ligge i én boolsk funksjon framfor i to triggere.
--
-- Registreringen ligger derfor i workflow.record_claim_verification(...), og
-- begge api-funksjonene kaller den. Den kjenner ingen legitimasjon og ingen
-- sesjon: den tar aktøren som allerede er autentisert, og skriver.
--
-- api.register_claim_verification(...) erstattes med
-- `create or replace function` — fremover-skrivende, ikke en retusjert linje i
-- 005k, fordi 20260908093000 allerede er kjørt i det hostede prosjektet (§74.32).
-- Signatur, rettigheter, svar og avvisninger er uendret. Den ene forskjellen er
-- rekkefølgen: legitimasjonen kontrolleres nå før vokabularverdiene, som er
-- strammere og ikke løsere.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §4, §6, §9, §10, §11, §12, §14
--   docs/CONTENT_GOVERNANCE.md §11 kvalifisert reviewer
--   docs/DATABASE_ARCHITECTURE.md §30, §43, §46, §48, §50, §57
--   docs/EVIDENCE_PIPELINE.md §39-§41
--   docs/MVP_IMPLEMENTATION_PLAN.md §15, §16, §49, §74.30, §74.35
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. workflow.assert_reviewer_authorized(uuid) — kalleren som reviewer
--
-- Speilbildet av knowledge.assert_editor_authorized(uuid) for reviewer-rollen,
-- med de samme tre kravene i den samme rekkefølgen, og med en egen melding for
-- hvert av dem: en avvisning som ikke sier hvilket krav som sviktet, er en
-- avvisning brukeren ikke kan gjøre noe med.
--
-- Rollen leses fra workflow.user_roles og aldri fra en JWT-claim
-- (DATABASE_ARCHITECTURE.md §46); auth.uid() brukes bare til identitet.
-- Gyldigheten måles med statement_timestamp() og ikke now(), slik at en
-- tilbakekalling virker umiddelbart (§74.6).
--
-- Funksjonen er *ikke* selve autorisasjonen for raden. Den er skriveveiens
-- kontroll, og gir en lesbar avvisning før noe skrives; radens egen garanti er
-- workflow.enforce_claim_verifier_mandate() og
-- workflow.enforce_reviewer_qualification(), som håndhever mandatet på radens
-- eget tidspunkt uansett hvordan den kom dit.
-- ----------------------------------------------------------------------------
create function workflow.assert_reviewer_authorized(p_scope_concept_id uuid default null)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_retired_at timestamptz;
begin
  select a.id, a.retired_at into v_actor_id, v_retired_at
  from provenance.actors a
  where a.auth_user_id = auth.uid();

  -- KI-aktørene har auth_user_id NULL (actors_auth_user_is_human_check), så et
  -- treff her er alltid et menneske; ingen egen actor_type-kontroll trengs.
  if v_actor_id is null then
    raise exception using
      errcode = 'insufficient_privilege',
      message = 'Kontoen din er ikke knyttet til en aktør i Antidep.',
      hint = 'En faglig vurdering skal attribueres til en navngitt person (ANTIDEP_CONSTITUTION.md §12, §14). En kaller uten aktørrad kan ikke registrere en vurdering i sitt eget navn. Ta kontakt med en administrator for å få kontoen din knyttet til en aktør.';
  end if;

  if v_retired_at is not null then
    raise exception using
      errcode = 'insufficient_privilege',
      message = 'Aktøren er trukket tilbake og kan ikke registrere en faglig vurdering.',
      hint = 'En tilbaketrukket aktør beholder hele sin historikk, men kan ikke utføre nye handlinger.';
  end if;

  if not exists (
    select 1
    from workflow.user_roles ur
    where ur.user_id = auth.uid()
      and ur.role_code = 'reviewer'
      and ur.valid_from <= statement_timestamp()
      and (ur.valid_to is null or ur.valid_to > statement_timestamp())
      -- Uten et begrep å kontrollere mot gjelder enhver gyldig tildeling. Med et
      -- begrep gjelder en uavgrenset tildeling fortsatt alt, mens en avgrenset
      -- må dekke nøyaktig det begrepet.
      and (
        p_scope_concept_id is null
        or ur.scope_id is null
        or ur.scope_id = p_scope_concept_id
      )
  ) then
    if p_scope_concept_id is null then
      raise exception using
        errcode = 'insufficient_privilege',
        message = 'Brukeren har ikke gyldig reviewer-rolle.',
        hint = 'Rollen leses fra workflow.user_roles, ikke fra en JWT-claim (DATABASE_ARCHITECTURE.md §46). editor-rollen gir ikke faglig godkjenningsrett, og admin gir det heller ikke: å registrere innhold og å gå god for det er forskjellige handlinger (MVP_IMPLEMENTATION_PLAN.md §16).';
    else
      raise exception using
        errcode = 'insufficient_privilege',
        message = 'Brukeren har ikke gyldig reviewer-rolle for dette innholdsområdet.',
        hint = 'Rollen leses fra workflow.user_roles, ikke fra en JWT-claim (DATABASE_ARCHITECTURE.md §46). En avgrenset reviewer-tildeling må dekke det kliniske temaet påstanden hører under. editor- og admin-rollene gir ikke faglig godkjenningsrett.';
    end if;
  end if;

  return v_actor_id;
end;
$$;

comment on function workflow.assert_reviewer_authorized(uuid) is
  'Kontrollerer at den innloggede brukeren har en registrert, ikke-tilbaketrukket aktør og en gyldig reviewer-rolle på kallets eget tidspunkt (statement_timestamp(), ikke transaksjonens starttidspunkt, slik at en tilbakekalling virker umiddelbart — MVP_IMPLEMENTATION_PLAN.md §74.6), og returnerer aktørens id. Speilbildet av knowledge.assert_editor_authorized(uuid) for den faglige rollen (ANTIDEP_CONSTITUTION.md §12). Avviser aldri stille: hvert krav har sin egen feilmelding. Med et klinisk begrep som argument må en avgrenset tildeling dekke nøyaktig det begrepet. Funksjonen er skriveveiens kontroll og ikke radens garanti — den siste er workflow.enforce_claim_verifier_mandate() og workflow.enforce_reviewer_qualification(), som håndhever mandatet på radens eget tidspunkt uansett hvordan raden kom dit. Kalles fra innsiden av en SECURITY DEFINER-funksjon og trenger derfor ikke være det selv.';

revoke execute on function workflow.assert_reviewer_authorized(uuid) from public;

-- ----------------------------------------------------------------------------
-- 2. workflow.assert_evidence_set_unchanged(uuid, text)
--
-- «Godkjenn det du faktisk så.» En menneskelig vurdering tar tid: flaten leses,
-- kildene slås opp, konklusjonen skrives. Kommer det en evidenslenke til i det
-- vinduet, gjelder vurderingen et annet grunnlag enn det som ble vurdert — og
-- den nye lenken kan være nettopp den motstridende evidensen kontrollen skulle
-- lete etter (ANTIDEP_CONSTITUTION.md §9).
--
-- Publiseringsgatens G9b og G13 fanger det samme ved publisering, og de er
-- fasiten. Denne kontrollen kommer i tillegg og har en annen hensikt: den lar
-- revieweren få vite det med en gang, framfor at en registrert vurdering står i
-- basen som en vurdering av noe annet enn den var. Databasen eier fortsatt
-- avtrykket som lagres; parameteren er bare det kalleren så.
--
-- Agentveien har ikke vilkåret, og det er en avlesning og ikke en glipp:
-- lesegrunnlaget og registreringen skjer i samme kjøring, millisekunder fra
-- hverandre, og signaturen til api.register_claim_verification(...) er allerede
-- i produksjon.
-- ----------------------------------------------------------------------------
create function workflow.assert_evidence_set_unchanged(
  p_claim_revision_id uuid,
  p_seen_evidence_set_digest text
)
  returns void
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_current text;
begin
  v_current := knowledge.claim_evidence_set_digest(p_claim_revision_id);

  if v_current is distinct from p_seen_evidence_set_digest then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Evidensgrunnlaget er endret etter at du hentet det fram.',
      hint = 'Vurderingen din gjelder det evidenssettet du faktisk så. Hent revisjonen fram på nytt, gå gjennom det som er kommet til, og registrer vurderingen på det fullstendige grunnlaget (ANTIDEP_CONSTITUTION.md §9, KNOWLEDGE_MODEL.md §19.2).';
  end if;
end;
$$;

comment on function workflow.assert_evidence_set_unchanged(uuid, text) is
  'Krever at evidenssettet til en påstandsrevisjon fortsatt er det kalleren oppgir å ha sett (knowledge.claim_evidence_set_digest). Brukes av de menneskelige skriveveiene, der det går tid mellom å lese grunnlaget og å konkludere: en lenke som kommer til i det vinduet, ville ellers blitt stilltiende dekket av en vurdering som aldri så den (ANTIDEP_CONSTITUTION.md §9). Kommer i tillegg til publiseringsgatens G9b og G13, som er fasiten ved publisering; denne sier fra med en gang framfor å la en vurdering av noe annet bli stående. SECURITY DEFINER fordi evidenslenkene ligger bak RLS med default deny; funksjonen leser bare og returnerer ingen data.';

revoke execute on function workflow.assert_evidence_set_unchanged(uuid, text) from public;

-- ----------------------------------------------------------------------------
-- 3. workflow.record_claim_verification(...) — selve registreringen, ett sted
--
-- Kroppen er den api.register_claim_verification(...) hadde fra migrasjon 005k,
-- uendret, med autentiseringen tatt ut: den hører til flaten, ikke til
-- registreringen. Rekkefølgen på kontrollene er bevart nøyaktig, inkludert at en
-- revisjon som ikke finnes avvises før en tom kontrollradliste gjør det.
--
-- Fire ting er bevisst ikke parametre kalleren kan velge fritt, av samme grunn
-- som i 005k:
--
--   verifier_actor_id                  avgjort av flaten, av kjøringen eller av
--                                      sesjonen — aldri oppgitt av kalleren
--   verified_revision_creator_actor_id leses fra revisjonen selv
--   verified_evidence_set_digest       beregnes av databasen (005j)
--   source_access                      utledes som den svakeste av lenkenes
-- ----------------------------------------------------------------------------
create function workflow.record_claim_verification(
  p_claim_revision_id uuid,
  p_verifier_actor_id uuid,
  p_agent_run_id uuid,
  p_outcome text,
  p_source_support text,
  p_population_match text,
  p_comparator_match text,
  p_timeframe_match text,
  p_direction_and_magnitude text,
  p_qualifiers_complete text,
  p_contradictory_evidence_represented text,
  p_citations jsonb,
  p_rationale text,
  p_findings text
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_outcome workflow.verification_outcome;
  v_checks workflow.verification_check_result[];
  v_creator_actor_id uuid;
  v_source_access workflow.verification_source_access;
  v_verification_id uuid;
  v_unknown text;
begin
  -- Vokabularparametrene castes først og for seg, slik at en ukjent verdi gir en
  -- setning som sier hva som er galt, framfor en fremmednøkkelfeil lenger ned.
  -- Vokabularene er offentlig dokumentert (DATABASE_ARCHITECTURE.md §30), så
  -- meldingene røper ingenting autentiseringen skjuler.
  begin
    v_outcome := p_outcome::workflow.verification_outcome;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke et kjent verifikasjonsutfall.', p_outcome),
        hint = 'Gyldige utfall er verified, needs_correction, rejected og uncertain (DATABASE_ARCHITECTURE.md §30).';
  end;

  begin
    v_checks := array[
      p_source_support, p_population_match, p_comparator_match, p_timeframe_match,
      p_direction_and_magnitude, p_qualifiers_complete,
      p_contradictory_evidence_represented
    ]::workflow.verification_check_result[];
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Ett eller flere av de sju kontrollpunktene har en ukjent verdi.',
        hint = 'Gyldige verdier er ok, deviation og not_assessable (DATABASE_ARCHITECTURE.md §30). not_assessable er ikke det samme som ok.';
  end;

  if jsonb_typeof(p_citations) is distinct from 'array' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'p_citations må være en jsonb-liste av kontrollerte evidenslenker.',
      hint = 'Hvert element skal ha claim_evidence_link_id, source_access og relationship_supported, og kan ha source_version_id, checked_content_hash og finding.';
  end if;

  -- Hvem som formulerte revisjonen leses her, ikke oppgis av kalleren:
  -- claim_verifications_revision_fkey håndhever at raden peker på den virkelige
  -- forfatteren, og en verdi kalleren kunne valgt fritt ville vært nøyaktig den
  -- innsnikingen kontrollen finnes for å hindre.
  select r.created_by_actor_id into v_creator_actor_id
  from knowledge.claim_revisions r
  where r.id = p_claim_revision_id;

  if v_creator_actor_id is null then
    raise exception using
      errcode = 'no_data_found',
      message = format('Påstandsrevisjonen %L finnes ikke.', p_claim_revision_id),
      hint = 'Publisering og verifikasjon peker på en eksakt revisjon, ikke på påstandsidentiteten (KNOWLEDGE_MODEL.md §19.3). Kontroller revisjons-ID-en.';
  end if;

  -- En kontrollrad som viser til en lenke fra en annen revisjon — eller til en
  -- lenke som ikke finnes — avvises med en setning som sier hvilken. De
  -- sammensatte fremmednøklene ville fanget det uansett, men da med en melding
  -- som ikke sier hva kalleren gjorde galt.
  select string_agg(distinct value ->> 'claim_evidence_link_id', ', ')
    into v_unknown
  from jsonb_array_elements(p_citations)
  where not exists (
    select 1
    from knowledge.claim_evidence_links l
    where l.id = nullif(value ->> 'claim_evidence_link_id', '')::uuid
      and l.claim_revision_id = p_claim_revision_id
  );

  if v_unknown is not null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Evidenslenker som ikke tilhører denne revisjonen: %s.', v_unknown),
      hint = 'Hver kontrollrad skal vise til en knowledge.claim_evidence_links-rad på nøyaktig den revisjonen som kontrolleres.';
  end if;

  -- Den samlede kildetilgangen er den svakeste av lenkenes. Var den kallerstyrt,
  -- kunne en kontroll der én lenke bare hadde et sammendrag blitt registrert som
  -- original_source, og ANTIDEP_CONSTITUTION.md §11 sitt forbud mot å godkjenne
  -- på andre agenters sammendrag ville vært omgåelig ved å aggregere.
  begin
    select c.access into v_source_access
    from (
      select (value ->> 'source_access')::workflow.verification_source_access as access
      from jsonb_array_elements(p_citations)
    ) as c
    order by workflow.source_access_strength(c.access), c.access
    limit 1;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'En av kontrollradene oppgir en ukjent kildetilgang.',
        hint = 'Gyldige verdier er original_source, verifiable_representation og derived_summary (ANTIDEP_CONSTITUTION.md §11).';
  end;

  if v_source_access is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Kontrollen oppgir ingen kontrollerte evidenslenker.',
      hint = 'En kontroll av en påstand er en kontroll mot et bestemt grunnlag. Registrer én kontrollrad per evidenslenke på revisjonen (ANTIDEP_CONSTITUTION.md §4, §11).';
  end if;

  insert into workflow.claim_verifications (
    claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id,
    outcome, source_access,
    source_support, population_match, comparator_match, timeframe_match,
    direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
    findings, rationale, verified_at, agent_run_id
  )
  values (
    p_claim_revision_id, v_creator_actor_id, p_verifier_actor_id,
    v_outcome, v_source_access,
    v_checks[1], v_checks[2], v_checks[3], v_checks[4],
    v_checks[5], v_checks[6], v_checks[7],
    p_findings, p_rationale, now(), p_agent_run_id
  )
  returning id into v_verification_id;

  -- Evidensfunnet leses fra lenken, ikke fra kalleren, av samme grunn som
  -- forfatteren over: da kan ingen kontrollrad påstå å ha kontrollert lenke L
  -- mot et annet funn enn det L faktisk peker på.
  begin
    insert into workflow.claim_verification_citations (
      claim_verification_id, claim_revision_id, claim_evidence_link_id, evidence_item_id,
      source_access, source_version_id, checked_content_hash,
      relationship_supported, finding
    )
    select
      v_verification_id,
      p_claim_revision_id,
      l.id,
      l.evidence_item_id,
      (c.value ->> 'source_access')::workflow.verification_source_access,
      nullif(c.value ->> 'source_version_id', '')::uuid,
      nullif(c.value ->> 'checked_content_hash', ''),
      (c.value ->> 'relationship_supported')::workflow.verification_check_result,
      nullif(c.value ->> 'finding', '')
    from jsonb_array_elements(p_citations) as c
    join knowledge.claim_evidence_links l
      on l.id = nullif(c.value ->> 'claim_evidence_link_id', '')::uuid;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'En av kontrollradene har en ukjent verdi for kildetilgang eller kontrollresultat.',
        hint = 'source_access skal være original_source, verifiable_representation eller derived_summary; relationship_supported skal være ok, deviation eller not_assessable.';
  end;

  -- Umiddelbart, i tillegg til constraint-triggeren som kjører ved commit:
  -- skriveveien skal avvise med en gang, og kontrollen skal kunne prøves i en
  -- transaksjon som rulles tilbake (migrasjon 005j, avsnitt 7).
  perform workflow.assert_claim_verification_complete(v_verification_id);

  return v_verification_id;
end;
$$;

comment on function workflow.record_claim_verification(
  uuid, uuid, uuid, text, text, text, text, text, text, text, text, jsonb, text, text
) is
  'Selve registreringen av en claim-verifikasjon, uten autentisering: kroppen api.register_claim_verification(text, text, uuid, uuid, text, text, text, text, text, text, text, text, jsonb, text, text) hadde fra migrasjon 005k, med legitimasjonskontrollen tatt ut. Finnes fordi det fra migrasjon 005n av er to skriveveier inn i workflow.claim_verifications — agenten med legitimasjon og en åpen agentkjøring, mennesket med sesjon og reviewer-rolle — og de to skal håndheve nøyaktig de samme invariantene: hvilke lenker som er lovlige, at kildetilgangen utledes som den svakeste av lenkenes, at evidensfunnet leses fra lenken og ikke fra kalleren, og at dekningen kontrolleres umiddelbart. Skrevet to ganger ville de kunnet komme i utakt, og da ville den ene veien sluppet gjennom det den andre stengte. Kalleren har allerede avgjort hvem verifikatoren er; p_verifier_actor_id er aldri en verdi som kommer fra klienten. Verifikatorens mandat, forbudet mot selvverifikasjon og alle feltregler håndheves av tabellens egne triggere og constraints, som er fasiten. SECURITY DEFINER fordi workflow og knowledge har RLS med default deny; EXECUTE er revokert fra PUBLIC og gitt til ingen klientrolle.';

revoke execute on function workflow.record_claim_verification(
  uuid, uuid, uuid, text, text, text, text, text, text, text, text, jsonb, text, text
) from public;

-- ----------------------------------------------------------------------------
-- 4. api.register_claim_verification(...) — uendret utad, ett registreringsledd
-- ----------------------------------------------------------------------------
create or replace function api.register_claim_verification(
  p_identity_key text,
  p_secret text,
  p_agent_run_id uuid,
  p_claim_revision_id uuid,
  p_outcome text,
  p_source_support text,
  p_population_match text,
  p_comparator_match text,
  p_timeframe_match text,
  p_direction_and_magnitude text,
  p_qualifiers_complete text,
  p_contradictory_evidence_represented text,
  p_citations jsonb,
  p_rationale text,
  p_findings text default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_identity_id uuid;
  v_verifier_actor_id uuid;
begin
  -- Autentiser identiteten eksplisitt for rollen citation_support_verification.
  -- En identitet i en annen rolle — også ekstraksjonsverifikatoren — avvises her,
  -- før noe leses eller skrives.
  v_identity_id := provenance.authenticate_agent_identity(
    p_identity_key, p_secret, 'citation_support_verification'::provenance.agent_role
  );

  -- Krev en åpen kjøring som tilhører nøyaktig denne identiteten, og la
  -- returverdien — ikke en klientoppgitt parameter — være aktøren raden
  -- attribueres til. Det finnes ingen parameter å be om en annen aktør gjennom.
  v_verifier_actor_id := provenance.assert_agent_run_open(p_agent_run_id, v_identity_id);

  return workflow.record_claim_verification(
    p_claim_revision_id, v_verifier_actor_id, p_agent_run_id,
    p_outcome, p_source_support, p_population_match, p_comparator_match,
    p_timeframe_match, p_direction_and_magnitude, p_qualifiers_complete,
    p_contradictory_evidence_represented,
    p_citations, p_rationale, p_findings
  );
end;
$$;

-- ----------------------------------------------------------------------------
-- 5. api.register_human_claim_verification(...) — den menneskelige skriveveien
--
-- Ingen agentkjøring: agent_run_id blir NULL, som kolonnen fra 005j er bygget
-- for. Aktøren er kallerens egen, hentet fra sesjonen og aldri fra en parameter,
-- og mandatet er reviewer-rollen for påstandens kliniske tema.
--
-- Skillet mot godkjenningen er med hensikt: dette er den faglige kontrollen mot
-- grunnlaget (ANTIDEP_CONSTITUTION.md §11), ikke beslutningen om å publisere
-- (§12). De er to beslutningsobjekter i basen, og de skal være to handlinger i
-- flaten. api.register_publication_approval(...) i migrasjon 006d er den andre.
--
-- `verified` er mulig herfra, og det er hele hensikten: tre av de sju
-- kontrollpunktene kan en deterministisk kontroll aldri sette til ok, og
-- claim_verifications_verified_requires_all_ok_check krever alle sju. Men
-- vilkårene er de samme for et menneske som for en maskin — CHECK-en er den
-- samme, dekningskontrollen den samme, og «ikke bedømt» teller fortsatt ikke som
-- «bestått».
-- ----------------------------------------------------------------------------
create function api.register_human_claim_verification(
  p_claim_revision_id uuid,
  p_seen_evidence_set_digest text,
  p_outcome text,
  p_source_support text,
  p_population_match text,
  p_comparator_match text,
  p_timeframe_match text,
  p_direction_and_magnitude text,
  p_qualifiers_complete text,
  p_contradictory_evidence_represented text,
  p_citations jsonb,
  p_rationale text,
  p_findings text default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_topic_concept_id uuid;
  v_verifier_actor_id uuid;
begin
  -- Temaet påstanden hører under er det en avgrenset reviewer-tildeling
  -- kontrolleres mot. Finnes revisjonen ikke, sier
  -- workflow.record_claim_verification(...) fra med sin egen setning; her ville
  -- en avvisning før autorisasjonen røpet hvilke revisjons-ID-er som finnes.
  select cl.topic_concept_id into v_topic_concept_id
  from knowledge.claim_revisions r
  join knowledge.claims cl on cl.id = r.claim_id
  where r.id = p_claim_revision_id;

  v_verifier_actor_id := workflow.assert_reviewer_authorized(v_topic_concept_id);

  -- Vurderingen gjelder det grunnlaget revieweren faktisk så.
  perform workflow.assert_evidence_set_unchanged(
    p_claim_revision_id, p_seen_evidence_set_digest
  );

  return workflow.record_claim_verification(
    p_claim_revision_id, v_verifier_actor_id, null,
    p_outcome, p_source_support, p_population_match, p_comparator_match,
    p_timeframe_match, p_direction_and_magnitude, p_qualifiers_complete,
    p_contradictory_evidence_represented,
    p_citations, p_rationale, p_findings
  );
end;
$$;

comment on function api.register_human_claim_verification(
  uuid, text, text, text, text, text, text, text, text, text, jsonb, text, text
) is
  'Den kontrollerte skriveveien for at en kvalifisert menneskelig reviewer registrerer sin egen faglige kontroll av én påstandsrevisjon mot det registrerte evidensgrunnlaget (ANTIDEP_CONSTITUTION.md §4, §9, §11, §12, DATABASE_ARCHITECTURE.md §30, §43, MVP_IMPLEMENTATION_PLAN.md §15). Motstykket til api.register_claim_verification(text, text, uuid, uuid, text, text, text, text, text, text, text, text, jsonb, text, text) for den menneskelige grenen av workflow.claim_verifier_has_mandate(uuid, uuid, timestamptz), som har vært håndhevet siden migrasjon 005j uten å ha en vei inn. Kalleren må ha en registrert, ikke-tilbaketrukket aktør og gyldig reviewer-rolle for påstandens kliniske tema (workflow.assert_reviewer_authorized(uuid)); aktøren raden attribueres til er kallerens egen og er ikke en parameter. p_seen_evidence_set_digest må være avtrykket av evidenssettet slik det er nå — en lenke som er kommet til mens vurderingen pågikk, avviser registreringen framfor å bli stilltiende dekket av den. agent_run_id er NULL: en menneskelig vurdering har ingen agentkjøring, og kolonnen fra 005j er bygget for nettopp det. Registreringen selv gjøres av workflow.record_claim_verification(uuid, uuid, uuid, text, text, text, text, text, text, text, text, jsonb, text, text), den samme funksjonen agentveien bruker, slik at de to veiene ikke kan komme i utakt. Alle øvrige regler er tabellens egne og uendret: dekningen skal være hele evidenssettet, en bekreftelse kan ikke ha uavklarte lenker under seg, alle sju kontrollpunktene må være ok for verified, verifikator kan ikke være den som formulerte revisjonen, og raden er append-only. Denne veien er ikke publiseringsgodkjenningen — den er api.register_publication_approval(uuid, text, text, text), og de to er med hensikt to beslutninger. SECURITY DEFINER fordi workflow, knowledge og provenance har RLS med default deny; tomt search_path, og kalleren autoriseres på funksjonens eget kall (§50). EXECUTE gis bare til authenticated: en uinnlogget kaller har ingen aktør og kan ikke ha en reviewer-rolle.';

revoke execute on function api.register_human_claim_verification(
  uuid, text, text, text, text, text, text, text, text, text, jsonb, text, text
) from public;
grant execute on function api.register_human_claim_verification(
  uuid, text, text, text, text, text, text, text, text, text, jsonb, text, text
) to authenticated;
