-- ============================================================================
-- Migrasjon 003d — kildeforankringen blir en del av evidensfunnets identitet
--
-- Formål: lukke issue #66. En rettet kildeforankring lot seg ikke registrere,
-- fordi `content_hash` ble regnet ut av kolonnene på `knowledge.evidence_items`
-- alene mens forankringen ligger i `knowledge.evidence_field_groundings`. Et
-- forslag som bare rettet et `source_excerpt`, en `source_locator` eller en
-- `justification`, ga nøyaktig den samme hashen, ble avvist av
-- `evidence_items_content_hash_key` som en dublett — og den gale forankringen
-- ble stående.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md
--     §4 enhver klinisk relevant påstand skal være etterprøvbar
--     §8 evidens og proveniens er førsteklasses data
--     §9 motstridende evidens skal bevares
--     §11 verifikasjon skal forsøke å falsifisere
--     §14 endringer skal være reversible, attribuerte og rapporterbare
--   docs/DATABASE_ARCHITECTURE.md §20, §29, §36, §50, §57, §59, §60, §67
--   docs/EVIDENCE_PIPELINE.md §13, §21, §25
--   docs/KNOWLEDGE_MODEL.md §11.1, §11.2, §19
--   docs/MVP_IMPLEMENTATION_PLAN.md §20, §29, §41-§42, §72
--
-- ----------------------------------------------------------------------------
-- Hvorfor identiteten utvides, og ikke forankringen gjøres rettbar
--
-- Issue #66 satte opp tre veier. Den valgte er den første, og valget følger av
-- datamodellen slik den allerede er:
--
--   * `knowledge.evidence_field_groundings` er append-only med den samme
--     begrunnelsen som funnet selv, og tabellens egen avvisningstekst sier
--     allerede hva en gal forankring betyr: «er den feil, er ekstraksjonen
--     feil». Den setningen er bare sann hvis en rettet forankring faktisk kan
--     bli en ny ekstraksjon.
--   * Forankringen skrives av ekstraktøren, i den samme transaksjonen som
--     funnet, og den sammensatte fremmednøkkelen låser den til funnets egen
--     skaper (migrasjon 005u). Den er altså allerede en del av ekstraksjonen og
--     ikke en senere vurdering av den.
--   * `UNIQUE (evidence_item_id, check_field)` finnes nettopp for at ett felt
--     ikke skal kunne ha to konkurrerende forankringer. En egen
--     korreksjonsrad — vei 2 i issue #66 — ville innført akkurat det den regelen
--     hindrer, og krevd en «gjeldende forankring»-avledning ved siden av.
--     Kontrollradene har den formen fordi en vurdering *er* en hendelse over
--     tid; en ekstraksjon er det ikke.
--
-- Konsekvensen er den append-only-modellen forutsetter: en rettet forankring er
-- et nytt evidensfunn ved siden av det gamle. Det gamle består urørt, og det
-- nye må selv gjennom maskinkontrollen, den menneskelige ekstraksjonskontrollen
-- og publiseringsgaten. Ingenting arves: verifikasjoner, claim-lenker og
-- godkjenninger peker på `evidence_item_id`, og den nye raden har sin egen.
--
-- ----------------------------------------------------------------------------
-- Hvordan avtrykket kan dekke en annen tabell
--
-- `content_hash` settes av en BEFORE INSERT-trigger, og på det tidspunktet
-- finnes forankringsradene ikke ennå — de skrives etter funnet, fordi de peker
-- på det. Hashen kan derfor ikke lese dem.
--
-- Løsningen er å la raden bære forankringens eget avtrykk i en kolonne,
-- `grounding_digest`, og la databasen kontrollere at kolonnen stemmer med de
-- radene som faktisk ble skrevet. Kontrollen er en `constraint trigger` som er
-- utsatt til commit, altså det tidspunktet der begge tabellene er ferdig
-- skrevet. En kaller som oppgir et avtrykk som ikke stemmer med forankringen,
-- får transaksjonen avvist — og et funn kan derfor ikke lyve om hva det hviler
-- på.
--
-- Kontrollen går begge veier. Den fanger både et funn som oppgir feil avtrykk,
-- og en forankring som legges til i etterkant på et funn som allerede er
-- registrert. Det siste er ikke en teoretisk mulighet: nettopp det ville vært
-- «å legge forankring på en gammel rad», som re-ekstraksjonen finnes for å
-- unngå (ANTIDEP_CONSTITUTION.md §8, §14).
--
-- ----------------------------------------------------------------------------
-- Én kanonisering, brukt av alle
--
-- `knowledge.canonical_field_groundings(jsonb)` normaliserer forslagets
-- forankringsliste én gang. Både innsettingen i
-- `knowledge.evidence_field_groundings` og avtrykket bygges av den, slik at de
-- to ikke kan komme i utakt — den samme begrunnelsen migrasjon 006a hadde for å
-- flytte kanoniseringen ut av triggerfunksjonen.
--
-- Rekkefølgen på forankringene i et forslag er ikke informasjon: ett felt har
-- én forankring, og hvilken rekkefølge de står i filen er tilfeldig.
-- Avtrykket sorterer dem derfor deterministisk, med `collate "C"`, slik at det
-- er byte-rekkefølge og ikke databasens lokaltilpassede kollasjon som avgjør.
-- To forslag som forankrer det samme, gir da det samme avtrykket uansett
-- rekkefølge — og en flyttet linje i en fil blir ikke feilaktig et nytt funn.
--
-- ----------------------------------------------------------------------------
-- Hva som skjer med radene som allerede finnes
--
-- Ingenting klinisk. `grounding_digest` fylles ut av forankringen hver rad
-- faktisk har — den tomme listen for alle funn registrert før migrasjon 005u —
-- og `content_hash` regnes ut på nytt etter den nye definisjonen, slik
-- migrasjon 006a gjorde det for v2. Ingen kanonisk kolonne røres, og
-- fingeravtrykket dekker etterpå nøyaktig det samme innholdet pluss den
-- forankringen raden allerede hadde.
--
-- Rehashingen kan ikke kollidere. To rader som var distinkte under v2, hadde
-- distinkte feltverdier; v3 leser de samme feltene og ett til, og den
-- lengdeprefiksede kanoniseringen er injektiv. Distinkte v2-hasher gir derfor
-- distinkte v3-hasher.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Kanoniseringen av en forankringsliste
--
-- Tar forslagets egen form — den `knowledge.record_evidence_item` får som
-- `p_field_groundings` — og gir tilbake de normaliserte verdiene. Normaliseringen
-- er nøyaktig den innsettingen gjorde fra før: `btrim` på de tre tekstfeltene, og
-- `check_field` urørt, slik at enum-castet fortsatt avviser en verdi som ikke er
-- et kontrollfelt framfor at kanoniseringen stilltiende retter den.
--
-- IMMUTABLE: den leser ingenting utenfor argumentet.
-- ----------------------------------------------------------------------------
create function knowledge.canonical_field_groundings(p_field_groundings jsonb)
  returns table (
    check_field text,
    source_excerpt text,
    source_locator text,
    justification text
  )
  language sql
  immutable
  set search_path = ''
