-- ============================================================================
-- Migrasjon 005am — evidensvurderingen blir sitt eget ledd
--
-- Migrasjon 005aj ga påstandsdannelsen en operativ skrivevei, og lot den samme
-- kjøringen skrive fire ting i én transaksjon: påstandsidentiteten, revisjonen,
-- evidenslenkene — og den endelige evidensvurderingen.
--
-- De tre første hører sammen. Den fjerde gjør det ikke.
--
-- EVIDENCE_PIPELINE.md §61 skiller `ClaimAgent` («verifiserte evidensfunn» inn,
-- «`Claim`/`ClaimRevision`-forslag» ut) fra `EvidenceAssessor` («samlet evidens»
-- inn, «`EvidenceAssessment`» ut), og er uttrykkelig på at skillet ikke er en
-- rubrikk i en prompt: «Ansvarsgrensen skal samtidig være en teknisk grense:
-- hver rolle som faktisk skriver til kunnskapsbasen, har en egen aktør med en
-- egen identitet og en egen legitimasjon … En rolle som bare er et navn i en
-- prompt, er ingen grense.» Med 005aj var vurderingen nettopp det: samme aktør,
-- samme identitet, samme legitimasjon, samme transaksjon.
--
-- Denne migrasjonen deler dem:
--
--   api.register_claim_synthesis(...)      påstand, revisjon, evidenslenker
--   api.register_evidence_assessment(...)  evidensvurderingen, senere, av en
--                                          annen identitet i rollen
--                                          evidence_assessment
--
-- ----------------------------------------------------------------------------
-- Når vurderingen kan registreres — og en motstrid mellom to styrende dokumenter
--
-- MVP_IMPLEMENTATION_PLAN.md §15 beskriver kjeden slik: «Editor oppretter
-- ClaimRevision → Claim–Evidence-relasjon registreres → claim-støtte verifiseres
-- → EvidenceAssessment registreres → Clinical Reviewer godkjenner». Vurderingen
-- kommer altså **etter** kildestøtteverifikasjonen.
--
-- EVIDENCE_PIPELINE.md nummererer fasene i motsatt rekkefølge: `EvidenceAssessment`
-- er §34 og citation-verifier er §39.
--
-- Motstriden er reell, og den avgjøres ikke stilltiende her. Denne migrasjonen
-- håndhever MVP §15 sin rekkefølge, fordi den er den strengeste og fordi den er
-- den faglig holdbare: GRADE-domenene `indirekthet`, `upresisjon` og
-- `inkonsistens` er vurderinger av hvor godt evidensen treffer **påstanden slik
-- den er formulert** — populasjon, komparator, tidsramme, retning og størrelse.
-- Det er nøyaktig de sju punktene claim-verifikasjonen bedømmer
-- (DATABASE_ARCHITECTURE.md §30). En sikkerhetsgradering gitt før noen hadde
-- kontrollert at kilden faktisk støtter ordlyden, ville vært en gradering av et
-- ukontrollert samsvar.
--
-- Rekkefølgen innfører ingen blindvei: publiseringsgaten krever allerede både
-- claim-verifikasjonen (G8, G9, G9b, G9c) og vurderingen (G10), hver for seg, og
-- `knowledge.claim_evidence_set_digest(uuid)` dekker bare lenke-ID-ene — en
-- vurdering registrert etterpå endrer derfor ikke avtrykket og ugyldiggjør ikke
-- G9b eller G13. Skulle prosjektet ville følge EVIDENCE_PIPELINE sin
-- fasenummerering i stedet, er det en faglig arkitekturbeslutning som hører
-- hjemme i styringsdokumentene, og vilkåret her kan da fjernes i én
-- fremover-skrivende migrasjon uten at noe annet må endres.
--
-- ----------------------------------------------------------------------------
-- Hva som ikke er svekket
--
-- 005aj sitt argument for at alt måtte skje i én transaksjon, står fortsatt: en
-- revisjon uten evidenslenker er en blindvei, fordi vurderingen forsegler
-- evidenssettet (`knowledge.reject_evidence_link_after_assessment`). Det
-- argumentet gjelder lenkene, ikke vurderingen — og det er nettopp fordi
-- vurderingen forsegler, at den skal komme sist, etter kontrollen, og ikke i det
-- samme åndedraget som den påstanden den vurderer grunnlaget for.
--
-- Synteseveien krever fortsatt minst én evidenslenke, og hvert lenket funn må
-- fortsatt ha nådd kontrollnivået `workflow.assert_evidence_usable_for_synthesis`
-- leser. Vurderingsveien leser det samme kravet en gang til, på sitt eget
-- tidspunkt: et funn kan ha blitt trukket tilbake, eller fått et åpent avvik, i
-- mellomtiden.
--
-- En revisjon som står uten vurdering, er dermed en synlig og gyldig
-- mellomtilstand — et forslag som har vært gjennom påstandsdannelsen, men ikke
-- gjennom kontrollen og vurderingen. Publiseringsgatens G10 stopper den til
-- vurderingen finnes.
--
-- ----------------------------------------------------------------------------
-- Hvorfor synteseveien slippes og lages på nytt
--
-- En parameter kan ikke fjernes med `create or replace function`: signaturen er
-- en del av funksjonens identitet, og en `or replace` med færre parametre ville
-- laget en **andre** overlast ved siden av den gamle. Da ville en kaller som
-- fortsatt sendte `p_assessment`, truffet den gamle veien og skrevet vurderingen
-- i synteserollen igjen — altså nøyaktig det denne migrasjonen fjerner. `drop`
-- og `create` er derfor det eneste som faktisk lukker veien.
--
-- Fremover-skrivende: ingen kjørt migrasjon er redigert. Den ene revisjonen og
-- den ene vurderingen som allerede er skrevet gjennom den gamle veien, ryddes
-- gjennom prosjektets egen `knowledge.discard_unpublished_claim_artifacts(...)`
-- med bevart audit og proveniens, ikke herfra: en migrasjon som slettet klinisk
-- innhold, ville gjort redaksjonell opprydding til en kodeendring.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §4, §6, §8, §9, §10, §11, §12, §17, §20
--   docs/DATABASE_ARCHITECTURE.md §22, §29, §30, §43, §46, §50, §59
--   docs/EVIDENCE_PIPELINE.md §26, §27, §34, §35, §39, §61
--   docs/KNOWLEDGE_MODEL.md §13, §19.2
--   docs/MVP_IMPLEMENTATION_PLAN.md §15, §49
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Kontrollen påstanden må ha vært gjennom før grunnlaget kan graderes
--
-- Hvert vilkår er ett av publiseringsgatens, lest med den samme rekkefølgen og
-- de samme funksjonene, slik at de to ikke kan bli uenige — samme grep som
-- workflow.assert_evidence_usable_for_synthesis(uuid[]) i migrasjon 005aj.
-- ----------------------------------------------------------------------------
create function workflow.assert_claim_verified_before_assessment(p_claim_revision_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_outcome workflow.verification_outcome;
  v_verifier_actor_id uuid;
  v_verified_at timestamptz;
  v_verified_digest text;
begin
  -- G8: påstanden er kontrollert mot grunnlaget av noen.
  if not exists (
    select 1
    from workflow.claim_verifications cv
    where cv.claim_revision_id = p_claim_revision_id
  ) then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Revisjon %L har ingen registrert claim-verifikasjon, og grunnlaget kan ikke graderes ennå.',
        p_claim_revision_id
      ),
      hint = 'Evidensvurderingen kommer etter kildestøtteverifikasjonen (MVP_IMPLEMENTATION_PLAN.md §15): GRADE-domenene indirekthet, upresisjon og inkonsistens er vurderinger av hvor godt evidensen treffer påstanden slik den er formulert, og det er nettopp det claim-verifikasjonen kontrollerer. Kjør npm run agent:verify-claims for revisjonen, eller registrer en menneskelig kontroll i /review.';
  end if;

  -- G9, G9b og G9c leser alle den gjeldende kontrollen, altså den siste. Den
  -- leses én gang, slik at de tre aldri kan bli uenige om hvilken rad de
  -- snakker om.
  select cv.outcome, cv.verifier_actor_id, cv.verified_at, cv.verified_evidence_set_digest
    into v_outcome, v_verifier_actor_id, v_verified_at, v_verified_digest
  from workflow.claim_verifications cv
  where cv.claim_revision_id = p_claim_revision_id
  order by cv.registration_ordinal desc
  limit 1;

  -- G9: den gjeldende kontrollen bekrefter påstanden.
  if v_outcome <> 'verified' then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Den gjeldende claim-verifikasjonen for revisjon %L konkluderer ikke med verified.',
        p_claim_revision_id
      ),
      hint = 'Den siste registrerte kontrollen er den gjeldende, og et åpent avvik skal ikke graderes bort i en evidensvurdering. Rett påstanden i en ny revisjon og få den kontrollert på nytt; en tidligere bekreftelse opphever ikke et senere avvik.';
  end if;

  -- G9b: kontrollen gjaldt det evidenssettet som ligger der nå.
  if knowledge.claim_evidence_set_digest(p_claim_revision_id)
     is distinct from v_verified_digest then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Evidensgrunnlaget for revisjon %L er endret etter den gjeldende claim-verifikasjonen.',
        p_claim_revision_id
      ),
      hint = 'Vurderingen ville gradert et grunnlag kontrollen aldri så, og den forsegler settet den gjelder. Registrer en ny claim-verifikasjon som dekker hele det utvidede settet (ANTIDEP_CONSTITUTION.md §4, §9).';
  end if;

  -- G9c: kontrollen ble gjort av noen med mandat til det. Tidspunktet er radens
  -- eget verified_at og ikke now(): en rolletildeling som senere avsluttes,
  -- opphever ikke en kontroll som var legitim da den ble gjort.
  if not workflow.claim_verifier_has_mandate(
       v_verifier_actor_id, p_claim_revision_id, v_verified_at
     ) then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Den gjeldende claim-verifikasjonen for revisjon %L er registrert av en aktør uten mandat til å kontrollere påstanden.',
        p_claim_revision_id
      ),
      hint = 'Sitat- og kildestøtteverifikasjon er et eget mandat (ANTIDEP_CONSTITUTION.md §10). Registrer en ny kontroll fra en aktør som har det.';
  end if;
