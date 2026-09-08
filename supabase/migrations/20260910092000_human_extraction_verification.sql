-- ============================================================================
-- Migrasjon 005s — mennesket får skriveveien maskinen allerede har, også for
--                  kontrollen av ekstraksjonen mot kilden
--
-- Speilbildet av migrasjon 005n. Der åpnet den menneskelige grenen av
-- workflow.claim_verifier_has_mandate(...); her åpnes den menneskelige veien
-- inn i workflow.evidence_verifications.
--
-- Hvorfor den trengs, står i MVP_IMPLEMENTATION_PLAN.md §74.36: begge
-- produksjonsrevisjonene stopper på publiseringsgatens G5, fordi den
-- deterministiske ekstraksjonsverifikatoren konkluderte med `uncertain` — den
-- fant ikke utdragene den trengte for å bekrefte alle feltene funnet påstår noe
-- om (§74.34). Det er ikke en teknisk feil, men en faglig mangel, og den kan
-- bare lukkes av et menneske som leser kilden. Uten denne migrasjonen finnes det
-- ingen vei for det mennesket å registrere avlesningen sin.
--
-- ----------------------------------------------------------------------------
-- Hva som IKKE er nytt her, og det er poenget
--
-- Ingen regel er lagt til, myket opp eller omgått i selve registreringen.
-- Mandatet er den samme funksjonen og den samme triggeren (005q), kravet om at
-- verifikator ikke er den som laget ekstraksjonen den samme CHECK-en, forbudet
-- mot å bekrefte på et avledet sammendrag den samme CHECK-en, kravet om at
-- kildepekeren er kontrollert i en bekreftelse den samme CHECK-en, kravet om
-- funn ved et annet utfall enn verified den samme CHECK-en, og append-only den
-- samme triggeren.
--
-- Den nye api-funksjonen legger til nøyaktig én ting maskinveien ikke trenger:
-- at revieweren må oppgi avtrykket av det grunnlaget hen faktisk så.
--
-- ----------------------------------------------------------------------------
-- Hvorfor selve registreringen flyttes ut i én funksjon
--
-- Fra nå av finnes det to skriveveier inn i workflow.evidence_verifications. De
-- skal håndheve nøyaktig de samme invariantene — hvilke vokabularverdier som er
-- lovlige, at skaperen av ekstraksjonen leses fra funnet og ikke fra kalleren,
-- at `verifiable_representation` faktisk har en etterprøvbar representasjon
-- under seg, og at raden skrives under radlåsen på evidensfunnet. Skrevet to
-- ganger ville de kunnet komme i utakt, og da ville den ene veien sluppet
-- gjennom det den andre stengte. Samme begrunnelse som 005n gir for
-- workflow.record_claim_verification(...).
--
-- Registreringen ligger derfor i workflow.record_evidence_verification(...), og
-- begge api-funksjonene kaller den. Den kjenner ingen legitimasjon og ingen
-- sesjon: den tar aktøren som allerede er autentisert, og skriver.
--
-- api.register_extraction_verification(...) erstattes med
-- `create or replace function` — fremover-skrivende, ikke en retusjert linje i
-- 005g, fordi 20260906091000 allerede er kjørt i det hostede prosjektet
-- (§74.32). Signatur, rettigheter, svar og avvisninger er uendret. Den ene
-- forskjellen er rekkefølgen: legitimasjonen kontrolleres nå før
-- vokabularverdiene, som er strammere og ikke løsere — nøyaktig det samme
-- byttet 005n gjorde for claim-verifikasjonen.
--
-- ----------------------------------------------------------------------------
-- «Kontroller det du faktisk så», og hvorfor den låser
--
-- En menneskelig ekstraksjonskontroll tar tid: flaten leses, kilden hentes fram,
-- utdragene sammenlignes felt for felt. Fire ting kan endre seg i det vinduet,
-- og alle fire endrer hva kontrollen faktisk ville dekket:
--
--   1. Kilden kan få statusen retracted eller withdrawn. Da hviler kontrollen på
--      et dokument som er tatt ut av bruk (publiseringsgatens G7).
--   2. Kildeversjonen funnet peker på, kan få et fingeravtrykk registrert — eller
--      være en annen enn den flaten viste.
--   3. En annen kontroll kan registreres i mellomtiden, av et menneske eller av
--      agenten. Da er «den gjeldende kontrollen» og dermed dekningen en annen enn
--      den revieweren så, og et åpent funn kan bli borte uten at noen så på det
--      igjen (G5b sin nullstilling).
--   4. Selve ekstraksjonen kan ikke endre seg — knowledge.evidence_items er
--      append-only — men avtrykket dekker den likevel, slik at kontrollen er
--      bundet til raden og ikke bare til id-en.
--
-- workflow.evidence_extraction_digest(uuid) dekker alle fire, og
-- workflow.assert_extraction_unchanged(uuid, text) sammenligner det kalleren
-- oppgir mot det som gjelder nå.
--
-- Sammenligningen alene er ikke nok, og det er lærdommen fra teknisk review av
-- PR #59 (migrasjon 006f): en kontroll uten lås er et øyeblikksbilde, og en rad
-- som commiter mellom kontrollen og innsettingen slipper gjennom. Funksjonen tar
-- derfor `for update` på evidensfunnets rad før den sammenligner, og holder
-- låsen ut transaksjonen — og workflow.record_evidence_verification(...) tar den
-- samme låsen, slik at to registreringer serialiseres mot hverandre. Da er begge
-- rekkefølgene riktige:
--
--   Kontrollen først   Den andre registreringen må vente til beslutningen er
--                      ferdig, og havner etter den.
--   Den andre først    Kontrollen ser det nye avtrykket og avvises som utdatert.
--
-- Kilderaden låses i tillegg med `for share`, som blokkerer en samtidig endring
-- av kildens status uten å blokkere andre lesere. Låserekkefølgen er evidensfunn
-- → kilde, og ingen kodevei tar dem i motsatt rekkefølge.
--
-- Agentveien har ikke avtrykksvilkåret, av samme grunn som i 005n: lesegrunnlag
-- og registrering skjer i samme kjøring, millisekunder fra hverandre, og
-- signaturen er allerede i produksjon. Låsen tar den likevel, fordi
-- serialiseringen bare virker om begge sider tar den.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §6, §10, §11, §12, §14
--   docs/CONTENT_GOVERNANCE.md §11 kvalifisert reviewer, §14
--   docs/DATABASE_ARCHITECTURE.md §29, §43, §46, §48, §50, §57, §59, §60
--   docs/EVIDENCE_PIPELINE.md §25, §61, §63
--   docs/MVP_IMPLEMENTATION_PLAN.md §15, §16, §42, §49, §74.30, §74.34, §74.36
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. workflow.evidence_extraction_digest(uuid) — avtrykket av det som ble sett
--
-- Samme lengdeprefiksede kanonisering og versjonerte prefiks som
-- knowledge.claim_evidence_set_digest(uuid) og content_hash: «|lengde:verdi»,
-- der «|~:» skiller NULL fra tom streng. En verdi kan derfor ikke flyttes fra
-- ett felt til det neste uten at avtrykket endrer seg.
--
-- Kontrollhistorikken dekkes av id-ene og ikke av en telling: tabellen er
-- append-only, men DATABASE_ARCHITECTURE.md §36 åpner for en unntaksvis
-- vedlikeholdsvei der en feilopprettet rad slettes fysisk, og da ville sletting
-- pluss innsetting holdt en telling uendret og endret settet.
--
-- Funksjonen tar ingen lås. Låsen hører til kontrollen som *avgjør* noe
-- (avsnitt 2); en leser som låste, ville blokkert flaten.
-- ----------------------------------------------------------------------------
create function workflow.evidence_extraction_digest(p_evidence_item_id uuid)
  returns text
  language sql
  stable
  security definer
  set search_path = ''
