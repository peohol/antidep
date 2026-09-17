-- ============================================================================
-- Migrasjon 013i — det strukturerte svaret
--
-- Standarden krever at hvert kunnskapsbehov får et svar med sin egen identitet,
-- avgrensning, kunnskapstype, dokumentasjon, usikkerhet, aktualitet og
-- endringshistorikk (MONOGRAPH_STANDARD.md §2). Denne migrasjonen er det
-- svaret.
--
-- ----------------------------------------------------------------------------
-- Hvorfor kunnskapstypene ikke får én felles kontrakt
--
-- Fordi de ikke kontrolleres likt. Et forskningsfunn hviler på en påstand som
-- har gått gjennom hele evidenskjeden — ekstraksjon, kildestøttekontroll og
-- evidensvurdering — og svaret peker på nøyaktig den påstandsrevisjonen. En
-- regulatorisk opplysning eller en preparatdata hviler på et ordrett utdrag fra
-- et registrert myndighetsdokument, med en lokalisering og et tidspunkt, og den
-- skal ikke ha en GRADE-vurdering: en oppdiktet evidenssikkerhet på en
-- preparatstyrke ville vært en påstand ingen har gjort. Et attribuert råd må i
-- tillegg si hvem som anbefaler det og når. Et avledet svar har ingen egen
-- kilde i det hele tatt — det er satt sammen av andre kontrollerte svar, og
-- skal ikke kunne legge til en ny opplysning.
--
-- Kontrakten er derfor uttømmende per kunnskapstype, og en type uten en
-- kontrakt stopper skrivingen framfor å havne stille i en som ikke passer.
--
-- ----------------------------------------------------------------------------
-- Hvorfor kontrollen kjører i skriveveien
--
-- Fordi et svar som ikke kan kontrolleres, ikke skal bli stående som et svar.
-- Kontrollen er Antideps egen deterministiske kode — den leser det ordrette
-- utdraget mot den registrerte representasjonen, ser etter lokaliseringen og
-- tidspunktet, og kontrollerer at kildeversjonen faktisk er godkjent for
-- nettopp dette behovet. Den er ikke en modellvurdering, og den føres opp som
-- en egen rad med hvilke felter som ble kontrollert, slik at dekningsvisningen
-- kan vise kontrollen som det den er (ANTIDEP_CONSTITUTION.md regel 3).
--
-- ----------------------------------------------------------------------------
-- Hvorfor et forskningssvar ikke får en egen agent
--
-- Fordi påstandsrevisjonen allerede *er* det kontrollerte svaret. En agent som
-- skrev det om igjen, ville laget en ny formulering ingen hadde kontrollert, og
-- det ville vært en ny monografivei forbi kontrollene. Overgangen fra en
-- registrert evidensvurdering til et monografisvar er derfor deterministisk:
-- den binder svaret til nøyaktig den påstandsrevisjonen som ble vurdert.
--
-- Styrende dokumenter: docs/MONOGRAPH_STANDARD.md §2, docs/EVIDENCE_PIPELINE.md,
-- docs/KNOWLEDGE_MODEL.md, docs/SOURCE_POLICY.md §5, §6,
-- docs/ANTIDEP_CONSTITUTION.md regel 2, 3, 4, 5.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Kunnskapstypene standarden navngir
-- ----------------------------------------------------------------------------

create type knowledge.monograph_knowledge_type as enum (
  'regulatory_fact',
  'product_data',
  'research_finding',
  'attributed_advice',
  'reasoning',
  'derived'
);

revoke usage on type knowledge.monograph_knowledge_type from public;

comment on type knowledge.monograph_knowledge_type is
  'Kunnskapstypene monografistandarden navngir (MONOGRAPH_STANDARD.md §2): regulatory_fact (regulatorisk opplysning), product_data (preparatdata), research_finding (forskningsfunn eller -syntese), attributed_advice (attribuert retningslinjeråd), reasoning (eksplisitt farmakologisk eller redaksjonelt resonnement) og derived (sammensatt av allerede kontrollerte svar, uten ny klinisk kunnskap). Typene finnes som egne verdier fordi de ikke kontrolleres likt: en preparatstyrke og et klinisk estimat har ingen felles kontrakt, og en felles kontrakt ville enten krevd en evidensvurdering av en styrke eller sluppet et estimat gjennom uten en.';

create type knowledge.monograph_answer_origin as enum ('agent', 'human', 'derived');

revoke usage on type knowledge.monograph_answer_origin from public;

comment on type knowledge.monograph_answer_origin is
  'Hvor en svarrevisjon kom fra: agent (en ekstern KI-agent leste dokumentet), human (en kliniker med mandat skrev eller rettet svaret) eller derived (Antideps egen kode bandt svaret til et allerede kontrollert grunnlag). Opphavet er en del av dokumentasjonen: et svar som ser likt ut, er ikke det samme svaret når det kom et annet sted fra.';

create type workflow.monograph_answer_check_field as enum (
  'source_support',
  'source_locator',
  'currency',
  'approved_use',
  'knowledge_type_match',
  'derivation_basis',
  'no_invented_certainty'
);

revoke usage on type workflow.monograph_answer_check_field from public;

comment on type workflow.monograph_answer_check_field is
  'Feltene den deterministiske svarkontrollen faktisk kontrollerer: source_support (det ordrette utdraget står i den registrerte representasjonen), source_locator (svaret sier hvor i dokumentet opplysningen står), currency (opplysningen har et tidspunkt som ikke ligger fram i tid), approved_use (kildeversjonen er godkjent for nettopp dette kunnskapsbehovet), knowledge_type_match (kunnskapstypen passer det materialet behovet hviler på), derivation_basis (et avledet svar hviler bare på andre kontrollerte svar i den samme utgaven) og no_invented_certainty (et svar uten forskningsgrunnlag bærer ingen evidenssikkerhet).';

-- ----------------------------------------------------------------------------
-- 2. Svaret og revisjonene av det
-- ----------------------------------------------------------------------------

create table knowledge.monograph_answers (
  id uuid primary key default gen_random_uuid(),
  reference text not null default workflow.new_public_reference(),

  -- Ett svar per kunnskapsbehov. Behovet *er* spørsmålet, og to svar på det
  -- samme spørsmålet ville vært to svar uten et spørsmål som skilte dem.
  need_id uuid not null
    references knowledge.monograph_needs (id) on update restrict on delete restrict,

  current_revision_id uuid,

  created_by_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint monograph_answers_need_key unique (need_id),
  constraint monograph_answers_reference_key unique (reference),
  constraint monograph_answers_reference_shape_check
    check (reference ~ '^[0-9a-f]{32}$')
);

comment on table knowledge.monograph_answers is
  'Svaret på ett kunnskapsbehov: identiteten som består gjennom revisjoner. Ett svar per behov, fordi behovet er spørsmålet — to svar på det samme spørsmålet ville vært to svar uten noe som skilte dem. Innholdet ligger i revisjonene, som er uforanderlige: en endring er en ny revisjon, og den forrige blir stående som det den var da den ble brukt (MONOGRAPH_STANDARD.md §2).';

alter table knowledge.monograph_answers enable row level security;

create index monograph_answers_current_revision_idx
  on knowledge.monograph_answers (current_revision_id);

create trigger monograph_answers_set_row_timestamps
  before insert or update on knowledge.monograph_answers
  for each row execute function catalog.set_row_timestamps();

create table knowledge.monograph_answer_revisions (
  id uuid primary key default gen_random_uuid(),
  reference text not null default workflow.new_public_reference(),

  answer_id uuid not null
    references knowledge.monograph_answers (id) on update restrict on delete restrict,
  revision_number integer not null,
  supersedes_revision_id uuid
    references knowledge.monograph_answer_revisions (id)
    on update restrict on delete restrict,

  knowledge_type knowledge.monograph_knowledge_type not null,
  origin knowledge.monograph_answer_origin not null,

  -- Svaret slik det leses. Ingen betydningsfull kvalifikasjon skal stå bare i
  -- en fritekst langt unna, så forbeholdene hører hjemme her.
  statement text not null,
  -- Den strukturerte verdien, når svaret har en. Formen er kunnskapstypens.
  structured_value jsonb,
  -- Faglig usikkerhet, atskilt fra søke- og tilgangsbegrensninger.
  uncertainty_summary text,
  limitation_note text,

  -- Forskningsfunn: nøyaktig den påstandsrevisjonen som ble kontrollert og
  -- vurdert. Svaret skriver den ikke om.
  claim_revision_id uuid
    references knowledge.claim_revisions (id) on update restrict on delete restrict,

  -- Regulatorisk opplysning, preparatdata og attribuert råd: det ordrette
  -- utdraget, hvor det står, og når opplysningen gjaldt.
  source_version_id uuid
    references knowledge.source_versions (id) on update restrict on delete restrict,
  as_of date,
  source_quote text,
  source_locator text,
  recommending_body text,
  recommendation_date date,

  -- Avledet og resonnement: de allerede kontrollerte svarene dette hviler på.
  derived_from_revision_ids uuid[],

  change_reason text,
  created_by_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,
  created_by_agent_run_id uuid
    references provenance.agent_runs (id) on update restrict on delete restrict,
  created_at timestamptz not null default now(),

  constraint monograph_answer_revisions_reference_key unique (reference),
  constraint monograph_answer_revisions_reference_shape_check
    check (reference ~ '^[0-9a-f]{32}$'),
  constraint monograph_answer_revisions_number_key unique (answer_id, revision_number),
  constraint monograph_answer_revisions_number_check check (revision_number >= 1),
  constraint monograph_answer_revisions_statement_shape_check
    check (statement = btrim(statement) and length(statement) between 1 and 8000),
  constraint monograph_answer_revisions_uncertainty_shape_check
    check (uncertainty_summary is null
           or (uncertainty_summary = btrim(uncertainty_summary)
               and length(uncertainty_summary) between 1 and 4000)),
  constraint monograph_answer_revisions_limitation_shape_check
    check (limitation_note is null
           or (limitation_note = btrim(limitation_note)
               and length(limitation_note) between 1 and 4000)),
  constraint monograph_answer_revisions_quote_shape_check
    check (source_quote is null
           or (source_quote = btrim(source_quote)
               and length(source_quote) between 1 and 4000)),
  constraint monograph_answer_revisions_locator_shape_check
    check (source_locator is null
           or (source_locator = btrim(source_locator)
               and length(source_locator) between 1 and 500)),
  constraint monograph_answer_revisions_body_shape_check
    check (recommending_body is null
           or (recommending_body = btrim(recommending_body)
               and length(recommending_body) between 1 and 300)),
  constraint monograph_answer_revisions_reason_shape_check
    check (change_reason is null
           or (change_reason = btrim(change_reason)
               and length(change_reason) between 1 and 2000)),
  constraint monograph_answer_revisions_structured_value_shape_check
    check (structured_value is null or jsonb_typeof(structured_value) = 'object'),
  constraint monograph_answer_revisions_origin_shape_check
    check (case origin
             when 'agent' then created_by_agent_run_id is not null
             when 'human' then created_by_agent_run_id is null
             when 'derived' then created_by_agent_run_id is null
             else false
           end),

  -- Den uttømmende kontrakten per kunnskapstype. En type uten en gren her
  -- stopper skrivingen, framfor å havne stille i en kontrakt som ikke passer.
  constraint monograph_answer_revisions_knowledge_type_shape_check
    check (case knowledge_type
             when 'research_finding' then
               claim_revision_id is not null
               and num_nonnulls(source_version_id, as_of, source_quote,
                                source_locator, recommending_body,
                                recommendation_date) = 0
               and derived_from_revision_ids is null
             when 'regulatory_fact' then
               claim_revision_id is null
               and source_version_id is not null and as_of is not null
               and source_quote is not null and source_locator is not null
               and num_nonnulls(recommending_body, recommendation_date) = 0
               and derived_from_revision_ids is null
             when 'product_data' then
               claim_revision_id is null
               and source_version_id is not null and as_of is not null
               and source_quote is not null and source_locator is not null
               and num_nonnulls(recommending_body, recommendation_date) = 0
               and derived_from_revision_ids is null
             when 'attributed_advice' then
               claim_revision_id is null
               and source_version_id is not null and as_of is not null
               and source_quote is not null and source_locator is not null
               and recommending_body is not null and recommendation_date is not null
               and derived_from_revision_ids is null
             when 'reasoning' then
               claim_revision_id is null
               and num_nonnulls(source_version_id, as_of, source_quote,
                                source_locator, recommending_body,
                                recommendation_date) = 0
               and derived_from_revision_ids is not null
               and cardinality(derived_from_revision_ids) >= 1
             when 'derived' then
               claim_revision_id is null
               and num_nonnulls(source_version_id, as_of, source_quote,
                                source_locator, recommending_body,
                                recommendation_date) = 0
               and derived_from_revision_ids is not null
               and cardinality(derived_from_revision_ids) >= 1
             else false
           end)
);

comment on table knowledge.monograph_answer_revisions is
  'Én uforanderlig utgave av svaret på ett kunnskapsbehov, med kunnskapstypen sin egen dokumentasjonskontrakt. Et forskningsfunn peker på nøyaktig den påstandsrevisjonen som ble kontrollert og vurdert, og skriver den ikke om. En regulatorisk opplysning, en preparatdata og et attribuert råd bærer et ordrett utdrag, en lokalisering og et tidspunkt — og ingen GRADE-vurdering, fordi en oppdiktet evidenssikkerhet på en preparatstyrke ville vært en påstand ingen har gjort. Et avledet svar og et resonnement hviler bare på andre kontrollerte svar (MONOGRAPH_STANDARD.md §2).';
comment on column knowledge.monograph_answer_revisions.limitation_note is
  'Søke- og tilgangsbegrensninger, holdt atskilt fra den faglige usikkerheten. Manglende fulltekst, en uløst uenighet og en teknisk svikt er ikke faglige konklusjoner, og de skal ikke kunne leses som «utilstrekkelig evidens» fordi de sto i samme felt (ANTIDEP_CONSTITUTION.md regel 4).';

alter table knowledge.monograph_answer_revisions enable row level security;

create index monograph_answer_revisions_answer_idx
  on knowledge.monograph_answer_revisions (answer_id, revision_number desc);
create index monograph_answer_revisions_claim_revision_idx
  on knowledge.monograph_answer_revisions (claim_revision_id);
create index monograph_answer_revisions_source_version_idx
  on knowledge.monograph_answer_revisions (source_version_id);

create trigger monograph_answer_revisions_set_created_at
  before insert or update on knowledge.monograph_answer_revisions
  for each row execute function catalog.set_created_at();

create trigger monograph_answer_revisions_are_append_only
  before update or delete on knowledge.monograph_answer_revisions
  for each row execute function knowledge.reject_append_only_mutation(
    'En svarrevisjon er det monografien sa i det øyeblikket den ble brukt. En endring er en ny revisjon; den forrige blir stående som det den var.');

alter table knowledge.monograph_answers
  add constraint monograph_answers_current_revision_fkey
    foreign key (current_revision_id)
    references knowledge.monograph_answer_revisions (id)
    on update restrict on delete restrict;

-- Ett behov kan bruke flere kilder. Den primære dokumentasjonen står på
-- revisjonen, slik at kontrakten kan kreve den i en CHECK; tilleggskildene står
-- her, med hver sin lokalisering, sitt utdrag og sitt tidspunkt — og de
-- kontrolleres med nøyaktig den samme funksjonen.
create table knowledge.monograph_answer_revision_sources (
  id uuid primary key default gen_random_uuid(),

  answer_revision_id uuid not null
    references knowledge.monograph_answer_revisions (id)
    on update restrict on delete restrict,
  source_version_id uuid not null
    references knowledge.source_versions (id) on update restrict on delete restrict,

  source_quote text not null,
  source_locator text not null,
  as_of date not null,
  created_at timestamptz not null default now(),

  constraint monograph_answer_revision_sources_pair_key
    unique (answer_revision_id, source_version_id),
  constraint monograph_answer_revision_sources_quote_shape_check
    check (source_quote = btrim(source_quote) and length(source_quote) between 1 and 4000),
  constraint monograph_answer_revision_sources_locator_shape_check
    check (source_locator = btrim(source_locator)
           and length(source_locator) between 1 and 500)
);

comment on table knowledge.monograph_answer_revision_sources is
  'Tilleggskildene én svarrevisjon hviler på, i tillegg til den primære dokumentasjonen som står på revisjonen selv. Finnes fordi ett kunnskapsbehov kan kreve flere kilder — en tabell over norske produkter kan hvile på flere preparatomtaler — og hver av dem skal ha sitt eget ordrette utdrag, sin egen lokalisering og sitt eget tidspunkt. Kontrolleres med nøyaktig den samme funksjonen som den primære.';

alter table knowledge.monograph_answer_revision_sources enable row level security;

create index monograph_answer_revision_sources_version_idx
  on knowledge.monograph_answer_revision_sources (source_version_id);

create trigger monograph_answer_revision_sources_set_created_at
  before insert or update on knowledge.monograph_answer_revision_sources
  for each row execute function catalog.set_created_at();

create trigger monograph_answer_revision_sources_are_append_only
  before update or delete on knowledge.monograph_answer_revision_sources
  for each row execute function knowledge.reject_append_only_mutation();

-- ----------------------------------------------------------------------------
-- 3. Den deterministiske svarkontrollen
--
-- Antideps egen kode, ikke en modellvurdering. Den leser det ordrette utdraget
-- mot den registrerte representasjonen, ser etter lokaliseringen og
-- tidspunktet, og kontrollerer at kildeversjonen faktisk er godkjent for
-- nettopp dette behovet.
-- ----------------------------------------------------------------------------