end;
$$;

comment on function workflow.assert_claim_verified_before_assessment(uuid) is
  'Kontrollen en påstandsrevisjon må ha vært gjennom før evidensgrunnlaget kan graderes (MVP_IMPLEMENTATION_PLAN.md §15). Vilkårene er påstandshalvdelen av publiseringsgaten — G8, G9, G9b og G9c i knowledge.assert_claim_revision_ready_for_approval(uuid) — lest med de samme funksjonene og den samme «siste kontroll vinner»-rekkefølgen, slik at de to ikke kan komme i utakt. Den finnes ikke for å legge til en regel, men for å lese den før vurderingen gjøres: GRADE-domenene indirekthet, upresisjon og inkonsistens er vurderinger av hvor godt evidensen treffer påstanden slik den er formulert, og det er nettopp det claim-verifikasjonen kontrollerer. Merk at EVIDENCE_PIPELINE.md nummererer fasene i motsatt rekkefølge (§34 før §39); den strengeste lesningen er valgt, og motstriden er ført i migrasjonens hodekommentar. SECURITY DEFINER fordi workflow og knowledge har RLS med default deny; tomt search_path.';

revoke execute on function workflow.assert_claim_verified_before_assessment(uuid) from public;

-- ----------------------------------------------------------------------------
-- 2. Synteseveien, uten evidensvurderingen
--
-- Uendret utenfra på alle andre punkter enn de tre: parameteren p_assessment er
-- borte, innsettingen i knowledge.evidence_assessments er borte, og svaret har
-- ikke lenger evidence_assessment_id. Samme autentisering, samme kontroll av
-- evidensgrunnlaget, samme identitetsregler, samme rekkefølge, samme SQLSTATE og
-- samme setning på hver avvisning.
-- ----------------------------------------------------------------------------
drop function api.register_claim_synthesis(
  text, text, uuid, uuid, uuid, text, text, text, text, jsonb, jsonb, uuid, uuid,
  text, text, uuid, text, text, numeric, text, text
);

