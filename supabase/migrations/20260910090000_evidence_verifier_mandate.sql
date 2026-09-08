-- ============================================================================
-- Migrasjon 005q — ekstraksjonskontrollen får mandatet sitt på raden
--
-- workflow.claim_verifications har siden migrasjon 005j hatt to lag rundt
-- mandatet: en boolsk funksjon som sier hvem som i det hele tatt kan kontrollere
-- en påstand, en trigger som håndhever den ved innsetting, og et vilkår i
-- publiseringsgaten (G9c) som leser den samme funksjonen på den gjeldende
-- kontrollen. workflow.evidence_verifications har ikke hatt noe av det.
--
-- Så lenge den eneste veien inn var api.register_extraction_verification(...),
-- som autentiserer en agentidentitet eksplisitt for rollen
-- extraction_verification, var forskjellen uten praktisk konsekvens. Fra
-- migrasjon 005s finnes det to veier inn — og den andre er et menneske med
-- sesjon og reviewer-rolle. Da er skriveveiens egen kontroll ikke lenger den
-- eneste tingen som avgjør hvem raden kan komme fra, og regelen hører hjemme
-- der publiseringsgaten faktisk leser den: på raden.
--
-- Dette er lærdommen fra teknisk review av PR #59 anvendt før feilen oppstår:
-- en kontroll som bare finnes i den ene skriveveien, er ikke en garanti om
-- raden. Migrasjonen legger derfor til, og fjerner ingenting.
--
-- ----------------------------------------------------------------------------
-- Hva mandatet er, og hvorfor scopet er endepunktet
--
-- For en agent er mandatet rollen på aktøren, som er selve rettighetsgrensen
-- (migrasjon 005e): extraction_verification og ingen annen. EVIDENCE_PIPELINE.md
-- §61 skiller den fra citation_support_verification nettopp fordi de to
-- kontrollerer forskjellige ting.
--
-- For et menneske er mandatet den samme reviewer-rollen §74.30 punkt 3 avgjorde
-- at claim-kontrollen bruker. Forskjellen er hva en *avgrenset* tildeling måles
-- mot: en påstand hører under claims.topic_concept_id, mens et evidensfunn hører
-- under evidence_items.outcome_concept_id — endepunktet funnet rapporterer om.
-- Begge er catalog.clinical_concepts, som er den eneste scopetypen
-- workflow.role_scope_type har.
--
-- Tidspunktet er radens eget verified_at og ikke now(), av samme grunn som i
-- 005j: en rolletildeling som senere avsluttes, opphever ikke en kontroll som
-- var legitim da den ble gjort (ANTIDEP_CONSTITUTION.md §14). Kravet om at
-- tildelingsraden fantes senest da, hindrer at en tilbakedatert valid_from
-- konstruerer gyldighet i etterkant.
--
-- ----------------------------------------------------------------------------
-- Dekningen får sin egen funksjon, av samme grunn
--
-- G5b regnet ut unionen av `checked_fields` over funnets bekreftede kontroller
-- inne i gaten. Reviewerflaten (005t) skal vise nøyaktig den samme dekningen —
-- hvilke felter som faktisk står igjen å kontrollere er det viktigste
-- revieweren trenger å vite — og en andre formulering ville før eller siden
-- vist noe annet enn gaten krever. Uttrykket flyttes derfor ordrett ut i
-- workflow.covered_check_fields(uuid), og gaten kaller den. Semantikken er
-- uendret, inkludert at en ikke-bekreftende kontroll nullstiller dekningen.
--
-- ----------------------------------------------------------------------------
-- Fremover-skrivende
--
-- knowledge.assert_claim_revision_ready_for_approval(uuid) gjenskapes i sin
-- helhet med `create or replace`; ingen kjørt migrasjon er redigert (§74.32).
-- G1 til G5 og G6 til G10 er ordrett de samme. G5b er den samme regelen uttrykt
-- gjennom den nye funksjonen, og G5c er nytt.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §10, §11, §12, §14
--   docs/CONTENT_GOVERNANCE.md §11, §14
--   docs/DATABASE_ARCHITECTURE.md §29, §43, §46, §50, §59, §60
--   docs/EVIDENCE_PIPELINE.md §25, §61, §63
--   docs/MVP_IMPLEMENTATION_PLAN.md §15, §16, §49, §74.30, §74.36
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. workflow.evidence_verifier_has_mandate(uuid, uuid, timestamptz)
--
-- Speilbildet av workflow.claim_verifier_has_mandate(uuid, uuid, timestamptz)
-- for ekstraksjonskontrollen. Regelen står ett sted fordi den håndheves to
-- steder: ved innsetting av raden, og i publiseringsgaten på den gjeldende
-- kontrollen (G5c). To formuleringer ville kunnet komme i utakt, og da ville
-- gaten sluppet gjennom nøyaktig det triggeren stengte, eller omvendt.
-- ----------------------------------------------------------------------------
create function workflow.evidence_verifier_has_mandate(
  p_verifier_actor_id uuid,
  p_evidence_item_id uuid,
  p_at timestamptz
)
  returns boolean
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_actor_type provenance.actor_type;
  v_agent_role provenance.agent_role;
  v_auth_user_id uuid;
  v_outcome_concept_id uuid;
