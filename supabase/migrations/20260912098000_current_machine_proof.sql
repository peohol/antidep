-- ============================================================================
-- Migrasjon 005ø — beviset er det gjeldende, og kjøringens kildeversjon er
--                  like uforanderlig som resten av premissene
--
-- To hull som begge lot en tidligere tilstand overleve en senere.
--
-- ----------------------------------------------------------------------------
-- 1. Et gammelt maskinbevis overlevde et nyere avvik
--
-- workflow.grounding_machine_proved(uuid) spurte om det *fantes* en maskinell
-- kontroll som hadde bevist venstresiden. Den spurte ikke om noen senere hadde
-- underkjent den. En kontroll som fant et avvik på det samme grunnlaget,
-- nullstilte derfor ikke beviset: den menneskelige feltkontrollen åpnet
-- fortsatt, og lagringsforutsetningen fra 005x var fortsatt oppfylt.
--
-- workflow.covered_check_fields(uuid) håndterte dette riktig allerede
-- (migrasjon 005y): et avvik nullstiller dekningen fra alt som ligger foran
-- det. Beviset får nå den samme regelen, ordrett, og av samme grunn — en
-- tidligere bekreftelse opphever ikke et senere avvik.
--
-- Avviket teller uansett hvem som fant det. En menneskelig kontrollør som
-- registrerer `needs_correction`, har funnet noe galt med den samme raden, og
-- et maskinbevis som overlevde det, ville sagt at venstresiden fortsatt var i
-- orden.
--
-- ----------------------------------------------------------------------------
-- 2. input_source_version_id var ikke vernet av freeze-triggeren
--
-- provenance.freeze_agent_run() verner premissene en kjøring ble åpnet med:
-- identitet, aktør, rolle, leverandør, modell, versjonene, `input_manifest` og
-- tidspunktene. Kolonnen fra 005z kom ikke med i listen, og en UPDATE som
-- samtidig gjorde en gyldig statusovergang, kunne derfor skrive om hvilken
-- kildeversjon kjøringen påsto å ha lest.
--
-- For en kjøring som allerede har produsert et evidensfunn, ville den
-- sammensatte fremmednøkkelen (005z) ofte stoppet det indirekte. En kjøring som
-- endte `failed` eller `aborted` uten å produsere noe, har ingen slik
-- referanse, og historikken kunne skrives om i stillhet.
--
-- Kolonnen er et premiss på linje med de andre og føres derfor opp der.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §8, §11, §20
--   docs/DATABASE_ARCHITECTURE.md §33, §34, §57
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Beviset er det gjeldende
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
      -- …og som ikke selv fant et avvik.
      and ev.outcome in ('verified', 'uncertain')
      -- …og som førte opp kildepekeren, som er beviset.
      and 'source_locator' = any (ev.checked_fields)
      -- …og som ingen har underkjent siden. Samme regel som
      -- workflow.covered_check_fields(uuid), og av samme grunn: en tidligere
      -- bekreftelse opphever ikke et senere avvik.
      and not exists (
        select 1
        from workflow.evidence_verifications later
        where later.evidence_item_id = p_evidence_item_id
          and later.outcome in ('needs_correction', 'rejected')
          and (later.verified_at, later.created_at, later.id)
              > (ev.verified_at, ev.created_at, ev.id)
      )
  );
$$;

comment on function workflow.grounding_machine_proved(uuid) is
  'Om det finnes et *gjeldende* maskinbevis for venstresiden: en maskinell ekstraksjonskontroll som gjelder nøyaktig det grunnlaget evidensfunnet har nå, som beviste at representasjonen lot seg reprodusere, at forankringen er komplett og at hvert forankret utdrag står ordrett i den — og som ingen har underkjent siden. Kravene er en agentkjøring (ev.agent_run_id, som de sammensatte fremmednøklene binder til rollen extraction_verification), et verified_grounding_digest lik det gjeldende, et utfall som ikke er et avvik, source_locator i checked_fields, og at ingen senere kontroll på det samme funnet endte i needs_correction eller rejected. Det siste kom til i migrasjon 005ø: uten det overlevde et gammelt bevis et nyere avvik, og den menneskelige feltkontrollen åpnet fortsatt. Regelen er ordrett den samme som workflow.covered_check_fields(uuid) bruker, og av samme grunn — en tidligere bekreftelse opphever ikke et senere avvik. source_locator er beviset uttrykt i et vokabular som allerede finnes: src/agents/extraction-checks.ts fører opp feltet bare under nøyaktig de tre vilkårene. Leses av skriveveien workflow.record_evidence_verification, som avviser en menneskelig bekreftelse uten den, og av grunnlagsflaten, som stopper kontrolløkten før feltskuffene når beviset mangler (ANTIDEP_CONSTITUTION.md §11, §17).';

-- ----------------------------------------------------------------------------
-- 2. Kildeversjonen er et premiss, og premisser er uforanderlige
-- ----------------------------------------------------------------------------
create or replace function provenance.freeze_agent_run()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Agentkjøring %L kan ikke slettes.', old.id),
      hint = 'En kjøring dokumenterer hva som faktisk ble kjørt med hvilke premisser, og er grunnlaget for at et KI-produsert objekt kan spores bakover (DATABASE_ARCHITECTURE.md §34).';
  end if;

  if new.agent_identity_id is distinct from old.agent_identity_id
    or new.actor_id is distinct from old.actor_id
    or new.agent_role is distinct from old.agent_role
    or new.provider is distinct from old.provider
    or new.model is distinct from old.model
    or new.model_version is distinct from old.model_version
    or new.prompt_template_version is distinct from old.prompt_template_version
    or new.pipeline_version is distinct from old.pipeline_version
    or new.input_manifest is distinct from old.input_manifest
    -- Kildeversjonen kjøringen ble åpnet for, er et premiss på linje med de
    -- andre (migrasjon 005z). Uten den her kunne en UPDATE som samtidig gjorde
    -- en gyldig statusovergang, skrive om hvilken utgave kjøringen påsto å ha
    -- lest — og for en kjøring uten produsert evidensfunn finnes det ingen
    -- fremmednøkkel som ville stoppet det.
    or new.input_source_version_id is distinct from old.input_source_version_id
    or new.started_at is distinct from old.started_at
    or new.created_at is distinct from old.created_at
  then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Premissene for agentkjøring %L er uforanderlige og kan ikke endres.', old.id
      ),
      hint = 'Registrer en ny kjøring dersom operasjonen skal kjøres om igjen med andre premisser. En kjøring som kunne omskrives i ettertid, ville ikke dokumentert noe.';
  end if;

  -- Én overgang, én vei. En kjøring som kunne gjenåpnes, ville kunnet
  -- produsere objekter etter at den var rapportert ferdig.
  if old.status <> 'running' then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Agentkjøring %L er avsluttet med statusen %L og kan ikke endres.', old.id, old.status
      ),
      hint = 'En avsluttet kjøring er endelig. Registrer en ny kjøring for et nytt forsøk.';
  end if;

  return new;
end;
$$;