create function api.register_claim_synthesis(
  p_identity_key text,
  p_secret text,
  p_agent_run_id uuid,
  p_topic_concept_id uuid,
  p_subject_drug_id uuid,
  p_statement text,
  p_scope text,
  p_comparator_kind text,
  p_uncertainty_summary text,
  p_evidence_links jsonb,
  p_claim_id uuid default null,
  p_population_id uuid default null,
  p_timeframe_min text default null,
  p_timeframe_max text default null,
  p_comparator_drug_id uuid default null,
  p_direction text default null,
  p_magnitude_measure text default null,
  p_magnitude_value numeric default null,
  p_magnitude_unit text default null,
  p_qualifiers text default null
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_identity_id uuid;
  v_actor_id uuid;
  v_claim_id uuid;
  v_claim_topic uuid;
  v_claim_drug uuid;
  v_claim_type knowledge.knowledge_type;
  v_claim_retired timestamptz;
  v_revision_number integer;
  v_supersedes uuid;
  v_revision_id uuid;
  v_evidence_item_ids uuid[];
  v_link_ids jsonb;
begin
  -- Autentiser eksplisitt for rollen claim_synthesis. En identitet i en annen
  -- rolle avvises her, før noe leses eller skrives.
  v_identity_id := provenance.authenticate_agent_identity(
    p_identity_key, p_secret, 'claim_synthesis'::provenance.agent_role
  );

  -- Krev en åpen kjøring som tilhører nøyaktig denne identiteten, og la
  -- returverdien — ikke en klientoppgitt parameter — være aktøren radene
  -- attribueres til.
  v_actor_id := provenance.assert_agent_run_open(p_agent_run_id, v_identity_id);

  -- Formen på evidenslenkene, før noe skrives. En tom eller feilformet liste
  -- skal si hva som mangler, ikke feile på en fremmednøkkel lenger nede.
  if p_evidence_links is null
     or jsonb_typeof(p_evidence_links) <> 'array'
     or jsonb_array_length(p_evidence_links) = 0 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'p_evidence_links må være en ikke-tom JSON-liste med evidenslenker.',
      hint = 'Hver lenke er et objekt med evidence_item_id, relationship_type, directness og relevance_note. Både relasjonstypen og begrunnelsen er påkrevd: en kilde som bare omhandler samme tema, skal ikke kunne telle som støtte (ANTIDEP_CONSTITUTION.md §4).';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_evidence_links) as link(value)
    where jsonb_typeof(link.value) <> 'object'
       or nullif(btrim(coalesce(link.value ->> 'evidence_item_id', '')), '') is null
       or nullif(btrim(coalesce(link.value ->> 'relationship_type', '')), '') is null
       or nullif(btrim(coalesce(link.value ->> 'directness', '')), '') is null
       or nullif(btrim(coalesce(link.value ->> 'relevance_note', '')), '') is null
  ) then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Hver evidenslenke må ha evidence_item_id, relationship_type, directness og relevance_note.',
      hint = 'Begrunnelsen er alltid påkrevd: den sier hvorfor nettopp dette funnet har nettopp denne relasjonen til nettopp denne formuleringen (KNOWLEDGE_MODEL.md §12).';
  end if;

  select array_agg(distinct (link.value ->> 'evidence_item_id')::uuid)
    into v_evidence_item_ids
  from jsonb_array_elements(p_evidence_links) as link(value);

  if cardinality(v_evidence_item_ids) <> jsonb_array_length(p_evidence_links) then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Det samme evidensfunnet er oppført flere ganger i evidenslenkene.',
      hint = 'Ett funn kan ha nøyaktig én relasjon til én revisjon (claim_evidence_links_revision_item_key). To oppføringer ville fått ett funn til å se ut som flere uavhengige, og en senere vurdering til å hvile på en oppblåst evidensmengde.';
  end if;

  -- Kontrollnivået, før påstanden lages. Se migrasjon 005aj, avsnitt 1.
  perform workflow.assert_evidence_usable_for_synthesis(v_evidence_item_ids);

  -- Identiteten: enten en ny påstand, eller en ny revisjon av en som finnes.
  --
  -- Den gjenbrukes ikke automatisk på (tema, virkestoff): to atomiske påstander
  -- om samme virkestoff og samme endepunkt er normalt og riktig
  -- (EVIDENCE_PIPELINE.md §28), og et automatisk oppslag ville slått dem sammen
  -- til revisjoner av hverandre. Kalleren sier hva den mener.
  if p_claim_id is null then
    insert into knowledge.claims (
      knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id
    )
    values (
      'evidence_synthesis'::knowledge.knowledge_type,
      p_topic_concept_id,
      p_subject_drug_id,
      v_actor_id
    )
    returning id into v_claim_id;

    v_revision_number := 1;
    v_supersedes := null;
  else
    select c.id, c.topic_concept_id, c.subject_drug_id, c.knowledge_type, c.retired_at
      into v_claim_id, v_claim_topic, v_claim_drug, v_claim_type, v_claim_retired
    from knowledge.claims c
    where c.id = p_claim_id
    for update;

    if v_claim_id is null then
      raise exception using
        errcode = 'no_data_found',
        message = format('Påstanden %L finnes ikke.', p_claim_id),
        hint = 'La p_claim_id stå tom for å opprette en ny påstandsidentitet, eller oppgi id-en til en som finnes.';
    end if;

    if v_claim_retired is not null then
      raise exception using
        errcode = 'restrict_violation',
        message = format('Påstanden %L er trukket tilbake og kan ikke få nye revisjoner.', p_claim_id),
        hint = 'En tilbaketrukket påstand er tatt ut av bruk. Opprett en ny påstand dersom temaet fortsatt skal dekkes; historikken til den gamle bevares (DATABASE_ARCHITECTURE.md §36).';
    end if;

    -- Identiteten er uforanderlig (knowledge.freeze_claim_identity). En kaller
    -- som oppgir et annet tema eller virkestoff enn påstanden har, mener en
    -- annen påstand, og skal få vite det her framfor å få en revisjon som sier
    -- noe annet enn identiteten den henger på.
    if v_claim_topic is distinct from p_topic_concept_id
       or v_claim_drug is distinct from p_subject_drug_id
       or v_claim_type <> 'evidence_synthesis' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format(
          'Påstanden %L gjelder et annet tema, virkestoff eller kunnskapstype enn det som er oppgitt.',
          p_claim_id
        ),
        hint = 'Kunnskapstype, tema og virkestoff er påstandens identitet og kan ikke endres (ANTIDEP_CONSTITUTION.md §7). Et endret tema eller virkestoff er en ny påstand.';
    end if;

    select max(r.revision_number) + 1,
           (array_agg(r.id order by r.revision_number desc))[1]
      into v_revision_number, v_supersedes
    from knowledge.claim_revisions r
    where r.claim_id = v_claim_id;

    -- En påstand uten revisjoner er en tilstand skriveveien her aldri lager,
    -- men den kan finnes: identiteten og revisjonen er to rader.
    v_revision_number := coalesce(v_revision_number, 1);
  end if;

  insert into knowledge.claim_revisions (
    claim_id, revision_number, knowledge_type, subject_drug_id, supersedes_revision_id,
    statement, scope, population_id, timeframe_min, timeframe_max,
    comparator_kind, comparator_drug_id, direction,
    magnitude_measure, magnitude_value, magnitude_unit,
    qualifiers, uncertainty_summary,
    created_by_actor_id, agent_run_id
  )
  values (
    v_claim_id,
    v_revision_number,
    'evidence_synthesis'::knowledge.knowledge_type,
    p_subject_drug_id,
    v_supersedes,
    p_statement,
    p_scope,
    p_population_id,
    p_timeframe_min::interval,
    p_timeframe_max::interval,
    p_comparator_kind::knowledge.comparator_kind,
    p_comparator_drug_id,
    p_direction::knowledge.claim_direction,
    p_magnitude_measure::knowledge.effect_measure,
    p_magnitude_value,
    p_magnitude_unit::knowledge.estimate_unit,
    p_qualifiers,
    p_uncertainty_summary,
    v_actor_id,
    -- agent_run_role er en generert konstant på raden (migrasjon 004a) og
    -- oppgis ikke her: rollen skal ikke kunne settes av en kaller.
    p_agent_run_id
  )
  returning id into v_revision_id;

  with inserted as (
    insert into knowledge.claim_evidence_links (
      claim_revision_id, evidence_item_id, relationship_type, directness,
      relevance_note, created_by_actor_id
    )
    select
      v_revision_id,
      (link.value ->> 'evidence_item_id')::uuid,
      (link.value ->> 'relationship_type')::knowledge.claim_evidence_relationship,
      (link.value ->> 'directness')::knowledge.evidence_directness,
      btrim(link.value ->> 'relevance_note'),
      v_actor_id
    from jsonb_array_elements(p_evidence_links) as link(value)
    returning id, evidence_item_id
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object('claim_evidence_link_id', i.id, 'evidence_item_id', i.evidence_item_id)
      order by i.id::text
    ),
    '[]'::jsonb
  )
    into v_link_ids
  from inserted i;

  return jsonb_build_object(
    'claim_id', v_claim_id,
    'claim_revision_id', v_revision_id,
    'revision_number', v_revision_number,
    'supersedes_revision_id', v_supersedes,
    'evidence_links', v_link_ids,
    -- Avtrykket av det evidenssettet revisjonen hviler på. Kjøringen fører det i
    -- proveniensen sin; claim-verifikasjonen må gjelde nøyaktig det
    -- (publiseringsgatens G9b), og evidensvurderingen som kommer etter den, må
    -- oppgi det samme avtrykket som sett (api.register_evidence_assessment).
    'evidence_set_digest', knowledge.claim_evidence_set_digest(v_revision_id)
  );