create function workflow.monograph_answer_citation_problem(
  p_need_id uuid,
  p_source_version_id uuid,
  p_as_of date,
  p_source_quote text,
  p_source_locator text)
  returns text
  language plpgsql
  stable
  set search_path = ''
as $$
declare
  v_text text;
begin
  -- approved_use: kildeversjonen må være godkjent for nettopp dette behovet.
  if not exists (
    select 1 from knowledge.monograph_source_uses u
    where u.need_id = p_need_id and u.source_version_id = p_source_version_id
  ) then
    return 'Kildeversjonen er ikke godkjent for dette kunnskapsbehovet.';
  end if;

  -- source_support: utdraget må stå ordrett i den registrerte representasjonen.
  v_text := knowledge.source_version_text(p_source_version_id);
  if v_text is null then
    return 'Kildeversjonen har ingen registrert representasjon å kontrollere utdraget mot.';
  end if;
  if nullif(btrim(coalesce(p_source_quote, '')), '') is null then
    return 'Svaret bærer ikke noe ordrett utdrag fra kilden.';
  end if;
  if position(btrim(p_source_quote) in v_text) = 0 then
    return 'Det ordrette utdraget står ikke i den registrerte representasjonen av kildeversjonen.';
  end if;

  -- source_locator: svaret må si hvor i dokumentet opplysningen står.
  if nullif(btrim(coalesce(p_source_locator, '')), '') is null then
    return 'Svaret sier ikke hvor i dokumentet opplysningen står.';
  end if;

  -- currency: opplysningen må ha et tidspunkt, og det kan ikke ligge fram i tid.
  if p_as_of is null then
    return 'Svaret sier ikke når opplysningen gjaldt.';
  end if;
  if p_as_of > (now() at time zone 'utc')::date then
    return 'Tidspunktet for opplysningen ligger fram i tid.';
  end if;

  return null;
end;
$$;

comment on function workflow.monograph_answer_citation_problem(uuid, uuid, date, text, text) is
  'Den første grunnen til at én kildehenvisning i et strukturert svar ikke kan stå, eller NULL: kildeversjonen er ikke godkjent for behovet, utdraget står ikke ordrett i den registrerte representasjonen, lokaliseringen mangler, eller tidspunktet mangler eller ligger fram i tid. Finnes som én funksjon fordi den primære dokumentasjonen og hver tilleggskilde skal kontrolleres likt — to kopier av regelen ville før eller siden sluppet gjennom noe den ene fanget.';

revoke execute on function workflow.monograph_answer_citation_problem(uuid, uuid, date, text, text) from public;

create function workflow.monograph_answer_problem(
  p_need_id uuid,
  p_knowledge_type knowledge.monograph_knowledge_type,
  p_claim_revision_id uuid,
  p_source_version_id uuid,
  p_as_of date,
  p_source_quote text,
  p_source_locator text,
  p_derived_from uuid[])
  returns text
  language plpgsql
  stable
  set search_path = ''
as $$
declare
  v_need knowledge.monograph_needs;
  v_kind knowledge.monograph_material_kind;
  v_count integer;
begin
  select n.* into v_need from knowledge.monograph_needs n where n.id = p_need_id;
  if not found then
    return 'Kunnskapsbehovet svaret gjelder, finnes ikke.';
  end if;

  if v_need.relevance = 'not_applicable' then
    return 'Behovet er avgjort som ikke relevant, og et svar på det ville motsagt avgjørelsen.';
  end if;

  -- knowledge_type_match: kunnskapstypen må passe materialet behovet hviler på.
  v_kind := knowledge.monograph_need_material_kind(p_need_id);
  if v_kind = 'research_full_text'
     and p_knowledge_type not in ('research_finding', 'derived') then
    return format(
      'Behovet ber om et forskningsfunn, og %L er ikke en forskningskunnskapstype.',
      p_knowledge_type);
  end if;
  if v_kind = 'authority_document'
     and p_knowledge_type = 'research_finding' then
    return 'Behovet hviler på et myndighets-, preparat- eller retningslinjedokument, og et slikt dokument bærer ikke et forskningsfunn.';
  end if;
  if v_kind = 'derived' and p_knowledge_type not in ('derived', 'reasoning') then
    return 'Behovet er et avledet svar, og det skal settes sammen av allerede kontrollerte svar framfor å hente ny kunnskap.';
  end if;

  if p_knowledge_type = 'research_finding' then
    -- Grunnlaget må ha gått hele veien: kontrollert kildestøtte og en
    -- registrert evidensvurdering. Uten begge er det ikke et kontrollert svar.
    if not exists (
      select 1 from knowledge.claim_revisions r where r.id = p_claim_revision_id
    ) then
      return 'Påstandsrevisjonen svaret hviler på, finnes ikke.';
    end if;

    begin
      perform workflow.assert_claim_verification_complete(p_claim_revision_id);
    exception
      when others then
        return 'Påstandsrevisjonen har ikke bestått kildestøttekontrollen.';
    end;

    if not exists (
      select 1 from knowledge.evidence_assessments a
      where a.claim_revision_id = p_claim_revision_id
    ) then
      return 'Påstandsrevisjonen har ingen registrert evidensvurdering.';
    end if;

    -- Og påstanden må svare på nettopp dette behovet. Uten kravet kunne et
    -- kontrollert funn om et annet spørsmål blitt monografiens svar her.
    if not exists (
      select 1
      from knowledge.claim_revisions r
      join knowledge.claims c on c.id = r.claim_id
      where r.id = p_claim_revision_id and c.monograph_need_id = p_need_id
    ) then
      return 'Påstanden svarer ikke på dette kunnskapsbehovet.';
    end if;

    return null;
  end if;

  if p_knowledge_type in ('regulatory_fact', 'product_data', 'attributed_advice') then
    return workflow.monograph_answer_citation_problem(
      p_need_id, p_source_version_id, p_as_of, p_source_quote, p_source_locator);
  end if;

  if p_knowledge_type in ('derived', 'reasoning') then
    -- derivation_basis: hvert grunnlag må være den gjeldende revisjonen av et
    -- annet svar i den samme monografiutgaven. Et avledet svar som hvilte på et
    -- utkast eller på et svar fra en annen utgave, ville sagt noe annet enn det
    -- monografien faktisk sier.
    select count(*) into v_count
    from unnest(coalesce(p_derived_from, array[]::uuid[])) as g(id)
    where exists (
      select 1
      from knowledge.monograph_answer_revisions r
      join knowledge.monograph_answers a on a.id = r.answer_id
      join knowledge.monograph_needs n on n.id = a.need_id
      where r.id = g.id
        and a.current_revision_id = r.id
        and a.need_id <> p_need_id
        and n.edition_id = v_need.edition_id
    );

    if v_count <> cardinality(coalesce(p_derived_from, array[]::uuid[])) then
      return 'Et avledet svar kan bare hvile på gjeldende svar i den samme monografiutgaven.';
    end if;

    return null;
  end if;

  return format('Kunnskapstypen %L har ingen kontroll.', p_knowledge_type);
end;
$$;

comment on function workflow.monograph_answer_problem(uuid, knowledge.monograph_knowledge_type, uuid, uuid, date, text, text, uuid[]) is
  'Den første grunnen til at et strukturert svar ikke kan stå, eller NULL. Antideps egen deterministiske kode: den leser det ordrette utdraget mot den registrerte representasjonen, ser etter lokaliseringen og tidspunktet, kontrollerer at kildeversjonen er godkjent for nettopp dette behovet, at et forskningssvar hviler på en påstand som har bestått kildestøttekontrollen og har en evidensvurdering, og at et avledet svar bare hviler på gjeldende svar i den samme utgaven. Ingen modellvurdering (ANTIDEP_CONSTITUTION.md regel 3).';

revoke execute on function workflow.monograph_answer_problem(uuid, knowledge.monograph_knowledge_type, uuid, uuid, date, text, text, uuid[]) from public;

create table workflow.monograph_answer_verifications (
  id uuid primary key default gen_random_uuid(),

  answer_revision_id uuid not null
    references knowledge.monograph_answer_revisions (id)
    on update restrict on delete restrict,
  checked_fields workflow.monograph_answer_check_field[] not null,
  rationale text not null,
  verifier_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,
  verified_at timestamptz not null default now(),
  created_at timestamptz not null default now(),

  constraint monograph_answer_verifications_revision_key unique (answer_revision_id),
  constraint monograph_answer_verifications_fields_check
    check (cardinality(checked_fields) >= 1),
  constraint monograph_answer_verifications_rationale_shape_check
    check (rationale = btrim(rationale) and length(rationale) between 1 and 2000)
);

comment on table workflow.monograph_answer_verifications is
  'Hvilke felter den deterministiske svarkontrollen faktisk kontrollerte for én svarrevisjon. Raden finnes for at dekningsvisningen skal kunne vise kontrollen som det den er — Antideps egen kode, ikke en modellvurdering — og for at «kontrollert» aldri skal være noe et menneske må ta på tro. Kontrollen kjører i skriveveien: en revisjon som ikke består den, blir ikke skrevet, og derfor har hver revisjon nøyaktig én kontrollrad.';

alter table workflow.monograph_answer_verifications enable row level security;

create trigger monograph_answer_verifications_set_created_at
  before insert or update on workflow.monograph_answer_verifications
  for each row execute function catalog.set_created_at();

create trigger monograph_answer_verifications_are_append_only
  before update or delete on workflow.monograph_answer_verifications
  for each row execute function knowledge.reject_append_only_mutation();

-- ----------------------------------------------------------------------------
-- 4. Leddene: den som skriver et myndighetssvar, og den som kontrollerer det
--
-- Den første er en faglig vurdering — å lese et dokument og formulere en
-- opplysning med kilde, lokalisering og tidspunkt — og den settes ut til en
-- ekstern KI-agent gjennom den samme kontrakten som resten av kjeden. Den andre
-- er Antideps egen deterministiske kode, og skal aldri kunne settes ut: en
-- kontroll utført av nok en modell ville vært nok en modellvurdering
-- (ANTIDEP_CONSTITUTION.md regel 3).
-- ----------------------------------------------------------------------------

insert into provenance.actors (actor_type, actor_key, display_name, description, agent_role)
values
  ('agent', 'agent:monograph-answer',
   'Antidep monografisvaragent',
   'KI-assistert prosess som leser et registrert myndighets-, preparat- eller retningslinjedokument og formulerer det strukturerte svaret på ett kunnskapsbehov: opplysningen, det ordrette utdraget, hvor det står og når det gjaldt. Aktøren vurderer ikke evidenssikkerhet og bygger ingen forskningssyntese — et forskningssvar bindes deterministisk til den påstandsrevisjonen som allerede er kontrollert og vurdert.',
   'monograph_answer'),
  ('agent', 'agent:monograph-answer-verification',
   'Antidep svarkontroll',
   'Antideps egen deterministiske kontroll av et strukturert monografisvar: at det ordrette utdraget står i den registrerte representasjonen, at lokaliseringen og tidspunktet finnes, at kildeversjonen er godkjent for nettopp dette behovet, og at et avledet svar bare hviler på gjeldende svar i den samme utgaven. Ikke en modell, og kan ikke settes ut til en.',
   'monograph_answer_verification');

insert into provenance.agent_identities (
  actor_id, agent_role, identity_key,
  registered_by_actor_id, registered_by_actor_type, registration_reason
)
select
  a.id, a.agent_role, v.identity_key,
  editor.id, 'human'::provenance.actor_type, v.reason
from (values
  ('agent:monograph-answer', 'agent-identity:monograph-answer-01',
   'Den tekniske identiteten monografisvarleddet handler med. Rollen er rettighetsgrensen: identiteten kan registrere ett strukturert svar på det kunnskapsbehovet oppgaven gjelder, og ingenting annet. Den kan ikke ekstrahere evidens, ikke formulere en påstand, ikke registrere en evidensvurdering, ikke godkjenne sin egen kilde og ikke publisere. Legitimasjon er ikke utstedt: identiteten er inert til provenance.issue_agent_identity_credential(text, text) kalles i det miljøet kjøreren skal lese hemmeligheten fra.'),
  ('agent:monograph-answer-verification', 'agent-identity:monograph-answer-verification-01',
   'Den tekniske identiteten den deterministiske svarkontrollen fører radene sine under. Kontrollen er Antideps egen kode og settes aldri ut; identiteten finnes for at kontrollraden skal ha et opphav som sier nettopp det.')
) as v(actor_key, identity_key, reason)
join provenance.actors a on a.actor_key = v.actor_key
cross join lateral (
  select id from provenance.actors where actor_key = 'human:peder-holman'
) editor;

do $$
begin
  if (select count(*) from provenance.agent_identities
      where identity_key in ('agent-identity:monograph-answer-01',
                             'agent-identity:monograph-answer-verification-01')) <> 2 then
    raise exception using
      errcode = 'no_data_found',
      message = 'Svarleddenes agentidentiteter ble ikke registrert.',
      hint = 'Registreringen forutsetter at aktørene over og human:peder-holman finnes. En tom krysskobling ville satt inn null rader uten å feile.';
  end if;
end;
$$;

insert into provenance.role_model_assignments
  (agent_role, capacity, provider, model, model_version, registered_by_actor_id, reason)
select 'monograph_answer_verification'::provenance.agent_role,
       'registration'::provenance.model_capacity,
       'antidep', 'monograph-answer-control', '1.0.0', a.id,
       'Den deterministiske svarkontrollen. Antideps egen kode: den leser det ordrette utdraget mot den registrerte representasjonen, kontrollerer lokalisering, tidspunkt og godkjent bruk, og fører opp hvilke felter som ble kontrollert. Det finnes ingen semantisk tildeling for denne rollen, og det er hele poenget.'
from provenance.actors a
where a.actor_key = 'human:peder-holman';

-- ----------------------------------------------------------------------------
-- 5. Skriveveien
-- ----------------------------------------------------------------------------

create function knowledge.record_monograph_answer_revision(
  p_need_id uuid,
  p_knowledge_type knowledge.monograph_knowledge_type,
  p_origin knowledge.monograph_answer_origin,
  p_statement text,
  p_structured_value jsonb,
  p_uncertainty_summary text,
  p_limitation_note text,
  p_claim_revision_id uuid,
  p_source_version_id uuid,
  p_as_of date,
  p_source_quote text,
  p_source_locator text,
  p_recommending_body text,
  p_recommendation_date date,
  p_derived_from uuid[],
  p_additional_sources jsonb,
  p_change_reason text,
  p_actor_id uuid,
  p_agent_run_id uuid)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_answer knowledge.monograph_answers;
  v_problem text;
  v_previous knowledge.monograph_answer_revisions;
  v_number integer;
  v_revision_id uuid;
  v_fields workflow.monograph_answer_check_field[];
  v_verifier_actor_id uuid;
  v_source jsonb;
  v_extra integer := 0;
begin
  -- Låsen på behovet først, slik at to samtidige svar på det samme spørsmålet
  -- blir to revisjoner i rekkefølge og ikke to revisjoner med samme nummer.
  perform 1 from knowledge.monograph_needs n where n.id = p_need_id for update;
  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Kunnskapsbehovet svaret gjelder, finnes ikke.';
  end if;

  v_problem := workflow.monograph_answer_problem(
    p_need_id, p_knowledge_type, p_claim_revision_id, p_source_version_id,
    p_as_of, p_source_quote, p_source_locator, p_derived_from);

  if v_problem is not null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = v_problem,
      hint = 'Et svar som ikke kan kontrolleres, skal ikke bli stående som et svar. Kontrollen er Antideps egen kode og kjører i skriveveien (ANTIDEP_CONSTITUTION.md regel 2).';
  end if;

  -- Og hver tilleggskilde, med den samme kontrollen. En kilde som slapp
  -- gjennom fordi den sto i et annet felt, ville vært en kilde ingen leste.
  if p_additional_sources is not null then
    if jsonb_typeof(p_additional_sources) <> 'array' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Tilleggskildene må være en liste.';
    end if;
    for v_source in select value from jsonb_array_elements(p_additional_sources) loop
      v_problem := workflow.monograph_answer_citation_problem(
        p_need_id,
        (v_source ->> 'source_version_id')::uuid,
        (v_source ->> 'as_of')::date,
        v_source ->> 'source_quote',
        v_source ->> 'source_locator');
      if v_problem is not null then
        raise exception using
          errcode = 'invalid_parameter_value',
          message = format('Tilleggskilden kan ikke stå: %s', v_problem);
      end if;
    end loop;
  end if;

  select a.* into v_answer
  from knowledge.monograph_answers a
  where a.need_id = p_need_id
  for update;

  if not found then
    insert into knowledge.monograph_answers (need_id, created_by_actor_id)
    values (p_need_id, p_actor_id)
    returning * into v_answer;
  end if;

  select r.* into v_previous
  from knowledge.monograph_answer_revisions r
  where r.answer_id = v_answer.id
  order by r.revision_number desc
  limit 1;

  v_number := coalesce(v_previous.revision_number, 0) + 1;

  insert into knowledge.monograph_answer_revisions (
    answer_id, revision_number, supersedes_revision_id,
    knowledge_type, origin, statement, structured_value,
    uncertainty_summary, limitation_note,
    claim_revision_id, source_version_id, as_of, source_quote, source_locator,
    recommending_body, recommendation_date, derived_from_revision_ids,
    change_reason, created_by_actor_id, created_by_agent_run_id
  )
  values (
    v_answer.id, v_number, v_previous.id,
    p_knowledge_type, p_origin, btrim(p_statement), p_structured_value,
    nullif(btrim(coalesce(p_uncertainty_summary, '')), ''),
    nullif(btrim(coalesce(p_limitation_note, '')), ''),
    p_claim_revision_id, p_source_version_id, p_as_of,
    nullif(btrim(coalesce(p_source_quote, '')), ''),
    nullif(btrim(coalesce(p_source_locator, '')), ''),
    nullif(btrim(coalesce(p_recommending_body, '')), ''),
    p_recommendation_date,
    case when p_derived_from is null or cardinality(p_derived_from) = 0
         then null else workflow.sorted_unique(p_derived_from) end,
    nullif(btrim(coalesce(p_change_reason, '')), ''),
    p_actor_id, p_agent_run_id
  )
  returning id into v_revision_id;

  if p_additional_sources is not null then
    for v_source in select value from jsonb_array_elements(p_additional_sources) loop
      insert into knowledge.monograph_answer_revision_sources
        (answer_revision_id, source_version_id, source_quote, source_locator, as_of)
      values (
        v_revision_id,
        (v_source ->> 'source_version_id')::uuid,
        btrim(v_source ->> 'source_quote'),
        btrim(v_source ->> 'source_locator'),
        (v_source ->> 'as_of')::date)
      on conflict on constraint monograph_answer_revision_sources_pair_key do nothing;
      v_extra := v_extra + 1;
    end loop;
  end if;

  -- Kontrollraden: hvilke felter som faktisk ble kontrollert for nettopp denne
  -- kunnskapstypen. «Kontrollert» skal aldri være noe et menneske må ta på tro.
  v_fields := case p_knowledge_type
    when 'research_finding' then
      array['knowledge_type_match', 'source_support', 'approved_use']
    when 'derived' then
      array['knowledge_type_match', 'derivation_basis', 'no_invented_certainty']
    when 'reasoning' then
      array['knowledge_type_match', 'derivation_basis', 'no_invented_certainty']
    else
      array['knowledge_type_match', 'source_support', 'source_locator',
            'currency', 'approved_use', 'no_invented_certainty']
  end::workflow.monograph_answer_check_field[];

  select a.id into v_verifier_actor_id
  from provenance.actors a
  where a.actor_key = 'agent:monograph-answer-verification';

  insert into workflow.monograph_answer_verifications
    (answer_revision_id, checked_fields, rationale, verifier_actor_id)
  values (
    v_revision_id, v_fields,
    format('Deterministisk svarkontroll for kunnskapstypen %L bestått i skriveveien, '
           || 'med %s tilleggskilde(r) kontrollert på samme måte.',
           p_knowledge_type, v_extra),
    v_verifier_actor_id);

  update knowledge.monograph_answers a
  set current_revision_id = v_revision_id
  where a.id = v_answer.id;

  -- Behovet er behandlet. Utfallet er svarets, og ikke en arbeidstilstand.
  perform knowledge.set_monograph_need_work_state(
    p_need_id, 'agent_complete'::knowledge.monograph_work_state,
    format('Strukturert svar registrert (revisjon %s).', v_number),
    'answered'::knowledge.monograph_outcome, p_actor_id, p_agent_run_id);

  return v_revision_id;
