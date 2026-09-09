-- ============================================================================
-- Migrasjon 005x — maskinbeviset blir en forutsetning for den menneskelige
--                  bekreftelsen
--
-- ----------------------------------------------------------------------------
-- Maskinbeviset var implementert, men ikke påkrevd
--
-- Arbeidsdelingen er at maskinen beviser venstresiden — at hvert forankret
-- utdrag står ordrett i nettopp den kildeversjonen raden peker på — og at
-- mennesket vurderer om den strukturerte verdien følger av utdraget. Uten et
-- krav kunne en reviewer åpne et funn der ingen slik kontroll var kjørt, svare
-- «Ja» på alt og registrere en `verified` menneskelig kontroll. Da hadde ingen
-- prøvd venstresiden, og bekreftelsen hvilte på at utdraget så troverdig ut.
--
-- Kravet håndheves i databasen, ikke bare i flaten:
-- workflow.record_evidence_verification(...) avviser en menneskelig
-- bekreftelse med mindre
--
--   a) hvert semantisk felt raden påstår noe om, har kildeforankring, og
--   b) det finnes en maskinell ekstraksjonskontroll som gjelder *nøyaktig
--      denne* tilstanden av raden, og som førte opp både raw_extraction og
--      source_locator som kontrollert uten å finne et avvik.
--
-- (b) forutsetter at en verifikasjonsrad vet hvilken tilstand den gjelder.
-- Kolonnen `verified_grounding_digest` er derfor lagt til, og settes av
-- skriveveien selv — under den radlåsen skriveveien allerede tar. Den er ikke
-- en parameter: en verdi kalleren kunne valgt, ville vært nøyaktig den
-- påstanden kolonnen finnes for å binde.
--
-- Avtrykket er *ikke* workflow.evidence_extraction_digest(uuid). Det dekker
-- også settet av verifikasjoner, med vilje: en kontrollør skal se at noen
-- andre har registrert en kontroll mens hen arbeidet. Men da endrer avtrykket
-- seg av at kontrollen selv skrives, og et maskinbevis ville vært foreldet i
-- samme øyeblikk det ble skrevet. workflow.evidence_grounding_digest(uuid)
-- dekker derfor nøyaktig det beviset hviler på: ekstraksjonen, kildeversjonen
-- og settet av forankringer. Endres noe av det, må maskinen kjøre på nytt;
-- at en annen kontroll er registrert i mellomtiden, gjør ikke beviset galt.
--
-- Den deterministiske kontrollen fører opp `source_locator` bare når
-- representasjonen er reprodusert *og* hvert forankret utdrag er gjenfunnet
-- ordrett (src/agents/extraction-checks.ts). Feltet er derfor det maskinelle
-- beviset, uttrykt i et vokabular som allerede finnes.
--
-- ----------------------------------------------------------------------------
-- Hva som IKKE endres
--
-- Ingen CHECK er fjernet eller myket opp, og ingen grant er utvidet.
-- Publiseringsgatens G5b leser fortsatt required_check_fields(uuid), og
-- covered_check_fields(uuid) er urørt. Kravet er nytt og strengere: en
-- menneskelig bekreftelse som gikk gjennom før, kan bli avvist nå.
--
-- Maskinelle kontroller er unntatt fra (b), fordi de *er* beviset; et krav om
-- at beviset skal ha et bevis, ville vært sirkulært. De er ikke unntatt fra
-- (a): en maskinell bekreftelse av en rad uten forankring ville påstått at det
-- fantes en venstreside å kontrollere.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §6, §8, §10, §11, §17
--   docs/DATABASE_ARCHITECTURE.md §29, §43, §50, §57
--   docs/EVIDENCE_PIPELINE.md §13, §21, §25
--   docs/MVP_IMPLEMENTATION_PLAN.md §15, §49
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. En verifikasjonsrad vet hvilken tilstand den gjelder
-- ----------------------------------------------------------------------------
-- Avtrykket av nøyaktig det en ekstraksjonskontroll faktisk kontrollerer:
-- ekstraksjonen, kildeversjonen den ble lest av, og settet av forankringer.
-- Settet av verifikasjoner er *ikke* med, til forskjell fra
-- workflow.evidence_extraction_digest(uuid): det avtrykket skal endre seg når
-- noen andre registrerer en kontroll, og et bevis som ble foreldet av at det
-- selv ble skrevet, hadde vært ubrukelig.
create function workflow.evidence_grounding_digest(p_evidence_item_id uuid)
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
      sv.representation::text,
      (
        select string_agg(g.id::text, ',' order by g.id::text)
        from knowledge.evidence_field_groundings g
        where g.evidence_item_id = e.id
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

comment on function workflow.evidence_grounding_digest(uuid) is
  'Avtrykket av nøyaktig det en ekstraksjonskontroll kontrollerer: evidensfunnets eget fingeravtrykk, kildens status, kildeversjonens id, fingeravtrykk, henteadresse og representasjonstype, og settet av kildeforankringer. Settet av verifikasjoner er ikke med, til forskjell fra workflow.evidence_extraction_digest(uuid), som dekker det med vilje slik at en kontrollør ser at noen andre har registrert en kontroll. Et maskinbevis må overleve at andre kontroller registreres, men ikke at grunnlaget endres — derfor dette snevrere avtrykket. Lengdeprefiks per ledd, som i alle Antideps avtrykk, slik at to felter ikke kan bytte innhold uten at avtrykket endrer seg.';

revoke execute on function workflow.evidence_grounding_digest(uuid) from public;

alter table workflow.evidence_verifications
  add column verified_grounding_digest text;

comment on column workflow.evidence_verifications.verified_grounding_digest is
  'Avtrykket workflow.evidence_grounding_digest(uuid) ga for evidensfunnet i det øyeblikket verifikasjonen ble skrevet, under radlåsen skriveveien tar. NULL betyr en rad fra før migrasjon 005x, aldri et ukjent avtrykk. Ikke en parameter: en verdi kalleren kunne valgt, ville vært nøyaktig den påstanden kolonnen finnes for å binde. Gjør det mulig å spørre om en kontroll gjelder det grunnlaget raden har nå, framfor et tidligere.';

-- ----------------------------------------------------------------------------
-- 2. Maskinbeviset, som et spørsmål databasen kan svare på
-- ----------------------------------------------------------------------------
create function workflow.grounding_machine_proved(p_evidence_item_id uuid)
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
      -- …som gjelder nøyaktig den tilstanden raden er i nå.
      and ev.verified_grounding_digest
          = workflow.evidence_grounding_digest(p_evidence_item_id)
      -- …og som ikke fant et avvik.
      and ev.outcome in ('verified', 'uncertain')
      -- …og som førte opp begge provenansfeltene. Den deterministiske
      -- kontrollen fører opp source_locator bare når representasjonen er
      -- reprodusert og hvert forankret utdrag er gjenfunnet ordrett.
      and 'raw_extraction' = any (ev.checked_fields)
      and 'source_locator' = any (ev.checked_fields)
  );