end;
$$;

comment on function api.register_claim_synthesis(
  text, text, uuid, uuid, uuid, text, text, text, text, jsonb, uuid, uuid,
  text, text, uuid, text, text, numeric, text, text
) is
  'Den kontrollerte skriveveien for at synteseagenten registrerer én påstandsrevisjon med evidensgrunnlaget sitt: påstandsidentiteten (eller en ny revisjon av en som finnes), revisjonen og evidenslenkene, i én transaksjon (ANTIDEP_CONSTITUTION.md §4, §7, §10, §12). Autentiserer identiteten eksplisitt for rollen claim_synthesis og krever en åpen agentkjøring som tilhører den; aktøren radene attribueres til er kjøringens egen og er ikke en parameter. Kunnskapstypen er hardkodet evidence_synthesis: et deterministisk faktum avgjøres mot en autoritativ kilde, og en klinisk anbefaling skal ikke ha en KI-kjøring som opphav. Hvert lenket evidensfunn må ha nådd kontrollnivået EVIDENCE_PIPELINE.md §26 og §27 krever, lest av workflow.assert_evidence_usable_for_synthesis(uuid[]) med publiseringsgatens egne funksjoner. Veien registrerer IKKE evidensvurderingen: den er et annet ansvar, med en egen rolle, en egen identitet og et eget senere ledd (api.register_evidence_assessment(...), migrasjon 005am, EVIDENCE_PIPELINE.md §61). Veien godkjenner ingenting: revisjonen er et forslag uten claim-verifikasjon, uten evidensvurdering, uten reviewbeslutning og uten publiseringspeker. SECURITY DEFINER fordi knowledge, catalog og provenance har RLS med default deny; tomt search_path. EXECUTE går til anon og authenticated av samme grunn som de øvrige agentendepunktene: en agent har ingen brukerkonto, og det er legitimasjonen og ikke Data API-rollen som er kontrollen.';