end;
$$;

comment on function knowledge.record_monograph_answer_revision(uuid, knowledge.monograph_knowledge_type, knowledge.monograph_answer_origin, text, jsonb, text, text, uuid, uuid, date, text, text, text, date, uuid[], jsonb, text, uuid, uuid) is
  'Den ene skriveveien for et strukturert monografisvar. Kontrollen kjører før innsettingen, ikke etter: et svar som ikke kan kontrolleres, skal ikke bli stående som et svar. Hver revisjon får sin egen kontrollrad med hvilke felter som faktisk ble kontrollert, og blir den gjeldende. Behovet får utfallet «besvart» — som er svarets konklusjon og ikke en arbeidstilstand.';

revoke execute on function knowledge.record_monograph_answer_revision(uuid, knowledge.monograph_knowledge_type, knowledge.monograph_answer_origin, text, jsonb, text, text, uuid, uuid, date, text, text, text, date, uuid[], jsonb, text, uuid, uuid) from public;

-- ----------------------------------------------------------------------------
-- 6. Sporet
-- ----------------------------------------------------------------------------

create function audit.record_monograph_answer_revision_event()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  insert into audit.events (
    operation, object_id, actor_id,
    old_revision_or_snapshot, new_revision_or_snapshot, reason, occurred_at
  )
  values (
    'monograph_answer_revision_created'::audit.event_operation,
    new.id,
    new.created_by_actor_id,
    -- Ingen «før»-tilstand: revisjonen *er* ny, og den forrige er et annet
    -- objekt med sin egen auditrad. Hvilken den avløste, står i selve
    -- øyeblikksbildet (supersedes_revision_id), så fortiden er ikke borte.
    null,
    to_jsonb(new),
    coalesce(new.change_reason,
             format('Første revisjon av svaret, av kunnskapstypen %L.',
                    new.knowledge_type)),
    new.created_at
  );
  return null;
end;
$$;

comment on function audit.record_monograph_answer_revision_event() is
  'Fører hver svarrevisjon i det uforanderlige sporet. Revisjonen er ny, så det finnes ingen «før»-tilstand av den; hvilken revisjon den avløste, står i øyeblikksbildet selv, og den forrige har sin egen auditrad. Sporet er det som gjør at en revisjon kan leses som en endring av noe bestemt, framfor som en ny tekst uten fortid (MONOGRAPH_STANDARD.md §2).';

revoke execute on function audit.record_monograph_answer_revision_event() from public;

create trigger monograph_answer_revisions_record_audit_event
  after insert on knowledge.monograph_answer_revisions
  for each row execute function audit.record_monograph_answer_revision_event();

-- ----------------------------------------------------------------------------
-- 7. Overgangen fra en registrert evidensvurdering til et forskningssvar
--
-- Deterministisk med vilje. Påstandsrevisjonen *er* det kontrollerte svaret, og
-- en agent som skrev det om igjen, ville laget en formulering ingen hadde
-- kontrollert — og det ville vært en ny monografivei forbi kontrollene.
-- ----------------------------------------------------------------------------

create function workflow.chain_answer_for_assessment(p_claim_revision_id uuid)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_revision knowledge.claim_revisions;
  v_claim knowledge.claims;
  v_assessment knowledge.evidence_assessments;
  v_existing knowledge.monograph_answer_revisions;
  v_statement text;
  v_uncertainty text;
  v_actor_id uuid;
begin
  select r.* into v_revision
  from knowledge.claim_revisions r
  where r.id = p_claim_revision_id;

  if not found then
    return null;
  end if;

  select c.* into v_claim
  from knowledge.claims c
  where c.id = v_revision.claim_id;

  -- Uten en monografiavgrensning er påstanden den artikkelbaserte flytens, og
  -- den har ikke noe kunnskapsbehov å være svar på.
  if v_claim.monograph_need_id is null then
    return null;
  end if;

  select a.* into v_assessment
  from knowledge.evidence_assessments a
  where a.claim_revision_id = p_claim_revision_id;

  if not found then
    return null;
  end if;

  -- Er svaret alt bundet til nøyaktig denne påstandsrevisjonen, er det gjort.
  select r.* into v_existing
  from knowledge.monograph_answer_revisions r
  join knowledge.monograph_answers a on a.id = r.answer_id
  where a.need_id = v_claim.monograph_need_id
    and a.current_revision_id = r.id
    and r.claim_revision_id = p_claim_revision_id;

  if found then
    return null;
  end if;

  v_actor_id := coalesce(v_assessment.created_by_actor_id, v_revision.created_by_actor_id);

  v_statement := v_revision.statement;
  -- Usikkerheten er påstandens egen, og evidenssikkerheten leses fra
  -- vurderingen framfor å bli skrevet inn på nytt: to steder som sa hver sitt om
  -- den samme vurderingen, ville før eller siden sagt noe forskjellig.
  v_uncertainty := v_revision.uncertainty_summary;

  return knowledge.record_monograph_answer_revision(
    v_claim.monograph_need_id,
    'research_finding'::knowledge.monograph_knowledge_type,
    'derived'::knowledge.monograph_answer_origin,
    v_statement,
    jsonb_strip_nulls(jsonb_build_object(
      'claim_revision', v_revision.id,
      'scope', v_revision.scope,
      'population_id', v_revision.population_id,
      'comparator_kind', v_revision.comparator_kind::text,
      'direction', v_revision.direction::text,
      'magnitude_measure', v_revision.magnitude_measure::text,
      'magnitude_value', v_revision.magnitude_value,
      'magnitude_unit', v_revision.magnitude_unit::text,
      'timeframe_min', v_revision.timeframe_min::text,
      'timeframe_max', v_revision.timeframe_max::text,
      'certainty_framework', v_assessment.framework::text,
      'certainty_level', v_assessment.certainty_level::text,
      'evidence_gap', v_assessment.evidence_gap)),
    v_uncertainty,
    null,
    p_claim_revision_id,
    null, null, null, null, null, null, null, null,
    format('Bundet til påstandsrevisjon %s, som har bestått kildestøttekontrollen og har en registrert evidensvurdering.',
           v_revision.revision_number),
    v_actor_id,
    null);
end;
$$;

comment on function workflow.chain_answer_for_assessment(uuid) is
  'Binder et monografisvar til nøyaktig den påstandsrevisjonen som er kontrollert og vurdert. Deterministisk med vilje: påstandsrevisjonen er det kontrollerte svaret, og en agent som formulerte det om igjen, ville laget en tekst ingen hadde kontrollert — en ny monografivei forbi kontrollene. Evidenssikkerheten leses fra vurderingen framfor å bli skrevet inn på nytt, slik at to steder ikke kan si hver sitt om den samme vurderingen. Idempotent.';

revoke execute on function workflow.chain_answer_for_assessment(uuid) from public;

-- ----------------------------------------------------------------------------
-- 8. Svaret fra monografisvaragenten
--
-- Agenten leser det registrerte dokumentet og formulerer opplysningen. Den
-- avgjør ikke hvilket behov svaret gjelder — det står i oppgaven — og den kan
-- ikke godkjenne sin egen kilde eller publisere noe.
-- ----------------------------------------------------------------------------

create function workflow.record_monograph_answer_handoff(
  p_job workflow.pipeline_jobs,
  p_input jsonb,
  p_result jsonb,
  p_agent_run_id uuid,
  p_actor_id uuid)
  returns jsonb
  language plpgsql
  set search_path = ''
as $$
declare
  v_answer jsonb := p_result -> 'answer';
  v_need_id uuid := workflow.manifest_uuid(p_job.input_manifest, 'monograph_need_id');
  v_source_version_id uuid :=
    workflow.manifest_uuid(p_job.input_manifest, 'source_version_id');
  v_type knowledge.monograph_knowledge_type;
  v_key text;
  v_revision_id uuid;
begin
  if v_answer is null or jsonb_typeof(v_answer) <> 'object' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Svaret har ingen answer som er et JSON-objekt.';
  end if;

  -- Ukjente felter avvises framfor å bli ignorert. Et felt Antidep ikke leser,
  -- ville sett ut som noe agenten hadde sagt, og ingen ville visst at det ikke
  -- ble brukt (ANTIDEP_CONSTITUTION.md regel 4).
  for v_key in select jsonb_object_keys(v_answer) loop
    if v_key not in ('knowledge_type', 'statement', 'structured_value',
                     'uncertainty_summary', 'limitation_note', 'as_of',
                     'source_quote', 'source_locator', 'recommending_body',
                     'recommendation_date', 'additional_sources') then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('Feltet %L ligger utenfor svarformen.', v_key);
    end if;
  end loop;

  begin
    v_type := (v_answer ->> 'knowledge_type')::knowledge.monograph_knowledge_type;
  exception
    when invalid_text_representation or null_value_not_allowed then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke en kunnskapstype monografistandarden navngir.',
                         v_answer ->> 'knowledge_type');
  end;

  -- Et forskningsfunn bindes deterministisk til en kontrollert
  -- påstandsrevisjon, og skal ikke kunne formuleres av denne rollen.
  if v_type in ('research_finding', 'derived', 'reasoning') then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Kunnskapstypen %L skrives ikke av monografisvarrollen.', v_type),
      hint = 'Et forskningsfunn bindes deterministisk til den påstandsrevisjonen som er kontrollert og vurdert, og et avledet svar settes sammen av andre kontrollerte svar. Begge veier ville blitt omgått av en agent som formulerte dem på nytt.';
  end if;

  v_revision_id := knowledge.record_monograph_answer_revision(
    v_need_id,
    v_type,
    'agent'::knowledge.monograph_answer_origin,
    v_answer ->> 'statement',
    v_answer -> 'structured_value',
    v_answer ->> 'uncertainty_summary',
    v_answer ->> 'limitation_note',
    null,
    v_source_version_id,
    (v_answer ->> 'as_of')::date,
    v_answer ->> 'source_quote',
    v_answer ->> 'source_locator',
    v_answer ->> 'recommending_body',
    (v_answer ->> 'recommendation_date')::date,
    null,
    v_answer -> 'additional_sources',
    'Registrert av monografisvarrollen fra det registrerte dokumentet.',
    p_actor_id,
    p_agent_run_id);

  return jsonb_build_object(
    'monograph_answer_revision_id', v_revision_id,
    'monograph_need_id', v_need_id,
    'knowledge_type', v_type::text);
end;
$$;

comment on function workflow.record_monograph_answer_handoff(workflow.pipeline_jobs, jsonb, jsonb, uuid, uuid) is
  'Skriveveien for svaret fra monografisvarrollen. Behovet og kildeversjonen leses av oppgaven og ikke av svaret: en agent som kunne oppgi dem, kunne oppgi feil, og et svar ville havnet under et spørsmål det ikke ble lest for. Kunnskapstypene research_finding, derived og reasoning avvises med vilje — de bindes deterministisk til et allerede kontrollert grunnlag, og en agent som formulerte dem på nytt, ville omgått kontrollene.';

revoke execute on function workflow.record_monograph_answer_handoff(workflow.pipeline_jobs, jsonb, jsonb, uuid, uuid) from public;

-- ----------------------------------------------------------------------------
-- 9. Overgangen som legger svaroppgaven i køen
--
-- Når materialet er i hus og godkjent for behovet, er det en oppgave. Ikke før:
-- en oppgave uten et dokument ville stått i køen som noe som ventet på et
-- menneske, uten å kunne utføres.
-- ----------------------------------------------------------------------------

create function workflow.chain_task_for_monograph_answer(p_need_id uuid)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_need knowledge.monograph_needs;
  v_use knowledge.monograph_source_uses;
  v_manifest jsonb;
  v_subject text;
  v_origin record;
begin
  select n.* into v_need
  from knowledge.monograph_needs n
  where n.id = p_need_id;

  if not found or v_need.relevance = 'not_applicable' then
    return null;
  end if;

  if knowledge.monograph_need_material_kind(p_need_id) <> 'authority_document' then
    return null;
  end if;

  -- Den nyeste godkjente kildebruken. Kommer det en nyere kildeversjon, er det
  -- et nytt grunnlag, og da er svaret å revidere framfor å la det gamle stå.
  select u.* into v_use
  from knowledge.monograph_source_uses u
  join knowledge.source_versions sv on sv.id = u.source_version_id
  where u.need_id = p_need_id
  order by sv.retrieved_at desc, u.created_at desc, u.id
  limit 1;

  if not found then
    return null;
  end if;

  -- Er det gjeldende svaret alt bygget av nøyaktig denne kildeversjonen, er
  -- det gjort.
  if exists (
    select 1
    from knowledge.monograph_answers a
    join knowledge.monograph_answer_revisions r on r.id = a.current_revision_id
    where a.need_id = p_need_id
      and r.source_version_id = v_use.source_version_id
  ) then
    return null;
  end if;

  v_subject := p_need_id::text;
  perform workflow.lock_chain_subject(
    'monograph_answer'::provenance.agent_role, v_subject);

  if workflow.agent_task_subject_queued(
       'monograph_answer'::provenance.agent_role, v_subject) then
    return null;
  end if;

  v_manifest := jsonb_build_object(
    'monograph_need_id', p_need_id,
    'source_version_id', v_use.source_version_id,
    'scope_digest', v_need.scope_digest);

  v_origin := workflow.chain_origin(
    v_use.approved_by_agent_run_id, v_use.approved_by_actor_id);

  return workflow.chain_enqueue_job(
    'monograph_answer'::provenance.agent_role,
    workflow.agent_task_job_key('monograph_answer'::provenance.agent_role, v_manifest),
    v_manifest,
    v_origin.actor_id,
    v_origin.agent_identity_id,
    true,
    'Svaroppgaven lagt i køen av den godkjente kildebruken.');
end;
$$;

comment on function workflow.chain_task_for_monograph_answer(uuid) is
  'Legger svaroppgaven for ett kunnskapsbehov i køen når materialet er i hus og godkjent for nettopp det behovet — og ikke før: en oppgave uten et dokument ville stått i køen som noe som ventet på et menneske uten å kunne utføres (ANTIDEP_CONSTITUTION.md regel 4). Gjelder bare behov som hviler på et myndighets-, preparat- eller retningslinjedokument; et forskningssvar bindes deterministisk til en kontrollert påstandsrevisjon. Idempotent, og kommer det en nyere kildeversjon, er det et nytt grunnlag og en ny oppgave.';

revoke execute on function workflow.chain_task_for_monograph_answer(uuid) from public;

-- Og overgangen fra en registrert godkjent kildebruk til oppgaven.
create function workflow.chain_after_monograph_source_use()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
declare
  v_state text;
begin
  begin
    perform workflow.chain_task_for_monograph_answer(new.need_id);
  exception
    when restrict_violation or no_data_found or invalid_parameter_value then
      null;
    when others then
      get stacked diagnostics v_state = returned_sqlstate;
      perform workflow.chain_note_failure('monografisvar', new.need_id, v_state);
  end;
  return null;
end;
$$;

revoke execute on function workflow.chain_after_monograph_source_use() from public;