as $$
  with reviewed as (
    select array[
      e.id::text,
      e.content_hash,
      e.source_id::text,
      s.source_status::text,
      sv.id::text,
      sv.content_hash,
      sv.retrieved_from,
      (
        select string_agg(ev.id::text, ',' order by ev.id::text)
        from workflow.evidence_verifications ev
        where ev.evidence_item_id = e.id
      )
    ] as parts
    from knowledge.evidence_items e
    join knowledge.sources s on s.id = e.source_id
    left join knowledge.source_versions sv on sv.id = e.source_version_id
    where e.id = p_evidence_item_id
  )
  select 'sha256-v1:' || encode(
    sha256(convert_to(
      (
        select string_agg(
          '|' || coalesce(length(p.part)::text, '~') || ':' || coalesce(p.part, ''),
          '' order by p.ordinality
        )
        from reviewed r2, unnest(r2.parts) with ordinality as p(part, ordinality)
      ),
      'UTF8'
    )),
    'hex'
  )
  from reviewed;
$$;

comment on function workflow.evidence_extraction_digest(uuid) is
  'Fingeravtrykk av alt en menneskelig ekstraksjonskontroll faktisk gjelder: evidensfunnets eget innholdsavtrykk, kilden og dens status, kildeversjonen med adresse og fingeravtrykk, og settet av kontroller som allerede er registrert på funnet. Brukes av den menneskelige skriveveien til å binde en vurdering til det grunnlaget revieweren så — kommer det en kontroll til, eller endres kildens status, mens vurderingen pågår, avvises registreringen framfor å bli stående som en vurdering av noe annet (ANTIDEP_CONSTITUTION.md §11, MVP_IMPLEMENTATION_PLAN.md §42). Kanoniseringen er den samme lengdeprefiksede formen som knowledge.claim_evidence_set_digest(uuid) bruker, så NULL og tom streng kan ikke forveksles. NULL når evidensfunnet ikke finnes. Tar ingen lås: den er en leser, og låsen hører til workflow.assert_extraction_unchanged(uuid, text). SECURITY DEFINER fordi knowledge og workflow har RLS med default deny.';