revoke execute on function api.register_claim_synthesis(
  text, text, uuid, uuid, uuid, text, text, text, text, jsonb, uuid, uuid,
  text, text, uuid, text, text, numeric, text, text
) from public;
grant execute on function api.register_claim_synthesis(
  text, text, uuid, uuid, uuid, text, text, text, text, jsonb, uuid, uuid,
  text, text, uuid, text, text, numeric, text, text
) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- 3. Vurderingsveien
--
-- Ingen feltvalidering er duplisert her: constraintene på
-- knowledge.evidence_assessments er fasiten, inkludert at en GRADE-gradering
-- krever alle fem domenene vurdert, at no_assessable_evidence krever at
-- domenene står tomme, og at den tilstanden må si hva som mangler
-- (ANTIDEP_CONSTITUTION.md §6, §17). Det som står her, er de vilkårene som
-- handler om *rekkefølge og mandat*, og som en tabellconstraint ikke kan se.
-- ----------------------------------------------------------------------------
create function api.register_evidence_assessment(
  p_identity_key text,
  p_secret text,
  p_agent_run_id uuid,
  p_claim_revision_id uuid,
  p_seen_evidence_set_digest text,
  p_framework text,
  p_certainty_level text,
  p_rationale text,
  p_risk_of_bias text default null,
  p_inconsistency text default null,
  p_indirectness text default null,
  p_imprecision text default null,
  p_publication_bias text default null,
  p_other_considerations text default null,
  p_evidence_gap text default null
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_identity_id uuid;
  v_actor_id uuid;
  v_claim_id uuid;
  v_knowledge_type knowledge.knowledge_type;
  v_retired_at timestamptz;
  v_evidence_item_ids uuid[];
  v_assessment_id uuid;
  v_assessed_at timestamptz;
begin
  -- Autentiser eksplisitt for rollen evidence_assessment. En syntese- eller
  -- verifikatoridentitet avvises her, før noe leses eller skrives: ansvaret for
  -- å gradere sikkerheten i grunnlaget er en annen rolle enn den som formulerte
  -- påstanden, og enn den som kontrollerte den (EVIDENCE_PIPELINE.md §61).
  v_identity_id := provenance.authenticate_agent_identity(
    p_identity_key, p_secret, 'evidence_assessment'::provenance.agent_role
  );

  v_actor_id := provenance.assert_agent_run_open(p_agent_run_id, v_identity_id);

  select r.claim_id, r.knowledge_type, c.retired_at
    into v_claim_id, v_knowledge_type, v_retired_at
  from knowledge.claim_revisions r
  join knowledge.claims c on c.id = r.claim_id
  where r.id = p_claim_revision_id;

  if v_claim_id is null then
    raise exception using
      errcode = 'no_data_found',
      message = format('Påstandsrevisjon %L finnes ikke.', p_claim_revision_id),
      hint = 'Vurderingen gjelder en eksakt revisjon, ikke påstandsidentiteten (KNOWLEDGE_MODEL.md §19.3). Kontroller revisjons-ID-en.';
  end if;

  -- Samme avgrensning som synteseveien, og av samme grunn: en klinisk
  -- anbefaling skal ikke ha en KI-kjøring som opphav, og et deterministisk
  -- faktum skal ikke ha en GRADE-vurdering i det hele tatt
  -- (ANTIDEP_CONSTITUTION.md §12, §17, KNOWLEDGE_MODEL.md §13).
  if v_knowledge_type <> 'evidence_synthesis' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format(
        'Revisjon %L er av typen %s, og denne veien vurderer bare evidenssynteser.',
        p_claim_revision_id, v_knowledge_type
      ),
      hint = 'En klinisk anbefaling skal ikke ha en KI-kjøring som opphav, og et deterministisk faktum skal ikke ha en evidensvurdering. Trenger en annen kunnskapstype en vurdering, er det en egen skrivevei med sine egne vilkår.';
  end if;

  if v_retired_at is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Påstanden bak revisjon %L er trukket tilbake og skal ikke vurderes.',
        p_claim_revision_id
      ),
      hint = 'En tilbaketrukket påstand er tatt ut av bruk. Historikken bevares (DATABASE_ARCHITECTURE.md §36).';
  end if;

  -- Låsen på revisjonsraden tas her, og holdes ut transaksjonen. Den er både
  -- kontrollen av at kalleren vurderte det grunnlaget som faktisk ligger der, og
  -- serialiseringen mot en evidenslenke som commiter i vinduet mellom lesningen
  -- og innsettingen — den samme raden hver innsetting i
  -- knowledge.claim_evidence_links allerede låser (migrasjon 006f). Uten den
  -- ville vurderingen kunnet forsegle et sett den aldri så.
  perform workflow.assert_evidence_set_unchanged(p_claim_revision_id, p_seen_evidence_set_digest);

  select array_agg(distinct l.evidence_item_id)
    into v_evidence_item_ids
  from knowledge.claim_evidence_links l
  where l.claim_revision_id = p_claim_revision_id;

  if v_evidence_item_ids is null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Revisjon %L har ingen registrerte evidenslenker, og det finnes ikke noe grunnlag å vurdere.',
        p_claim_revision_id
      ),
      hint = 'Evidenslenkene registreres sammen med revisjonen av api.register_claim_synthesis(...). En vurdering uten et evidensgrunnlag ville vært en gradering av ingenting (ANTIDEP_CONSTITUTION.md §4).';
  end if;

  -- Kontrollnivået leses på nytt, på vurderingstidspunktet: et funn kan ha blitt
  -- trukket tilbake, eller fått et åpent avvik, etter at revisjonen ble laget.
  -- Samme funksjon som synteseveien bruker, slik at de to ikke kan bli uenige.
  perform workflow.assert_evidence_usable_for_synthesis(v_evidence_item_ids);

  -- Rekkefølgen: kildestøtteverifikasjonen kommer først. Se hodekommentaren.
  perform workflow.assert_claim_verified_before_assessment(p_claim_revision_id);

  -- Én vurdering per revisjon (evidence_assessments_claim_revision_key). En
  -- eksisterende vurdering skal ikke møtes av en naken unique-avvisning: den
  -- betyr at revisjonen allerede er gradert, og at en ny vurdering hører hjemme
  -- i en ny revisjon.
  if exists (
    select 1
    from knowledge.evidence_assessments a
    where a.claim_revision_id = p_claim_revision_id
  ) then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Revisjon %L har allerede en evidensvurdering.', p_claim_revision_id),
      hint = 'Vurderingen er append-only og forsegler evidenssettet til revisjonen. En endret vurdering av det samme grunnlaget er en ny revisjon, ikke en overskriving (ANTIDEP_CONSTITUTION.md §14).';
  end if;

  insert into knowledge.evidence_assessments (
    claim_revision_id, assessed_knowledge_type, framework, certainty_level,
    risk_of_bias, inconsistency, indirectness, imprecision, publication_bias,
    other_considerations, rationale, evidence_gap, assessed_at,
    created_by_actor_id, agent_run_id
  )
  values (
    p_claim_revision_id,
    v_knowledge_type,
    p_framework::knowledge.assessment_framework,
    p_certainty_level::knowledge.certainty_level,
    p_risk_of_bias::knowledge.grade_domain_rating,
    p_inconsistency::knowledge.grade_domain_rating,
    p_indirectness::knowledge.grade_domain_rating,
    p_imprecision::knowledge.grade_domain_rating,
    p_publication_bias::knowledge.grade_domain_rating,
    btrim(p_other_considerations),
    btrim(p_rationale),
    btrim(p_evidence_gap),
    -- Tidspunktet eies av databasen, som verified_at på kontrollene: en verdi
    -- kalleren kunne oppgitt, kunne datert en vurdering til noe annet enn da den
    -- faktisk ble gjort (DATABASE_ARCHITECTURE.md §7.3).
    now(),
    v_actor_id,
    -- agent_run_role er en generert konstant på raden (migrasjon 004b) og
    -- oppgis ikke her: rollen skal ikke kunne settes av en kaller.
    p_agent_run_id
  )
  returning id, assessed_at into v_assessment_id, v_assessed_at;

  return jsonb_build_object(
    'evidence_assessment_id', v_assessment_id,
    'claim_revision_id', p_claim_revision_id,
    'claim_id', v_claim_id,
    'certainty_level', p_certainty_level,
    'assessed_at', v_assessed_at,
    'evidence_set_digest', knowledge.claim_evidence_set_digest(p_claim_revision_id)
  );