begin
  select a.actor_type, a.agent_role, a.auth_user_id
    into v_actor_type, v_agent_role, v_auth_user_id
  from provenance.actors a
  where a.id = p_verifier_actor_id;

  if not found then
    return false;
  end if;

  -- En agent har mandatet gjennom rollen sin, og bare gjennom den.
  if v_actor_type = 'agent' then
    return v_agent_role = 'extraction_verification';
  end if;

  -- Et menneske har det gjennom en gyldig reviewer-tildeling for endepunktet
  -- funnet rapporterer om. Ingen annen aktørtype kan kontrollere en ekstraksjon:
  -- en deterministisk prosess, en import eller en systemaktør har ingen faglig
  -- vurdering å registrere (ANTIDEP_CONSTITUTION.md §12).
  if v_actor_type <> 'human' or v_auth_user_id is null then
    return false;
  end if;

  select e.outcome_concept_id into v_outcome_concept_id
  from knowledge.evidence_items e
  where e.id = p_evidence_item_id;

  return exists (
    select 1
    from workflow.user_roles ur
    where ur.user_id = v_auth_user_id
      and ur.role_code = 'reviewer'
      and ur.created_at <= p_at
      and ur.valid_from <= p_at
      and (ur.valid_to is null or ur.valid_to > p_at)
      and (ur.scope_id is null or ur.scope_id = v_outcome_concept_id)
  );
end;
$$;

comment on function workflow.evidence_verifier_has_mandate(uuid, uuid, timestamptz) is
  'Om aktøren hadde mandat til å kontrollere denne ekstraksjonen mot kilden på det oppgitte tidspunktet: en agent i rollen extraction_verification, eller et menneske med gyldig reviewer-rolle for endepunktet evidensfunnet rapporterer om (EVIDENCE_PIPELINE.md §25, §61, ANTIDEP_CONSTITUTION.md §10, §12, MVP_IMPLEMENTATION_PLAN.md §74.30 punkt 3). Speilbildet av workflow.claim_verifier_has_mandate(uuid, uuid, timestamptz); forskjellen er hva en avgrenset tildeling måles mot — en påstand hører under claims.topic_concept_id, et evidensfunn under evidence_items.outcome_concept_id. Regelen står ett sted fordi den håndheves to steder: ved innsetting av raden, og i publiseringsgaten på den gjeldende kontrollen (G5c). Tidspunktet er radens eget verified_at og ikke now(): en tildeling som senere avsluttes, opphever ikke en kontroll som var legitim da den ble gjort (§14). Rollen leses fra workflow.user_roles og aldri fra en JWT-claim (DATABASE_ARCHITECTURE.md §46). SECURITY DEFINER fordi både aktørregisteret, medlemskapsmodellen og evidensfunnene har RLS med default deny; funksjonen leser bare og returnerer ingen data.';

