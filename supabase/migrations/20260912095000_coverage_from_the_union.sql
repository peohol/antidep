-- ============================================================================
-- Migrasjon 005y — dekningen er unionen av kontroller, og ingen rad påstår mer
--                  enn sin egen operasjon
--
-- Publiseringsgatens G5b har alltid vært en union: «kravet gjelder unionen over
-- funnets bekreftede kontroller, slik at flere verifikatorledd kan dele
-- arbeidet» (migrasjon 20260907093000). To regler gjorde likevel at unionen
-- ikke virket i praksis, og resultatet var at den menneskelige kontrollraden
-- måtte påstå å ha kontrollert noe mennesket aldri ble spurt om.
--
-- ----------------------------------------------------------------------------
-- 1. Den ene raden måtte oppgi source_locator for å kunne bekrefte
--
-- `evidence_verifications_locator_checked_check` krevde `source_locator` i
-- *enhver* bekreftelse. Kildepekeren er en provenanspåstand — «hvor i
-- dokumentet står funnet?» — og den kontrolleres av maskinen, ikke av
-- klinikeren. Kravet tvang derfor menneskets rad til å føre opp et felt økten
-- aldri stilte spørsmål om.
--
-- Garantien forsvinner ikke: den flyttes dit den hører hjemme. G5b krever
-- fortsatt at `source_locator` er dekket, og `workflow.required_check_fields`
-- fører det opp for hver rad. Forskjellen er at dekningen nå kan komme fra den
-- kontrollen som faktisk gjorde jobben.
--
-- ----------------------------------------------------------------------------
-- 2. Bare bekreftende kontroller talte, og maskinen bekrefter sjelden
--
-- `workflow.covered_check_fields` telte bare rader med utfallet `verified`, og
-- nullstilte dekningen ved enhver senere rad som ikke var det. Den
-- deterministiske kontrollen ender normalt på `uncertain`: katalogen er norsk
-- og kildene engelske, så begreper og tall står ofte ukontrollert. Maskinen
-- kunne dermed aldri bidra med dekning, uansett hva den faktisk hadde bevist.
--
-- Regelen skilles derfor i to, som er det den alltid mente:
--
--   * Et **avvik** (`needs_correction`, `rejected`) er en motsigelse. Det
--     nullstiller dekningen fra alt som ligger foran, som før.
--   * En **uavklart** kontroll er ingen motsigelse. Den konkluderte ikke om
--     raden som helhet, men feltene den førte opp i `checked_fields`, gikk den
--     faktisk gjennom og fant i orden. De teller.
--
-- Det forutsetter at `checked_fields` er sann per felt, og det er den:
-- `src/agents/extraction-checks.ts` fører bare opp felter den positivt
-- bekreftet, og fra denne leveransen gjør den menneskelige utledningen det
-- samme.
--
-- G5 er urørt og er det som hindrer at en uavklart kontroll blir en
-- bekreftelse: den *siste* registrerte kontrollen må fortsatt være `verified`.
-- Unionen sier hva som er dekket; G5 sier at noen konkluderte.
--
-- ----------------------------------------------------------------------------
-- 3. raw_extraction kreves bare når raden har en
--
-- `required_check_fields` førte opp `raw_extraction` ubetinget. Kolonnen er
-- valgfri, og fra agentkontrakten (migrasjon 005v) er den ikke lenger
-- kontrollgrunnlaget — kildeforankringen er. En agentekstraksjon uten
-- `source_quote` påstår ingenting i den kolonnen, og et krav om å kontrollere
-- den ville aldri kunnet oppfylles. Feltet føres derfor opp etter samme regel
-- som resten: når raden faktisk sier noe der.
--
-- ----------------------------------------------------------------------------
-- 4. Maskinbeviset hviler ikke lenger på raw_extraction
--
-- `workflow.grounding_machine_proved` krevde både `raw_extraction` og
-- `source_locator` i maskinradens `checked_fields`. Det gjorde den gamle
-- kolonnen til en skjult forutsetning i den nye stien: en helt gyldig
-- agentekstraksjon med komplett forankring, men uten `source_quote`, kunne
-- aldri bli bevist og dermed aldri menneskebekreftes.
--
-- Beviset er `source_locator` alene, og det er tilstrekkelig fordi
-- `checkExtraction` fører opp nettopp det feltet bare når representasjonen lot
-- seg reprodusere, forankringen er komplett, og hvert forankret utdrag ble
-- gjenfunnet ordrett.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §6, §10, §11, §17
--   docs/DATABASE_ARCHITECTURE.md §29, §57
--   docs/MVP_IMPLEMENTATION_PLAN.md §15, §49
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Kildepekerkravet flyttes fra raden til gaten
-- ----------------------------------------------------------------------------
alter table workflow.evidence_verifications
  drop constraint evidence_verifications_locator_checked_check;

