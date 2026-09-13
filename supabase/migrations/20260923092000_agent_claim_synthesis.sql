-- ============================================================================
-- Migrasjon 005aj — synteseagenten får sin egen skrivevei
--
-- Kjeden MVP_IMPLEMENTATION_PLAN.md §15 beskriver, har hatt ett ledd uten en
-- operativ vei: påstandsdannelsen. Kilden, kildeversjonen, evidensfunnet,
-- forankringen, den maskinelle kontrollen, den menneskelige kildekontrollen,
-- claim-verifikasjonen, reviewbeslutningen og publiseringen har alle hver sin
-- kontrollerte skrivevei i `api`. Påstanden hadde ingen. De påstandene som har
-- stått i basen, ble lagt inn av migrasjon 004 selv, og er fjernet igjen
-- (migrasjon 005ah) fordi grunnlaget under dem ikke lot seg kontrollere.
--
-- Uten denne veien finnes det bare to måter å få en påstand inn på, og begge er
-- utelukket: en migrasjon som skriver klinisk innhold, eller direkte SQL mot
-- produksjonsbasen. Den første gjør faglig innhold til en kodeendring; den andre
-- er nøyaktig det ANTIDEP_CONSTITUTION.md §15 sier at en kvalifisert redaktør
-- ikke skal trenge, og etterlater ingen proveniens.
--
-- ----------------------------------------------------------------------------
-- Hva veien gjør, og hvorfor alt skjer i én transaksjon
--
-- Én påstandsrevisjon er ikke én rad. Den er identiteten, revisjonen,
-- evidenslenkene og evidensvurderingen — og de tre siste er append-only og
-- forseglet av hverandre: `knowledge.reject_evidence_link_after_assessment()`
-- gjør at evidenssettet ikke kan utvides etter at vurderingen er registrert.
-- En halvferdig syntese er derfor ikke en tilstand som kan rettes opp; den er en
-- revisjon som aldri kan få resten av grunnlaget sitt.
--
-- Funksjonen skriver derfor alt eller ingenting. Den avviser en kaller som
-- forsøker å registrere en revisjon uten evidenslenker eller uten
-- evidensvurdering — ikke fordi databasen ellers ville vært inkonsistent, men
-- fordi den mellomtilstanden er en blindvei.
--
-- ----------------------------------------------------------------------------
-- Kunnskapstypen er hardkodet, som `extraction_method` er det på 005v
--
-- `evidence_synthesis` og ingen annen. De to øvrige typene hører ikke til dette
-- leddet: et `deterministic_fact` avgjøres direkte mot en autoritativ kilde
-- (EVIDENCE_PIPELINE.md §4.1) og trenger verken GRADE-vurdering eller
-- syntesearbeid, og en `clinical_recommendation` er en normativ påstand om hva
-- klinikeren bør gjøre — den skal ikke ha en KI-kjøring som opphav
-- (ANTIDEP_CONSTITUTION.md §12, §17). Typen er derfor ikke en parameter kalleren
-- kan velge. Trenger et senere ledd en annen type, er det en egen skrivevei med
-- sine egne vilkår, ikke et ekstra argument her.
--
-- ----------------------------------------------------------------------------
-- Hvilken evidens som kan bære en påstand
--
-- EVIDENCE_PIPELINE.md §27: «Claim-agenten skal bruke **verifiserte**
-- EvidenceItem». §26: «Bare evidens som har nådd nødvendig kontrollnivå skal
-- kunne brukes til publiserbar syntese.» Kravet finnes fra før, som
-- evidenshalvdelen av publiseringsgaten (G4, G5, G5b, G5c, G6 og G7 i
-- `knowledge.assert_claim_revision_ready_for_approval`). Det som har manglet, er
-- at det leses *før* påstanden lages.
--
-- `workflow.assert_evidence_usable_for_synthesis(uuid[])` er den lesningen. Den
-- er ikke en ny regel og ikke en andre formulering av en gammel: den kaller de
-- samme funksjonene gaten kaller, i samme rekkefølge, slik at de to ikke kan bli
-- uenige. Poenget er *når* den svarer. Uten den ville en syntese bygget på et
-- funn som er trukket tilbake, ikke kontrollert, eller kontrollert med et åpent
-- avvik, blitt en revisjon som aldri kan publiseres — og som, fordi
-- evidenssettet forsegles av vurderingen, må erstattes av en ny revisjon i sin
-- helhet når funnet rettes. Det er nøyaktig det artefaktet migrasjon 005ah måtte
-- bygges for å rydde bort.
--
-- Gaten er ikke svekket noe sted. Den leser fortsatt alt den leste, på
-- publiseringstidspunktet, av seg selv.
--
-- ----------------------------------------------------------------------------
-- Hva veien ikke gjør
--
-- Den godkjenner ingenting. En revisjon herfra er et KI-utarbeidet forslag: den
-- har ingen claim-verifikasjon, ingen reviewbeslutning og ingen
-- publiseringspeker, og publiseringsgaten stopper den på G8 til en separat
-- kontrollfase har vært gjennom den (ANTIDEP_CONSTITUTION.md §11, §12).
-- Identiteten `agent-identity:claim-synthesis-01` har rollen `claim_synthesis`
-- og ingen annen, så den kan verken kontrollere sin egen påstand
-- (`claim_verifications_separate_actor_check` ville uansett stoppet det, men her
-- stopper allerede autentiseringen) eller registrere en faglig beslutning
-- (`workflow.review_decisions` krever en menneskelig aktør).
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §4, §5, §6, §7, §8, §9, §10, §11, §12, §17, §20
--   docs/DATABASE_ARCHITECTURE.md §13, §14, §21, §22, §29, §30, §43, §46, §50
--   docs/EVIDENCE_PIPELINE.md §26, §27, §28, §29, §30, §34, §35
--   docs/KNOWLEDGE_MODEL.md §8, §9, §12, §13, §19
--   docs/MVP_IMPLEMENTATION_PLAN.md §15, §29, §49
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Kontrollnivået evidensen må ha nådd før den kan bære en påstand
--
-- Hvert vilkår under er ett av publiseringsgatens, lest med den samme
-- funksjonen og den samme «siste kontroll vinner»-rekkefølgen. Meldingene sier
-- hvilket vilkår som sviktet og hva som retter det, fordi kalleren er en kjøring
-- som skal kunne rapportere grunnen videre uten å gjette.
-- ----------------------------------------------------------------------------
create function workflow.assert_evidence_usable_for_synthesis(p_evidence_item_ids uuid[])
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_offenders text;
begin
  if p_evidence_item_ids is null or cardinality(p_evidence_item_ids) = 0 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En påstand kan ikke registreres uten et evidensgrunnlag.',
      hint = 'Oppgi minst ett evidensfunn med en begrunnet relasjon til påstanden. En påstand uten kobling til en identifiserbar kilde er ikke etterprøvbar (ANTIDEP_CONSTITUTION.md §4).';
  end if;

  -- Funnet finnes i det hele tatt. Uten dette ville de øvrige vilkårene svart
  -- «ingen kontroll registrert» på en id som ikke peker på noe.
  select string_agg(distinct wanted.id::text, ', ' order by wanted.id::text)
    into v_offenders
  from unnest(p_evidence_item_ids) as wanted(id)
  where not exists (
    select 1 from knowledge.evidence_items e where e.id = wanted.id
  );

  if v_offenders is not null then
    raise exception using
      errcode = 'no_data_found',
      message = format('Evidensfunn som ikke finnes: %s.', v_offenders),
      hint = 'Kontroller id-ene. Et evidensfunn registreres av api.register_agent_extraction(...) eller api.create_evidence_item(...).';
  end if;

  -- G4: funnet er kontrollert av noen.
  select string_agg(distinct wanted.id::text, ', ' order by wanted.id::text)
    into v_offenders
  from unnest(p_evidence_item_ids) as wanted(id)
  where not exists (
    select 1
    from workflow.evidence_verifications ev
    where ev.evidence_item_id = wanted.id
  );

  if v_offenders is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Evidensfunn uten registrert ekstraksjonsverifikasjon: %s.', v_offenders),
      hint = 'En separat kontrollfase skal ha gått gjennom ekstraksjonen mot kildematerialet før den kan bære en påstand (ANTIDEP_CONSTITUTION.md §11, EVIDENCE_PIPELINE.md §26, §27). Kjør npm run agent:verify-extraction, og la deretter en kvalifisert redaktør gjøre kildekontrollen i /extraction-review.';
  end if;

  -- G5: den gjeldende kontrollen bekrefter funnet. Den siste er den gjeldende:
  -- et senere needs_correction, rejected eller uncertain er et åpent avvik,
  -- uansett hvor mange bekreftelser som ligger foran det.
  select string_agg(distinct wanted.id::text, ', ' order by wanted.id::text)
    into v_offenders
  from unnest(p_evidence_item_ids) as wanted(id)
  where (
    select ev.outcome
    from workflow.evidence_verifications ev
    where ev.evidence_item_id = wanted.id
    order by ev.registration_ordinal desc
    limit 1
  ) <> 'verified';

  if v_offenders is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Evidensfunn med åpent verifikasjonsfunn: %s.', v_offenders),
      hint = 'Den siste registrerte ekstraksjonskontrollen konkluderer ikke med verified, og en påstand bygget på funnet ville aldri kunne publiseres (publiseringsgatens G5). Rett ekstraksjonen i et nytt evidensfunn og få det kontrollert på nytt; en tidligere bekreftelse opphever ikke et senere avvik.';
  end if;

  -- G5b: kontrollene dekker til sammen det raden faktisk påstår. Samme union
  -- som gaten leser, med den samme nullstillingen ved en ikke-bekreftende
  -- kontroll.
  select string_agg(distinct wanted.id::text, ', ' order by wanted.id::text)
    into v_offenders
  from unnest(p_evidence_item_ids) as wanted(id)
  where exists (
    select 1
    from unnest(workflow.required_check_fields(wanted.id)) as required(field)
    where required.field <> all (workflow.covered_check_fields(wanted.id))
  );

  if v_offenders is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Evidensfunn uten fullstendig kontrollert ekstraksjon: %s.', v_offenders),
      hint = 'De registrerte kontrollene dekker ikke alle feltene funnet påstår noe om. workflow.required_check_fields(evidence_item_id) viser hva som kreves, og workflow.covered_check_fields(evidence_item_id) hva som er dekket. Merk at en ikke-bekreftende kontroll nullstiller dekningen.';
  end if;

  -- G5c: den gjeldende kontrollen ble gjort av noen med mandat til det.
  select string_agg(distinct wanted.id::text, ', ' order by wanted.id::text)
    into v_offenders
  from unnest(p_evidence_item_ids) as wanted(id)
  cross join lateral (
    select ev.verifier_actor_id, ev.verified_at
    from workflow.evidence_verifications ev
    where ev.evidence_item_id = wanted.id
    order by ev.registration_ordinal desc
    limit 1
  ) as current_check
  where not workflow.evidence_verifier_has_mandate(
          current_check.verifier_actor_id, wanted.id, current_check.verified_at
        );

  if v_offenders is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Evidensfunn der den gjeldende ekstraksjonskontrollen mangler mandat: %s.', v_offenders),
      hint = 'Kontroll av en ekstraksjon mot kilden er et eget mandat (ANTIDEP_CONSTITUTION.md §10). Registrer en ny kontroll fra en aktør som har det.';
  end if;

  -- G6: ekstraksjonen er ikke trukket tilbake.
  select string_agg(distinct wanted.id::text, ', ' order by wanted.id::text)
    into v_offenders
  from unnest(p_evidence_item_ids) as wanted(id)
  where (
    select rd.decision
    from workflow.review_decisions rd
    where rd.evidence_item_id = wanted.id
      and rd.review_type = 'extraction_withdrawal'
    order by rd.registration_ordinal desc
    limit 1
  ) = 'extraction_withdrawn';

  if v_offenders is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Evidensfunn med tilbaketrukket ekstraksjon: %s.', v_offenders),
      hint = 'En tilbaketrukket ekstraksjon skal ikke bære en påstand. Bygg påstanden på et annet funn, eller registrer en ny beslutning som opprettholder ekstraksjonen dersom tilbaketrekkingen var feil.';
  end if;

  -- G7: ingen lenket kilde er trukket tilbake eller tilbakekalt.
  select string_agg(distinct s.id::text, ', ' order by s.id::text)
    into v_offenders
  from unnest(p_evidence_item_ids) as wanted(id)
  join knowledge.evidence_items e on e.id = wanted.id
  join knowledge.sources s on s.id = e.source_id
  where s.source_status in ('retracted', 'withdrawn');

  if v_offenders is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Kilder med statusen retracted eller withdrawn i grunnlaget: %s.', v_offenders),
      hint = 'En tilbaketrukket eller tilbakekalt kilde kan ikke bære en påstand (DATABASE_ARCHITECTURE.md §58).';
  end if;