revoke execute on function workflow.evidence_extraction_digest(uuid) from public;

-- ----------------------------------------------------------------------------
-- 2. workflow.assert_extraction_unchanged(uuid, text) — låsen og sammenligningen
--
-- Låsen først, sammenligningen etterpå, og låsen holdes ut transaksjonen. Se
-- hodekommentaren for hvorfor rekkefølgen er hele poenget.
--
-- Funksjonen kan ikke være STABLE: PostgreSQL tillater ikke `select ... for
-- update` i en ikke-VOLATILE funksjon. Det er en fordel — en tilbakeføring til
-- STABLE feiler ved kjøring framfor å fjerne låsen i stillhet (migrasjon 006f).
-- ----------------------------------------------------------------------------
create function workflow.assert_extraction_unchanged(
  p_evidence_item_id uuid,
  p_seen_extraction_digest text
)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_source_id uuid;
  v_current text;
begin
  -- Evidensfunnet først. Den samme raden workflow.record_evidence_verification()
  -- låser, slik at to registreringer serialiseres mot hverandre.
  select e.source_id into v_source_id
  from knowledge.evidence_items e
  where e.id = p_evidence_item_id
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = format('Evidensfunnet %L finnes ikke.', p_evidence_item_id),
      hint = 'Kontroller id-en. Et evidensfunn registreres av api.create_evidence_item(...) og er append-only, så det forsvinner aldri i ettertid.';
  end if;

  -- Kilden etterpå, med delt lås: en samtidig statusendring må vente, men andre
  -- lesere og andre kontroller på samme kilde slipper fram.
  perform 1
  from knowledge.sources s
  where s.id = v_source_id
  for share;

  v_current := workflow.evidence_extraction_digest(p_evidence_item_id);

  if v_current is distinct from p_seen_extraction_digest then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Grunnlaget for ekstraksjonskontrollen er endret etter at du hentet det fram.',
      hint = 'Kontrollen din gjelder den kildeversjonen, den ekstraksjonen og de tidligere kontrollene du faktisk så. Noe av det er endret — kildens status, kildeversjonen, eller en ny kontroll som er registrert i mellomtiden. Hent funnet fram på nytt, gå gjennom det som er kommet til, og registrer kontrollen på det fullstendige grunnlaget (ANTIDEP_CONSTITUTION.md §11, MVP_IMPLEMENTATION_PLAN.md §42).';
  end if;