revoke execute on function workflow.evidence_verifier_has_mandate(uuid, uuid, timestamptz) from public;

create function workflow.enforce_evidence_verifier_mandate()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if not workflow.evidence_verifier_has_mandate(
       new.verifier_actor_id, new.evidence_item_id, new.verified_at
     ) then
    raise exception using
      errcode = 'insufficient_privilege',
      message = 'Verifikatoraktøren hadde ikke mandat til å kontrollere denne ekstraksjonen mot kilden.',
      hint = 'Kontroll av en ekstraksjon mot kilden er et eget mandat (ANTIDEP_CONSTITUTION.md §10): en agent må ha rollen extraction_verification, og et menneske må ha gyldig reviewer-rolle for endepunktet funnet rapporterer om på verified_at, med en tildelingsrad som fantes senest da. En ekstraksjonsagent, en claim-verifikator eller en bruker uten reviewer-rolle kan ikke registrere raden publiseringsgaten leser.';
  end if;

  return new;
end;
$$;

comment on function workflow.enforce_evidence_verifier_mandate() is
  'Tverradsinvariant: krever at en ekstraksjonsverifikasjon kommer fra en aktør med mandatet til det (workflow.evidence_verifier_has_mandate(uuid, uuid, timestamptz)). Uten den kunne enhver aktør som ikke tilfeldigvis var den som laget ekstraksjonen, skrive raden publiseringsgatens G4 og G5 leser. Ikke SECURITY DEFINER: den kaller en funksjon som er det, og skal ikke selv være mer privilegert enn operasjonen den kontrollerer.';

revoke execute on function workflow.enforce_evidence_verifier_mandate() from public;

create trigger evidence_verifications_enforce_verifier_mandate
  before insert on workflow.evidence_verifications
  for each row execute function workflow.enforce_evidence_verifier_mandate();

-- ----------------------------------------------------------------------------
-- 2. workflow.covered_check_fields(uuid) — dekningen, ett sted
--
-- Uttrykket er ordrett det G5b hadde inne i gaten fra migrasjon 005i, flyttet ut
-- uendret: unionen av checked_fields over funnets *bekreftede* kontroller, der
-- en bekreftelse bare teller så lenge ingen ikke-bekreftende kontroll er nyere
-- enn den. Rekkefølgen er den samme som G5 bruker for «den siste», slik at de to
-- ikke kan bli uenige om hva som er nyere.
--
-- Tom liste og ikke NULL når ingenting er dekket: en manglende verdi ville
-- kunnet leses som «ukjent dekning», og det er ikke det samme som «ingen».
-- ----------------------------------------------------------------------------
create function workflow.covered_check_fields(p_evidence_item_id uuid)
  returns workflow.evidence_check_field[]
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select coalesce(
    array_agg(distinct f.field),
    '{}'::workflow.evidence_check_field[]
  )
  from workflow.evidence_verifications ev
  cross join unnest(ev.checked_fields) as f(field)
  where ev.evidence_item_id = p_evidence_item_id
    and ev.outcome = 'verified'
    and not exists (
      select 1
      from workflow.evidence_verifications later
      where later.evidence_item_id = p_evidence_item_id
        and later.outcome <> 'verified'
        and (later.verified_at, later.created_at, later.id)
            > (ev.verified_at, ev.created_at, ev.id)
    );
$$;

comment on function workflow.covered_check_fields(uuid) is
  'Feltene som per nå teller som kontrollert for ett evidensfunn: unionen av checked_fields over funnets bekreftede ekstraksjonsverifikasjoner, der en bekreftelse bare teller så lenge ingen ikke-bekreftende kontroll er nyere enn den (publiseringsgatens G5b, migrasjon 005i). En ikke-bekreftende kontroll nullstiller altså dekningen, slik at et senere avvik ikke kan omgås av en enda senere delkontroll som aldri så på det omstridte feltet. Uttrykket lå inne i gaten og er flyttet hit uendret, fordi reviewerflaten skal vise nøyaktig den dekningen gaten krever — to formuleringer ville før eller siden vist noe annet enn gaten leser. Tom liste betyr «ingenting er dekket», aldri «ukjent». Sammenlign med workflow.required_check_fields(uuid), som sier hva funnet påstår noe om.';