create trigger monograph_source_uses_enqueue_answer
  after insert on knowledge.monograph_source_uses
  for each row execute function workflow.chain_after_monograph_source_use();

-- ----------------------------------------------------------------------------
-- 10. Og overgangen fra en registrert evidensvurdering
-- ----------------------------------------------------------------------------

create or replace function workflow.chain_after_evidence_assessment()
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

  -- Og monografisvaret, bundet til nøyaktig den påstandsrevisjonen som ble
  -- vurdert. Feiler den ene overgangen, skal den andre likevel skje: de er to
  -- forskjellige stykker arbeid om det samme grunnlaget.
  begin
    perform workflow.chain_answer_for_assessment(new.claim_revision_id);
  exception
    when restrict_violation or no_data_found or invalid_parameter_value then
      null;
    when others then
      get stacked diagnostics v_state = returned_sqlstate;
      perform workflow.chain_note_failure('monografisvar', new.claim_revision_id, v_state);
  end;

  return null;
end;
$$;

-- ----------------------------------------------------------------------------
-- 11. Kontrakten, oppgaveflaten og rekonsilieringen
--
-- Monografisvarrollen føres inn i nøyaktig den samme eksterne agentkontrakten
-- som resten av kjeden. Den deterministiske svarkontrollen står bevisst *ikke*
-- i kontrakten: den er Antideps egen kode, og en ekstern modell som fikk
-- utføre den, ville gjort kontrollen til nok en modellvurdering
-- (ANTIDEP_CONSTITUTION.md regel 3).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION workflow.agent_task_contract(p_agent_role provenance.agent_role)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select case p_agent_role
    when 'evidence_extraction' then jsonb_build_object(
      'prompt_template_version', 'evidence-extraction/handoff-drafting/1',
      'output_schema_version', 'antidep/extraction-draft@1'
    )
    when 'claim_synthesis' then jsonb_build_object(
      'prompt_template_version', 'claim-synthesis/handoff-drafting/1',
      'output_schema_version', 'antidep/claim-synthesis-draft@1'
    )
    when 'evidence_assessment' then jsonb_build_object(
      'prompt_template_version', 'evidence-assessment/handoff-drafting/1',
      'output_schema_version', 'antidep/evidence-assessment-draft@1'
    )
    -- Migrasjon 013i hever svarformen til @2: et begrepsforslag kan navngi
    -- behovet verdien ble dokumentert under, slik at aksepten forgrener
    -- nettopp det behovet framfor å utvide utgaven på malenes hovedakse.
    when 'source_discovery' then jsonb_build_object(
      'prompt_template_version', 'source-discovery/handoff-search/1',
      'output_schema_version', 'antidep/source-discovery-draft@2'
    )
    when 'source_quality_assessment' then jsonb_build_object(
      'prompt_template_version', 'source-coverage/handoff-control/1',
      'output_schema_version', 'antidep/source-coverage-control-draft@1'
    )
    -- Migrasjon 013i: svaret på et behov som hviler på et myndighets-,
    -- preparat- eller retningslinjedokument. Den deterministiske
    -- svarkontrollen står bevisst ikke her: den er Antideps egen kode.
    when 'monograph_answer' then jsonb_build_object(
      'prompt_template_version', 'monograph-answer/handoff-fact/1',
      'output_schema_version', 'antidep/monograph-answer-draft@1'
    )
    else null
  end;
$function$;

CREATE OR REPLACE FUNCTION workflow.agent_task_manifest_subject(p_agent_role provenance.agent_role, p_input_manifest jsonb)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select case p_agent_role
    when 'evidence_extraction' then coalesce(p_input_manifest ->> 'source_version_id', '?')
    when 'claim_synthesis' then workflow.claim_synthesis_subject(
      p_input_manifest ->> 'subject_drug_id',
      p_input_manifest ->> 'topic_concept_id',
      p_input_manifest ->> 'monograph_need_id')
    when 'source_discovery' then coalesce(p_input_manifest ->> 'search_plan_id', '?')
    when 'source_quality_assessment' then coalesce(p_input_manifest ->> 'search_plan_id', '?')
    when 'monograph_answer' then coalesce(p_input_manifest ->> 'monograph_need_id', '?')
    else coalesce(p_input_manifest ->> 'claim_revision_id', '?')
  end;
$function$;

CREATE OR REPLACE FUNCTION workflow.agent_task_subject(p_job workflow.pipeline_jobs)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select case p_job.agent_role
    when 'evidence_extraction' then (
      select jsonb_build_object('kind', 'kilde', 'label', s.title)
      from knowledge.source_versions sv
      join knowledge.sources s on s.id = sv.source_id
      where sv.id = workflow.manifest_uuid(p_job.input_manifest, 'source_version_id')
    )
    when 'claim_synthesis' then (
      select jsonb_build_object('kind', 'påstand',
               'label', format('%s — %s', d.canonical_name, c.canonical_label))
      from catalog.drugs d, catalog.clinical_concepts c
      where d.id = workflow.manifest_uuid(p_job.input_manifest, 'subject_drug_id')
        and c.id = workflow.manifest_uuid(p_job.input_manifest, 'topic_concept_id')
    )
    when 'evidence_assessment' then (
      select jsonb_build_object('kind', 'påstandsrevisjon', 'label', r.statement)
      from knowledge.claim_revisions r
      where r.id = workflow.manifest_uuid(p_job.input_manifest, 'claim_revision_id')
    )
    when 'source_discovery' then (
      select jsonb_build_object('kind', 'søkeplan',
               'label', format('%s — %s', d.canonical_name, sp.question))
      from workflow.monograph_search_plans p
      join knowledge.monograph_editions e on e.id = p.edition_id
      join catalog.drugs d on d.id = e.drug_id
      join knowledge.monograph_source_profiles sp on sp.id = p.profile_id
      where p.id = workflow.manifest_uuid(p_job.input_manifest, 'search_plan_id')
    )
    when 'monograph_answer' then (
      select jsonb_build_object('kind', 'monografisvar',
               'label', format('%s — %s%s', d.canonical_name, t.code,
                 coalesce(' (' || knowledge.monograph_need_scope_label(n.id) || ')', '')))
      from knowledge.monograph_needs n
      join knowledge.monograph_editions e on e.id = n.edition_id
      join catalog.drugs d on d.id = e.drug_id
      join knowledge.monograph_question_templates t on t.id = n.template_id
      where n.id = workflow.manifest_uuid(p_job.input_manifest, 'monograph_need_id')
    )
    when 'source_quality_assessment' then (
      select jsonb_build_object('kind', 'kontroll av søkedekning',
               'label', format('%s — %s', d.canonical_name, sp.question))
      from workflow.monograph_search_plans p
      join knowledge.monograph_editions e on e.id = p.edition_id
      join catalog.drugs d on d.id = e.drug_id
      join knowledge.monograph_source_profiles sp on sp.id = p.profile_id
      where p.id = workflow.manifest_uuid(p_job.input_manifest, 'search_plan_id')
    )
  end;
$function$;

CREATE OR REPLACE FUNCTION workflow.agent_task_input_problem(p_job workflow.pipeline_jobs)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_manifest jsonb := p_job.input_manifest;
  v_source_version_id uuid;
  v_revision_id uuid;
  v_ids uuid[];
  v_count integer;
  v_knowledge_type knowledge.knowledge_type;
  v_retired_at timestamptz;
  v_plan_id uuid;
  v_plan workflow.monograph_search_plans;
begin
  if p_job.agent_role = 'evidence_extraction' then
    v_source_version_id := workflow.manifest_uuid(v_manifest, 'source_version_id');
    if v_source_version_id is null then
      return 'Oppgaven sier ikke hvilken kildeversjon den gjelder.';
    end if;
    if not exists (select 1 from knowledge.source_versions sv where sv.id = v_source_version_id) then
      return 'Kildeversjonen oppgaven gjelder, finnes ikke.';
    end if;
    if knowledge.source_version_text(v_source_version_id) is null then
      return 'Kildeteksten er ikke lagret for denne kildeversjonen, så oppgaven kan ikke inneholde artikkelen. Last opp fullteksten på nytt gjennom fulltekstbiblioteket.';
    end if;

    v_ids := workflow.manifest_uuids(v_manifest, 'drug_ids');
    if v_ids is null or cardinality(v_ids) = 0 then
      return 'Oppgaven sier ikke hvilke virkestoff funnet kan gjelde.';
    end if;
    select count(*) into v_count from catalog.drugs d where d.id = any (v_ids);
    if v_count <> cardinality(v_ids) then
      return 'Ett av virkestoffene i oppgaven finnes ikke i katalogen.';
    end if;

    v_ids := workflow.manifest_uuids(v_manifest, 'outcome_concept_ids');
    if v_ids is null or cardinality(v_ids) = 0 then
      return 'Oppgaven sier ikke hvilke endepunkt funnet kan gjelde.';
    end if;
    select count(*) into v_count
    from catalog.clinical_concepts c
    where c.id = any (v_ids) and c.concept_type = 'outcome';
    if v_count <> cardinality(v_ids) then
      return 'Ett av endepunktene i oppgaven finnes ikke i katalogen.';
    end if;

    v_ids := coalesce(workflow.manifest_uuids(v_manifest, 'population_ids'), array[]::uuid[]);
    select count(*) into v_count from catalog.populations p where p.id = any (v_ids);
    if v_count <> cardinality(v_ids) then
      return 'En av populasjonene i oppgaven finnes ikke i katalogen.';
    end if;
    return null;
  end if;

  if p_job.agent_role = 'monograph_answer' then
    -- Behovet, materialet og den godkjente bruken. Uten alle tre ville
    -- oppgaven ikke kunnet utføres, og den skal da ikke stå i køen som noe
    -- som ventet på et menneske (ANTIDEP_CONSTITUTION.md regel 4).
    if workflow.manifest_uuid(v_manifest, 'monograph_need_id') is null
       or workflow.manifest_uuid(v_manifest, 'source_version_id') is null then
      return 'Oppgaven sier ikke hvilket kunnskapsbehov og hvilken kildeversjon svaret gjelder.';
    end if;
    if not exists (
      select 1 from knowledge.monograph_needs n
      where n.id = workflow.manifest_uuid(v_manifest, 'monograph_need_id')
        and n.relevance <> 'not_applicable'
    ) then
      return 'Kunnskapsbehovet finnes ikke, eller er avgjort som ikke relevant.';
    end if;
    if not exists (
      select 1 from knowledge.monograph_source_uses u
      where u.need_id = workflow.manifest_uuid(v_manifest, 'monograph_need_id')
        and u.source_version_id = workflow.manifest_uuid(v_manifest, 'source_version_id')
    ) then
      return 'Kildeversjonen er ikke godkjent for dette kunnskapsbehovet.';
    end if;
    if knowledge.source_version_text(
         workflow.manifest_uuid(v_manifest, 'source_version_id')) is null then
      return 'Kildeversjonen har ingen registrert representasjon å lese opplysningen ut av.';
    end if;
    return null;
  end if;

  if p_job.agent_role = 'claim_synthesis' then
    if workflow.manifest_uuid(v_manifest, 'topic_concept_id') is null
       or workflow.manifest_uuid(v_manifest, 'subject_drug_id') is null then
      return 'Oppgaven sier ikke hvilket tema og virkestoff påstanden skal gjelde.';
    end if;
    -- Katalogverdiene må finnes, og ikke bare ha formen. Uten dette ville
    -- oppgaven blitt bygget av et tomt oppslag, og feilen kommet først når et
    -- ferdig svar ikke lot seg registrere.
    if not exists (
      select 1 from catalog.clinical_concepts c
      where c.id = workflow.manifest_uuid(v_manifest, 'topic_concept_id')
        and c.concept_type = 'outcome'
    ) then
      return 'Temaet oppgaven gjelder, finnes ikke som et endepunkt i katalogen.';
    end if;
    if not exists (
      select 1 from catalog.drugs d
      where d.id = workflow.manifest_uuid(v_manifest, 'subject_drug_id')
    ) then
      return 'Virkestoffet oppgaven gjelder, finnes ikke i katalogen.';
    end if;
    v_ids := workflow.manifest_uuids(v_manifest, 'evidence_item_ids');
    if v_ids is null or cardinality(v_ids) = 0 then
      return 'Oppgaven sier ikke hvilke evidensfunn syntesen skal bygge på.';
    end if;

    -- Kontrollnivået evidensen må ha nådd, lest med skriveveiens egen funksjon.
    -- Et funn uten bekreftet ekstraksjonskontroll — eller med et senere åpent
    -- avvik — kan ikke bære en påstand, og det er like sant før oppgaven hentes
    -- ut som etter at svaret er skrevet.
    return workflow.evidence_usable_problem(
      v_ids, 'Evidensgrunnlaget er ikke klart for en syntese ennå');
  end if;

  if p_job.agent_role = 'evidence_assessment' then
    v_revision_id := workflow.manifest_uuid(v_manifest, 'claim_revision_id');
    if v_revision_id is null then
      return 'Oppgaven sier ikke hvilken påstandsrevisjon den gjelder.';
    end if;

    select r.knowledge_type, c.retired_at into v_knowledge_type, v_retired_at
    from knowledge.claim_revisions r
    join knowledge.claims c on c.id = r.claim_id
    where r.id = v_revision_id;

    if not found then
      return 'Påstandsrevisjonen oppgaven gjelder, finnes ikke.';
    end if;
    if v_knowledge_type <> 'evidence_synthesis' then
      return 'Påstanden er ikke en evidenssyntese, og skal ikke graderes. En klinisk anbefaling og et deterministisk faktum har ingen evidensvurdering.';
    end if;
    if v_retired_at is not null then
      return 'Påstanden er trukket tilbake, og skal ikke vurderes.';
    end if;
    if exists (
      select 1 from knowledge.evidence_assessments a
      where a.claim_revision_id = v_revision_id
    ) then
      return 'Påstanden er allerede vurdert. En endret vurdering av det samme grunnlaget er en ny påstandsformulering, ikke en overskriving.';
    end if;
    if not exists (
      select 1 from workflow.claim_verifications v
      where v.claim_revision_id = v_revision_id
    ) then
      return 'Påstanden er ikke kildestøttekontrollert ennå. Evidensvurderingen kommer etter den kontrollen.';
    end if;

    select array_agg(distinct l.evidence_item_id) into v_ids
    from knowledge.claim_evidence_links l
    where l.claim_revision_id = v_revision_id;

    if v_ids is null then
      return 'Påstanden har ingen evidenslenker, og det finnes ikke noe grunnlag å vurdere.';
    end if;

    -- De samme to vilkårene skriveveien leser på vurderingstidspunktet, i den
    -- samme rekkefølgen: grunnlaget må fortsatt kunne bære påstanden, og
    -- kildestøttekontrollen må være gjeldende, bekreftet og gjort av noen med
    -- mandat — på nøyaktig det evidenssettet som ligger der nå.
    return coalesce(
      workflow.evidence_usable_problem(
        v_ids, 'Evidensgrunnlaget bak påstanden er ikke lenger brukbart'),
      workflow.claim_verified_problem(
        v_revision_id, 'Kildestøttekontrollen av påstanden holder ikke'));
  end if;

  if p_job.agent_role in ('source_discovery', 'source_quality_assessment') then
    v_plan_id := workflow.manifest_uuid(v_manifest, 'search_plan_id');
    if v_plan_id is null then
      return 'Oppgaven sier ikke hvilken søkeplan den gjelder.';
    end if;

    select p.* into v_plan
    from workflow.monograph_search_plans p where p.id = v_plan_id;
    if not found then
      return 'Søkeplanen oppgaven gjelder, finnes ikke.';
    end if;

    if (v_manifest ->> 'plan_version')::integer is distinct from v_plan.plan_version then
      return 'Søkeplanen har fått en ny versjon siden oppgaven ble lagt inn. Arbeidet hører til den nye versjonen.';
    end if;

    if v_plan.closed_at is not null then
      return 'Søkedekningen for denne planen er allerede erklært ferdig.';
    end if;

    if v_plan.paused_at is not null then
      return format('Søket står på pause: %s', v_plan.paused_reason);
    end if;

    if not exists (
      select 1 from workflow.monograph_search_plan_needs pn where pn.plan_id = v_plan_id
    ) then
      return 'Søkeplanen dekker ikke noe kunnskapsbehov, og det finnes ikke noe spørsmål å søke etter.';
    end if;

    if p_job.agent_role = 'source_quality_assessment' then
      -- Kontrollen kontrollerer et søk. Uten et utført søk å kontrollere ville
      -- den vurdert en dekning som ikke finnes (SOURCE_POLICY.md §6).
      if not exists (
        select 1 from workflow.monograph_searches s
        where s.plan_id = v_plan_id
          and s.plan_version = v_plan.plan_version
          and s.outcome in ('executed', 'zero_results')
      ) then
        return 'Ingen søk er utført på denne planversjonen ennå, så det finnes ingen søkedekning å kontrollere.';
      end if;

      if exists (
        select 1 from workflow.monograph_coverage_controls cc
        where cc.plan_id = v_plan_id and cc.plan_version = v_plan.plan_version
      ) then
        return 'Denne planversjonen er allerede dekningskontrollert. Skal dekningen kontrolleres på nytt, er planen blitt en annen.';
      end if;
    end if;

    return null;
  end if;

  return format('Rollen %s har ingen oppgaveform ennå.', p_job.agent_role);
end;
$function$;

CREATE OR REPLACE FUNCTION workflow.agent_task(p_job workflow.pipeline_jobs)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_manifest jsonb := p_job.input_manifest;
  v_contract jsonb := workflow.agent_task_contract(p_job.agent_role);
  v_binding jsonb;
  v_input jsonb;
  v_subject jsonb;
  v_ignored jsonb;
  v_prior jsonb := '[]'::jsonb;
  v_model provenance.role_model_assignments;
  v_source_version_id uuid;
  v_revision_id uuid;
  v_evidence_ids uuid[];
  v_drug_ids uuid[];
  v_outcome_ids uuid[];
  v_population_ids uuid[];
  v_plan_id uuid;