end;
$$;

comment on function workflow.assert_evidence_usable_for_synthesis(uuid[]) is
  'Kontrollnivået et evidensfunn må ha nådd før det kan bære en påstand (EVIDENCE_PIPELINE.md §26, §27). Vilkårene er evidenshalvdelen av publiseringsgaten — G4, G5, G5b, G5c, G6 og G7 i knowledge.assert_claim_revision_ready_for_approval(uuid) — lest av de samme funksjonene og med den samme «siste kontroll vinner»-rekkefølgen, slik at de to ikke kan komme i utakt. Den finnes ikke for å legge til en regel, men for å lese den før påstanden lages: en syntese bygget på et ukontrollert eller tilbaketrukket funn blir en revisjon som aldri kan publiseres, og som må erstattes i sin helhet når funnet rettes, fordi evidensvurderingen forsegler evidenssettet. SECURITY DEFINER fordi knowledge og workflow har RLS med default deny; tomt search_path.';

revoke execute on function workflow.assert_evidence_usable_for_synthesis(uuid[]) from public;

-- ----------------------------------------------------------------------------
-- 2. Skriveveien
-- ----------------------------------------------------------------------------
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
  p_assessment jsonb,
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
  v_assessment_id uuid;
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

  -- Kontrollnivået, før påstanden lages. Se avsnitt 1.
  perform workflow.assert_evidence_usable_for_synthesis(v_evidence_item_ids);

  -- Evidensvurderingen er ikke valgfri for en evidenssyntese
  -- (ANTIDEP_CONSTITUTION.md §6). Den er dessuten forseglingshandlingen for
  -- evidenssettet, så en revisjon uten den er en revisjon som senere kan få
  -- flere lenker uten at noen har vurdert helheten.
  if p_assessment is null or jsonb_typeof(p_assessment) <> 'object' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'p_assessment må være et JSON-objekt med evidensvurderingen.',
      hint = 'En evidenssyntese skal ha en eksplisitt vurdering av sikkerheten i kunnskapsgrunnlaget, med de fem GRADE-domenene vurdert — eller certainty_level = no_assessable_evidence med en evidence_gap som sier hva som mangler (ANTIDEP_CONSTITUTION.md §6).';
  end if;

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

  -- Lenkene før vurderingen, fordi vurderingen forsegler settet
  -- (knowledge.reject_evidence_link_after_assessment).
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

  insert into knowledge.evidence_assessments (
    claim_revision_id, assessed_knowledge_type, framework, certainty_level,
    risk_of_bias, inconsistency, indirectness, imprecision, publication_bias,
    other_considerations, rationale, evidence_gap, assessed_at, created_by_actor_id
  )
  values (
    v_revision_id,
    'evidence_synthesis'::knowledge.knowledge_type,
    (p_assessment ->> 'framework')::knowledge.assessment_framework,
    (p_assessment ->> 'certainty_level')::knowledge.certainty_level,
    (p_assessment ->> 'risk_of_bias')::knowledge.grade_domain_rating,
    (p_assessment ->> 'inconsistency')::knowledge.grade_domain_rating,
    (p_assessment ->> 'indirectness')::knowledge.grade_domain_rating,
    (p_assessment ->> 'imprecision')::knowledge.grade_domain_rating,
    (p_assessment ->> 'publication_bias')::knowledge.grade_domain_rating,
    btrim(p_assessment ->> 'other_considerations'),
    btrim(p_assessment ->> 'rationale'),
    btrim(p_assessment ->> 'evidence_gap'),
    -- Tidspunktet eies av databasen, som verified_at på kontrollene: en verdi
    -- kalleren kunne oppgitt, kunne datert en vurdering til noe annet enn da den
    -- faktisk ble gjort (DATABASE_ARCHITECTURE.md §7.3).
    now(),
    v_actor_id
  )
  returning id into v_assessment_id;

  return jsonb_build_object(
    'claim_id', v_claim_id,
    'claim_revision_id', v_revision_id,
    'revision_number', v_revision_number,
    'supersedes_revision_id', v_supersedes,
    'evidence_links', v_link_ids,
    'evidence_assessment_id', v_assessment_id,
    -- Avtrykket av det evidenssettet revisjonen nå hviler på. Kjøringen fører
    -- det i proveniensen sin, og claim-verifikasjonen som følger, må gjelde
    -- nøyaktig det (publiseringsgatens G9b).
    'evidence_set_digest', knowledge.claim_evidence_set_digest(v_revision_id)
  );