revoke execute on function workflow.covered_check_fields(uuid) from public;

-- ----------------------------------------------------------------------------
-- 3. Forutsetningene før en godkjenning leser mandatet og den delte dekningen
--
-- G1 til G5 og G6 til G10 er ordrett uendret. G5b er den samme regelen uttrykt
-- gjennom workflow.covered_check_fields(uuid). G5c er nytt, og er speilbildet av
-- G9c: den gjeldende ekstraksjonskontrollen skal være registrert av noen som
-- hadde mandat til å gjøre den.
-- ----------------------------------------------------------------------------
create or replace function knowledge.assert_claim_revision_ready_for_approval(p_claim_revision_id uuid)
  returns void
  language plpgsql
  set search_path = ''
as $$
declare
  v_claim_id uuid;
  v_knowledge_type knowledge.knowledge_type;
  v_retired_at timestamptz;
  v_offenders text;
  v_claim_verification_outcome workflow.verification_outcome;
  v_claim_verifier_actor_id uuid;
  v_claim_verified_at timestamptz;
  v_claim_verified_digest text;
begin
  -- G1: revisjonen finnes.
  select r.claim_id, r.knowledge_type, c.retired_at
    into v_claim_id, v_knowledge_type, v_retired_at
  from knowledge.claim_revisions r
  join knowledge.claims c on c.id = r.claim_id
  where r.id = p_claim_revision_id;

  if not found then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Påstandsrevisjon %L finnes ikke.', p_claim_revision_id),
      hint = 'Publisering peker på en eksakt revisjon, ikke på påstandsidentiteten (KNOWLEDGE_MODEL.md §19.3). Kontroller revisjons-ID-en.';
  end if;

  -- G2: påstanden er ikke trukket tilbake.
  if v_retired_at is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Påstanden bak revisjon %L er trukket tilbake og kan ikke publiseres.',
        p_claim_revision_id
      ),
      hint = 'En tilbaketrukket påstand er tatt ut av bruk. Opprett en ny påstand dersom temaet fortsatt skal dekkes; historikken til den gamle bevares (DATABASE_ARCHITECTURE.md §36).';
  end if;

  -- G3: nødvendige EvidenceItems finnes.
  -- ANTIDEP_CONSTITUTION.md §4: ingen publisert klinisk relevant påstand skal
  -- eksistere uten eksplisitt kobling til én eller flere identifiserbare kilder.
  -- Kravet gjelder alle tre kunnskapstypene; også et deterministisk faktum skal
  -- kunne spores til kilden sin.
  if not exists (
    select 1
    from knowledge.claim_evidence_links l
    where l.claim_revision_id = p_claim_revision_id
  ) then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Revisjon %L har ingen registrerte evidenslenker og kan ikke publiseres.',
        p_claim_revision_id
      ),
      hint = 'Registrer minst ett evidensfunn med en begrunnet relasjon til revisjonen. En publisert påstand uten kobling til en identifiserbar kilde er ikke etterprøvbar (ANTIDEP_CONSTITUTION.md §4).';
  end if;

  -- G4: hvert lenket evidensfunn er faktisk kontrollert av noen.
  select string_agg(distinct l.evidence_item_id::text, ', ' order by l.evidence_item_id::text)
    into v_offenders
  from knowledge.claim_evidence_links l
  where l.claim_revision_id = p_claim_revision_id
    and not exists (
      select 1
      from workflow.evidence_verifications ev
      where ev.evidence_item_id = l.evidence_item_id
    );

  if v_offenders is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Evidensfunn uten registrert ekstraksjonsverifikasjon: %s.', v_offenders
      ),
      hint = 'En separat kontrollfase skal ha gått gjennom ekstraksjonen mot kildematerialet før påstanden publiseres (ANTIDEP_CONSTITUTION.md §11, DATABASE_ARCHITECTURE.md §29). Registrer verifikasjonen i workflow.evidence_verifications.';
  end if;

  -- G5: den gjeldende ekstraksjonsverifikasjonen bekrefter funnet.
  -- Den siste kontrollen er den gjeldende: et senere needs_correction, rejected
  -- eller uncertain er et åpent blokkerende verifikasjonsfunn, uansett hvor mange
  -- bekreftelser som ligger foran det.
  select string_agg(distinct l.evidence_item_id::text, ', ' order by l.evidence_item_id::text)
    into v_offenders
  from knowledge.claim_evidence_links l
  where l.claim_revision_id = p_claim_revision_id
    and (
      select ev.outcome
      from workflow.evidence_verifications ev
      where ev.evidence_item_id = l.evidence_item_id
      order by ev.verified_at desc, ev.created_at desc, ev.id desc
      limit 1
    ) <> 'verified';

  if v_offenders is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Evidensfunn med åpent verifikasjonsfunn: %s.', v_offenders
      ),
      hint = 'Den siste registrerte ekstraksjonsverifikasjonen konkluderer ikke med verified. Rett ekstraksjonen i et nytt evidensfunn og registrer en ny kontroll; en tidligere bekreftelse opphever ikke et senere avvik.';
  end if;

  -- G5b: kontrollene dekker til sammen det raden faktisk påstår.
  --
  -- G5 leste bare `outcome`. En kontroll som *med vilje* lar felter stå
  -- ukontrollert — den deterministiske ekstraksjonsverifikatoren bedømmer
  -- verken tidspunkt, retning, effektmål, availability-semantikk eller
  -- forbehold — kunne dermed tilfredsstille en gate som er ment å bety at
  -- ekstraksjonen er kontrollert. `checked_fields` sa sannheten, men ingen
  -- leste den (DATABASE_ARCHITECTURE.md §29).
  --
  -- Regelen er uendret fra migrasjon 005i, inkludert at dekningen har samme
  -- gjeldende-semantikk som utfallet: en ikke-bekreftende kontroll nullstiller
  -- den, slik at et senere avvik ikke kan omgås av en enda senere delkontroll
  -- som aldri så på det omstridte feltet. Selve unionen står nå i
  -- workflow.covered_check_fields(uuid), fordi reviewerflaten skal vise nøyaktig
  -- den dekningen gaten krever (migrasjon 005q).
  select string_agg(distinct l.evidence_item_id::text, ', ' order by l.evidence_item_id::text)
    into v_offenders
  from knowledge.claim_evidence_links l
  where l.claim_revision_id = p_claim_revision_id
    and exists (
      select 1
      from unnest(workflow.required_check_fields(l.evidence_item_id)) as required(field)
      where required.field <> all (workflow.covered_check_fields(l.evidence_item_id))
    );

  if v_offenders is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Evidensfunn uten fullstendig kontrollert ekstraksjon: %s.', v_offenders
      ),
      hint = 'De registrerte kontrollene dekker ikke alle feltene funnet påstår noe om. workflow.required_check_fields(evidence_item_id) viser hva som kreves; en delkontroll kan ikke alene tilfredsstille publiseringsgaten (ANTIDEP_CONSTITUTION.md §11, DATABASE_ARCHITECTURE.md §29). Merk at en ikke-bekreftende kontroll nullstiller dekningen: bekreftelser som ligger foran den, teller ikke lenger.';
  end if;

  -- G5c: den gjeldende ekstraksjonskontrollen ble gjort av noen med mandat.
  --
  -- Speilbildet av G9c, og det finnes av samme grunn. Migrasjon 005q håndhever
  -- mandatet ved innsetting, og dette vilkåret er den andre lesningen av den
  -- samme regelen — den samme funksjonen, slik at de to ikke kan komme i utakt.
  -- At begge finnes, er bevisst: gaten er stedet der konsekvensen inntreffer, og
  -- en rad skrevet før regelen fantes, gjennom en senere skrivevei, eller av en
  -- vedlikeholdsoperasjon, skal ikke kunne bære en publisering fordi den slapp
  -- forbi det ene laget.
  --
  -- «Den gjeldende» er den samme raden G5 leser, hentet med den samme
  -- rekkefølgen. G4 har allerede slått fast at det finnes minst én.
  select string_agg(distinct l.evidence_item_id::text, ', ' order by l.evidence_item_id::text)
    into v_offenders
  from knowledge.claim_evidence_links l
  cross join lateral (
    select ev.verifier_actor_id, ev.verified_at
    from workflow.evidence_verifications ev
    where ev.evidence_item_id = l.evidence_item_id
    order by ev.verified_at desc, ev.created_at desc, ev.id desc
    limit 1
  ) as current_check
  where l.claim_revision_id = p_claim_revision_id
    and not workflow.evidence_verifier_has_mandate(
          current_check.verifier_actor_id, l.evidence_item_id, current_check.verified_at
        );

  if v_offenders is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Evidensfunn der den gjeldende ekstraksjonskontrollen mangler mandat: %s.', v_offenders
      ),
      hint = 'Kontroll av en ekstraksjon mot kilden er et eget mandat (ANTIDEP_CONSTITUTION.md §10): en agent må ha rollen extraction_verification, og et menneske må ha hatt gyldig reviewer-rolle for endepunktet funnet rapporterer om da kontrollen ble gjort. Registrer en ny kontroll fra en aktør som har mandatet.';
  end if;

  -- G6: ingen lenket ekstraksjon er trukket tilbake.
  -- Overlevert eksplisitt fra migrasjon 005: «er dette evidensfunnet trukket
  -- tilbake?» er ikke en statuskolonne, men en avledet tilstand — den siste
  -- beslutningen av typen extraction_withdrawal for funnet.
  select string_agg(distinct l.evidence_item_id::text, ', ' order by l.evidence_item_id::text)
    into v_offenders
  from knowledge.claim_evidence_links l
  where l.claim_revision_id = p_claim_revision_id
    and (
      select rd.decision
      from workflow.review_decisions rd
      where rd.evidence_item_id = l.evidence_item_id
        and rd.review_type = 'extraction_withdrawal'
      order by rd.decided_at desc, rd.created_at desc, rd.id desc
      limit 1
    ) = 'extraction_withdrawn';

  if v_offenders is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Evidensfunn med tilbaketrukket ekstraksjon: %s.', v_offenders
      ),
      hint = 'En tilbaketrukket ekstraksjon skal ikke bære en publisert påstand. Opprett en ny revisjon uten det tilbaketrukne funnet, eller registrer en ny beslutning som opprettholder ekstraksjonen dersom tilbaketrekkingen var feil (DATABASE_ARCHITECTURE.md §29).';
  end if;

  -- G7: ingen lenket kilde er trukket tilbake eller tilbakekalt.
  -- DATABASE_ARCHITECTURE.md §58, siste kulepunkt: en withdrawn eller retracted
  -- kilde skal ikke ubemerket tilfredsstille en gate som om statusen var normal.
  select string_agg(distinct s.id::text, ', ' order by s.id::text)
    into v_offenders
  from knowledge.claim_evidence_links l
  join knowledge.evidence_items e on e.id = l.evidence_item_id
  join knowledge.sources s on s.id = e.source_id
  where l.claim_revision_id = p_claim_revision_id
    and s.source_status in ('retracted', 'withdrawn');

  if v_offenders is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Kilder med statusen retracted eller withdrawn i grunnlaget: %s.', v_offenders
      ),
      hint = 'En tilbaketrukket eller tilbakekalt kilde kan ikke bære en publisert påstand. Vurder grunnlaget på nytt i en ny revisjon (DATABASE_ARCHITECTURE.md §58).';
  end if;

  -- G8: påstanden er kontrollert mot grunnlaget.
  -- DATABASE_ARCHITECTURE.md §38 sitt «ClaimEvidenceLinks er kontrollert» er
  -- nettopp claim-verifikasjonen fra §30: den kontrollerer om grunnlaget faktisk
  -- støtter ordlyden, om populasjon, komparator, tidsramme, retning og størrelse
  -- stemmer, om vesentlige forbehold mangler og om motstridende evidens er
  -- representert. Migrasjon 005 håndhever allerede at en verifikasjon ikke kan
  -- konkludere med verified uten at alle sju punktene er bedømt og holder.
  if not exists (
    select 1
    from workflow.claim_verifications cv
    where cv.claim_revision_id = p_claim_revision_id
  ) then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Revisjon %L har ingen registrert claim-verifikasjon.', p_claim_revision_id
      ),
      hint = 'En separat kontrollfase skal ha forsøkt å falsifisere påstanden mot det registrerte grunnlaget før den publiseres (ANTIDEP_CONSTITUTION.md §11, DATABASE_ARCHITECTURE.md §30). Registrer kontrollen i workflow.claim_verifications.';
  end if;

  -- G9, G9b og G9c leser alle den *gjeldende* claim-verifikasjonen, altså den
  -- siste, med samme rekkefølge G5 bruker for ekstraksjonsverifikasjonene. Den
  -- leses én gang, slik at de tre vilkårene aldri kan bli uenige om hvilken rad
  -- de snakker om.
  select cv.outcome, cv.verifier_actor_id, cv.verified_at, cv.verified_evidence_set_digest
    into v_claim_verification_outcome, v_claim_verifier_actor_id,
         v_claim_verified_at, v_claim_verified_digest
  from workflow.claim_verifications cv
  where cv.claim_revision_id = p_claim_revision_id
  order by cv.verified_at desc, cv.created_at desc, cv.id desc
  limit 1;

  -- G9: den gjeldende claim-verifikasjonen bekrefter påstanden.
  if v_claim_verification_outcome <> 'verified' then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Den gjeldende claim-verifikasjonen for revisjon %L konkluderer ikke med verified.',
        p_claim_revision_id
      ),
      hint = 'Den siste registrerte kontrollen er den gjeldende. Rett påstanden i en ny revisjon og få den kontrollert på nytt; en tidligere bekreftelse opphever ikke et senere avvik.';
  end if;

  -- G9b: kontrollen gjaldt det evidenssettet som faktisk ville blitt publisert.
  --
  -- En claim-verifikasjon er en vurdering av påstanden mot et bestemt grunnlag,
  -- og migrasjon 005j gir databasen eierskap til avtrykket av det grunnlaget.
  -- Uten dette vilkåret ville sekvensen «kontroller → legg til en lenke →
  -- publiser» sluppet gjennom en bekreftelse som aldri så den nye lenken — og
  -- den lenken kan være nettopp den motstridende evidensen kontrollen skulle
  -- lete etter (ANTIDEP_CONSTITUTION.md §9, §11, KNOWLEDGE_MODEL.md §19.2).
  --
  -- Sammenligningen er på avtrykk og ikke på tidspunkter, av samme grunn som
  -- G13: now() er transaksjonens starttidspunkt og ikke committidspunktet, så en
  -- lenke kan bære en created_at foran kontrollen og likevel ha blitt synlig
  -- etter den. Avtrykket er uavhengig av rekkefølge.
  if knowledge.claim_evidence_set_digest(p_claim_revision_id)
     is distinct from v_claim_verified_digest then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Evidensgrunnlaget for revisjon %L er endret etter den gjeldende claim-verifikasjonen.',
        p_claim_revision_id
      ),
      hint = 'Kontrollen gjaldt et annet evidenssett enn det som er registrert nå, og dekker derfor ikke grunnlaget påstanden ville blitt publisert på. Registrer en ny claim-verifikasjon som dekker hele det utvidede settet (ANTIDEP_CONSTITUTION.md §4, §9).';
  end if;

  -- G9c: kontrollen ble gjort av noen med mandat til det.
  --
  -- Migrasjon 005j håndhever mandatet ved innsetting, og dette vilkåret er den
  -- andre lesningen av den samme regelen — den samme funksjonen, slik at de to
  -- ikke kan komme i utakt. At begge finnes, er bevisst: gaten er stedet der
  -- konsekvensen inntreffer, og en rad skrevet før regelen fantes, gjennom en
  -- senere skrivevei, eller av en vedlikeholdsoperasjon, skal ikke kunne bære en
  -- publisering fordi den slapp forbi det ene laget.
  --
  -- Tidspunktet er radens eget verified_at, ikke now(): en rolletildeling som
  -- senere avsluttes, opphever ikke en kontroll som var legitim da den ble
  -- gjort. Historikken består (ANTIDEP_CONSTITUTION.md §14).
  if not workflow.claim_verifier_has_mandate(
       v_claim_verifier_actor_id, p_claim_revision_id, v_claim_verified_at
     ) then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Den gjeldende claim-verifikasjonen for revisjon %L er registrert av en aktør uten mandat til å kontrollere påstanden.',
        p_claim_revision_id
      ),
      hint = 'Sitat- og kildestøtteverifikasjon er et eget mandat (ANTIDEP_CONSTITUTION.md §10): en agent må ha rollen citation_support_verification, og et menneske må ha hatt gyldig reviewer-rolle for innholdsområdet da kontrollen ble gjort. Registrer en ny kontroll fra en aktør som har mandatet.';
  end if;

  -- G10: evidensvurderingen finnes for de typene som skal ha en.
  -- ANTIDEP_CONSTITUTION.md §6: en evidensbasert syntese skal ha en eksplisitt
  -- vurdering av sikkerheten i kunnskapsgrunnlaget. Migrasjon 004 tillater ikke
  -- en vurdering på et deterministisk faktum, så kravet gjelder de to typene som
  -- kan ha en.
  if v_knowledge_type in ('evidence_synthesis', 'clinical_recommendation')
     and not exists (
       select 1
       from knowledge.evidence_assessments a
       where a.claim_revision_id = p_claim_revision_id
     ) then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Revisjon %L mangler evidensvurdering og kan ikke publiseres som %s.',
        p_claim_revision_id, v_knowledge_type
      ),
      hint = 'En evidenssyntese eller klinisk anbefaling skal ha en eksplisitt vurdering av sikkerheten i kunnskapsgrunnlaget, med de fem GRADE-domenene vurdert (ANTIDEP_CONSTITUTION.md §6). Registrer vurderingen i knowledge.evidence_assessments.';
  end if;