$$;

comment on function workflow.grounding_machine_proved(uuid) is
  'Om det finnes en maskinell ekstraksjonskontroll som gjelder nøyaktig den tilstanden evidensfunnet er i nå, og som beviste venstresiden: at representasjonen lot seg reprodusere og at hvert forankret utdrag står ordrett i den. Kravene er en agentkjøring (ev.agent_run_id, som de sammensatte fremmednøklene binder til rollen extraction_verification), et verified_grounding_digest lik det gjeldende, et utfall som ikke er et avvik, og både raw_extraction og source_locator i checked_fields. Det siste er beviset uttrykt i et vokabular som allerede finnes: src/agents/extraction-checks.ts fører opp source_locator bare når representasjonen er reprodusert og hvert forankret utdrag er gjenfunnet ordrett. Leses av skriveveien workflow.record_evidence_verification, som avviser en menneskelig bekreftelse uten den (ANTIDEP_CONSTITUTION.md §11, §17).';

revoke execute on function workflow.grounding_machine_proved(uuid) from public;

-- ----------------------------------------------------------------------------
-- 3. Skriveveien setter avtrykket og håndhever forutsetningen
--
-- Fremover-skrivende med `create or replace function`: signaturen er uendret,
-- og begge inngangspunktene — api.register_extraction_verification (agenten)
-- og api.register_human_extraction_verification (mennesket) — kaller den
-- samme funksjonen som før.
-- ----------------------------------------------------------------------------
create or replace function workflow.record_evidence_verification(
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
  v_missing text;
begin
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

  begin
    v_checked_fields := p_checked_fields::workflow.evidence_check_field[];
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Ett eller flere kontrollerte felter er ikke et kjent felt.',
        hint = 'Gyldige felter er kolonnene på knowledge.evidence_items som workflow.evidence_check_field lister (DATABASE_ARCHITECTURE.md §29).';
  end;

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
    agent_run_id, verified_grounding_digest
  )
  values (
    p_evidence_item_id, v_creator_actor_id, p_verifier_actor_id,
    v_outcome, v_source_access, v_checked_fields, p_findings, p_rationale, now(),
    p_agent_run_id,
    -- Avtrykket leses her, under radlåsen over: da er det nøyaktig det
    -- grunnlaget verifikasjonen faktisk gjelder.
    workflow.evidence_grounding_digest(p_evidence_item_id)
  )
  returning id into v_verification_id;

  -- ---------------------------------------------------------------------
  -- Forutsetningene for en bekreftelse, prøvd etter innsettingen
  --
  -- Etter, ikke før: tabellens egne CHECK-er er fasiten for hva en rad kan
  -- være, og de skal få avvise først. En kontroll her oppe ville skygget for
  -- dem, slik at en registrering med feil kildetilgang fikk en melding om
  -- forankring framfor om kildetilgang. Unntaket ruller transaksjonen tilbake,
  -- så en avvist registrering etterlater ingenting.
  -- ---------------------------------------------------------------------
  if v_outcome = 'verified' then
    -- 1. Det må finnes en venstreside å ha kontrollert. Gjelder begge
    --    verifikatorledd: en maskinell bekreftelse av en uforankret rad ville
    --    påstått det samme som en menneskelig.
    select string_agg(f.field::text, ', ')
      into v_missing
    from unnest(workflow.semantic_check_fields(p_evidence_item_id)) as f(field)
    where f.field <> all (workflow.grounded_check_fields(p_evidence_item_id));

    if v_missing is not null then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format(
          'Evidensfunnet mangler kildeforankring for %s, og kan ikke bekreftes.', v_missing),
        hint = 'En bekreftelse forutsetter at hvert felt raden påstår noe om, har sitt ordrette kildeutdrag å bli kontrollert mot (migrasjon 005u). Funnet må ekstraheres på nytt gjennom agentveien api.register_agent_extraction; ingen skrivevei kan forankre en rad i ettertid.';
    end if;

    -- 2. …og maskinen må ha bevist den. Maskinelle kontroller er unntatt: de
    --    er beviset, og et krav om at beviset skal ha et bevis ville vært
    --    sirkulært.
    if p_agent_run_id is null
       and not workflow.grounding_machine_proved(p_evidence_item_id) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Ingen maskinell kontroll har bevist at kildeutdragene står ordrett i denne utgaven av kilden.',
        hint = 'Arbeidsdelingen er at maskinen beviser at utdragene kommer fra kilden, og at mennesket vurderer om verdien følger av utdraget (ANTIDEP_CONSTITUTION.md §11, §17). Kjør ekstraksjonsverifikatoren mot funnet først; den fører opp raw_extraction og source_locator som kontrollert når representasjonen lot seg reprodusere og hvert forankret utdrag ble gjenfunnet ordrett. Er grunnlaget endret etter at kontrollen ble kjørt, må den kjøres på nytt.';
    end if;
  end if;

  return v_verification_id;
end;
$$;