end;
$$;

comment on function api.register_claim_synthesis(
  text, text, uuid, uuid, uuid, text, text, text, text, jsonb, jsonb, uuid, uuid,
  text, text, uuid, text, text, numeric, text, text
) is
  'Den kontrollerte skriveveien for at synteseagenten registrerer én påstandsrevisjon med hele grunnlaget sitt: påstandsidentiteten (eller en ny revisjon av en som finnes), revisjonen, evidenslenkene og evidensvurderingen, i én transaksjon (ANTIDEP_CONSTITUTION.md §4, §6, §7, §10, §12). Autentiserer identiteten eksplisitt for rollen claim_synthesis og krever en åpen agentkjøring som tilhører den; aktøren radene attribueres til er kjøringens egen og er ikke en parameter. Kunnskapstypen er hardkodet evidence_synthesis: et deterministisk faktum avgjøres mot en autoritativ kilde, og en klinisk anbefaling skal ikke ha en KI-kjøring som opphav. Hvert lenket evidensfunn må ha nådd kontrollnivået EVIDENCE_PIPELINE.md §26 og §27 krever, lest av workflow.assert_evidence_usable_for_synthesis(uuid[]) med publiseringsgatens egne funksjoner. Veien godkjenner ingenting: revisjonen er et forslag uten claim-verifikasjon, uten reviewbeslutning og uten publiseringspeker. SECURITY DEFINER fordi knowledge, catalog og provenance har RLS med default deny; tomt search_path. EXECUTE går til anon og authenticated av samme grunn som de øvrige agentendepunktene: en agent har ingen brukerkonto, og det er legitimasjonen og ikke Data API-rollen som er kontrollen.';

revoke execute on function api.register_claim_synthesis(
  text, text, uuid, uuid, uuid, text, text, text, text, jsonb, jsonb, uuid, uuid,
  text, text, uuid, text, text, numeric, text, text
) from public;
grant execute on function api.register_claim_synthesis(
  text, text, uuid, uuid, uuid, text, text, text, text, jsonb, jsonb, uuid, uuid,
  text, text, uuid, text, text, numeric, text, text
) to anon, authenticated;