begin
  if p_job.agent_role = 'evidence_extraction' then
    v_source_version_id := workflow.manifest_uuid(v_manifest, 'source_version_id');
    v_drug_ids := workflow.manifest_uuids(v_manifest, 'drug_ids');
    v_outcome_ids := workflow.manifest_uuids(v_manifest, 'outcome_concept_ids');
    v_population_ids := coalesce(workflow.manifest_uuids(v_manifest, 'population_ids'), array[]::uuid[]);

    select jsonb_build_object(
             'source_id', sv.source_id,
             'source_version_id', sv.id,
             'content_hash', sv.content_hash,
             'representation', sv.representation::text,
             'document_sha256', sv.document_sha256,
             'drug_ids', to_jsonb(v_drug_ids),
             'outcome_concept_ids', to_jsonb(v_outcome_ids),
             'population_ids', to_jsonb(v_population_ids)
           ),
           jsonb_build_object(
             'source', jsonb_build_object(
               'source_id', s.id,
               'title', s.title,
               'authors_or_issuer', s.authors_or_issuer,
               'publisher_or_journal', s.publisher_or_journal,
               'publication_date', s.publication_date,
               'source_type', s.source_type::text
             ),
             'source_version', jsonb_build_object(
               'source_version_id', sv.id,
               'retrieved_from', sv.retrieved_from,
               'retrieved_at', sv.retrieved_at,
               'content_hash', sv.content_hash,
               'representation', sv.representation::text,
               'document_sha256', sv.document_sha256
             ),
             'representation_text', knowledge.source_version_text(sv.id),
             'drugs', (
               select coalesce(jsonb_agg(jsonb_build_object(
                        'drug_id', d.id, 'label', d.canonical_name) order by d.canonical_name), '[]'::jsonb)
               from catalog.drugs d where d.id = any (v_drug_ids)
             ),
             'outcomes', (
               select coalesce(jsonb_agg(jsonb_build_object(
                        'outcome_concept_id', c.id, 'label', c.canonical_label) order by c.canonical_label), '[]'::jsonb)
               from catalog.clinical_concepts c where c.id = any (v_outcome_ids)
             ),
             'populations', (
               select coalesce(jsonb_agg(jsonb_build_object(
                        'population_id', p.id, 'label', p.canonical_label) order by p.canonical_label), '[]'::jsonb)
               from catalog.populations p where p.id = any (v_population_ids)
             )
           ),
           null::jsonb
      into v_binding, v_input, v_ignored
    from knowledge.source_versions sv
    join knowledge.sources s on s.id = sv.source_id
    where sv.id = v_source_version_id;

  elsif p_job.agent_role = 'claim_synthesis' then
    v_evidence_ids := workflow.manifest_uuids(v_manifest, 'evidence_item_ids');

    select jsonb_build_object(
             'topic_concept_id', workflow.manifest_uuid(v_manifest, 'topic_concept_id'),
             'subject_drug_id', workflow.manifest_uuid(v_manifest, 'subject_drug_id'),
             'claim_id', workflow.manifest_uuid(v_manifest, 'claim_id'),
             'monograph_need_id',
               workflow.manifest_uuid(v_manifest, 'monograph_need_id'),
             'population_ids', to_jsonb(coalesce(
               workflow.manifest_uuids(v_manifest, 'population_ids'), array[]::uuid[])),
             'evidence', (
               select coalesce(jsonb_agg(
                 jsonb_build_object('evidence_item_id', e.id, 'content_hash', e.content_hash)
                 order by e.id::text), '[]'::jsonb)
               from knowledge.evidence_items e where e.id = any (v_evidence_ids)
             )
           ),
           jsonb_build_object(
             'topic', jsonb_build_object(
               'topic_concept_id', c.id, 'label', c.canonical_label),
             'subject_drug', jsonb_build_object(
               'drug_id', d.id, 'label', d.canonical_name),
             'claim_id', workflow.manifest_uuid(v_manifest, 'claim_id'),
             -- Spørsmålet syntesen svarer på, ordrett fra standarden, med
             -- avgrensningen behovet har. Uten det ville agenten fått et
             -- grunnlag uten å få vite hvilket spørsmål det er grunnlag for
             -- (MONOGRAPH_STANDARD.md §2).
             'monograph_need', knowledge.monograph_need_brief(
               workflow.manifest_uuid(v_manifest, 'monograph_need_id')),
             'populations', (
               select coalesce(jsonb_agg(jsonb_build_object(
                        'population_id', p.id, 'label', p.canonical_label) order by p.canonical_label), '[]'::jsonb)
               from catalog.populations p
               where p.id = any (coalesce(
                 workflow.manifest_uuids(v_manifest, 'population_ids'), array[]::uuid[]))
             ),
             'evidence', (
               select coalesce(jsonb_agg(workflow.evidence_extraction_dossier(e.id) order by e.id::text), '[]'::jsonb)
               from knowledge.evidence_items e where e.id = any (v_evidence_ids)
             )
           ),
           null::jsonb
      into v_binding, v_input, v_ignored
    from catalog.clinical_concepts c, catalog.drugs d
    where c.id = workflow.manifest_uuid(v_manifest, 'topic_concept_id')
      and d.id = workflow.manifest_uuid(v_manifest, 'subject_drug_id');

    select coalesce(jsonb_agg(
             jsonb_build_object('role', r.agent_role::text, 'agent_run_id', r.id)
             order by r.id::text), '[]'::jsonb)
      into v_prior
    from knowledge.evidence_items e
    join provenance.agent_runs r on r.id = e.agent_run_id
    where e.id = any (v_evidence_ids);

  elsif p_job.agent_role = 'monograph_answer' then
    -- Bindingen er behovet, avgrensningsavtrykket og kildeversjonen. Kommer
    -- det en ny kildeversjon eller endrer avgrensningen seg imellom, får
    -- oppgaven et nytt avtrykk, og et svar avgitt på det gamle grunnlaget kan
    -- ikke importeres (ANTIDEP_CONSTITUTION.md regel 5).
    v_source_version_id := workflow.manifest_uuid(v_manifest, 'source_version_id');

    select jsonb_build_object(
             'monograph_need_id', n.id,
             'scope_digest', n.scope_digest,
             'source_version_id', sv.id,
             'content_hash', sv.content_hash,
             'representation', sv.representation::text
           ),
           jsonb_build_object(
             'need', knowledge.monograph_need_brief(n.id),
             'approved_use', (
               select u.approved_use from knowledge.monograph_source_uses u
               where u.need_id = n.id and u.source_version_id = sv.id),
             'drug', (select d.canonical_name from catalog.drugs d
                      join knowledge.monograph_editions e on e.id = n.edition_id
                      where d.id = e.drug_id),
             'source', jsonb_build_object(
               'title', s.title,
               'authors_or_issuer', s.authors_or_issuer,
               'publisher_or_journal', s.publisher_or_journal,
               'source_type', s.source_type::text,
               'publication_date', s.publication_date),
             'source_version', jsonb_build_object(
               'retrieved_from', sv.retrieved_from,
               'retrieved_at', sv.retrieved_at,
               'representation', sv.representation::text,
               'content_hash', sv.content_hash),
             'representation_text', knowledge.source_version_text(sv.id)
           ),
           null::jsonb
      into v_binding, v_input, v_ignored
    from knowledge.monograph_needs n,
         knowledge.source_versions sv
         join knowledge.sources s on s.id = sv.source_id
    where n.id = workflow.manifest_uuid(v_manifest, 'monograph_need_id')
      and sv.id = v_source_version_id;

  elsif p_job.agent_role in ('source_discovery', 'source_quality_assessment') then
    v_plan_id := workflow.manifest_uuid(v_manifest, 'search_plan_id');

    -- Bindingen er søkeplanen, dens versjon, avgrensningsavtrykket, profilen og
    -- de behovene planen dekket da oppgaven ble bygget — og hvor langt søket
    -- var kommet. Kommer det et nytt søk eller en ny kandidat imellom, får
    -- oppgaven et nytt avtrykk, og et svar avgitt på det gamle grunnlaget kan
    -- ikke importeres (ANTIDEP_CONSTITUTION.md regel 5).
    select jsonb_build_object(
             'search_plan_id', p.id,
             'plan_version', p.plan_version,
             'profile_code', sp.code,
             'scope_digest', p.scope_digest,
             'need_ids', (
               select coalesce(jsonb_agg(pn.need_id order by pn.need_id::text), '[]'::jsonb)
               from workflow.monograph_search_plan_needs pn where pn.plan_id = p.id),
             'searches_seen', coalesce((
               select max(s.registration_ordinal) from workflow.monograph_searches s
               where s.plan_id = p.id and s.plan_version = p.plan_version), 0),
             'candidates_seen', (
               select count(*) from workflow.monograph_candidate_sources c
               where c.plan_id = p.id)
           ),
           workflow.monograph_discovery_task_input(p.id, p_job.agent_role),
           null::jsonb
      into v_binding, v_input, v_ignored
    from workflow.monograph_search_plans p
    join knowledge.monograph_source_profiles sp on sp.id = p.profile_id
    where p.id = v_plan_id;

    -- Kontrollen hviler på generatorens kjøringer, og de står i bindingen:
    -- et svar kan bekrefte hvilke kjøringer det kontrollerte, men ikke velge
    -- dem.
    if p_job.agent_role = 'source_quality_assessment' then
      select coalesce(jsonb_agg(
               jsonb_build_object('role', r.agent_role::text, 'agent_run_id', r.id)
               order by r.id::text), '[]'::jsonb)
        into v_prior
      from workflow.monograph_searches s
      join provenance.agent_runs r on r.id = s.agent_run_id
      where s.plan_id = v_plan_id and s.plan_version = (
        select p.plan_version from workflow.monograph_search_plans p where p.id = v_plan_id);
    end if;

  elsif p_job.agent_role = 'evidence_assessment' then
    v_revision_id := workflow.manifest_uuid(v_manifest, 'claim_revision_id');

    select jsonb_build_object(
             'claim_revision_id', r.id,
             'revision_content_hash', r.content_hash,
             'evidence_set_digest', knowledge.claim_evidence_set_digest(r.id)
           ),
           jsonb_build_object(
             'dossier', workflow.claim_evidence_dossier(r.id),
             'seen_evidence_set_digest', knowledge.claim_evidence_set_digest(r.id)
           ),
           null::jsonb
      into v_binding, v_input, v_ignored
    from knowledge.claim_revisions r
    where r.id = v_revision_id;

    select coalesce(jsonb_agg(
             jsonb_build_object('role', x.role, 'agent_run_id', x.run_id)
             order by x.role, x.run_id::text), '[]'::jsonb)
      into v_prior
    from (
      select r.agent_role::text as role, r.id as run_id
      from knowledge.claim_revisions cr
      join provenance.agent_runs r on r.id = cr.agent_run_id
      where cr.id = v_revision_id
      union all
      select r.agent_role::text, r.id
      from workflow.claim_verifications v
      join provenance.agent_runs r on r.id = v.agent_run_id
      where v.claim_revision_id = v_revision_id
    ) x;
  else
    -- Uttømmende over rollene som kan settes ut. En rolle uten en gren ville
    -- ellers gitt en oppgave uten inndata, og et svar bundet til ingenting.
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Rollen %s har ingen oppgaveform.', p_job.agent_role);
  end if;

  v_subject := workflow.agent_task_subject(p_job);
  v_model := provenance.current_semantic_model(p_job.agent_role);

  v_binding := jsonb_build_object(
    'task_version', workflow.agent_handoff_task_version(),
    'role', p_job.agent_role::text,
    'job_key', p_job.job_key,
    'pipeline_job_id', p_job.id,
    'prompt_template_version', v_contract ->> 'prompt_template_version',
    'output_schema_version', v_contract ->> 'output_schema_version',
    -- Tildelingen er en del av det som binder svaret. Byttes modellen, får hver
    -- utestående oppgave et nytt avtrykk, og et svar avgitt under den gamle
    -- tildelingen kan ikke komme tilbake og registrere den gamle modellen på
    -- nytt (ANTIDEP_CONSTITUTION.md regel 3). Tildelingens id står med, fordi to
    -- tildelinger av den samme modellen er to avgjørelser.
    'semantic_model', case when v_model.id is null then null else jsonb_build_object(
      'assignment_id', v_model.id,
      'provider', v_model.provider,
      'model', v_model.model,
      'model_version', v_model.model_version,
      'model_version_disclosure', v_model.model_version_disclosure::text
    ) end,
    'input', v_binding,
    'prior_runs', v_prior
  );

  return jsonb_build_object(
    'task_version', workflow.agent_handoff_task_version(),
    'answer_version', workflow.agent_handoff_answer_version(),
    'pipeline_job_id', p_job.id,
    'job_key', p_job.job_key,
    'role', p_job.agent_role::text,
    'prompt_template_version', v_contract ->> 'prompt_template_version',
    'output_schema_version', v_contract ->> 'output_schema_version',
    'request_digest', workflow.agent_task_digest(v_binding),
    'binding', v_binding,
    'subject', v_subject,
    'registered_model', case when v_model.id is null then null else jsonb_build_object(
      'provider', v_model.provider,
      'model', v_model.model,
      'model_version', v_model.model_version,
      'model_version_disclosure', v_model.model_version_disclosure::text
    ) end,
    'input', v_input
  );