end;
$$;

comment on function workflow.assert_extraction_unchanged(uuid, text) is
  'Krever at grunnlaget for en ekstraksjonskontroll fortsatt er det kalleren oppgir å ha sett (workflow.evidence_extraction_digest(uuid)). Brukes av den menneskelige skriveveien, der det går tid mellom å lese grunnlaget og å konkludere. Funksjonen tar `for update` på evidensfunnets rad før den sammenligner, og `for share` på kilderaden, og holder begge låsene ut transaksjonen. Uten det var kontrollen bare et øyeblikksbilde: en kontroll eller en statusendring som commitet i vinduet mellom sammenligningen og innsettingen, ville blitt en del av grunnlaget uten at noe menneske hadde sett den — samme luke som migrasjon 006f lukket for claim-reviewen. workflow.record_evidence_verification(uuid, uuid, uuid, text, text, text[], text, text) tar den samme radlåsen, slik at to registreringer serialiseres mot hverandre uansett hvilken vei de kommer fra. Låserekkefølgen er evidensfunn → kilde, og ingen kodevei tar dem i motsatt rekkefølge. VOLATILE av nødvendighet: PostgreSQL tillater ikke `select ... for update` i en ikke-VOLATILE funksjon, og en tilbakeføring til STABLE feiler derfor ved kjøring framfor å fjerne låsen i stillhet. Publiseringsgatens G5, G5b, G5c og G7 er fortsatt fasiten ved publisering; denne kontrollen kommer i tillegg og sier fra med en gang. SECURITY DEFINER fordi knowledge og workflow har RLS med default deny; funksjonen returnerer ingen data.';

revoke execute on function workflow.assert_extraction_unchanged(uuid, text) from public;