as $$
  select
    g.value ->> 'check_field',
    btrim(g.value ->> 'source_excerpt'),
    btrim(g.value ->> 'source_locator'),
    btrim(g.value ->> 'justification')
  from jsonb_array_elements(
    case
      when p_field_groundings is null
        or jsonb_typeof(p_field_groundings) = 'null' then '[]'::jsonb
      else p_field_groundings
    end
  ) as g;
$$;

comment on function knowledge.canonical_field_groundings(jsonb) is
  'Normaliserer forslagets kildeforankringer én gang, i den formen knowledge.record_evidence_item tar imot dem. Både innsettingen i knowledge.evidence_field_groundings og avtrykket knowledge.evidence_field_grounding_digest(jsonb) bygges av denne funksjonen, slik at identiteten og det som faktisk lagres, ikke kan komme i utakt (samme begrunnelse som migrasjon 006a hadde for å samle kanoniseringen ett sted). btrim på de tre tekstfeltene speiler CHECK-ene på tabellen; check_field står urørt, slik at enum-castet i innsettingen fortsatt avviser en verdi som ikke er et kontrollfelt. SQL NULL og JSON null er den tomme listen; alt annet enn en liste avvises av jsonb_array_elements.';

revoke execute on function knowledge.canonical_field_groundings(jsonb) from public;