comment on column workflow.evidence_verifications.checked_fields is
  'Nøyaktig de feltene denne ene operasjonen gikk gjennom og fant i orden — aldri flere. En rad skal aldri påstå større dekning enn operasjonen faktisk hadde (DATABASE_ARCHITECTURE.md §29). Publiseringsgatens G5b leser unionen over funnets kontroller (workflow.covered_check_fields(uuid)), slik at maskinen kan dekke provenansfeltene og mennesket de semantiske, uten at noen av dem overdriver. Fram til migrasjon 005y krevde evidence_verifications_locator_checked_check at enhver bekreftelse førte opp source_locator; kravet er flyttet til gaten, der unionen avgjør.';

-- ----------------------------------------------------------------------------
-- 2. Dekningen: et avvik nullstiller, en uavklart kontroll gjør det ikke
-- ----------------------------------------------------------------------------
create or replace function workflow.covered_check_fields(p_evidence_item_id uuid)
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
    -- En kontroll som fant et avvik, dekker ingenting: konklusjonen motsier
    -- raden. En uavklart kontroll motsier ingenting — den konkluderte bare
    -- ikke om raden som helhet, og feltene den førte opp, gikk den gjennom.
    and ev.outcome in ('verified', 'uncertain')
    and not exists (
      select 1
      from workflow.evidence_verifications later
      where later.evidence_item_id = p_evidence_item_id
        and later.outcome in ('needs_correction', 'rejected')
        and (later.verified_at, later.created_at, later.id)
            > (ev.verified_at, ev.created_at, ev.id)
    );
$$;

comment on function workflow.covered_check_fields(uuid) is
  'Feltene funnets registrerte kontroller til sammen har gått gjennom og funnet i orden. Unionen over kontroller med utfallet verified eller uncertain: en uavklart kontroll motsier ingenting, og feltene den førte opp i checked_fields, gikk den faktisk gjennom — det er nettopp arbeidsdelingen mellom den deterministiske kontrollen, som beviser provenansfeltene, og mennesket, som bedømmer de semantiske. En kontroll som fant et avvik (needs_correction, rejected) nullstiller derimot dekningen fra alt som ligger foran den: en tidligere bekreftelse opphever ikke et senere avvik. At noen faktisk konkluderte, er G5 sin oppgave, ikke denne funksjonens: gaten krever at den *siste* kontrollen er verified. Leses av publiseringsgatens G5b og av reviewerflaten, som viser nøyaktig det samme settet.';

-- ----------------------------------------------------------------------------
-- 3. raw_extraction kreves bare når raden har en
-- ----------------------------------------------------------------------------
create or replace function workflow.required_check_fields(p_evidence_item_id uuid)
  returns workflow.evidence_check_field[]
  language sql
  stable
  set search_path = ''