end;
$$;

comment on function api.register_evidence_assessment(
  text, text, uuid, uuid, text, text, text, text, text, text, text, text, text, text, text
) is
  'Den kontrollerte skriveveien for at evidensvurderingsagenten registrerer én EvidenceAssessment for én påstandsrevisjon (ANTIDEP_CONSTITUTION.md §6, §17, EVIDENCE_PIPELINE.md §34, §35, §61). Autentiserer identiteten eksplisitt for rollen evidence_assessment — ikke claim_synthesis — og krever en åpen agentkjøring som tilhører den; aktøren raden attribueres til er kjøringens egen og er ikke en parameter. Veien kommer ETTER kildestøtteverifikasjonen (MVP_IMPLEMENTATION_PLAN.md §15): workflow.assert_claim_verified_before_assessment(uuid) krever publiseringsgatens G8, G9, G9b og G9c, lest med gatens egne funksjoner. Evidensgrunnlaget kontrolleres på nytt på vurderingstidspunktet med workflow.assert_evidence_usable_for_synthesis(uuid[]), og p_seen_evidence_set_digest må være avtrykket av evidenssettet slik det er nå — kontrollen tar FOR UPDATE på revisjonsraden og holder låsen, slik at en lenke som kommer til underveis, ikke kan bli stilltiende forseglet av en vurdering som aldri så den. Kunnskapstypen må være evidence_synthesis. Nøyaktig én vurdering per revisjon; raden er append-only og forsegler evidenssettet (knowledge.reject_evidence_link_after_assessment). assessed_at er alltid now(). Ingen feltvalidering er duplisert her: constraintene på knowledge.evidence_assessments er fasiten, inkludert kravet om at alle fem GRADE-domenene er vurdert, og at no_assessable_evidence står uten domener og med en evidence_gap som sier hva som mangler. Veien godkjenner ingenting. SECURITY DEFINER fordi knowledge, workflow og provenance har RLS med default deny; tomt search_path. EXECUTE går til anon og authenticated av samme grunn som de øvrige agentendepunktene: en agent har ingen brukerkonto, og det er legitimasjonen og ikke Data API-rollen som er kontrollen.';

revoke execute on function api.register_evidence_assessment(
  text, text, uuid, uuid, text, text, text, text, text, text, text, text, text, text, text
) from public;
grant execute on function api.register_evidence_assessment(
  text, text, uuid, uuid, text, text, text, text, text, text, text, text, text, text, text
) to anon, authenticated;