-- ----------------------------------------------------------------------------
-- 2. Avtrykket av en forankringsliste
--
-- Lengdeprefikset per felt, som alle andre avtrykk i Antidep, slik at skjøten er
-- entydig selv når et utdrag inneholder skilletegnet. Hver forankring blir én
-- del, og delene sorteres på seg selv med `collate "C"`: rekkefølgen i forslaget
-- er tilfeldig og skal ikke kunne endre identiteten, og en kollasjon som
-- varierer mellom miljøer ville gjort det samme avtrykket miljøavhengig.
-- ----------------------------------------------------------------------------
create function knowledge.evidence_field_grounding_digest(p_field_groundings jsonb)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  with part as (
    select (
      select string_agg(
        '|' || coalesce(length(f.value)::text, '~') || ':' || coalesce(f.value, ''),
        '' order by f.ordinality
      )
      from unnest(array[
        c.check_field, c.source_excerpt, c.source_locator, c.justification
      ]) with ordinality as f(value, ordinality)
    ) as canonical
    from knowledge.canonical_field_groundings(p_field_groundings) c
  )
  select 'sha256-v1:' || encode(
    sha256(convert_to(
      coalesce(
        (select string_agg(p.canonical, '' order by p.canonical collate "C") from part p),
        ''
      ),
      'UTF8'
    )),
    'hex'
  );
$$;

comment on function knowledge.evidence_field_grounding_digest(jsonb) is
  'Fingeravtrykket av settet av kildeforankringer et evidensfunn hviler på (ANTIDEP_CONSTITUTION.md §8, §11). Hvert felt kanoniseres lengdeprefikset, og forankringene sorteres på sin egen kanoniske streng med collate "C": rekkefølgen i et forslag er tilfeldig og skal ikke endre identiteten, og en lokaltilpasset kollasjon ville gjort avtrykket avhengig av hvilket miljø det ble regnet ut i. Den tomme listen har sitt eget avtrykk og er tilstanden alle funn registrert før migrasjon 005u er i. Verdien bæres av knowledge.evidence_items.grounding_digest og inngår i content_hash fra sha256-v3, slik at en rettet forankring blir et nytt evidensfunn framfor en avvist dublett.';

revoke execute on function knowledge.evidence_field_grounding_digest(jsonb) from public;

-- ----------------------------------------------------------------------------
-- 3. Det samme avtrykket, regnet av radene som faktisk står i basen
--
-- Brukes av kontrollen under og av backfillen. Den bygger forslagets form av
-- tabellen og delegerer, slik at det finnes nøyaktig én definisjon av hva
-- avtrykket er.
-- ----------------------------------------------------------------------------
create function knowledge.evidence_item_grounding_digest(p_evidence_item_id uuid)
  returns text
  language sql
  stable
  set search_path = ''
as $$
  select knowledge.evidence_field_grounding_digest(coalesce(
    (
      select jsonb_agg(jsonb_build_object(
        'check_field', g.check_field::text,
        'source_excerpt', g.source_excerpt,
        'source_locator', g.source_locator,
        'justification', g.justification
      ))
      from knowledge.evidence_field_groundings g
      where g.evidence_item_id = p_evidence_item_id
    ),
    '[]'::jsonb
  ));
$$;

comment on function knowledge.evidence_item_grounding_digest(uuid) is
  'Avtrykket av de kildeforankringene som faktisk er registrert på ett evidensfunn, gjennom den samme kanoniseringen som knowledge.evidence_field_grounding_digest(jsonb). Ingen ORDER BY er nødvendig her: avtrykket sorterer selv. Leses av den utsatte kontrollen som krever at knowledge.evidence_items.grounding_digest stemmer med radene, og av rehashingen i denne migrasjonen.';

revoke execute on function knowledge.evidence_item_grounding_digest(uuid) from public;

-- ----------------------------------------------------------------------------
-- 4. Kolonnen som bærer avtrykket
--
-- DEFAULT er avtrykket av den tomme listen, altså «ingen forankring registrert».
-- Det er den sanne verdien for et funn som ikke leverer noen, og den gjør at en
-- innsetting uten forankring fortsatt er nøyaktig like gyldig som før.
-- ----------------------------------------------------------------------------
alter table knowledge.evidence_items
  add column grounding_digest text not null
    default knowledge.evidence_field_grounding_digest('[]'::jsonb);

alter table knowledge.evidence_items
  add constraint evidence_items_grounding_digest_format_check
    check (grounding_digest ~ '^sha256-v[0-9]+:[0-9a-f]{64}$');