end;
$function$;
CREATE OR REPLACE FUNCTION workflow.record_agent_handoff_answer(p_pipeline_job_id uuid, p_answer jsonb, p_actor_id uuid, p_runner_connection_id uuid, p_lease_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_actor_id uuid;
  v_attempt integer;
  v_job workflow.pipeline_jobs;
  v_problem text;
  v_task jsonb;
  v_binding jsonb;
  v_input jsonb;
  v_answer_digest text;
  v_existing workflow.agent_handoff_imports;
  v_identity jsonb;
  v_provider text;
  v_model text;
  v_model_version text;
  v_disclosure provenance.model_version_disclosure;
  v_answered_at timestamptz;
  v_result jsonb;
  v_unknown text;
  v_agent_identity provenance.agent_identities;
  v_agent_actor_id uuid;
  v_registration provenance.role_model_assignments;
  v_semantic provenance.role_model_assignments;
  v_lease uuid;
  v_run_id uuid;
  v_outcome jsonb;
  v_extraction jsonb;
  v_claim jsonb;
  v_assessment jsonb;
  v_evidence_item_id uuid;
  v_ids uuid[];
  v_id uuid;
begin
  -- Kalleren har allerede fastslått hvem dette er: en redaktør med mandat i den
  -- manuelle veien, eller den registrerte kjørertilkoblingens egen registrant i
  -- den autonome. Autentiseringen hører i api-funksjonen, arbeidet her.
  v_actor_id := p_actor_id;

  select j.* into v_job
  from workflow.pipeline_jobs j
  where j.id = p_pipeline_job_id
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = format('Det finnes ingen agentoppgave med id %L.', p_pipeline_job_id);
  end if;

  -- ------------------------------------------------------------------
  -- Gjentakelsen først, før alt annet
  --
  -- Det samme svaret sendt inn igjen — et dobbeltklikk, en gjenopptatt
  -- økt — skal svare med det som allerede ble registrert, framfor å lage
  -- et nytt klinisk objekt. Et *annet* svar på en jobb som allerede er
  -- besvart, er ikke en gjentakelse, og avvises.
  -- ------------------------------------------------------------------
  v_answer_digest := 'sha256:' || encode(sha256(convert_to(p_answer::text, 'UTF8')), 'hex');

  select i.* into v_existing
  from workflow.agent_handoff_imports i
  where i.pipeline_job_id = p_pipeline_job_id;

  if found then
    if v_existing.answer_digest = v_answer_digest then
      return jsonb_build_object(
        'imported', false,
        'already_imported', true,
        'delivered_by', case when v_existing.runner_connection_id is null
                             then 'manual' else 'autonomous_runner' end,
        'pipeline_job_id', p_pipeline_job_id,
        'agent_role', v_existing.agent_role::text,
        'agent_run_id', v_existing.agent_run_id,
        'outcome', v_existing.outcome
      );
    end if;
    raise exception using
      errcode = 'unique_violation',
      message = 'Denne agentoppgaven har allerede tatt imot et annet svar.',
      hint = 'Ett svar per oppgave. To svar ville gitt to kliniske objekter for det samme arbeidet, og ingen ville kunnet si hvilket som gjaldt (ANTIDEP_CONSTITUTION.md regel 4). Skal arbeidet gjøres om igjen, er det en ny oppgave.';
  end if;

  if v_job.state = 'succeeded' then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Agentoppgaven er allerede fullført.',
      hint = 'Jobben har et registrert utfall fra før. Skal arbeidet gjøres om igjen, er det en ny oppgave.';
  end if;
  -- Uttaket, før alt annet som handler om jobbens tilstand.
  --
  -- Den manuelle veien tar selv et uttak, som før. Den autonome kommer med et
  -- uttak den allerede holder, og det uttaket er svarets eneste adgangstegn: et
  -- håndtak som ikke er jobbens gjeldende leie, er et foreldet svar fra en
  -- kjøring som er overtatt eller har løpt ut, og det skal avvises før noe
  -- skrives (ANTIDEP_CONSTITUTION.md regel 4, 7).
  if p_lease_token is not null then
    if v_job.state <> 'leased'
       or v_job.lease_token is distinct from p_lease_token
       or v_job.lease_expires_at is null
       or v_job.lease_expires_at <= statement_timestamp() then
      raise exception using
        errcode = 'restrict_violation',
        message = 'Uttaket dette svaret ble gjort under, gjelder ikke lenger.',
        hint = 'Leien er løpt ut eller overtatt av en annen kjøring. Hent arbeid på nytt framfor å levere et svar på et uttak som ikke er ditt; et svar fra et foreldet uttak ville kunnet skrive over arbeidet en annen kjøring nettopp gjorde.';
    end if;
    v_attempt := v_job.attempts;
    v_lease := p_lease_token;
  else
    if v_job.attempts >= v_job.max_attempts then
      raise exception using
        errcode = 'restrict_violation',
        message = 'Agentoppgaven har brukt opp forsøkene sine og blir stående.',
        hint = 'En oppbrukt jobb skal ikke se ut som en jobb som fortsatt er underveis (ANTIDEP_CONSTITUTION.md regel 4). Legg inn oppgaven på nytt dersom den skal forsøkes igjen.';
    end if;
    v_attempt := v_job.attempts + 1;
    v_lease := gen_random_uuid();
  end if;

  v_problem := workflow.agent_task_problem(v_job, p_lease_token);
  if v_problem is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = v_problem;
  end if;

  -- ------------------------------------------------------------------
  -- Formen på svaret, og bindingen
  -- ------------------------------------------------------------------
  if p_answer is null or jsonb_typeof(p_answer) <> 'object' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Svaret er ikke et JSON-objekt.';
  end if;

  select string_agg(quote_literal(k.value), ', ' order by k.value) into v_unknown
  from jsonb_object_keys(p_answer) as k(value)
  where k.value not in (
    'answer_version', 'task_version', 'role', 'job_key', 'request_digest',
    'output_schema_version', 'identity', 'answered_at', 'result'
  );
  if v_unknown is not null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Svaret har felter denne kontrakten ikke kjenner: %s.', v_unknown),
      hint = 'Ukjente felter avvises framfor å ignoreres: et felt med skrivefeil ville ellers sett ut som en utelatt opplysning, og et felt ingen leser, ville vært en påstand uten virkning.';
  end if;

  v_task := workflow.agent_task(v_job);
  v_binding := v_task -> 'binding';
  v_input := v_binding -> 'input';

  if p_answer ->> 'answer_version' is distinct from workflow.agent_handoff_answer_version() then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Svaret er skrevet mot %L, men Antidep leser %L.',
        p_answer ->> 'answer_version', workflow.agent_handoff_answer_version());
  end if;
  if p_answer ->> 'task_version' is distinct from workflow.agent_handoff_task_version() then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Svaret gjelder oppgaveformen %L, men denne oppgaven er %L.',
        p_answer ->> 'task_version', workflow.agent_handoff_task_version());
  end if;
  if p_answer ->> 'role' is distinct from v_job.agent_role::text then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Svaret er avgitt i rollen %L, mens oppgaven gjelder rollen %L.',
        p_answer ->> 'role', v_job.agent_role::text),
      hint = 'Rollen avgjør hva svaret får lov til å registrere. Et svar fra ett ledd skal ikke kunne lukkes inn i et annet.';
  end if;
  if p_answer ->> 'job_key' is distinct from v_job.job_key then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Svaret gjelder en annen agentoppgave enn den det importeres på.';
  end if;
  if p_answer ->> 'output_schema_version' is distinct from (v_task ->> 'output_schema_version') then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Svaret er skrevet mot svarformen %L, mens oppgaven krever %L.',
        p_answer ->> 'output_schema_version', v_task ->> 'output_schema_version');
  end if;
  if p_answer ->> 'request_digest' is distinct from (v_task ->> 'request_digest') then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format(
        'Svaret er avgitt på forespørselen %s, mens oppgaven nå er %s.',
        coalesce(p_answer ->> 'request_digest', '(mangler)'), v_task ->> 'request_digest'),
      hint = 'Avtrykket dekker rollen, oppgaven, promptmalen, svarformen og hele grunnlaget oppgaven ble bygget av. Er noe av det endret siden oppgaven ble hentet ut, gjelder ikke det gamle svaret lenger. Hent oppgaven på nytt og be om et nytt svar (ANTIDEP_CONSTITUTION.md regel 2, 4).';
  end if;

  v_result := p_answer -> 'result';
  if v_result is null or jsonb_typeof(v_result) <> 'object' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Svaret har ingen result som er et JSON-objekt.';
  end if;

  -- ------------------------------------------------------------------
  -- Hvem som svarte
  -- ------------------------------------------------------------------
  v_identity := p_answer -> 'identity';
  if v_identity is null or jsonb_typeof(v_identity) <> 'object' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Svaret sier ikke hvilken modell som utførte oppgaven.',
      hint = 'identity skal ha provider, model og model_version_disclosure — og model_version når tjenesten faktisk oppgir en versjon. Uten den kan ingen si om kontrollene i kjeden er uavhengige (ANTIDEP_CONSTITUTION.md regel 3).';
  end if;

  select string_agg(quote_literal(k.value), ', ' order by k.value) into v_unknown
  from jsonb_object_keys(v_identity) as k(value)
  where k.value not in ('provider', 'model', 'model_version', 'model_version_disclosure');
  if v_unknown is not null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('identity har felter denne kontrakten ikke kjenner: %s.', v_unknown);
  end if;

  -- Den samme lesningen tildelingen ble gjort med, slik at «samme modell» betyr
  -- det samme begge steder.
  v_identity := provenance.canonical_model_identity(
    v_identity ->> 'provider',
    v_identity ->> 'model',
    v_identity ->> 'model_version',
    v_identity ->> 'model_version_disclosure'
  );
  v_provider := v_identity ->> 'provider';
  v_model := v_identity ->> 'model';
  v_model_version := v_identity ->> 'model_version';
  v_disclosure := (v_identity ->> 'model_version_disclosure')::provenance.model_version_disclosure;

  -- Svaret bekrefter identiteten sin; det etablerer den ikke. Tildelingen er
  -- tatt på forhånd av en redaktør med mandat, den står i bindingen avtrykket er
  -- regnet av, og et svar fra en annen modell avvises her — før noe skrives. Et
  -- svar som fikk registrere sin egen identitet, ville etablert premisset som
  -- autoriserte det selv, og separasjonen mellom leddene ville hvilt på en
  -- erklæring modellen avga om seg selv (ANTIDEP_CONSTITUTION.md regel 3).
  v_semantic := provenance.require_semantic_model_assignment(v_job.agent_role, v_identity);

  if p_answer ->> 'answered_at' is not null then
    begin
      v_answered_at := (p_answer ->> 'answered_at')::timestamptz;
    exception
      when others then
        raise exception using
          errcode = 'invalid_parameter_value',
          message = format('answered_at er %L, som ikke er et tidspunkt.', p_answer ->> 'answered_at');
    end;

    -- Et svar kan ikke være avgitt i framtiden. Slakken finnes fordi agenten
    -- kjører på en annen maskin med en annen klokke, og et tidspunkt avrundet
    -- til nærmeste minutt ikke er en usann påstand; uten den ville en riktig
    -- import blitt stoppet av tre sekunder, og kontrollen blitt skrudd av
    -- framfor fulgt. Samme regel og samme slakk som i den filbaserte kjøringen.
    if v_answered_at > statement_timestamp() + interval '5 minutes'
       or v_answered_at < v_job.enqueued_at - interval '5 minutes' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format(
          'answered_at er %L, som ligger utenfor oppgaven: den ble lagt inn %L og importeres nå.',
          v_answered_at, v_job.enqueued_at
        ),
        hint = 'Tidspunktet registreres som da agenten svarte. Et svar avgitt før oppgaven fantes, eller inn i framtiden, er ikke en unøyaktighet — det er en usann proveniens (ANTIDEP_CONSTITUTION.md regel 4). La feltet stå tomt om du er usikker.';
    end if;
  end if;

  -- ------------------------------------------------------------------
  -- Uttaket og kjøringen
  --
  -- Importen gjør det en kjører ville gjort: tar ut jobben med en leie i
  -- rollens egen agentidentitet, åpner kjøringen for nettopp det uttaket, og
  -- melder utfallet. Da gjelder de samme bindingene og de samme reglene som
  -- for et automatisert ledd — inkludert at kjøringen ikke kan gjenbrukes på
  -- en annen jobb.
  -- ------------------------------------------------------------------
  select ai.* into v_agent_identity
  from provenance.agent_identities ai
  where ai.agent_role = v_job.agent_role
    and ai.valid_from <= statement_timestamp()
    and (ai.valid_to is null or ai.valid_to > statement_timestamp())
  order by ai.valid_from
  limit 1;

  if v_agent_identity.id is null then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Rollen %L har ingen gyldig agentidentitet å registrere kjøringen under.', v_job.agent_role);
  end if;
  v_agent_actor_id := v_agent_identity.actor_id;

  v_registration := provenance.current_role_model(v_job.agent_role);
  if v_registration.id is null then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Rollen %L har ingen gyldig modelltildeling for registreringsleddet.', v_job.agent_role);
  end if;

  -- Den manuelle veien tar uttaket her; den autonome tok det da den hentet
  -- arbeidet, og skal ikke ta det en gang til — et nytt uttak ville talt et
  -- forsøk som aldri fant sted, og byttet ut nøkkelen midt i sitt eget svar.
  if p_lease_token is null then
    update workflow.pipeline_jobs
    set state = 'leased',
        attempts = v_attempt,
        leased_by_agent_identity_id = v_agent_identity.id,
        lease_expires_at = statement_timestamp() + interval '15 minutes',
        lease_token = v_lease,
        -- Uttaket er et menneskes. Sto det en kjører på raden fra et uttak som
        -- rakk å løpe ut, er den ikke lenger holderen, og skal ikke bli stående
        -- som om den var det.
        runner_connection_id = null,
        -- En jobb som sto som failed, bærer et fullføringstidspunkt. Uttaket er
        -- et nytt forsøk, og et forsøk som pågår, er ikke fullført.
        completed_at = null
    where id = v_job.id;

    perform workflow.record_pipeline_job_event(
      v_job.id, v_job.state, 'leased'::workflow.pipeline_job_state,
      v_attempt, v_actor_id, null,
      'Uttak for import av et eksternt agentsvar.'
    );
  end if;

  insert into provenance.agent_runs (
    agent_identity_id, actor_id, agent_role,
    provider, model, model_version, model_version_disclosure,
    semantic_provider, semantic_model, semantic_model_version,
    semantic_model_version_disclosure,
    prompt_template_version, pipeline_version,
    status, input_manifest, input_source_version_id
  )
  values (
    v_agent_identity.id, v_agent_actor_id, v_job.agent_role,
    v_registration.provider, v_registration.model, v_registration.model_version,
    v_registration.model_version_disclosure,
    v_provider, v_model, v_model_version, v_disclosure,
    v_task ->> 'prompt_template_version', 'antidep-evidence/1',
    'running',
    jsonb_build_object('handoff', jsonb_build_object(
      'task_version', v_task ->> 'task_version',
      'answer_version', v_task ->> 'answer_version',
      'request_digest', v_task ->> 'request_digest',
      'output_schema_version', v_task ->> 'output_schema_version',
      'answer_digest', v_answer_digest,
      'answered_at', v_answered_at,
      'imported_by_actor_id', v_actor_id,
      'binding', v_binding
    )),
    case when v_job.agent_role = 'evidence_extraction'
         then (v_input ->> 'source_version_id')::uuid end
  )
  returning id into v_run_id;

  insert into workflow.pipeline_job_runs (agent_run_id, pipeline_job_id, lease_token, attempt)
  values (v_run_id, v_job.id, v_lease, v_attempt);

  -- ------------------------------------------------------------------
  -- Arbeidet, gjennom de samme skriveveiene som agentkjørerne bruker
  -- ------------------------------------------------------------------
  if v_job.agent_role = 'evidence_extraction' then
    v_extraction := v_result -> 'extraction';
    if v_extraction is null or jsonb_typeof(v_extraction) <> 'object' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret har ingen extraction som er et JSON-objekt.';
    end if;

    -- Katalogen er redaktørens avgrensning, og modellen velger innenfor den.
    -- En id utenfor oppgaven ville flyttet funnet til et annet virkestoff eller
    -- et naboendepunkt, og den ordrette kontrollen kontrollerer utdrag — ikke
    -- avgrensning.
    v_ids := workflow.manifest_uuids(v_input, 'drug_ids');
    v_id := workflow.manifest_uuid(v_extraction, 'intervention_drug_id');
    if v_id is null or not (v_id = any (v_ids)) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret oppgir et virkestoff som ikke står blant virkestoffene i oppgaven.';
    end if;
    v_id := workflow.manifest_uuid(v_extraction, 'comparator_drug_id');
    if v_extraction ->> 'comparator_drug_id' is not null and (v_id is null or not (v_id = any (v_ids))) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret oppgir et komparatorvirkestoff som ikke står blant virkestoffene i oppgaven.';
    end if;
    v_ids := workflow.manifest_uuids(v_input, 'outcome_concept_ids');
    v_id := workflow.manifest_uuid(v_extraction, 'outcome_concept_id');
    if v_id is null or not (v_id = any (v_ids)) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret oppgir et endepunkt som ikke står blant endepunktene i oppgaven.';
    end if;
    v_ids := coalesce(workflow.manifest_uuids(v_input, 'population_ids'), array[]::uuid[]);
    v_id := workflow.manifest_uuid(v_extraction, 'population_id');
    if v_extraction ->> 'population_id' is not null and (v_id is null or not (v_id = any (v_ids))) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret oppgir en populasjon som ikke står blant populasjonene i oppgaven.';
    end if;

    v_evidence_item_id := knowledge.record_evidence_item(
      (v_input ->> 'source_id')::uuid,
      v_extraction ->> 'design_code',
      v_extraction ->> 'population_availability',
      v_extraction ->> 'population_detail',
      v_extraction ->> 'sample_size_availability',
      (v_extraction ->> 'intervention_drug_id')::uuid,
      v_extraction ->> 'comparator_kind',
      (v_extraction ->> 'outcome_concept_id')::uuid,
      v_extraction ->> 'outcome_detail',
      v_extraction ->> 'timepoint_availability',
      v_extraction ->> 'reported_direction',
      v_extraction ->> 'estimate_availability',
      v_extraction ->> 'confidence_interval_availability',
      v_extraction ->> 'source_locator',
      (v_input ->> 'source_version_id')::uuid,
      workflow.manifest_uuid(v_extraction, 'population_id'),
      (v_extraction ->> 'sample_size')::integer,
      v_extraction ->> 'intervention_detail',
      workflow.manifest_uuid(v_extraction, 'comparator_drug_id'),
      v_extraction ->> 'comparator_detail',
      v_extraction ->> 'timepoint_min',
      v_extraction ->> 'timepoint_max',
      v_extraction ->> 'effect_measure',
      (v_extraction ->> 'estimate')::numeric,
      v_extraction ->> 'estimate_unit',
      (v_extraction ->> 'ci_lower')::numeric,
      (v_extraction ->> 'ci_upper')::numeric,
      (v_extraction ->> 'ci_level_percent')::numeric,
      v_extraction ->> 'limitations_text',
      v_extraction ->> 'source_quote',
      v_result -> 'field_groundings',
      'ai_assisted',
      v_agent_actor_id,
      v_run_id
    );

    perform workflow.assert_extraction_fully_grounded(v_evidence_item_id);
    v_outcome := jsonb_build_object('evidence_item_id', v_evidence_item_id);

  elsif v_job.agent_role = 'claim_synthesis' then
    v_claim := v_result -> 'claim';
    if v_claim is null or jsonb_typeof(v_claim) <> 'object' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret har ingen claim som er et JSON-objekt.';
    end if;

    -- Evidenssettet er oppgavens, ikke svarets. En lenke til et funn utenfor
    -- oppgaven ville gitt en påstand som hvilte på noe ingen hadde avgrenset.
    if exists (
      select 1
      from jsonb_array_elements(coalesce(v_result -> 'evidence_links', '[]'::jsonb)) as link(value)
      where workflow.manifest_uuid(link.value, 'evidence_item_id') is null
         or not (workflow.manifest_uuid(link.value, 'evidence_item_id') = any (
              select (e.value ->> 'evidence_item_id')::uuid
              from jsonb_array_elements(v_input -> 'evidence') as e(value)))
    ) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret lenker til et evidensfunn som ikke står i oppgaven.',
        hint = 'Hvilke funn en syntese kan bygge på, er en faglig avgrensning som ligger i oppgaven. En modell som fikk velge fritt, ville kunnet bygge påstanden på noe ingen hadde tatt stilling til.';
    end if;

    -- Og hele settet, ikke en delmengde av det. Et svar som utelot et funn som
    -- MOTSIER påstanden, ville gitt en syntese som hvilte på et annet grunnlag
    -- enn det redaktøren avgrenset — og uenigheten ville vært borte uten at noe
    -- i kjeden sa fra (ANTIDEP_CONSTITUTION.md regel 4).
    if exists (
      select 1
      from jsonb_array_elements(v_input -> 'evidence') as assigned(value)
      where not exists (
        select 1
        from jsonb_array_elements(coalesce(v_result -> 'evidence_links', '[]'::jsonb)) as link(value)
        where link.value ->> 'evidence_item_id' = assigned.value ->> 'evidence_item_id'
      )
    ) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret dekker ikke alle evidensfunnene oppgaven avgrenset.',
        hint = 'Hvert funn i oppgaven skal ha en relasjon til påstanden — også et funn som motsier den, som da føres som contradicts. Et utelatt funn ville gjort grunnlaget til et annet enn det som finnes.';
    end if;

    -- Populasjonen er redaktørens avgrensning, som katalogen i et
    -- ekstraksjonsoppdrag. En id kopiert ut av dossieret ville passert
    -- fremmednøkkelen og flyttet påstanden til en annen populasjon.
    v_ids := coalesce(workflow.manifest_uuids(v_input, 'population_ids'), array[]::uuid[]);
    v_id := workflow.manifest_uuid(v_claim, 'population_id');
    if v_claim ->> 'population_id' is not null and (v_id is null or not (v_id = any (v_ids))) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret oppgir en populasjon som ikke står blant populasjonene i oppgaven.';
    end if;

    v_outcome := knowledge.record_agent_claim_synthesis(
      v_run_id,
      v_agent_actor_id,
      (v_input ->> 'topic_concept_id')::uuid,
      (v_input ->> 'subject_drug_id')::uuid,
      v_claim ->> 'statement',
      v_claim ->> 'scope',
      v_claim ->> 'comparator_kind',
      v_claim ->> 'uncertainty_summary',
      v_result -> 'evidence_links',
      workflow.manifest_uuid(v_input, 'claim_id'),
      workflow.manifest_uuid(v_claim, 'population_id'),
      v_claim ->> 'timeframe_min',
      v_claim ->> 'timeframe_max',
      workflow.manifest_uuid(v_claim, 'comparator_drug_id'),
      v_claim ->> 'direction',
      v_claim ->> 'magnitude_measure',
      (v_claim ->> 'magnitude_value')::numeric,
      v_claim ->> 'magnitude_unit',
      v_claim ->> 'qualifiers'
    );

  elsif v_job.agent_role = 'monograph_answer' then
    v_outcome := workflow.record_monograph_answer_handoff(
      v_job, v_input, v_result, v_run_id, v_agent_actor_id);

  elsif v_job.agent_role in ('source_discovery', 'source_quality_assessment') then
    v_outcome := workflow.record_monograph_discovery_answer(
      v_job, v_input, v_result, v_run_id, v_agent_actor_id);

  elsif v_job.agent_role = 'evidence_assessment' then
    v_assessment := v_result -> 'assessment';
    if v_assessment is null or jsonb_typeof(v_assessment) <> 'object' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret har ingen assessment som er et JSON-objekt.';
    end if;

    v_outcome := knowledge.record_evidence_assessment_row(
      v_run_id,
      v_agent_actor_id,
      (v_input ->> 'claim_revision_id')::uuid,
      -- Avtrykket av evidenssettet er oppgavens eget, ikke svarets: oppgaven
      -- viste nøyaktig det settet, og request_digest dekker det allerede. En
      -- verdi fra svaret ville vært en påstand om hva agenten så.
      v_input ->> 'evidence_set_digest',
      v_assessment ->> 'framework',
      v_assessment ->> 'certainty_level',
      v_assessment ->> 'rationale',
      v_assessment ->> 'risk_of_bias',
      v_assessment ->> 'inconsistency',
      v_assessment ->> 'indirectness',
      v_assessment ->> 'imprecision',
      v_assessment ->> 'publication_bias',
      v_assessment ->> 'other_considerations',
      v_assessment ->> 'evidence_gap'
    );

  else
    -- Uttømmende over rollene. En rolle uten en gren ville ellers fått
    -- oppgaven registrert som fullført uten at noe klinisk arbeid ble skrevet.
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Rollen %s har ingen skrivevei for et eksternt agentsvar.',
                       v_job.agent_role);
  end if;

  -- ------------------------------------------------------------------
  -- Utfallet
  -- ------------------------------------------------------------------
  update provenance.agent_runs
  set status = 'succeeded', completed_at = now(), output_manifest = v_outcome
  where id = v_run_id;

  update workflow.pipeline_jobs
  set state = 'succeeded',
      agent_run_id = v_run_id,
      output_manifest = v_outcome,
      completed_at = now(),
      failure_reason = null
  where id = v_job.id;

  perform workflow.record_pipeline_job_event(
    v_job.id, 'leased'::workflow.pipeline_job_state, 'succeeded'::workflow.pipeline_job_state,
    v_attempt, v_actor_id, null,
    case when p_runner_connection_id is null
      then 'Eksternt agentsvar importert og registrert.'
      else 'Eksternt agentsvar levert av en autonom kjører og registrert.' end
  );

  insert into workflow.agent_handoff_imports (
    pipeline_job_id, agent_role, request_digest, answer_digest,
    agent_run_id, imported_by_actor_id, answered_at, outcome,
    runner_connection_id
  )
  values (
    v_job.id, v_job.agent_role, v_task ->> 'request_digest', v_answer_digest,
    v_run_id, v_actor_id, v_answered_at, v_outcome,
    p_runner_connection_id
  );

  return jsonb_build_object(
    'imported', true,
    'already_imported', false,
    'delivered_by', case when p_runner_connection_id is null then 'manual' else 'autonomous_runner' end,
    'pipeline_job_id', v_job.id,
    'agent_role', v_job.agent_role::text,
    'agent_run_id', v_run_id,
    'request_digest', v_task ->> 'request_digest',
    'model', jsonb_build_object(
      'provider', v_provider, 'model', v_model,
      'model_version', v_model_version,
      'model_version_disclosure', v_disclosure::text),
    'outcome', v_outcome
  );