-- ----------------------------------------------------------------------------
-- 3. workflow.record_evidence_verification(...) — selve registreringen, ett sted
--
-- Kroppen er den api.register_extraction_verification(...) hadde fra migrasjon
-- 005g, uendret, med autentiseringen tatt ut og radlåsen lagt til.
--
-- To ting er bevisst ikke parametre kalleren kan velge fritt, av samme grunn som
-- i 005g:
--
--   verifier_actor_id                  avgjort av flaten, av kjøringen eller av
--                                      sesjonen — aldri oppgitt av kalleren
--   verified_item_creator_actor_id     leses fra evidensfunnet selv
-- ----------------------------------------------------------------------------
create function workflow.record_evidence_verification(
  p_evidence_item_id uuid,
  p_verifier_actor_id uuid,
  p_agent_run_id uuid,
  p_outcome text,
  p_source_access text,
  p_checked_fields text[],
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
  v_source_access workflow.verification_source_access;
  v_checked_fields workflow.evidence_check_field[];
  v_creator_actor_id uuid;
  v_source_version_id uuid;
  v_source_version_content_hash text;
  v_verification_id uuid;
begin
  -- Vokabularparametrene castes først og for seg, slik at en ukjent verdi gir
  -- en setning som sier hva som er galt, framfor en fremmednøkkelfeil lenger
  -- ned. Vokabularene er offentlig dokumentert (DATABASE_ARCHITECTURE.md §29),
  -- så meldingene røper ingenting autentiseringen skjuler.
  begin
    v_outcome := p_outcome::workflow.verification_outcome;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke et kjent verifikasjonsutfall.', p_outcome),
        hint = 'Gyldige utfall er verified, needs_correction, rejected og uncertain (DATABASE_ARCHITECTURE.md §29).';
  end;

  begin
    v_source_access := p_source_access::workflow.verification_source_access;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke en kjent kildetilgang.', p_source_access),
        hint = 'Gyldige verdier er original_source, verifiable_representation og derived_summary (ANTIDEP_CONSTITUTION.md §11).';
  end;

  -- Kastet direkte som array-til-array, ikke via unnest()/array_agg(): det
  -- siste ville gjort en tom liste om til NULL (aggregater over null rader
  -- returnerer NULL), og en tom liste skal avvises av tabellens egen
  -- evidence_verifications_checked_fields_check — ikke av en NOT NULL lenger
  -- oppe, som ville skjult hvilken regel som faktisk avviste den.
  begin
    v_checked_fields := p_checked_fields::workflow.evidence_check_field[];
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Ett eller flere kontrollerte felter er ikke et kjent felt.',
        hint = 'Gyldige felter er kolonnene på knowledge.evidence_items som workflow.evidence_check_field lister (DATABASE_ARCHITECTURE.md §29).';
  end;

  -- Hvem som laget evidensfunnet leses her, ikke oppgis av kalleren:
  -- evidence_verifications_item_fkey (migrasjon 005) håndhever at raden som
  -- skrives, peker på den virkelige skaperen, og en verdi kalleren kunne valgt
  -- fritt ville vært nøyaktig den innsnikingen kontrollen finnes for å hindre.
  --
  -- `for update` i den samme setningen: radlåsen på evidensfunnet er det som
  -- serialiserer to registreringer mot hverandre, og som
  -- workflow.assert_extraction_unchanged(uuid, text) legger seg på for at
  -- avtrykket revieweren så, fortsatt skal gjelde når raden skrives.
  select e.created_by_actor_id, e.source_version_id
    into v_creator_actor_id, v_source_version_id
  from knowledge.evidence_items e
  where e.id = p_evidence_item_id
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = format('Evidensfunnet %L finnes ikke.', p_evidence_item_id),
      hint = 'Kontroller id-en. Et evidensfunn registreres av api.create_evidence_item(...) og er append-only, så det forsvinner aldri i ettertid.';
  end if;

  -- §74.30 punkt 1/2: `verifiable_representation` er en påstand om at det
  -- finnes et grunnlag en tredjepart faktisk kan etterprøve mot — ikke bare et
  -- løfte om at kilden ble besøkt. Bare det at evidensfunnet peker på en
  -- knowledge.source_versions-rad er ikke nok: retrieved_from alene er et
  -- sporet besøk, ikke en etterprøvbar representasjon. content_hash er
  -- mekanismen som gjør representasjonen etterprøvbar, så den må også være satt
  -- på den kildeversjonen.
  if v_source_access = 'verifiable_representation' then
    if v_source_version_id is null then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Evidensfunnet har ingen lagret kildeversjon å vise til.',
        hint = 'verifiable_representation forutsetter at evidensfunnet peker på en knowledge.source_versions-rad (source_version_id). Uten det er original_source eller derived_summary det eneste kildegrunnlaget som faktisk kan dokumenteres for dette funnet.';
    end if;

    select content_hash into v_source_version_content_hash
    from knowledge.source_versions
    where id = v_source_version_id;

    if v_source_version_content_hash is null then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Kildeversjonen evidensfunnet peker på har ingen lagret fingeravtrykk (content_hash).',
        hint = 'verifiable_representation krever at kildeversjonen har content_hash satt, slik at retrieved_from og content_hash sammen lar en tredjepart hente kilden på nytt og etterprøve den, uavhengig av om fulltekst er lagret i storage_reference. Uten content_hash er raden bare et sporet besøk (original_source eller derived_summary er da det som faktisk kan dokumenteres).';
    end if;
  end if;

  insert into workflow.evidence_verifications (
    evidence_item_id, verified_item_creator_actor_id, verifier_actor_id,
    outcome, source_access, checked_fields, findings, rationale, verified_at,
    agent_run_id
  )
  values (
    p_evidence_item_id, v_creator_actor_id, p_verifier_actor_id,
    v_outcome, v_source_access, v_checked_fields, p_findings, p_rationale, now(),
    p_agent_run_id
  )
  returning id into v_verification_id;

  return v_verification_id;
end;
$$;

comment on function workflow.record_evidence_verification(
  uuid, uuid, uuid, text, text, text[], text, text
) is
  'Selve registreringen av en ekstraksjonsverifikasjon, uten autentisering: kroppen api.register_extraction_verification(text, text, uuid, uuid, text, text, text[], text, text) hadde fra migrasjon 005g, med legitimasjonskontrollen tatt ut og radlåsen lagt til. Finnes fordi det fra migrasjon 005s av er to skriveveier inn i workflow.evidence_verifications — agenten med legitimasjon og en åpen agentkjøring, mennesket med sesjon og reviewer-rolle — og de to skal håndheve nøyaktig de samme invariantene: hvilke vokabularverdier som er lovlige, at skaperen av ekstraksjonen leses fra funnet og ikke fra kalleren, at verifiable_representation faktisk har en etterprøvbar representasjon under seg, og at raden skrives under radlåsen på evidensfunnet. Skrevet to ganger ville de kunnet komme i utakt, og da ville den ene veien sluppet gjennom det den andre stengte. Kalleren har allerede avgjort hvem verifikatoren er; p_verifier_actor_id er aldri en verdi som kommer fra klienten. verified_at settes til now(): begge veiene registrerer kontrollen i det den konkluderes. Verifikatorens mandat, forbudet mot selvverifikasjon og alle feltregler håndheves av tabellens egne triggere og constraints, som er fasiten. SECURITY DEFINER fordi workflow og knowledge har RLS med default deny; EXECUTE er revokert fra PUBLIC og gitt til ingen klientrolle.';

revoke execute on function workflow.record_evidence_verification(
  uuid, uuid, uuid, text, text, text[], text, text
) from public;

-- ----------------------------------------------------------------------------
-- 4. api.register_extraction_verification(...) — uendret utad, ett registreringsledd
-- ----------------------------------------------------------------------------
create or replace function api.register_extraction_verification(
  p_identity_key text,
  p_secret text,
  p_agent_run_id uuid,
  p_evidence_item_id uuid,
  p_outcome text,
  p_source_access text,
  p_checked_fields text[],
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
  -- Autentiser identiteten eksplisitt for rollen extraction_verification. En
  -- identitet i en annen rolle avvises her, før noe leses eller skrives.
  v_identity_id := provenance.authenticate_agent_identity(
    p_identity_key, p_secret, 'extraction_verification'::provenance.agent_role
  );

  -- Krev en åpen kjøring som tilhører nøyaktig denne identiteten, og la
  -- returverdien — ikke en klientoppgitt parameter — være aktøren raden
  -- attribueres til. Det finnes ingen parameter å be om en annen aktør gjennom.
  v_verifier_actor_id := provenance.assert_agent_run_open(p_agent_run_id, v_identity_id);

  return workflow.record_evidence_verification(
    p_evidence_item_id, v_verifier_actor_id, p_agent_run_id,
    p_outcome, p_source_access, p_checked_fields, p_rationale, p_findings
  );
end;
$$;

-- ----------------------------------------------------------------------------
-- 5. api.register_human_extraction_verification(...) — den menneskelige veien
--
-- Ingen agentkjøring: agent_run_id blir NULL, som kolonnen fra 005g er bygget
-- for. Aktøren er kallerens egen, hentet fra sesjonen og aldri fra en parameter,
-- og mandatet er reviewer-rollen for endepunktet funnet rapporterer om.
--
-- `verified` er mulig herfra, og det er hele hensikten: den deterministiske
-- kontrollen bedømmer med vilje en delmengde av feltene (§74.34), og
-- publiseringsgatens G5b krever at unionen dekker alt funnet påstår noe om. Men
-- vilkårene er de samme for et menneske som for en maskin — CHECK-ene er de
-- samme, mandatkontrollen den samme, og «ikke kontrollert» teller fortsatt ikke
-- som «kontrollert».
--
-- Skillet mot claim-kontrollen er med hensikt: dette er kontrollen av at
-- ekstraksjonen gjengir kilden riktig (EVIDENCE_PIPELINE.md §25), ikke
-- kontrollen av at grunnlaget støtter påstanden (§39). De er to
-- kontrollobjekter i basen, og publiseringsgaten krever dem hver for seg (G5 og
-- G9).
-- ----------------------------------------------------------------------------
create function api.register_human_extraction_verification(
  p_evidence_item_id uuid,
  p_seen_extraction_digest text,
  p_outcome text,
  p_source_access text,
  p_checked_fields text[],
  p_rationale text,
  p_findings text default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_outcome_concept_id uuid;
  v_verifier_actor_id uuid;
begin
  -- Endepunktet funnet rapporterer om er det en avgrenset reviewer-tildeling
  -- kontrolleres mot. Finnes ikke funnet, sier
  -- workflow.assert_extraction_unchanged(uuid, text) fra med sin egen setning;
  -- her ville en avvisning før autorisasjonen røpet hvilke evidens-ID-er som
  -- finnes.
  select e.outcome_concept_id into v_outcome_concept_id
  from knowledge.evidence_items e
  where e.id = p_evidence_item_id;

  v_verifier_actor_id := workflow.assert_reviewer_authorized(v_outcome_concept_id);

  -- Kontrollen gjelder det grunnlaget revieweren faktisk så. Låsen tas her, og
  -- holdes ut transaksjonen.
  perform workflow.assert_extraction_unchanged(
    p_evidence_item_id, p_seen_extraction_digest
  );

  return workflow.record_evidence_verification(
    p_evidence_item_id, v_verifier_actor_id, null,
    p_outcome, p_source_access, p_checked_fields, p_rationale, p_findings
  );
end;
$$;

comment on function api.register_human_extraction_verification(
  uuid, text, text, text, text[], text, text
) is
  'Den kontrollerte skriveveien for at en kvalifisert menneskelig reviewer registrerer sin egen kontroll av én ekstraksjon mot kildematerialet (ANTIDEP_CONSTITUTION.md §6, §11, §12, DATABASE_ARCHITECTURE.md §29, §43, MVP_IMPLEMENTATION_PLAN.md §15). Motstykket til api.register_extraction_verification(text, text, uuid, uuid, text, text, text[], text, text) for den menneskelige grenen av workflow.evidence_verifier_has_mandate(uuid, uuid, timestamptz). Kalleren må ha en registrert, ikke-tilbaketrukket aktør og gyldig reviewer-rolle for endepunktet evidensfunnet rapporterer om (workflow.assert_reviewer_authorized(uuid)); aktøren raden attribueres til er kallerens egen og er ikke en parameter. p_seen_extraction_digest må være avtrykket av grunnlaget slik det er nå (workflow.evidence_extraction_digest(uuid)) — en kontroll som er kommet til, eller en endret kildestatus, avviser registreringen framfor å bli stilltiende dekket av den; kontrollen tar radlåsen på evidensfunnet før den sammenligner, slik at vinduet mellom sammenligningen og innsettingen er lukket. agent_run_id er NULL: en menneskelig kontroll har ingen agentkjøring, og kolonnen fra 005g er bygget for nettopp det. Registreringen selv gjøres av workflow.record_evidence_verification(uuid, uuid, uuid, text, text, text[], text, text), den samme funksjonen agentveien bruker, slik at de to veiene ikke kan komme i utakt. Alle øvrige regler er tabellens egne og uendret: verifikator kan ikke være den som laget ekstraksjonen, en bekreftelse kan ikke hvile på et avledet sammendrag alene, en bekreftelse må ha kontrollert source_locator, et annet utfall enn verified må ha et funn, checked_fields kan ikke være tom, og raden er append-only. Denne veien er ikke kontrollen av påstanden mot grunnlaget — den er api.register_human_claim_verification(uuid, text, text, text, text, text, text, text, text, text, jsonb, text, text), og publiseringsgaten krever begge, hver for seg (G5 og G9). SECURITY DEFINER fordi workflow, knowledge og provenance har RLS med default deny; tomt search_path, og kalleren autoriseres på funksjonens eget kall (§50). EXECUTE gis bare til authenticated: en uinnlogget kaller har ingen aktør og kan ikke ha en reviewer-rolle.';

revoke execute on function api.register_human_extraction_verification(
  uuid, text, text, text, text[], text, text
) from public;
grant execute on function api.register_human_extraction_verification(
  uuid, text, text, text, text[], text, text
) to authenticated;