comment on column knowledge.evidence_items.grounding_digest is
  'Fingeravtrykket av settet av kildeforankringer funnet ble registrert med (knowledge.evidence_field_grounding_digest(jsonb)). Finnes som kolonne fordi content_hash settes av en BEFORE INSERT-trigger, mens forankringsradene skrives etter funnet de peker på — hashen kan derfor ikke lese dem selv. Verdien er ikke en påstand kalleren slipper unna med: en utsatt constraint trigger krever ved commit at den stemmer med radene i knowledge.evidence_field_groundings, i begge retninger. Avtrykket av den tomme listen betyr «ingen forankring registrert», som er tilstanden alle funn registrert før migrasjon 005u er i.';

-- ----------------------------------------------------------------------------
-- 5. Identiteten, versjonert til sha256-v3
--
-- Feltlisten, feltrekkefølgen, normaliseringen og skjøten fra migrasjon 006a er
-- uendret. Det eneste nye er at forankringens avtrykk er med, sist i listen.
-- Prefikset versjoneres slik migrasjon 003 forutsatte: gamle verdier skal ikke
-- bli stille uforenlige med nye.
-- ----------------------------------------------------------------------------
create or replace function knowledge.evidence_item_content_hash(item knowledge.evidence_items)
  returns text
  language plpgsql
  immutable
  set search_path = ''
as $$
declare
  fields text[];
  field text;
  canonical text := 'sha256-v3';
