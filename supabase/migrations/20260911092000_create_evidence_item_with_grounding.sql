-- ============================================================================
-- Migrasjon 007f — ekstraksjonen produserer sin egen kildeforankring
--
-- Migrasjon 005u innførte knowledge.evidence_field_groundings. Denne
-- migrasjonen gir den den eneste skriveveien den skal ha: den samme
-- transaksjonen som registrerer evidensfunnet.
--
-- Hvorfor ikke et eget endepunkt: to kall er to transaksjoner, og mellom dem
-- ville det finnes et evidensfunn uten forankring som en kontrollør kunne rukket
-- å hente fram. Forankringen er ikke et tillegg til ekstraksjonen; den er en del
-- av den (ANTIDEP_CONSTITUTION.md §8), og den skal derfor bli til samtidig.
--
-- ----------------------------------------------------------------------------
-- Hvorfor funksjonen slippes og lages på nytt framfor å få en overload
--
-- En ny parameter med standardverdi lager en *ny* funksjon ved siden av den
-- gamle. PostgREST ville da hatt to kandidater for det samme navnet, og hvilken
-- som ble valgt, ville avhengt av hvilke argumenter klienten tilfeldigvis sendte
-- — altså av klienten og ikke av kontrakten. Den gamle signaturen slippes derfor
-- eksplisitt, og den nye får de samme rettighetene.
--
-- Fremover-skrivende: ingen merget migrasjon er endret. 20260904092000 har
-- allerede kjørt i det hostede prosjektet (§74.32), og DROP + CREATE er den
-- eneste operasjonen som kan bytte signatur uten å etterlate to.
--
-- ----------------------------------------------------------------------------
-- Hva som IKKE endres
--
-- Autorisasjonen er den samme funksjonen (knowledge.assert_editor_authorized),
-- extraction_method er fortsatt hardkodet, content_hash eies fortsatt av
-- databasen, raw_extraction bygges fortsatt av p_source_quote under den samme
-- ene nøkkelen, og dublettoversettelsen er ordrett den samme. Ingen constraint,
-- trigger, policy eller grant er fjernet eller svekket.
--
-- Forankringen er valgfri på databasenivå, og det er et bevisst valg: et
-- evidensfunn uten forankring er nettopp den tilstanden alle funn registrert før
-- 005u er i, og den skal kunne beskrives framfor å gjøres uuttrykkelig.
-- Kontrollflaten viser fraværet som fravær. Det ekstraksjonsflaten krever av seg
-- selv, er en flateregel og ikke en databaseregel.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §4, §6, §8, §11, §12, §20
--   docs/DATABASE_ARCHITECTURE.md §29, §35, §43, §50, §57, §59
--   docs/MVP_IMPLEMENTATION_PLAN.md §15, §29, §74.32
-- ============================================================================

drop function api.create_evidence_item(
  uuid, text, text, text, text, uuid, text, uuid, text, text, text, text, text, text,
  uuid, uuid, integer, text, uuid, text, text, text, text, numeric, text, numeric,
  numeric, numeric, text, text
);