as $$
  select array_remove(
    array[
      -- Alltid: raden påstår disse uansett hvordan den er fylt ut.
      'source_locator',
      'intervention_arm',
      'outcome',
      'reported_direction',
      -- At de øvrige feltene er ført som rapportert eller ikke rapportert, er
      -- selv en påstand om kilden, og en av de enkleste å ta feil på uten at
      -- noe tall ser galt ut.
      'availability_semantics',
      -- Den rå gjengivelsen er valgfri, og fra migrasjon 005v er den ikke
      -- kontrollgrunnlaget — kildeforankringen er. En rad uten den påstår
      -- ingenting der, og et krav om å kontrollere den ville aldri kunnet
      -- oppfylles.
      case when e.raw_extraction is not null then 'raw_extraction' end,
      case when e.effect_measure is not null then 'effect_measure' end,
      case when e.comparator_kind <> 'none' then 'comparator_arm' end,
      case when e.population_availability = 'reported_value' then 'population' end,
      case when e.sample_size_availability = 'reported_value' then 'sample_size' end,
      case when e.timepoint_availability = 'reported_value' then 'timepoint' end,
      case when e.estimate_availability = 'reported_value' then 'estimate' end,
      case
        when e.confidence_interval_availability = 'reported_value'
        then 'confidence_interval'
      end,
      case when e.limitations_text is not null then 'limitations' end
    ]::workflow.evidence_check_field[],
    null
  )
  from knowledge.evidence_items e
  where e.id = p_evidence_item_id;
$$;

comment on function workflow.required_check_fields(uuid) is
  'Feltene et evidensfunn faktisk påstår noe om, og som til sammen må være kontrollert før funnet kan bære en publisert påstand (publiseringsgatens G5b). Utledet av raden selv framfor av en vedlikeholdt liste: et felt som ikke er rapportert, påstår ingenting og kreves ikke — men at det er ført som ikke rapportert, dekkes av availability_semantics, som alltid kreves. Fra migrasjon 005y gjelder det samme raw_extraction: kolonnen er valgfri, og fra agentkontrakten i 005v er kildeforankringen kontrollgrunnlaget, så en rad uten rå gjengivelse påstår ingenting der. Én kontroll trenger ikke dekke alt; kravet gjelder unionen over funnets kontroller (workflow.covered_check_fields(uuid)), slik at flere verifikatorledd kan dele arbeidet.';

-- ----------------------------------------------------------------------------
-- 4. Maskinbeviset er source_locator alene
-- ----------------------------------------------------------------------------
create or replace function workflow.grounding_machine_proved(p_evidence_item_id uuid)
  returns boolean
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select exists (
    select 1
    from workflow.evidence_verifications ev
    where ev.evidence_item_id = p_evidence_item_id
      -- En agentkjøring. De to sammensatte fremmednøklene på tabellen
      -- garanterer at den er i rollen extraction_verification.
      and ev.agent_run_id is not null
      -- …som gjelder nøyaktig det grunnlaget raden har nå.
      and ev.verified_grounding_digest
          = workflow.evidence_grounding_digest(p_evidence_item_id)
      -- …og som ikke fant et avvik.
      and ev.outcome in ('verified', 'uncertain')
      -- …og som førte opp kildepekeren. Den deterministiske kontrollen fører
      -- den opp bare når representasjonen lot seg reprodusere, forankringen er
      -- komplett, og hvert forankret utdrag ble gjenfunnet ordrett.
      and 'source_locator' = any (ev.checked_fields)
  );
$$;

comment on function workflow.grounding_machine_proved(uuid) is
  'Om det finnes en maskinell ekstraksjonskontroll som gjelder nøyaktig det grunnlaget evidensfunnet har nå, og som beviste venstresiden: at representasjonen lot seg reprodusere, at forankringen er komplett, og at hvert forankret utdrag står ordrett i den. Kravene er en agentkjøring (ev.agent_run_id, som de sammensatte fremmednøklene binder til rollen extraction_verification), et verified_grounding_digest lik det gjeldende, et utfall som ikke er et avvik, og source_locator i checked_fields. Det siste er beviset uttrykt i et vokabular som allerede finnes: src/agents/extraction-checks.ts fører opp source_locator bare under nøyaktig de tre vilkårene. Fram til migrasjon 005y krevdes også raw_extraction, som gjorde den valgfrie legacy-kolonnen til en skjult forutsetning i den nye stien — en agentekstraksjon uten source_quote kunne da aldri bli bevist. Leses av skriveveien workflow.record_evidence_verification, som avviser en menneskelig bekreftelse uten den, og av grunnlagsflaten, som stopper kontrolløkten før feltskuffene når beviset mangler (ANTIDEP_CONSTITUTION.md §11, §17).';