begin
  -- Samme felter, samme rekkefølge og samme normalisering som i migrasjon 003
  -- og 006a: numeriske verdier gjennom trim_scale, slik at 0.80 og 0.8 er samme
  -- verdi, og tidsrom som sekunder, slik at «8 uker» skrevet på to måter er det.
  fields := array[
    item.source_id::text,
    item.source_version_id::text,
    item.design_code::text,
    item.population_id::text,
    item.population_availability::text,
    item.population_detail,
    item.sample_size::text,
    item.sample_size_availability::text,
    item.intervention_drug_id::text,
    item.intervention_detail,
    item.comparator_kind::text,
    item.comparator_drug_id::text,
    item.comparator_detail,
    item.outcome_concept_id::text,
    item.outcome_detail,
    extract(epoch from item.timepoint_min)::text,
    extract(epoch from item.timepoint_max)::text,
    item.timepoint_availability::text,
    item.reported_direction::text,
    item.effect_measure::text,
    trim_scale(item.estimate)::text,
    item.estimate_unit::text,
    item.estimate_availability::text,
    trim_scale(item.ci_lower)::text,
    trim_scale(item.ci_upper)::text,
    trim_scale(item.ci_level_percent)::text,
    item.confidence_interval_availability::text,
    item.limitations_text,
    item.source_locator,
    item.extraction_method::text,
    item.raw_extraction::text,
    -- Nytt i sha256-v3: kildeforankringen er en del av ekstraksjonens identitet,
    -- ikke en opplysning ved siden av den (issue #66). Avtrykket og ikke
    -- utdragene selv, fordi hashen leser radens egne kolonner.
    item.grounding_digest
  ];

  foreach field in array fields loop
    -- Lengdeprefiks gjør skjøten entydig; «~» skiller NULL fra tom streng.
    canonical := canonical || '|' || coalesce(length(field)::text, '~') || ':'
                 || coalesce(field, '');
  end loop;

  return 'sha256-v3:' || encode(sha256(convert_to(canonical, 'UTF8')), 'hex');
end;
$$;

comment on function knowledge.evidence_item_content_hash(knowledge.evidence_items) is
  'Beregner fingeravtrykket av et evidensfunn fra radens egne kanoniske felter, inkludert avtrykket av kildeforankringen (grounding_digest, sha256-v3). Feltene kanoniseres lengdeprefikset, slik at to ulike funn ikke kan gi samme kanoniske streng selv om fritekstfeltene inneholder skilletegnet, og «~» skiller NULL fra tom streng. At forankringen er med, gjør en rettet forankring til et nytt evidensfunn ved siden av det gamle framfor en avvist dublett — som er det append-only-modellen forutsetter (issue #66). Felles definisjon for innsettingstriggeren, for dublettoppslaget i knowledge.record_evidence_item og for rehashing i vedlikeholdsmigrasjoner, slik at det bare finnes ett sted å endre.';

-- ----------------------------------------------------------------------------
-- 6. Backfill og rehashing av eksisterende rader
--
-- Samme form som migrasjon 006a: knowledge.evidence_items er append-only og
-- avviser UPDATE også for tabelleieren, så triggeren slås av eksplisitt rundt
-- operasjonen, som en synlig og reviewbar handling. Vinduet er så smalt som
-- mulig, og inneholder bare de to setningene som må gjøres.
--
-- Rekkefølgen er nødvendig: avtrykket må stå i kolonnen før hashen leser den.
--
-- Dette er ikke en redigering av klinisk innhold. Ingen kanonisk kolonne røres;
-- begge feltene er teknisk metadata databasen selv eier, og fingeravtrykket
-- dekker etterpå nøyaktig det samme innholdet som før, pluss den forankringen
-- raden allerede hadde.
-- ----------------------------------------------------------------------------
alter table knowledge.evidence_items disable trigger evidence_items_reject_mutation;

update knowledge.evidence_items e
set grounding_digest = knowledge.evidence_item_grounding_digest(e.id);

update knowledge.evidence_items e
set content_hash = knowledge.evidence_item_content_hash(e.*);

alter table knowledge.evidence_items enable trigger evidence_items_reject_mutation;

-- Etter backfillen skal ingen rad ligge igjen på en eldre definisjon, og hvert
-- avtrykk skal stemme med de forankringene raden faktisk har. Kontrollene står
-- her, ikke bare i testpakken, fordi en delvis migrert tabell ikke skal kunne
-- commite.
do $$
begin
  if exists (
    select 1 from knowledge.evidence_items
    where content_hash !~ '^sha256-v3:[0-9a-f]{64}$'
  ) then
    raise exception
      'Rehashing av knowledge.evidence_items er ufullstendig; rader står igjen med en eldre hashdefinisjon.';
  end if;

  if exists (
    select 1 from knowledge.evidence_items e
    where e.grounding_digest is distinct from knowledge.evidence_item_grounding_digest(e.id)
  ) then
    raise exception
      'Minst én rad i knowledge.evidence_items bærer et forankringsavtrykk som ikke stemmer med forankringen som er registrert på den.';
  end if;
end;
$$;

-- ----------------------------------------------------------------------------
-- 7. Avtrykket skal alltid stemme med forankringen
--
-- Utsatt til commit, fordi funnet og forankringen skrives i den rekkefølgen
-- fremmednøkkelen krever, og påstanden først kan avgjøres når begge er skrevet.
-- Den kjører på begge tabellene: et funn som oppgir feil avtrykk, og en
-- forankring som legges til i etterkant, er den samme feilen sett fra hver sin
-- side.
--
-- SECURITY DEFINER fordi en utsatt trigger kjører ved commit, altså utenfor den
-- SECURITY DEFINER-funksjonen som skrev radene, og knowledge har RLS med default
-- deny. Funksjonen leser bare, returnerer ingen data og kan bare avvise.
-- ----------------------------------------------------------------------------
create function knowledge.assert_grounding_digest_matches()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_evidence_item_id uuid := (to_jsonb(new) ->> tg_argv[0])::uuid;
  v_recorded text;
  v_actual text;
begin
  select e.grounding_digest into v_recorded
  from knowledge.evidence_items e
  where e.id = v_evidence_item_id;

  -- Finnes ikke funnet, er det ingenting å påstå. Tilfellet er ikke nåbart i
  -- dag — knowledge.evidence_items avviser DELETE, og fremmednøkkelen på
  -- forankringen krever at funnet finnes — men en kontroll skal si «ukjent»
  -- framfor «avvik» når den ikke har grunnlag.
  if v_recorded is null then
    return null;
  end if;

  v_actual := knowledge.evidence_item_grounding_digest(v_evidence_item_id);

  if v_recorded is distinct from v_actual then
    raise exception using
      errcode = 'integrity_constraint_violation',
      message = 'Kildeforankringen på evidensfunnet stemmer ikke med avtrykket funnet er registrert med.',
      detail = format('evidence_item_id=%s', v_evidence_item_id),
      hint = 'Forankringen er en del av ekstraksjonens identitet (sha256-v3). Den skrives i samme transaksjon som funnet, av knowledge.record_evidence_item, og kan ikke legges til eller endres etterpå: er forankringen feil, er ekstraksjonen feil, og rettelsen er et nytt evidensfunn ved siden av det gamle.';
  end if;

  return null;
end;
$$;

comment on function knowledge.assert_grounding_digest_matches() is
  'Krever at knowledge.evidence_items.grounding_digest er avtrykket av de kildeforankringene som faktisk står på funnet. Utsatt til commit, fordi funnet skrives før forankringen som peker på det, og påstanden først kan avgjøres når begge er skrevet. Kjører på begge tabellene: et funn som oppgir feil avtrykk, og en forankring som legges til på et allerede registrert funn, er den samme feilen sett fra hver sin side — og det siste er nettopp «å legge forankring på en gammel rad», som re-ekstraksjonen finnes for å unngå (ANTIDEP_CONSTITUTION.md §8, §14). Kolonnen som bærer evidensfunnets id oppgis som triggerargument. SECURITY DEFINER fordi en utsatt trigger kjører ved commit, utenfor skriveveiens egen kontekst, og knowledge har RLS med default deny; funksjonen leser bare og returnerer ingen data.';

revoke execute on function knowledge.assert_grounding_digest_matches() from public;

create constraint trigger evidence_items_grounding_digest_matches
  after insert on knowledge.evidence_items
  deferrable initially deferred
  for each row execute function knowledge.assert_grounding_digest_matches('id');

create constraint trigger evidence_field_groundings_digest_matches
  after insert on knowledge.evidence_field_groundings
  deferrable initially deferred
  for each row execute function knowledge.assert_grounding_digest_matches('evidence_item_id');

-- ----------------------------------------------------------------------------
-- 8. Skriveveien setter avtrykket, og dubletten betyr nå noe strengere
--
-- Funksjonen har samme signatur, samme SECURITY INVOKER og samme rekkefølge som
-- i migrasjon 007h. Tre ting er nye:
--
--   1. forankringen kanoniseres én gang, og både innsettingen og avtrykket
--      bygges av den samme kanoniseringen
--   2. radvariabelen og INSERT-en bærer `grounding_digest`, slik at identiteten
--      dekker forankringen
--   3. dublettteksten sier det som nå er sant: en dublett er den samme
--      ekstraksjonen *med den samme forankringen*
--
-- Oppslaget etter den kolliderende raden er uendret i form og bruker fortsatt
-- nøyaktig den identiteten UNIQUE-regelen bruker — nå med forankringen i seg,
-- fordi radvariabelen bærer det samme avtrykket som innsettingen.
-- ----------------------------------------------------------------------------
create or replace function knowledge.record_evidence_item(
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
  p_source_version_id uuid,
  p_population_id uuid,
  p_sample_size integer,
  p_intervention_detail text,
  p_comparator_drug_id uuid,
  p_comparator_detail text,
  p_timepoint_min text,
  p_timepoint_max text,
  p_effect_measure text,
  p_estimate numeric,
  p_estimate_unit text,
  p_ci_lower numeric,
  p_ci_upper numeric,
  p_ci_level_percent numeric,
  p_limitations_text text,
  p_source_quote text,
  p_field_groundings jsonb,
  p_extraction_method text,
  p_created_by_actor_id uuid,
  -- NULL for editorveien: en registrering gjennom skjemaet er ingen
  -- agentkjøring, og en id her ville vært en påstand om det motsatte.
  p_agent_run_id uuid
)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_evidence_item_id uuid;
  v_duplicate_field text;
  v_raw_extraction jsonb;
  -- Forankringens avtrykk, utledet én gang av den samme kanoniseringen
  -- innsettingen under bruker. Det er denne verdien som gjør en rettet
  -- forankring til et nytt funn framfor en avvist dublett (migrasjon 003d).
  v_grounding_digest text;
  -- Radvariabelen finnes bare for å kunne be knowledge.evidence_item_content_hash
  -- om avtrykket av nøyaktig den raden innsettingen forsøker. Den er ikke en
  -- kopi av identitetsdefinisjonen: den kanoniske funksjonen er den samme, og
  -- feltene her settes av de samme uttrykkene som INSERT-en bruker.
  v_candidate knowledge.evidence_items;
  v_existing_id uuid;
begin
  -- Forankringen kontrolleres på form før noe skrives, slik at en feil form gir
  -- en setning som sier hva som er galt framfor en fremmednøkkel- eller
  -- casting-feil lenger ned. Kontrollen står først også fordi kanoniseringen
  -- under forutsetter en liste.
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
  select c.check_field
    into v_duplicate_field
  from knowledge.canonical_field_groundings(p_field_groundings) c
  group by c.check_field
  having count(*) > 1
  limit 1;

  if v_duplicate_field is not null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Feltet %L er forankret mer enn én gang.', v_duplicate_field),
      hint = 'Ett felt har én forankring: det minste ordrette utdraget som er tilstrekkelig for å bedømme nettopp det feltet. Er to utdrag nødvendige, hører de til ett utdrag med begge setningene.';
  end if;

  -- Et tomt sitatfelt er et fravær, ikke et tomt sitat. Ingen validering av
  -- innholdet: et sitat er ordrett tekst fra kilden, og det er ikke noe her
  -- som kan avgjøre om det er riktig gjengitt — det er verifikatorens oppgave
  -- (ANTIDEP_CONSTITUTION.md §11).
  --
  -- Utledet én gang og brukt to steder: i innsettingen, og i radvariabelen som
  -- avtrykket beregnes av. To uttrykk ville kunnet komme i utakt, og da ville
  -- oppslaget etter en dublett pekt på feil rad eller på ingen.
  v_raw_extraction := case
    when nullif(btrim(coalesce(p_source_quote, '')), '') is null then null
    else jsonb_build_object('sitat', btrim(p_source_quote))
  end;

  -- Samme begrunnelse for forankringen: avtrykket og radene den beskriver må
  -- komme fra én kanonisering, ellers ville den utsatte kontrollen i migrasjon
  -- 003d avvist transaksjonen ved commit.
  v_grounding_digest := knowledge.evidence_field_grounding_digest(p_field_groundings);

  -- Feltene knowledge.evidence_item_content_hash(knowledge.evidence_items)
  -- leser, og bare de. Alt annet på raden — id, tidsstempler, aktør,
  -- agentkjøring — inngår ikke i identiteten og settes derfor ikke her.
  v_candidate.source_id := p_source_id;
  v_candidate.source_version_id := p_source_version_id;
  v_candidate.design_code := p_design_code::knowledge.study_design;
  v_candidate.population_id := p_population_id;
  v_candidate.population_availability := p_population_availability::knowledge.value_availability;
  v_candidate.population_detail := p_population_detail;
  v_candidate.sample_size := p_sample_size;
  v_candidate.sample_size_availability := p_sample_size_availability::knowledge.value_availability;
  v_candidate.intervention_drug_id := p_intervention_drug_id;
  v_candidate.intervention_detail := p_intervention_detail;
  v_candidate.comparator_kind := p_comparator_kind::knowledge.comparator_kind;
  v_candidate.comparator_drug_id := p_comparator_drug_id;
  v_candidate.comparator_detail := p_comparator_detail;
  v_candidate.outcome_concept_id := p_outcome_concept_id;
  v_candidate.outcome_detail := p_outcome_detail;
  v_candidate.timepoint_min := p_timepoint_min::interval;
  v_candidate.timepoint_max := p_timepoint_max::interval;
  v_candidate.timepoint_availability := p_timepoint_availability::knowledge.value_availability;
  v_candidate.reported_direction := p_reported_direction::knowledge.effect_direction;
  v_candidate.effect_measure := p_effect_measure::knowledge.effect_measure;
  v_candidate.estimate := p_estimate;
  v_candidate.estimate_unit := p_estimate_unit::knowledge.estimate_unit;
  v_candidate.estimate_availability := p_estimate_availability::knowledge.value_availability;
  v_candidate.ci_lower := p_ci_lower;
  v_candidate.ci_upper := p_ci_upper;
  v_candidate.ci_level_percent := p_ci_level_percent;
  v_candidate.confidence_interval_availability :=
    p_confidence_interval_availability::knowledge.value_availability;
  v_candidate.limitations_text := p_limitations_text;
  v_candidate.source_locator := p_source_locator;
  v_candidate.extraction_method := p_extraction_method::knowledge.extraction_method;
  v_candidate.raw_extraction := v_raw_extraction;
  v_candidate.grounding_digest := v_grounding_digest;

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
    grounding_digest, created_by_actor_id, agent_run_id
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
    p_extraction_method::knowledge.extraction_method,
    v_raw_extraction,
    v_grounding_digest,
    p_created_by_actor_id,
    p_agent_run_id
  )
  returning id into v_evidence_item_id;

  -- Forankringen, i samme transaksjon. Aktøren er den samme som laget funnet,
  -- og den sammensatte fremmednøkkelen på tabellen håndhever nettopp det.
  -- Verdiene kommer fra den samme kanoniseringen avtrykket ble regnet av.
  begin
    insert into knowledge.evidence_field_groundings (
      evidence_item_id, created_by_actor_id, check_field,
      source_excerpt, source_locator, justification
    )
    select
      v_evidence_item_id,
      p_created_by_actor_id,
      c.check_field::workflow.evidence_check_field,
      c.source_excerpt,
      c.source_locator,
      c.justification
    from knowledge.canonical_field_groundings(p_field_groundings) c;
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
  -- Den eneste oversatte avvisningen. content_hash dekker de strukturerte
  -- feltene på raden *og* avtrykket av kildeforankringen (sha256-v3), så en
  -- dublett er den samme registreringen, med den samme forankringen, en gang
  -- til — og en korreksjon av et hvilket som helst av dem, forankringen
  -- inkludert, gir en ny hash og slipper inn ved siden av den gamle
  -- (migrasjon 003, 006a, 003d).
  --
  -- Avvisningen navngir raden som kolliderte, i detail. Uten det måtte en
  -- kaller som vil gjenoppta en avbrutt kjøring gjette seg til hvilken rad det
  -- var, og en gjetning på noe annet enn den kanoniske identiteten kan peke på
  -- feil rad: to funn fra den samme kildeversjonen kan legitimt dele forankring
  -- og likevel gjelde ulike utfall (migrasjon 007h). Oppslaget bruker nøyaktig
  -- den identiteten UNIQUE-regelen bruker — den samme funksjonen, på en
  -- radvariabel satt av de samme uttrykkene som innsettingen.
  --
  -- Finner oppslaget ingenting, står detail tomt framfor å påstå noe. Det er
  -- ikke det forventede tilfellet, men en påstand uten dekning er verre enn en
  -- manglende opplysning.
  when unique_violation then
    select e.id into v_existing_id
    from knowledge.evidence_items e
    where e.content_hash = knowledge.evidence_item_content_hash(v_candidate)
      and e.id is distinct from v_evidence_item_id;

    raise exception using
      errcode = 'unique_violation',
      message = 'Nøyaktig det samme evidensfunnet er allerede registrert.',
      detail = case
        when v_existing_id is null then 'Den kolliderende raden lot seg ikke slå opp.'
        else format('evidence_item_id=%s', v_existing_id)
      end,
      hint = 'Et evidensfunn identifiseres av hele sitt faglige innhold, kildeforankringen medregnet. Er dette en korreksjon, skal minst én strukturert verdi eller minst ett utdrag, én kildepeker eller én begrunnelse være endret — da registreres den som et nytt funn ved siden av det gamle, og det gamle består (knowledge.evidence_items er append-only). Det nye funnet arver ingen kontroll: det må selv gjennom maskinkontrollen og den menneskelige ekstraksjonskontrollen.';