end;
$function$;

CREATE OR REPLACE FUNCTION api.resume_chain_transitions(p_identity_key text, p_secret text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  -- Grensen er en kostnadsgrense, og den avgjør i tillegg om passeringen nådde
  -- *enden* av leddet: færre rader enn grensen betyr at feiingen er rundt.
  -- Markøren (workflow.chain_reconciliation_cursors) gjør at neste passering
  -- fortsetter der denne slapp, slik at en grense ikke blir til sult.
  v_limit constant integer := workflow.chain_reconciliation_limit();
  v_identity provenance.agent_identities;
  v_row record;
  v_state text;
  v_queued integer := 0;
  v_candidates integer := 0;
  v_reviews integer := 0;
  v_acquisitions integer := 0;
  v_plans integer := 0;
  v_answers integer := 0;
  v_seen integer;
  v_failed boolean;
  v_position text;
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
  v_position := workflow.chain_cursor_position('ekstraksjonskontroll');
  for v_row in
    select e.id, e.id::text as sort_key
    from knowledge.evidence_items e
    where not exists (
      select 1 from workflow.pipeline_jobs j
      where j.agent_role = 'extraction_verification'::provenance.agent_role
        and j.job_key = workflow.control_job_key('ekstraksjon', e.id))
      and e.id::text > v_position
    order by e.id::text
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
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
  if workflow.chain_cursor_step(
       'ekstraksjonskontroll', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('ekstraksjonskontroll');
  end if;

  -- Synteseoppgaver som mangler.
  --
  -- Utvalget er de *subjektene* som mangler en oppgave, og ikke enhver
  -- kontrollert rad: ett subjekt er én oppgave, og uten avgrensningen ville
  -- passeringen brukt grensen sin på rader den allerede hadde gjort ferdig.
  -- Portene speiler overgangens egne — den gjeldende kontrollen er den siste, og
  -- et par som alt har en påstand, er ikke automatikkens å skrive om — slik at
  -- en rad som med rette står, ikke blir liggende i utvalget for alltid.
  v_seen := 0;
  v_failed := false;
  v_position := workflow.chain_cursor_position('syntese');
  for v_row in
    with gjeldende as (
      select distinct on (ev.evidence_item_id)
             ev.evidence_item_id, ev.outcome
      from workflow.evidence_verifications ev
      order by ev.evidence_item_id, ev.registration_ordinal desc
    ),
    utestaaende as (
      select e.intervention_drug_id as drug_id,
             e.outcome_concept_id as topic_id,
             min(e.id::text) as sort_key
      from knowledge.evidence_items e
      join gjeldende g on g.evidence_item_id = e.id and g.outcome = 'verified'
      where not exists (
        select 1 from knowledge.claims c
        where c.topic_concept_id = e.outcome_concept_id
          and c.subject_drug_id = e.intervention_drug_id)
      group by e.intervention_drug_id, e.outcome_concept_id
    )
    select u.sort_key::uuid as id, u.sort_key
    from utestaaende u
    where not workflow.agent_task_subject_queued(
            'claim_synthesis'::provenance.agent_role,
            format('%s+%s', u.drug_id, u.topic_id))
      and u.sort_key > v_position
    order by u.sort_key
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
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
  if workflow.chain_cursor_step('syntese', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('syntese');
  end if;

  -- Kildestøttekontroller som mangler.
  v_seen := 0;
  v_failed := false;
  v_position := workflow.chain_cursor_position('kildestottekontroll');
  for v_row in
    select r.id, r.id::text as sort_key
    from knowledge.claim_revisions r
    where not exists (
      select 1 from workflow.pipeline_jobs j
      where j.agent_role = 'citation_support_verification'::provenance.agent_role
        and j.job_key = workflow.control_job_key('kildestotte', r.id))
      and r.id::text > v_position
    order by r.id::text
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
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
  if workflow.chain_cursor_step(
       'kildestottekontroll', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('kildestottekontroll');
  end if;

  -- Evidensvurderinger som mangler. Som over: de revisjonene som faktisk mangler
  -- oppgaven, lest med den gjeldende kontrollen og ikke med en hvilken som helst.
  v_seen := 0;
  v_failed := false;
  v_position := workflow.chain_cursor_position('evidensvurdering');
  for v_row in
    with gjeldende as (
      select distinct on (cv.claim_revision_id)
             cv.claim_revision_id, cv.outcome
      from workflow.claim_verifications cv
      order by cv.claim_revision_id, cv.registration_ordinal desc
    )
    select g.claim_revision_id as id, g.claim_revision_id::text as sort_key
    from gjeldende g
    where g.outcome = 'verified'
      and not workflow.agent_task_subject_queued(
            'evidence_assessment'::provenance.agent_role, g.claim_revision_id::text)
      and g.claim_revision_id::text > v_position
    order by g.claim_revision_id::text
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
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
  if workflow.chain_cursor_step(
       'evidensvurdering', v_position, v_failed, v_seen < v_limit) then
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
  v_position := workflow.chain_cursor_position('kandidat');
  for v_row in
    select distinct a.claim_revision_id as id, a.claim_revision_id::text as sort_key
    from knowledge.evidence_assessments a
    where not exists (
      select 1 from knowledge.candidates c where c.claim_revision_id = a.claim_revision_id)
      and a.claim_revision_id::text > v_position
    order by a.claim_revision_id::text
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
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
  if workflow.chain_cursor_step('kandidat', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('kandidat');
  end if;

  -- ------------------------------------------------------------------
  -- Redaksjonelle revisjonsvurderinger som mangler.
  --
  -- Det sjette leddet, og det eneste som ikke ender i en jobb: her stopper
  -- kjeden med vilje, og det som skal stå igjen, er en synlig oppgave til et
  -- menneske (migrasjon 012d). Svikter den overgangen teknisk, ville den nye
  -- kunnskapen vært usynlig for alltid — derfor feies den igjen her, som de
  -- fem andre.
  --
  -- Utvalget er *parene* som har brukbar evidens ingen revisjon av påstanden
  -- hviler på, og ikke enhver kontrollert rad: ett par er én oppgave.
  -- Brukbarheten avgjøres inne i overgangen, med skriveveiens egen funksjon;
  -- her er utvalget den billigere formen — en gjeldende, bekreftet kontroll —
  -- slik at passeringen ikke bruker grensen sin på rader som uansett faller.
  -- ------------------------------------------------------------------
  v_seen := 0;
  v_failed := false;
  v_position := workflow.chain_cursor_position('paastandsrevisjon');
  for v_row in
    with gjeldende as (
      select distinct on (ev.evidence_item_id)
             ev.evidence_item_id, ev.outcome
      from workflow.evidence_verifications ev
      order by ev.evidence_item_id, ev.registration_ordinal desc
    ),
    par as (
      -- Par som har ny, kontrollert evidens ingen revisjon hviler på.
      select c.id as claim_id,
             c.subject_drug_id as drug_id,
             c.topic_concept_id as topic_id,
             c.monograph_need_id as need_id
      from knowledge.claims c
      join knowledge.evidence_items e
        on e.intervention_drug_id = c.subject_drug_id
       and e.outcome_concept_id = c.topic_concept_id
       -- Og innenfor påstandens egen avgrensning. En monografiavgrenset
       -- påstand utfordres ikke av et funn om et annet spørsmål.
       and (c.monograph_need_id is null
            or knowledge.monograph_need_for_evidence_item(e.id) = c.monograph_need_id)
      join gjeldende g on g.evidence_item_id = e.id and g.outcome = 'verified'
      where c.id = workflow.claim_awaiting_revision(
                     c.subject_drug_id, c.topic_concept_id, c.monograph_need_id)
        and not exists (
          select 1
          from knowledge.claim_evidence_links l
          join knowledge.claim_revisions r on r.id = l.claim_revision_id
          where r.claim_id = c.id and l.evidence_item_id = e.id)
      group by c.id, c.subject_drug_id, c.topic_concept_id, c.monograph_need_id
      union
      -- Og oppgavene som alt står åpne. Utvalget over finner dem gjennom en
      -- evidensrad, og en hard sletting tar den raden bort: da ville en oppgave
      -- ingen kan fullføre, ikke vært mulig å nå herfra i det hele tatt. Selve
      -- skrivingen holder tilstanden i takt (avsnitt 14); dette er nettet under.
      select c.id, c.subject_drug_id, c.topic_concept_id, c.monograph_need_id
      from workflow.claim_revision_reviews r
      join knowledge.claims c on c.id = r.claim_id
      where r.state = 'open'
    ),
    utestaaende as (
      -- Ett par og én avgrensning er én oppgave, også når begge kildene over
      -- peker på den.
      select distinct on (
               workflow.claim_synthesis_subject(
                 p.drug_id::text, p.topic_id::text, p.need_id::text))
             p.claim_id, p.drug_id, p.topic_id, p.need_id,
             workflow.claim_synthesis_subject(
               p.drug_id::text, p.topic_id::text, p.need_id::text) as sort_key
      from par p
      order by workflow.claim_synthesis_subject(
                 p.drug_id::text, p.topic_id::text, p.need_id::text),
               p.claim_id
    )
    select u.claim_id as id, u.drug_id, u.topic_id, u.need_id, u.sort_key
    from utestaaende u
    where u.sort_key > v_position
    order by u.sort_key
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
    begin
      if workflow.notice_claim_revision_need(
           v_row.drug_id, v_row.topic_id, v_row.need_id) is not null then
        v_reviews := v_reviews + 1;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('paastandsrevisjon', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if workflow.chain_cursor_step(
       'paastandsrevisjon', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('paastandsrevisjon');
  end if;

  -- --------------------------------------------------------------------
  -- Søkeplaner uten en oppdagelsesoppgave, og lukkede søk uten en kontroll.
  --
  -- Begge overgangene er idempotente, så leddet kan gå gjennom alle åpne
  -- planer: en plan som alt har oppgavene sine, koster et oppslag.
  -- --------------------------------------------------------------------
  v_seen := 0;
  v_failed := false;
  v_position := workflow.chain_cursor_position('kildeoppdagelse');
  for v_row in
    select p.id, p.id::text as sort_key
    from workflow.monograph_search_plans p
    where p.closed_at is null
      and p.paused_at is null
      and p.id::text > v_position
    order by p.id::text
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
    begin
      if workflow.chain_task_for_search_plan(v_row.id) is not null then
        v_plans := v_plans + 1;
      end if;
      if workflow.chain_task_for_search_coverage(v_row.id) is not null then
        v_plans := v_plans + 1;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('kildeoppdagelse', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if workflow.chain_cursor_step(
       'kildeoppdagelse', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('kildeoppdagelse');
  end if;

  -- --------------------------------------------------------------------
  -- Valgte kilder som ikke er hentet inn.
  --
  -- Utestående betyr: kilderaden er ikke løst, eller et behov kilden er valgt
  -- for, har verken en godkjent kildebruk eller en åpen forespørsel. Et behov
  -- som står på en avklaring, er ikke utestående her — det venter på et
  -- menneske, og det står synlig på behovet (ANTIDEP_CONSTITUTION.md regel 4).
  -- --------------------------------------------------------------------
  v_seen := 0;
  v_failed := false;
  v_position := workflow.chain_cursor_position('innhenting');
  for v_row in
    select c.id, c.id::text as sort_key
    from workflow.monograph_candidate_sources c
    where c.decision in ('selected_for_retrieval'::workflow.monograph_candidate_decision,
                         'included'::workflow.monograph_candidate_decision)
      and workflow.monograph_candidate_identifier_system(c.identifier_kind) is not null
      and (
        c.source_id is null
        or exists (
          select 1
          from workflow.monograph_candidate_source_needs cn
          join knowledge.monograph_needs n on n.id = cn.need_id
          where cn.candidate_source_id = c.id
            and n.relevance <> 'not_applicable'::knowledge.monograph_relevance
            and n.work_state <> 'awaiting_clarification'::knowledge.monograph_work_state
            and knowledge.monograph_need_material_kind(cn.need_id)
                  <> 'derived'::knowledge.monograph_material_kind
            and not exists (
              select 1
              from knowledge.monograph_source_uses u
              join knowledge.source_versions sv on sv.id = u.source_version_id
              where u.need_id = cn.need_id and sv.source_id = c.source_id)
            and not exists (
              select 1 from workflow.full_text_requests r
              where r.source_id = c.source_id and r.state = 'open')
            and not exists (
              select 1 from workflow.monograph_document_requests r
              where r.source_id = c.source_id and r.state = 'open')))
      and c.id::text > v_position
    order by c.id::text
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
    begin
      if workflow.acquire_monograph_candidate(v_row.id) is not null then
        v_acquisitions := v_acquisitions + 1;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('innhenting', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if workflow.chain_cursor_step(
       'innhenting', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('innhenting');
  end if;

  -- --------------------------------------------------------------------
  -- Monografisvar som mangler.
  --
  -- To slag: et forskningsbehov der påstanden er vurdert uten at svaret er
  -- bundet til den vurderte revisjonen, og et myndighetsbehov der materialet
  -- er godkjent uten at svaroppgaven står i køen.
  -- --------------------------------------------------------------------
  v_seen := 0;
  v_failed := false;
  v_position := workflow.chain_cursor_position('monografisvar');
  for v_row in
    with utestaaende as (
      select c.monograph_need_id as need_id,
             r.id as claim_revision_id
      from knowledge.evidence_assessments a
      join knowledge.claim_revisions r on r.id = a.claim_revision_id
      join knowledge.claims c on c.id = r.claim_id
      where c.monograph_need_id is not null
        and not exists (
          select 1
          from knowledge.monograph_answers ma
          join knowledge.monograph_answer_revisions mr on mr.id = ma.current_revision_id
          where ma.need_id = c.monograph_need_id
            and mr.claim_revision_id = r.id)
      union all
      select u.need_id, null::uuid
      from knowledge.monograph_source_uses u
      join knowledge.monograph_needs n on n.id = u.need_id
      where n.relevance <> 'not_applicable'::knowledge.monograph_relevance
        and knowledge.monograph_need_material_kind(u.need_id)
              = 'authority_document'::knowledge.monograph_material_kind
        and not exists (
          select 1
          from knowledge.monograph_answers ma
          join knowledge.monograph_answer_revisions mr on mr.id = ma.current_revision_id
          where ma.need_id = u.need_id
            and mr.source_version_id = u.source_version_id)
        and not exists (
          select 1 from workflow.pipeline_jobs j
          where j.agent_role = 'monograph_answer'::provenance.agent_role
            and j.job_key like 'agent-handoff:' || u.need_id::text || ':%')
    )
    select distinct on (u.need_id::text || coalesce(u.claim_revision_id::text, ''))
           u.need_id as id, u.claim_revision_id,
           u.need_id::text || coalesce(u.claim_revision_id::text, '') as sort_key
    from utestaaende u
    where u.need_id::text || coalesce(u.claim_revision_id::text, '') > v_position
    order by u.need_id::text || coalesce(u.claim_revision_id::text, '')
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
    begin
      if v_row.claim_revision_id is not null then
        if workflow.chain_answer_for_assessment(v_row.claim_revision_id) is not null then
          v_answers := v_answers + 1;
        end if;
      else
        if workflow.chain_task_for_monograph_answer(v_row.id) is not null then
          v_answers := v_answers + 1;
        end if;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('monografisvar', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if workflow.chain_cursor_step(
       'monografisvar', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('monografisvar');
  end if;

  return jsonb_build_object('queued', v_queued, 'candidates_built', v_candidates,
                            'revision_reviews', v_reviews,
                            'search_tasks', v_plans,
                            'acquisitions', v_acquisitions,
                            'monograph_answers', v_answers);
end;
$function$;

-- ----------------------------------------------------------------------------
-- 12. Et begrepsforslag kan navngi behovet verdien kom fra
--
-- Et delutfall en oppdagelsesagent ser rapportert for ett spørsmål, hører til
-- nettopp det spørsmålet. Uten dette måtte en ny utfallsverdi utvide hele
-- utgaven på malenes hovedakse, og et kryssprodukt av alle akser er ikke det
-- standarden ber om (MONOGRAPH_STANDARD.md §3). Referansen må være et av
-- oppgavens egne behov: et forslag som kunne navngi et hvilket som helst behov,
-- ville utvidet noe oppgaven ikke gjaldt.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION workflow.record_monograph_discovery_answer(p_job workflow.pipeline_jobs, p_input jsonb, p_result jsonb, p_run_id uuid, p_actor_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_plan_id uuid := workflow.manifest_uuid(p_input, 'search_plan_id');
  v_plan workflow.monograph_search_plans;
  v_unknown text;
  v_item jsonb;
  v_use jsonb;
  v_need_id uuid;
  v_search_id uuid;
  v_candidate_id uuid;
  v_outcome workflow.monograph_search_outcome;
  v_decision workflow.monograph_candidate_decision;
  v_axis knowledge.monograph_scope_axis;
  v_searches integer := 0;
  v_candidates integer := 0;
  v_decisions integer := 0;
  v_proposals integer := 0;
  v_control jsonb;
  v_control_id uuid;
  v_own_searches integer := 0;
  v_closed boolean := false;
  v_closure text;
  v_next_job uuid;
  v_allowed text[];
begin
  select p.* into v_plan
  from workflow.monograph_search_plans p
  where p.id = v_plan_id
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Søkeplanen oppgaven gjelder, finnes ikke lenger.';
  end if;

  -- Ukjente felter avvises framfor å ignoreres: et felt med skrivefeil ville
  -- ellers sett ut som en utelatt opplysning.
  v_allowed := case p_job.agent_role
    when 'source_discovery' then array['searches', 'candidates', 'term_proposals', 'note']
    else array['searches', 'candidates', 'control', 'note']
  end;

  select string_agg(quote_literal(k.value), ', ' order by k.value) into v_unknown
  from jsonb_object_keys(p_result) as k(value)
  where not (k.value = any (v_allowed));
  if v_unknown is not null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Svaret har felter denne kontrakten ikke kjenner: %s.', v_unknown),
      hint = format('Feltene rollen %s leser, er %s.',
                    p_job.agent_role, array_to_string(v_allowed, ', '));
  end if;

  -- ------------------------------------------------------------------
  -- Søkene agenten rapporterer
  -- ------------------------------------------------------------------
  if p_result ? 'searches' then
    if jsonb_typeof(p_result -> 'searches') <> 'array' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'searches er ikke en JSON-liste.';
    end if;

    for v_item in select value from jsonb_array_elements(p_result -> 'searches') loop
      select string_agg(quote_literal(k.value), ', ' order by k.value) into v_unknown
      from jsonb_object_keys(v_item) as k(value)
      where k.value not in (
        'platform', 'query_string', 'filters', 'outcome', 'result_count',
        'screened_count', 'truncated', 'truncation_note', 'limitation_note',
        'track_codes'
      );
      if v_unknown is not null then
        raise exception using
          errcode = 'invalid_parameter_value',
          message = format('Et rapportert søk har felter denne kontrakten ikke kjenner: %s.', v_unknown);
      end if;

      begin
        v_outcome := (v_item ->> 'outcome')::workflow.monograph_search_outcome;
      exception
        when invalid_text_representation then
          raise exception using
            errcode = 'invalid_parameter_value',
            message = format('%L er ikke et søkeutfall.', v_item ->> 'outcome'),
            hint = 'Utfallene er executed, zero_results, unavailable og failed. En utilgjengelig søkevei er ikke null treff (SOURCE_POLICY.md §8.2).';
      end;

      v_search_id := workflow.record_monograph_search(
        v_plan_id,
        v_item ->> 'platform',
        v_item ->> 'query_string',
        v_item ->> 'filters',
        statement_timestamp(),
        (v_item ->> 'result_count')::integer,
        coalesce((v_item ->> 'screened_count')::integer, 0),
        coalesce((v_item ->> 'truncated')::boolean, false),
        v_item ->> 'truncation_note',
        v_outcome,
        v_item ->> 'limitation_note',
        -- Agentens egen beretning, og ingenting annet. Verdien settes her og
        -- kan ikke oppgis i svaret.
        'agent_reported'::workflow.monograph_execution_evidence,
        null, null,
        (select coalesce(array_agg(t.value #>> '{}'), array[]::text[])
         from jsonb_array_elements(coalesce(v_item -> 'track_codes', '[]'::jsonb)) as t(value)),
        p_run_id, p_actor_id);

      v_searches := v_searches + 1;
      if v_outcome in ('executed', 'zero_results') then
        v_own_searches := v_own_searches + 1;
      end if;
    end loop;
  end if;

  -- ------------------------------------------------------------------
  -- Kandidatkildene, med sine mulige bruksområder og utvalgsbeslutninger
  -- ------------------------------------------------------------------
  if p_result ? 'candidates' then
    if jsonb_typeof(p_result -> 'candidates') <> 'array' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'candidates er ikke en JSON-liste.';
    end if;

    for v_item in select value from jsonb_array_elements(p_result -> 'candidates') loop
      select string_agg(quote_literal(k.value), ', ' order by k.value) into v_unknown
      from jsonb_object_keys(v_item) as k(value)
      where k.value not in (
        'identifier_kind', 'identifier_value', 'title', 'authors_or_issuer',
        'publisher_or_journal', 'publication_year', 'discovery_path',
        'access_limited', 'access_limitation_note',
        'could_change_conclusion', 'materiality_reason',
        'decision', 'decision_reason', 'uses'
      );
      if v_unknown is not null then
        raise exception using
          errcode = 'invalid_parameter_value',
          message = format('En kandidatkilde har felter denne kontrakten ikke kjenner: %s.', v_unknown);
      end if;

      v_candidate_id := workflow.record_monograph_candidate_source(
        v_plan_id, null,
        v_item ->> 'identifier_kind',
        v_item ->> 'identifier_value',
        v_item ->> 'title',
        v_item ->> 'authors_or_issuer',
        v_item ->> 'publisher_or_journal',
        (v_item ->> 'publication_year')::integer,
        v_item ->> 'discovery_path',
        coalesce((v_item ->> 'access_limited')::boolean, false),
        v_item ->> 'access_limitation_note',
        coalesce((v_item ->> 'could_change_conclusion')::boolean, false),
        v_item ->> 'materiality_reason',
        p_run_id, p_actor_id);
      v_candidates := v_candidates + 1;

      -- Hva kilden kan brukes til, per behov. Behovet må være ett av dem planen
      -- dekker: en bruk utenfor oppgaven ville flyttet kilden til et spørsmål
      -- ingen hadde avgrenset.
      if v_item ? 'uses' then
        for v_use in select value from jsonb_array_elements(coalesce(v_item -> 'uses', '[]'::jsonb)) loop
          select n.id into v_need_id
          from knowledge.monograph_needs n
          join workflow.monograph_search_plan_needs pn on pn.need_id = n.id
          where pn.plan_id = v_plan_id and n.reference = v_use ->> 'need_reference';

          if v_need_id is null then
            raise exception using
              errcode = 'invalid_parameter_value',
              message = 'Svaret oppgir en bruk for et kunnskapsbehov som ikke står i oppgaven.',
              hint = 'Hvilke behov søkeplanen dekker, er en faglig avgrensning som ligger i oppgaven. En bruk utenfor den ville flyttet kilden til et spørsmål ingen hadde avgrenset.';
          end if;

          insert into workflow.monograph_candidate_source_needs
            (candidate_source_id, need_id, proposed_use)
          values (v_candidate_id, v_need_id, v_use ->> 'proposed_use')
          on conflict (candidate_source_id, need_id) do nothing;
        end loop;
      end if;

      if v_item ->> 'decision' is not null then
        begin
          v_decision := (v_item ->> 'decision')::workflow.monograph_candidate_decision;
        exception
          when invalid_text_representation then
            raise exception using
              errcode = 'invalid_parameter_value',
              message = format('%L er ikke en utvalgsbeslutning.', v_item ->> 'decision');
        end;

        perform workflow.decide_monograph_candidate_source(
          v_candidate_id, v_decision, v_item ->> 'decision_reason', null, p_run_id);
        v_decisions := v_decisions + 1;
      end if;
    end loop;
  end if;

  -- ------------------------------------------------------------------
  -- Forslagene om nye avgrensningsverdier
  --
  -- Forslag, og ikke utvidelser: aksepten er en egen handling med et annet
  -- opphav, og den kan ikke være denne kjøringen (MONOGRAPH_STANDARD.md §4).
  -- ------------------------------------------------------------------
  if p_result ? 'term_proposals' then
    if jsonb_typeof(p_result -> 'term_proposals') <> 'array' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'term_proposals er ikke en JSON-liste.';
    end if;

    for v_item in select value from jsonb_array_elements(p_result -> 'term_proposals') loop
      select string_agg(quote_literal(k.value), ', ' order by k.value) into v_unknown
      from jsonb_object_keys(v_item) as k(value)
      where k.value not in ('axis', 'label', 'rationale', 'from_need');
      if v_unknown is not null then
        raise exception using
          errcode = 'invalid_parameter_value',
          message = format('Et forslag har felter denne kontrakten ikke kjenner: %s.', v_unknown);
      end if;

      begin
        v_axis := (v_item ->> 'axis')::knowledge.monograph_scope_axis;
      exception
        when invalid_text_representation then
          raise exception using
            errcode = 'invalid_parameter_value',
            message = format('%L er ikke en avgrensningsakse.', v_item ->> 'axis');
      end;

      -- Behovet verdien ble dokumentert under, når agenten navngir det. Da
      -- forgrener aksepten nettopp det behovet framfor å utvide hele utgaven
      -- på malenes hovedakse (MONOGRAPH_STANDARD.md §3). Referansen må høre
      -- til en av oppgavens egne behov: et forslag som kunne navngi et hvilket
      -- som helst behov, ville utvidet noe oppgaven ikke gjaldt.
      v_need_id := null;
      if nullif(btrim(coalesce(v_item ->> 'from_need', '')), '') is not null then
        select n.id into v_need_id
        from knowledge.monograph_needs n
        join workflow.monograph_search_plan_needs pn on pn.need_id = n.id
        where n.reference = btrim(v_item ->> 'from_need')
          and pn.plan_id = v_plan.id;

        if v_need_id is null then
          raise exception using
            errcode = 'invalid_parameter_value',
            message = format(
              'Forslaget viser til behovet %L, som ikke er et av oppgavens behov.',
              v_item ->> 'from_need');
        end if;
      end if;

      perform knowledge.record_monograph_term_proposal(
        v_plan.edition_id, v_axis, v_item ->> 'label', v_item ->> 'rationale',
        p_actor_id, p_run_id, v_need_id, null, null, null, null, null);
      v_proposals := v_proposals + 1;
    end loop;
  end if;

  -- ------------------------------------------------------------------
  -- Kontrollen av søkedekningen
  -- ------------------------------------------------------------------
  if p_job.agent_role = 'source_quality_assessment' then
    v_control := p_result -> 'control';
    if v_control is null or jsonb_typeof(v_control) <> 'object' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret har ingen control som er et JSON-objekt.';
    end if;

    select string_agg(quote_literal(k.value), ', ' order by k.value) into v_unknown
    from jsonb_object_keys(v_control) as k(value)
    where k.value not in (
      'outcome', 'note', 'searched_independently', 'missed_candidates',
      'exclusions_checked', 'materiality_assessed'
    );
    if v_unknown is not null then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('Kontrollen har felter denne kontrakten ikke kjenner: %s.', v_unknown);
    end if;

    -- En erklæring om egne søk er ikke en utførelse. Kontrollen har nettopp
    -- registrert sine egne søk i den samme transaksjonen; finnes det ingen som
    -- gikk, avvises erklæringen (SOURCE_POLICY.md §6).
    if coalesce((v_control ->> 'searched_independently')::boolean, false)
       and v_own_searches = 0 then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Kontrollen erklærer at den søkte selv, men har ikke rapportert et eget søk som gikk.',
        hint = 'En erklæring er ikke en utførelse. Rapporter dine egne motsøk i «searches»; et kontrollledd som bare leser generatorens valgte referanser, kan kontrollere sitatene, men ikke vurdere dekningsgraden (SOURCE_POLICY.md §6).';
    end if;

    v_control_id := workflow.record_monograph_coverage_control(
      v_plan_id,
      (v_control ->> 'outcome')::workflow.monograph_coverage_outcome,
      v_control ->> 'note',
      coalesce((v_control ->> 'searched_independently')::boolean, false),
      coalesce((v_control ->> 'missed_candidates')::integer, 0),
      coalesce((v_control ->> 'exclusions_checked')::integer, 0),
      coalesce((v_control ->> 'materiality_assessed')::boolean, false),
      p_run_id, p_actor_id);

    -- Godtar kontrollen dekningen, og holder porten, erklæres søkedekningen
    -- ferdig i den samme transaksjonen. Det er ikke et menneskelig
    -- godkjenningsklikk som mangler her: porten er den samme enten en redaktør
    -- eller kjeden erklærer dekningen ferdig, og en redaktør kan fortsatt gjøre
    -- det selv (SOURCE_POLICY.md §10).
    if (v_control ->> 'outcome') = 'accepted' then
      v_closure := workflow.monograph_search_closure_problem(v_plan_id);
      if v_closure is null then
        update workflow.monograph_search_plans
        set closed_at = now(),
            closed_note = format('Søkedekningen erklært ferdig av den separate kontrollen: %s',
                                 v_control ->> 'note'),
            closed_by_actor_id = p_actor_id
        where id = v_plan_id;

        update knowledge.monograph_needs n
        set work_state = 'appraising_sources', work_state_note = null
        where n.id in (
          select pn.need_id from workflow.monograph_search_plan_needs pn
          where pn.plan_id = v_plan_id)
          and n.relevance = 'relevant'
          and n.work_state in ('not_started', 'searching');

        v_closed := true;
      end if;
    end if;
  else
    -- Et registrert søkesvar legger kontrolloppgaven i køen.
    v_next_job := workflow.chain_task_for_search_coverage(v_plan_id);
  end if;

  return jsonb_build_object(
    'search_plan_id', v_plan_id,
    'searches_recorded', v_searches,
    'candidates_recorded', v_candidates,
    'selection_decisions', v_decisions,
    'term_proposals', v_proposals,
    'coverage_control_id', v_control_id,
    'search_coverage_closed', v_closed,
    'closure_problem', workflow.monograph_search_closure_problem(v_plan_id),
    'next_job_id', v_next_job);
end;
$function$;