end;
$$;

comment on function knowledge.assert_claim_revision_ready_for_approval(uuid) is
  'Forutsetningene som skal holde før et menneske tar stilling til publisering: publiseringsgatens G1 til G10. Uendret fra migrasjon 20260909096000 bortsett fra to ting. G5b uttrykker den samme dekningsregelen gjennom workflow.covered_check_fields(uuid), slik at reviewerflaten kan vise nøyaktig den dekningen gaten krever uten en andre formulering av den. G5c er nytt og er speilbildet av G9c: den gjeldende ekstraksjonskontrollen for hvert lenket evidensfunn må være registrert av en aktør som hadde mandat til å gjøre den (workflow.evidence_verifier_has_mandate(uuid, uuid, timestamptz)) — den samme funksjonen triggeren på workflow.evidence_verifications håndhever ved innsetting, slik at gaten og triggeren ikke kan komme i utakt. Funksjonen leses to steder og er skrevet ett sted: knowledge.assert_claim_revision_publishable(uuid) kaller den før sine egne G11, G12 og G13, og api.register_publication_approval(uuid, text, text, text) kaller den før den registrerer en approved-beslutning, slik at en godkjenning aldri kan gis til et ukontrollert utkast og siden bli stående når kontrollene kommer (ANTIDEP_CONSTITUTION.md §13, KNOWLEDGE_MODEL.md §20). Avviser med restrict_violation på hvert vilkår, og med invalid_parameter_value når revisjonen ikke finnes. SECURITY INVOKER med tomt search_path: den kalles fra DEFINER-kontekster og skal ikke utvide DEFINER-flaten (DATABASE_ARCHITECTURE.md §50).';

revoke execute on function knowledge.assert_claim_revision_ready_for_approval(uuid) from public;