end;
$$;

comment on function knowledge.record_evidence_item(
  uuid, text, text, text, text, uuid, text, uuid, text, text, text, text, text, text,
  uuid, uuid, integer, text, uuid, text, text, text, text, numeric, text, numeric,
  numeric, numeric, text, text, jsonb, text, uuid, uuid
) is
  'Innsettingen av ett evidensfunn med sin kildeforankring, uten autorisasjon. Finnes fordi det fra migrasjon 005v av er to skriveveier inn i knowledge.evidence_items — editoren med sesjon og editor-rolle, og ekstraksjonsagenten med legitimasjon og en åpen kjøring — og de to skal håndheve nøyaktig de samme invariantene: vokabularverdiene, hvordan raw_extraction bygges av ett sitat under én dokumentert nøkkel, at forankringen skrives i samme transaksjon og attribueres til den som laget funnet, og hvordan dubletten oversettes. Kalleren har allerede avgjort hvem aktøren er og hvilken ekstraksjonsmetode raden har; ingen av de to er verdier som kommer fra klienten. content_hash eies av databasen. Fra migrasjon 003d dekker identiteten også kildeforankringen: forankringen kanoniseres én gang av knowledge.canonical_field_groundings(jsonb), avtrykket legges på raden som grounding_digest, og både innsettingen i knowledge.evidence_field_groundings og avtrykket bygges av den samme kanoniseringen. Et forslag som bare retter et utdrag, en kildepeker eller en begrunnelse, blir dermed et nytt evidensfunn ved siden av det gamle — som må gjennom de samme kontrollene selv (issue #66). Dublettavvisningen navngir fra migrasjon 007h raden som kolliderte, i detail, slått opp med den samme kanoniske identiteten UNIQUE-regelen bruker — slik at en kjøring som ble avbrutt mellom registreringen og kontrollen, kan fullføre kontrollen av nøyaktig den raden framfor å gjette. Ingen feltvalidering er duplisert her: constraintene på knowledge.evidence_items og knowledge.evidence_field_groundings er fasiten, og deres avvisninger propageres uendret.';