create function api.create_evidence_item(
  -- Påkrevd: nøyaktig de kolonnene knowledge.evidence_items krever.
  p_source_id uuid,
  p_design_code text,
  p_population_availability text,
  p_population_detail text,
  p_sample_size_availability text,
  p_intervention_drug_id uuid,
  p_comparator_kind text,
  p_outcome_concept_id uuid,
  p_outcome_detail text,
  p_timepoint_availability text,
  p_reported_direction text,
  p_estimate_availability text,
  p_confidence_interval_availability text,
  p_source_locator text,
  -- Valgfritt. Utelatt betyr NULL, og NULL betyr det den ledsagende
  -- `*_availability`-kolonnen sier at det betyr — aldri null og aldri
  -- «ingen effekt» (ANTIDEP_CONSTITUTION.md §6, DATABASE_ARCHITECTURE.md §19.1).
  p_source_version_id uuid default null,
  p_population_id uuid default null,
  p_sample_size integer default null,
  p_intervention_detail text default null,
  p_comparator_drug_id uuid default null,
  p_comparator_detail text default null,
  p_timepoint_min text default null,
  p_timepoint_max text default null,
  p_effect_measure text default null,
  p_estimate numeric default null,
  p_estimate_unit text default null,
  p_ci_lower numeric default null,
  p_ci_upper numeric default null,
  p_ci_level_percent numeric default null,
  p_limitations_text text default null,
  p_source_quote text default null,
  -- Kildeforankringen per kontrollfelt (migrasjon 005u). En jsonb-liste der
  -- hvert element har check_field, source_excerpt, source_locator og
  -- justification. NULL og tom liste er det samme: ingen forankring registrert.
  p_field_groundings jsonb default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_evidence_item_id uuid;
  v_duplicate_field text;
begin
  -- Endepunktet er innholdsområdet et evidensfunn hører under, og det er derfor
  -- det en avgrenset editor-tildeling kontrolleres mot.
  v_actor_id := knowledge.assert_editor_authorized(p_outcome_concept_id);

  -- Forankringen kontrolleres på form før noe skrives, slik at en feil form gir
  -- en setning som sier hva som er galt framfor en fremmednøkkel- eller
  -- casting-feil lenger ned.
  if p_field_groundings is not null
     and jsonb_typeof(p_field_groundings) is distinct from 'array' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'p_field_groundings må være en jsonb-liste av kildeforankringer.',
      hint = 'Hvert element skal ha check_field, source_excerpt, source_locator og justification (migrasjon 005u).';
  end if;

  -- To forankringer av samme felt ville vært to påstander om hvilket utdrag
  -- verdien hviler på. Unikheten er tabellens egen; oversettelsen her navngir
  -- feltet framfor constrainten.
  select g.value ->> 'check_field'
    into v_duplicate_field
  from jsonb_array_elements(coalesce(p_field_groundings, '[]'::jsonb)) as g
  group by g.value ->> 'check_field'
  having count(*) > 1
  limit 1;

  if v_duplicate_field is not null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Feltet %L er forankret mer enn én gang.', v_duplicate_field),
      hint = 'Ett felt har én forankring: det minste ordrette utdraget som er tilstrekkelig for å bedømme nettopp det feltet. Er to utdrag nødvendige, hører de til ett utdrag med begge setningene.';
  end if;

  insert into knowledge.evidence_items (
    source_id, source_version_id, design_code,
    population_id, population_availability, population_detail,
    sample_size, sample_size_availability,
    intervention_drug_id, intervention_detail,
    comparator_kind, comparator_drug_id, comparator_detail,
    outcome_concept_id, outcome_detail,
    timepoint_min, timepoint_max, timepoint_availability,
    reported_direction, effect_measure, estimate, estimate_unit, estimate_availability,
    ci_lower, ci_upper, ci_level_percent, confidence_interval_availability,
    limitations_text, source_locator, extraction_method, raw_extraction,
    created_by_actor_id
  )
  values (
    p_source_id,
    p_source_version_id,
    p_design_code::knowledge.study_design,
    p_population_id,
    p_population_availability::knowledge.value_availability,
    p_population_detail,
    p_sample_size,
    p_sample_size_availability::knowledge.value_availability,
    p_intervention_drug_id,
    p_intervention_detail,
    p_comparator_kind::knowledge.comparator_kind,
    p_comparator_drug_id,
    p_comparator_detail,
    p_outcome_concept_id,
    p_outcome_detail,
    p_timepoint_min::interval,
    p_timepoint_max::interval,
    p_timepoint_availability::knowledge.value_availability,
    p_reported_direction::knowledge.effect_direction,
    p_effect_measure::knowledge.effect_measure,
    p_estimate,
    p_estimate_unit::knowledge.estimate_unit,
    p_estimate_availability::knowledge.value_availability,
    p_ci_lower,
    p_ci_upper,
    p_ci_level_percent,
    p_confidence_interval_availability::knowledge.value_availability,
    p_limitations_text,
    p_source_locator,
    'manual'::knowledge.extraction_method,
    -- Et tomt sitatfelt er et fravær, ikke et tomt sitat. Ingen validering av
    -- innholdet: et sitat er ordrett tekst fra kilden, og det er ikke noe her
    -- som kan avgjøre om det er riktig gjengitt — det er verifikatorens
    -- oppgave (ANTIDEP_CONSTITUTION.md §11).
    case
      when nullif(btrim(coalesce(p_source_quote, '')), '') is null then null
      else jsonb_build_object('sitat', btrim(p_source_quote))
    end,
    v_actor_id
  )
  returning id into v_evidence_item_id;

  -- Forankringen, i samme transaksjon. Aktøren er den samme som laget funnet,
  -- og den sammensatte fremmednøkkelen på tabellen håndhever nettopp det.
  begin
    insert into knowledge.evidence_field_groundings (
      evidence_item_id, created_by_actor_id, check_field,
      source_excerpt, source_locator, justification
    )
    select
      v_evidence_item_id,
      v_actor_id,
      (g.value ->> 'check_field')::workflow.evidence_check_field,
      btrim(g.value ->> 'source_excerpt'),
      btrim(g.value ->> 'source_locator'),
      btrim(g.value ->> 'justification')
    from jsonb_array_elements(coalesce(p_field_groundings, '[]'::jsonb)) as g;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'En av kildeforankringene viser til et felt som ikke finnes.',
        hint = 'Gyldige felter er de kolonnene på knowledge.evidence_items som workflow.evidence_check_field lister (DATABASE_ARCHITECTURE.md §29).';
    when not_null_violation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'En av kildeforankringene mangler et påkrevd felt.',
        hint = 'Hvert element skal ha check_field, source_excerpt, source_locator og justification. Et ordrett utdrag uten kildepeker er ikke etterprøvbart, og en peker uten utdrag sier ikke hva som står der.';
  end;

  return v_evidence_item_id;
exception
  -- Den eneste oversatte avvisningen. content_hash dekker hele radens faglige
  -- innhold, så en dublett er nøyaktig samme registrering en gang til — og en
  -- korreksjon av et hvilket som helst felt gir en ny hash og slipper inn ved
  -- siden av den gamle (migrasjon 003, 006a).
  when unique_violation then
    raise exception using
      errcode = 'unique_violation',
      message = 'Nøyaktig det samme evidensfunnet er allerede registrert.',
      hint = 'Et evidensfunn identifiseres av hele sitt faglige innhold. Er dette en korreksjon, skal minst ett felt være endret — da registreres den som et nytt funn ved siden av det gamle, og det gamle består (knowledge.evidence_items er append-only).';
end;
$$;

comment on function api.create_evidence_item(
  uuid, text, text, text, text, uuid, text, uuid, text, text, text, text, text, text,
  uuid, uuid, integer, text, uuid, text, text, text, text, numeric, text, numeric,
  numeric, numeric, text, text, jsonb
) is
  'Den kontrollerte skriveveien for å registrere et EvidenceItem med sin egen kildeforankring (DATABASE_ARCHITECTURE.md §43, MVP_IMPLEMENTATION_PLAN.md §15, §29). Kontrollerer at kalleren har en registrert, aktiv aktør og en gyldig editor-rolle for endepunktet funnet gjelder (knowledge.assert_editor_authorized(uuid)), setter inn raden attribuert til kallerens egen aktør, skriver kildeforankringen per kontrollfelt i den samme transaksjonen, og returnerer funnets id. Erstatter signaturen fra migrasjon 007e, som er sluppet: en overload ville latt klienten og ikke kontrakten avgjøre hvilken funksjon PostgREST kaller. Auditradene skrives av triggerne på tabellene, i samme transaksjon. SECURITY DEFINER fordi knowledge.evidence_items, knowledge.evidence_field_groundings, workflow.user_roles og provenance.actors har RLS med default deny for authenticated; tomt search_path, og kalleren valideres på funksjonens eget kall (§50). extraction_method er ikke parameter og er alltid manual, content_hash eies av databasen, og raw_extraction bygges av p_source_quote. p_field_groundings er en jsonb-liste der hvert element har check_field, source_excerpt, source_locator og justification; NULL og tom liste betyr at ingen forankring er registrert, som er tilstanden alle funn registrert før migrasjon 005u er i. Ingen feltvalidering er duplisert her: constraintene på de to tabellene er fasiten, og deres avvisninger propageres uendret. Unntakene er dubletten og de tre formfeilene i forankringslisten, som oversettes til setninger på norsk uten at noen regel endres.';

revoke execute on function api.create_evidence_item(
  uuid, text, text, text, text, uuid, text, uuid, text, text, text, text, text, text,
  uuid, uuid, integer, text, uuid, text, text, text, text, numeric, text, numeric,
  numeric, numeric, text, text, jsonb
) from public;
grant execute on function api.create_evidence_item(
  uuid, text, text, text, text, uuid, text, uuid, text, text, text, text, text, text,
  uuid, uuid, integer, text, uuid, text, text, text, text, numeric, text, numeric,
  numeric, numeric, text, text, jsonb
) to authenticated;

-- ----------------------------------------------------------------------------
-- Kommentaren som navngir signaturen, oppdatert
--
-- workflow.ensure_editor_role_grant() sin kommentar navngir de to skriveveiene
-- editor-rollen åpner, med full signatur. Den ene av dem har nettopp byttet
-- signatur, og en kommentar som navngir en funksjon som ikke finnes, er en
-- kommentar som lyver — det er nøyaktig det vakten i
-- supabase/tests/280_content_hash_serialization_test.sql finnes for å fange.
--
-- Kommentaren erstattes derfor her, framfor å bli rettet i migrasjon 006c, som
-- allerede er kjørt i det hostede prosjektet (§74.32). Innholdet er ordrett det
-- samme; bare signaturen er den nye.
-- ----------------------------------------------------------------------------
comment on function workflow.ensure_editor_role_grant() is
  'Idempotent tildeling av `editor`-rollen til den navngitte kvalifiserte redaktørens brukerkonto, altså retten til å registrere kilder og evidens som forslag (CONTENT_GOVERNANCE.md §8). Åpner de kontrollerte skriveveiene api.create_source(text, text, text, text, text, text, text, date, text) fra migrasjon 007c og api.create_evidence_item(uuid, text, text, text, text, uuid, text, uuid, text, text, text, text, text, text, uuid, uuid, integer, text, uuid, text, text, text, text, numeric, text, numeric, numeric, numeric, text, text, jsonb) fra migrasjon 007e og 007f, som begge krever en gyldig editor-tildeling gjennom knowledge.assert_editor_authorized(uuid). Gir verken faglig godkjenningsrett (reviewer) eller publiseringsrett (publisher): de tre er forskjellige rettigheter med hver sin rad. Forutsetter at aktørraden er knyttet til kontoen av workflow.ensure_named_editor_authorization() (migrasjon 005b) og setter ikke koblingen selv. Returnerer account_missing (ingen rad i auth.users), authorized (tildelingen ble skrevet), already_authorized (en tildeling er gyldig nå), role_not_yet_valid (en tildeling begynner å gjelde senere) eller role_ended (en tildeling er avsluttet). Bare authorized skriver noe. Gyldighet måles med statement_timestamp() fordi predikatet avgjør noe (MVP_IMPLEMENTATION_PLAN.md §74.6). En avsluttet tildeling gjeninnføres aldri: en tilbakekalling som en migrasjonskjøring omgjør, er ingen tilbakekalling (DATABASE_ARCHITECTURE.md §46). Konto og aktørnøkkel er konstanter i kroppen, og rollen er det også: funksjonen kan bare gjøre denne ene tildelingen, aldri en vilkårlig.';
