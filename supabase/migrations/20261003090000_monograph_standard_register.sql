-- ============================================================================
-- Migrasjon 013a — monografistandarden som et versjonert register i databasen
--
-- `docs/MONOGRAPH_STANDARD.md` sier hva en monografi skal undersøke, og
-- `docs/SOURCE_POLICY.md` sier hvor grunnlaget skal letes etter. Begge er
-- skrevet for mennesker, og fram til nå har ingenting i Antidep kunnet lese
-- dem: en bestilling kunne ikke opprette behov av 80 maler den ikke visste
-- fantes, og en søkeplan kunne ikke vite hvilke søkespor en profil krever.
--
-- Denne migrasjonen legger inn den samme standarden som rader.
--
-- ----------------------------------------------------------------------------
-- Ett register, lest fra to sider
--
-- Verdiene her er ikke skrevet av for hånd. `src/monograph/standard.ts`
-- uttrykker den samme kontrakten for flaten og agentoppgavene, og
-- `standard-seed.ts` bygger nøyaktig den seedteksten som står nederst i denne
-- filen. To prøver holder de tre fra å drive fra hverandre:
--
--   * `standard.test.ts` leser begge dokumentene på nytt og krever at hver rad
--     er den samme — kode for kode, kravtype for kravtype, profil for profil.
--   * `standard-seed.test.ts` bygger seeden på nytt og krever at denne filen
--     inneholder den ordrett.
--
-- Det er den samme formen `model-roles.ts` har mot migrasjon 009c. Tre steder
-- som ikke *kan* si forskjellige ting, er ikke tre registre.
--
-- ----------------------------------------------------------------------------
-- Hvorfor versjonen står på hver rad
--
-- Fordi en ny standardversjon aldri skal kunne endre spørsmålet under et svar
-- som allerede finnes (MONOGRAPH_STANDARD.md §9). Et dekningskart bærer
-- versjonen det ble opprettet under, og behovene peker på malradene i nettopp
-- den versjonen. En ny versjon er en ny migrasjon med sin egen seed; de gamle
-- radene blir stående, uforanderlige, og en godkjent monografiutgave leser
-- fortsatt sine egne spørsmål.
--
-- ----------------------------------------------------------------------------
-- Hvorfor registeret ligger i `knowledge` og ikke i et eget schema
--
-- Fordi konvensjonsvakten i `supabase/tests/030_conventions_test.sql` gjelder
-- `catalog`, `knowledge`, `workflow`, `provenance`, `audit` og `api`. Et nytt
-- schema ville vært utenfor hver eneste regel den håndhever — RLS, grants,
-- primærnøkkelform, tidsstempler — og en vakt som ikke dekker det nyeste
-- laget, er ikke en vakt. Standarden er dessuten kunnskap: den sier hva
-- Antidep skal undersøke.
--
-- Styrende dokumenter: docs/MONOGRAPH_STANDARD.md, docs/SOURCE_POLICY.md,
-- docs/MONOGRAPH_PLAN.md (fase C), docs/DATABASE_ARCHITECTURE.md,
-- docs/ANTIDEP_CONSTITUTION.md regel 5, 7.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Vokabularene
-- ----------------------------------------------------------------------------

create type knowledge.monograph_requirement_type as enum (
  'mandatory',
  'conditional',
  'derived'
);

revoke usage on type knowledge.monograph_requirement_type from public;

comment on type knowledge.monograph_requirement_type is
  'Kravtypen til én spørsmålsmal (MONOGRAPH_STANDARD.md §3): mandatory er obligatorisk å undersøke, conditional er betinget fordypning etter en angitt utløser, og derived er en avledet presentasjon bygget av allerede kontrollerte svar. mandatory betyr at malen skal undersøkes, ikke at et positivt eller presist svar må finnes: et nøytralt, negativt eller usikkert forskningsutfall er et gyldig svar, mens glemt arbeid, manglende tilgang og teknisk svikt ikke er det. Skillet er hele grunnen til at dekningskartet ikke kan flate ut relevans, arbeidstilstand og faglig utfall til ett tall.';

create type knowledge.monograph_answer_form as enum (
  'fact',
  'table',
  'estimate',
  'advice',
  'profile',
  'relation',
  'directed_relation',
  'summary',
  'derived'
);

revoke usage on type knowledge.monograph_answer_form from public;

comment on type knowledge.monograph_answer_form is
  'Svarformen malen ber om (MONOGRAPH_STANDARD.md §2): fact (strukturert faktum eller klassifikasjon), table (en samling slike poster med egen identitet per rad), estimate (tall med definisjon og kontekst), advice (attribuert råd med handling, betingelser og hvem som anbefaler), profile (flere navngitte delutfall med egne svar, ikke en udokumentert totalskår), relation (en relasjon mellom to navngitte størrelser), directed_relation (en rettet relasjon der A→B og B→A er forskjellige svar), summary (en kildebelagt sammenfatning, blant annet en begrunnet ikke-sammenlignbarhet) og derived (sammensatt av allerede kontrollerte svar uten ny klinisk kunnskap). En mal kan ha flere former; da er hver form et eget kontrollerbart svar.';

create type knowledge.monograph_scope_axis as enum (
  'product',
  'formulation',
  'indication',
  'population',
  'treatment_phase',
  'outcome',
  'comparator',
  'dose',
  'timeframe',
  'interaction_partner',
  'exposure',
  'comorbidity',
  'risk_area',
  'gene',
  'switch_target',
  'finding'
);

revoke usage on type knowledge.monograph_scope_axis from public;

comment on type knowledge.monograph_scope_axis is
  'Aksene et kunnskapsbehov avgrenses og gjentas på (MONOGRAPH_STANDARD.md §2, §3). Avgrensningen følger svaret: to svar skal ikke kollidere fordi begge gjelder det samme virkestoffet og det samme overordnede temaet, når indikasjon, populasjon, dose, formulering, komparator eller tidsrom er forskjellig. switch_target er rettet med vilje — A→B og B→A er forskjellige behov, og kildedata kan gjenbrukes uten at rådet speilvendes (§3.12).';

-- ----------------------------------------------------------------------------
-- 2. Standardversjonen
--
-- Raden er uforanderlig etter at den er lagt inn. Den er det en monografiutgave
-- peker på, og en omskriving ville endret spørsmålene under svar som allerede
-- er godkjent.
-- ----------------------------------------------------------------------------

create table knowledge.monograph_standard_versions (
  id uuid primary key default gen_random_uuid(),
  version text not null,
  title text not null,
  -- Dokumentet standarden er skrevet i. Peker på repoet og ikke på en adresse:
  -- den faglige fasiten er en fil under review, ikke en side som kan endres.
  document_path text not null,
  published_on date not null,
  notes text,
  created_at timestamptz not null default now(),

  constraint monograph_standard_versions_version_key unique (version),
  constraint monograph_standard_versions_version_shape_check
    check (version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'),
  constraint monograph_standard_versions_title_shape_check
    check (title = btrim(title) and length(title) between 1 and 300),
  constraint monograph_standard_versions_document_path_shape_check
    check (document_path = btrim(document_path) and length(document_path) between 1 and 300)
);

comment on table knowledge.monograph_standard_versions is
  'Én rad per versjon av monografistandarden (MONOGRAPH_STANDARD.md). Uforanderlig: en monografiutgave peker på versjonen den ble opprettet under, og en omskriving ville endret spørsmålene under svar som allerede er kontrollert eller godkjent (§9). En ny standardversjon er en ny rad og en ny migrasjon med sin egen seed.';

alter table knowledge.monograph_standard_versions enable row level security;

-- ----------------------------------------------------------------------------
-- 3. Kildeprofilene
-- ----------------------------------------------------------------------------

create table knowledge.monograph_source_profiles (
  id uuid primary key default gen_random_uuid(),
  standard_version text not null
    references knowledge.monograph_standard_versions (version)
    on update restrict on delete restrict,
  code text not null,
  ordinal integer not null,
  question text not null,
  first_choice text not null,
  supplement text not null,
  created_at timestamptz not null default now(),

  constraint monograph_source_profiles_version_code_key unique (standard_version, code),
  constraint monograph_source_profiles_version_ordinal_key unique (standard_version, ordinal),
  constraint monograph_source_profiles_code_shape_check
    check (code ~ '^[A-Z]{2,4}$'),
  constraint monograph_source_profiles_ordinal_check check (ordinal between 1 and 99),
  constraint monograph_source_profiles_question_shape_check
    check (question = btrim(question) and length(question) between 1 and 500),
  constraint monograph_source_profiles_first_choice_shape_check
    check (first_choice = btrim(first_choice) and length(first_choice) between 1 and 2000),
  constraint monograph_source_profiles_supplement_shape_check
    check (supplement = btrim(supplement) and length(supplement) between 1 and 2000)
);

comment on table knowledge.monograph_source_profiles is
  'De 13 kildeprofilene i SOURCE_POLICY.md §3, per standardversjon. Profilen sier hvilke kilder som er første valg for et spørsmål og hva som må suppleres eller kontrolleres særskilt. Flere profiler på samme mal betyr at forskjellige deler av svaret trenger hvert sitt grunnlag; de er ikke alternative snarveier. En profil er ikke en universell godkjenning av en kilde: egnetheten vurderes for et navngitt spørsmål og en bestemt bruk.';

alter table knowledge.monograph_source_profiles enable row level security;

-- ----------------------------------------------------------------------------
-- 4. Spørsmålsmalene
-- ----------------------------------------------------------------------------

create table knowledge.monograph_question_templates (
  id uuid primary key default gen_random_uuid(),
  standard_version text not null
    references knowledge.monograph_standard_versions (version)
    on update restrict on delete restrict,
  -- Den stabile identiteten: MN01–MN80. Endres aldri (MONOGRAPH_STANDARD.md §9).
  code text not null,
  ordinal integer not null,
  section text not null,
  prompt text not null,
  requirement knowledge.monograph_requirement_type not null,
  -- Kravkolonnen ordrett, fordi «O screening; B fordypning» ikke er bare «O».
  requirement_text text not null,
  condition_text text,
  conditional_deepening text,
  answer_forms knowledge.monograph_answer_form[] not null,
  -- MN80 har ingen forhåndsbestemt kildeprofil: profilen følger av funnet.
  open_source_profiles boolean not null default false,
  expansion_axes knowledge.monograph_scope_axis[] not null default array[]::knowledge.monograph_scope_axis[],
  created_at timestamptz not null default now(),

  constraint monograph_question_templates_version_code_key unique (standard_version, code),
  constraint monograph_question_templates_version_ordinal_key unique (standard_version, ordinal),
  constraint monograph_question_templates_code_shape_check
    check (code ~ '^MN[0-9]{2}$'),
  constraint monograph_question_templates_ordinal_check check (ordinal between 1 and 999),
  constraint monograph_question_templates_section_shape_check
    check (section = btrim(section) and length(section) between 1 and 200),
  constraint monograph_question_templates_prompt_shape_check
    check (prompt = btrim(prompt) and length(prompt) between 1 and 1000),
  constraint monograph_question_templates_requirement_text_shape_check
    check (requirement_text = btrim(requirement_text)
           and length(requirement_text) between 1 and 200),
  constraint monograph_question_templates_condition_shape_check
    check (condition_text is null
           or (condition_text = btrim(condition_text)
               and length(condition_text) between 1 and 500)),
  constraint monograph_question_templates_deepening_shape_check
    check (conditional_deepening is null
           or (conditional_deepening = btrim(conditional_deepening)
               and length(conditional_deepening) between 1 and 500)),
  -- En betinget mal uten betingelse ville vært en mal ingen kan avgjøre
  -- relevansen av; en avledet uten sin egen ville vært det samme.
  constraint monograph_question_templates_condition_required_check
    check (requirement = 'mandatory' or condition_text is not null),
  constraint monograph_question_templates_answer_forms_check
    check (cardinality(answer_forms) between 1 and 3),
  constraint monograph_question_templates_axes_check
    check (cardinality(expansion_axes) <= 6)
);

comment on table knowledge.monograph_question_templates is
  'De 80 spørsmålsmalene MN01–MN80 i MONOGRAPH_STANDARD.md §3, per standardversjon. Koden er den stabile identiteten og endres aldri. requirement skiller obligatorisk å undersøke fra betinget fordypning og avledet presentasjon, og conditional_deepening bærer den betingede fordypningen som følger en obligatorisk screening — «O screening; B fordypning» er to krav, ikke ett. expansion_axes sier hvilke akser malen gjentas på: 80 maler betyr ikke 80 behov.';
comment on column knowledge.monograph_question_templates.open_source_profiles is
  'Malen har ingen forhåndsbestemt kildeprofil, fordi profilen følger av funnet. Gjelder MN80, og er ikke en åpning for et fritekstfelt uten kontroll: hvert tillegg får avgrensning, kildeprofil, svarform, relevans og dokumentasjon som øvrige behov (MONOGRAPH_STANDARD.md §3.14).';

alter table knowledge.monograph_question_templates enable row level security;

create table knowledge.monograph_template_profiles (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null
    references knowledge.monograph_question_templates (id)
    on update restrict on delete restrict,
  profile_id uuid not null
    references knowledge.monograph_source_profiles (id)
    on update restrict on delete restrict,
  ordinal integer not null,
  created_at timestamptz not null default now(),

  constraint monograph_template_profiles_pair_key unique (template_id, profile_id),
  constraint monograph_template_profiles_order_key unique (template_id, ordinal),
  constraint monograph_template_profiles_ordinal_check check (ordinal between 1 and 9)
);

comment on table knowledge.monograph_template_profiles is
  'Koblingen mellom én spørsmålsmal og kildeprofilene standarden oppgir for den, i standardens egen rekkefølge. Flere profiler betyr at forskjellige deler av svaret trenger hvert sitt grunnlag (SOURCE_POLICY.md §3).';

alter table knowledge.monograph_template_profiles enable row level security;

-- ----------------------------------------------------------------------------
-- 5. Søkesporene
--
-- Minimumsdekningen i SOURCE_POLICY.md §4.2: sporene som må være *forsøkt og
-- dokumentert* før søkedekningen kan erklæres ferdig. Et spor som ikke er
-- forsøkt, hindrer avslutning; et spor som var utilgjengelig, er en registrert
-- begrensning og ikke null treff (§8.2).
-- ----------------------------------------------------------------------------

create table knowledge.monograph_search_tracks (
  id uuid primary key default gen_random_uuid(),
  standard_version text not null
    references knowledge.monograph_standard_versions (version)
    on update restrict on delete restrict,
  code text not null,
  ordinal integer not null,
  label text not null,
  created_at timestamptz not null default now(),

  constraint monograph_search_tracks_version_code_key unique (standard_version, code),
  constraint monograph_search_tracks_version_ordinal_key unique (standard_version, ordinal),
  constraint monograph_search_tracks_code_shape_check
    check (code ~ '^[a-z][a-z0-9_]{2,60}$'),
  constraint monograph_search_tracks_ordinal_check check (ordinal between 1 and 99),
  constraint monograph_search_tracks_label_shape_check
    check (label = btrim(label) and length(label) between 1 and 300)
);

comment on table knowledge.monograph_search_tracks is
  'Søkesporene SOURCE_POLICY.md §4.2 krever forsøkt og dokumentert per kildeprofil. Sporet er et krav til *dokumentasjon av forsøket*, ikke en anbefaling: et spor som ikke er forsøkt, hindrer at søkedekningen kan erklæres ferdig, og et spor som var utilgjengelig, registreres som en begrensning framfor som null treff.';

alter table knowledge.monograph_search_tracks enable row level security;

create table knowledge.monograph_search_track_profiles (
  id uuid primary key default gen_random_uuid(),
  track_id uuid not null
    references knowledge.monograph_search_tracks (id)
    on update restrict on delete restrict,
  profile_id uuid not null
    references knowledge.monograph_source_profiles (id)
    on update restrict on delete restrict,
  created_at timestamptz not null default now(),

  constraint monograph_search_track_profiles_pair_key unique (track_id, profile_id)
);

comment on table knowledge.monograph_search_track_profiles is
  'Hvilke kildeprofiler et søkespor er obligatorisk for (SOURCE_POLICY.md §4.2).';

alter table knowledge.monograph_search_track_profiles enable row level security;

-- ----------------------------------------------------------------------------
-- 5c. Verdiene standarden selv navngir
--
-- Fire maler er screeningsspørsmål med en liste standarden skriver ut: MN38
-- navngir elleve alvorlige risikoområder, MN50 fire psykiatriske
-- tilleggstilstander, MN51 seks somatiske forhold og MN55 fem eksponeringer
-- (MONOGRAPH_STANDARD.md §3.6, §3.7, §3.8).
--
-- De hører i registeret og ikke i en utvidelsesregel, fordi de er *spørsmål
-- standarden stiller* og ikke funn en agent gjør. «MN38 skal minst vurdere …»
-- er et krav om å undersøke, og ikke en erklæring om at hvert virkestoff gir
-- hver risiko. Et dekningskart oppretter derfor ett behov per verdi med én
-- gang, framfor å vente på at noe blir dokumentert — og en risiko som ikke er
-- undersøkt, blir da synlig framfor å mangle.
-- ----------------------------------------------------------------------------

create table knowledge.monograph_prescribed_scope_values (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null
    references knowledge.monograph_question_templates (id)
    on update restrict on delete restrict,
  axis knowledge.monograph_scope_axis not null,
  label text not null,
  ordinal integer not null,
  created_at timestamptz not null default now(),

  constraint monograph_prescribed_scope_values_key unique (template_id, axis, label),
  constraint monograph_prescribed_scope_values_ordinal_key unique (ordinal),
  constraint monograph_prescribed_scope_values_label_shape_check
    check (label = btrim(label) and length(label) between 1 and 300),
  constraint monograph_prescribed_scope_values_ordinal_check check (ordinal between 1 and 999)
);

comment on table knowledge.monograph_prescribed_scope_values is
  'Avgrensningsverdiene standarden selv navngir for en screeningsmal: de elleve risikoområdene i MN38, de psykiatriske tilstandene i MN50, de somatiske forholdene i MN51 og eksponeringene i MN55. De er spørsmål standarden stiller og ikke funn en agent gjør, så et dekningskart oppretter ett behov per verdi med én gang — en risiko som ikke er undersøkt, blir da synlig framfor å mangle. Ordinalen er standardens egen rekkefølge.';

alter table knowledge.monograph_prescribed_scope_values enable row level security;

create index monograph_prescribed_scope_values_template_idx
  on knowledge.monograph_prescribed_scope_values (template_id, ordinal);

-- ----------------------------------------------------------------------------
-- 5b. created_at eies av databasen, ikke av innleggingen
--
-- En ren default gjelder bare når kolonnen utelates. Registeret er append-only,
-- og tidspunktet er det en senere migrering og en dekningsoversikt leser; en
-- verdi en innlegging kunne oppgi, ville ikke vært databasens observasjon.
-- Samme regel som resten av `knowledge`, håndhevet av
-- supabase/tests/080_knowledge_structure_test.sql.
-- ----------------------------------------------------------------------------

create trigger monograph_standard_versions_set_created_at
  before insert or update on knowledge.monograph_standard_versions
  for each row execute function catalog.set_created_at();
create trigger monograph_source_profiles_set_created_at
  before insert or update on knowledge.monograph_source_profiles
  for each row execute function catalog.set_created_at();
create trigger monograph_question_templates_set_created_at
  before insert or update on knowledge.monograph_question_templates
  for each row execute function catalog.set_created_at();
create trigger monograph_template_profiles_set_created_at
  before insert or update on knowledge.monograph_template_profiles
  for each row execute function catalog.set_created_at();
create trigger monograph_search_tracks_set_created_at
  before insert or update on knowledge.monograph_search_tracks
  for each row execute function catalog.set_created_at();
create trigger monograph_search_track_profiles_set_created_at
  before insert or update on knowledge.monograph_search_track_profiles
  for each row execute function catalog.set_created_at();
create trigger monograph_prescribed_scope_values_set_created_at
  before insert or update on knowledge.monograph_prescribed_scope_values
  for each row execute function catalog.set_created_at();

-- ----------------------------------------------------------------------------
-- 6. Registeret er uforanderlig
--
-- Samme grep som for kildeversjoner og modelltildelinger: standarden er et
-- historisk faktum som svar og dekningskart hviler på. En rettelse med
-- meningsendring er en ny standardversjon, ikke en omskriving av denne.
-- ----------------------------------------------------------------------------

create function knowledge.freeze_monograph_standard()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  raise exception using
    errcode = 'restrict_violation',
    message = 'Monografistandardens register er uforanderlig.',
    hint = 'Et dekningskart peker på malradene i den versjonen det ble opprettet under, og en endring her ville endret spørsmålet under et svar som allerede er kontrollert eller godkjent (MONOGRAPH_STANDARD.md §9). En ny standardversjon er en ny versjonsrad med sin egen seed.';
end;
$$;

comment on function knowledge.freeze_monograph_standard() is
  'Avviser enhver endring eller sletting i monografistandardens register. Standarden er et historisk faktum svarene hviler på; en ny versjon legges inn som nye rader ved siden av de gamle.';

revoke execute on function knowledge.freeze_monograph_standard() from public;

create trigger monograph_standard_versions_are_frozen
  before update or delete on knowledge.monograph_standard_versions
  for each row execute function knowledge.freeze_monograph_standard();
create trigger monograph_source_profiles_are_frozen
  before update or delete on knowledge.monograph_source_profiles
  for each row execute function knowledge.freeze_monograph_standard();
create trigger monograph_question_templates_are_frozen
  before update or delete on knowledge.monograph_question_templates
  for each row execute function knowledge.freeze_monograph_standard();
create trigger monograph_template_profiles_are_frozen
  before update or delete on knowledge.monograph_template_profiles
  for each row execute function knowledge.freeze_monograph_standard();
create trigger monograph_search_tracks_are_frozen
  before update or delete on knowledge.monograph_search_tracks
  for each row execute function knowledge.freeze_monograph_standard();
create trigger monograph_search_track_profiles_are_frozen
  before update or delete on knowledge.monograph_search_track_profiles
  for each row execute function knowledge.freeze_monograph_standard();
create trigger monograph_prescribed_scope_values_are_frozen
  before update or delete on knowledge.monograph_prescribed_scope_values
  for each row execute function knowledge.freeze_monograph_standard();

-- ----------------------------------------------------------------------------
-- 7. Versjon 1.0.0
-- ----------------------------------------------------------------------------

insert into knowledge.monograph_standard_versions
  (version, title, document_path, published_on, notes)
values (
  '1.0.0',
  'Antidep Monograph Standard v1',
  'docs/MONOGRAPH_STANDARD.md',
  date '2026-09-17',
  'Fase A og B i monografiplanen. Spørsmålsregisteret er MONOGRAPH_STANDARD.md §3; kildeprofilene og søkesporene er SOURCE_POLICY.md §3 og §4.2. Radene under er bygget av src/monograph/standard-seed.ts, som src/monograph/standard-seed.test.ts kontrollerer mot denne filen.'
);

-- >>> BEGYNNELSEN PÅ DEN GENERERTE SEEDEN (src/monograph/standard-seed.ts) <<<

insert into knowledge.monograph_source_profiles
  (standard_version, code, ordinal, question, first_choice, supplement)
values
  ('1.0.0', 'REG', 1,
   'Norsk godkjenning, dosegrenser, kontraindikasjoner, preparathåndtering',
   'Gjeldende norsk myndighetsgodkjent preparatomtale, identifisert via DMP/Legemiddelsøk; relevant EMA-produktinformasjon når den gjelder produktet',
   'Faglige råd merkes separat. Behold forskjeller mellom produkter, formuleringer, indikasjoner og aldersgrupper. Kontroller at versjonen ikke er avløst.'),
  ('1.0.0', 'PROD', 2,
   'Preparater, styrker, pakninger, markedsføring og refusjon',
   'Gjeldende DMP-legemiddeldata, FEST/FHIR der egnet og tilgjengelig, samt produktets preparatomtale',
   'Mangelsituasjon og lokal lagerstatus er egne forhold. Leverandørens faktiske datadekning og vilkår må kontrolleres før integrasjon. En synlig delestrek er ikke dokumentasjon på like deldoser.'),
  ('1.0.0', 'EFF', 3,
   'Effekt, dose–respons, behandlingsfaser og sammenligning',
   'Relevante systematiske oversikter, eventuelt nettverksmetaanalyser, med lesbar metode og dekkende populasjon, komparator og utfall',
   'Oppdateringssøk etter oversiktens siste søkedato; sentrale primærstudier ved hull, motstrid eller behov for kontroll. Observasjonsstudier vurderes separat, ikke som automatisk erstatning for randomisering.'),
  ('1.0.0', 'AE', 4,
   'Vanlige bivirkninger og behandlingsavbrudd',
   'Kontrollerte studier og systematiske oversikter med brukbare nevnere og registreringsmetoder; preparatomtalen som regulatorisk oversikt',
   'Skill aktiv utspørring fra spontanrapportering i en studie, varighet, dose og baselineplager. Frekvenskategorier fra forskjellige preparatomtaler er ikke en komparativ studie.'),
  ('1.0.0', 'SAFE', 5,
   'Alvorlige, sjeldne eller vedvarende skader',
   'Preparatomtaler og myndighetenes sikkerhetsvurderinger, supplert med egnede oversikter, store observasjonsstudier og målrettede primærstudier',
   'Kasuistikker og meldesystemer kan gi signaler; de gir ikke alene insidens eller bevist årsak. Kontroller eksponering, nevner, tidsforløp, alternative forklaringer og mulig rapporteringsskjevhet (S11).'),
  ('1.0.0', 'POP', 6,
   'Graviditet, amming, alder, organsvikt og komorbiditet',
   'REG for godkjenningsgrenser; relevante spesialistretningslinjer og systematiske oversikter/primærstudier i den aktuelle gruppen',
   'Teratologiske/laktasjonsfaglige oppslagsverk og norske faglige råd kan brukes som attribuert veiledning når versjon, begrunnelse og tilgang kan kontrolleres. Skill risiko ved behandling fra risiko ved sykdom og behandlingsstopp.'),
  ('1.0.0', 'INT', 7,
   'Interaksjoner og praktisk håndtering',
   'REG og dokumenterte kliniske interaksjonsstudier; egnet nasjonal interaksjonsinformasjon og faglige retningslinjer',
   'Skill eksponeringsendring fra dokumentert klinisk utfall, in vitro fra mennesker og mekanisme fra håndteringsråd. Registrer begge virkestoffene, retning, dose, varighet og vedvarende virkning etter stopp.'),
  ('1.0.0', 'PK', 8,
   'Farmakokinetikk og farmakodynamikk',
   'REG og humane PK-/PD-studier, supplert med faglige synteser',
   'Arts-/in vitro-data merkes og kan ikke alene begrunne klinisk effekt. Behold dose, formulering, analytt/metabolitt, matriks, tidspunkt, studiepopulasjon og målemetode.'),
  ('1.0.0', 'PGX', 9,
   'Genetikk og klinisk anvendelse',
   'Relevante CPIC-/DPWG-anbefalinger med identifisert versjon, supplert med REG og studiene anbefalingen bygger på',
   'Skill hvordan et eksisterende prøvesvar brukes fra hvem som bør testes. CPIC-dokumentet undersøkt her beskriver det første, ikke generell testindikasjon (S09). Behold uenighet mellom retningslinjer.'),
  ('1.0.0', 'TDM', 10,
   'Konsentrasjonsmåling og fortolkning',
   'Identifiserte faglige TDM-retningslinjer og norske laboratoriers dokumenterte analyse-/fortolkningsveiledning; relevante PK- og kliniske studier',
   'Et laboratorieintervall, et konsensusbasert terapeutisk referanseområde og et dokumentert konsentrasjon–effekt-forhold er forskjellige. Registrer analytt, matriks, prøvetid, likevekt, enhet og metode.'),
  ('1.0.0', 'STOP', 11,
   'Seponering, nedtrapping og bytte',
   'Relevante retningslinjer og faglige råd, inkludert NICE og NHS SPS der anvendelige; kontrollerte studier og oversikter når de finnes',
   'REG, PROD, PK og INT er tilleggskrav ved konkrete doser/bytteplaner. Skill veiledning og farmakologisk ekstrapolasjon fra empirisk sammenlignede strategier. Norske formuleringer må kontrolleres særskilt (S08, S10, S12).'),
  ('1.0.0', 'TOX', 12,
   'Overdosering og forgiftningsrisiko',
   'Norske oppdaterte toksikologiske anbefalinger når tilgjengelige, REG og relevante humane forgiftningsstudier',
   'Skill terapeutisk bruk fra overdose, isolert inntak fra blandingsinntak, og klinisk risiko fra rapporteringsfrekvens. Akutt behandling er ikke en automatisk doseringsfunksjon i v1.'),
  ('1.0.0', 'SYN', 13,
   'Kortoversikt og gjenbruk',
   'Allerede kontrollerte svar på de underliggende spørsmålene',
   'Ingen ny ekstern faktakilde og ingen ny klinisk slutning i sammendragsleddet. Alle meningsbærende forbehold og avvik skal følge med.')
;

insert into knowledge.monograph_question_templates
  (standard_version, code, ordinal, section, prompt, requirement, requirement_text,
   condition_text, conditional_deepening, answer_forms, open_source_profiles, expansion_axes)
values
  ('1.0.0', 'MN01', 1,
   '3.1 Identitet og norske preparater',
   'Hvilket virkestoff gjelder dette? Kanonisk navn, relevante synonymer, virkestoff-/saltangivelse og identifikatorer; kombinasjonspreparater skilles ut.',
   'mandatory', 'O',
   null, null,
   array['fact']::knowledge.monograph_answer_form[],
   false,
   array[]::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN02', 2,
   '3.1 Identitet og norske preparater',
   'Hvilken klasse og hvilke dokumenterte virkningsmekanismer har det? Skill etablert farmakologi fra hypoteser om klinisk effekt.',
   'mandatory', 'O',
   null, null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN03', 3,
   '3.1 Identitet og norske preparater',
   'Hvilke norske produkter finnes? Handelsnavn, formulering, administrasjonsvei, styrke og relevant pakningsidentitet.',
   'mandatory', 'O',
   null, null,
   array['table']::knowledge.monograph_answer_form[],
   false,
   array['product']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN04', 4,
   '3.1 Identitet og norske preparater',
   'Er produktene markedsført, avregistrert eller omfattet av kjente leveringsbegrensninger? Datakilde og tidspunkt; ikke påstå lokal lagerstatus.',
   'mandatory', 'O',
   null, null,
   array['table']::knowledge.monograph_answer_form[],
   false,
   array['product']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN05', 5,
   '3.1 Identitet og norske preparater',
   'Hvordan kan hvert produkt håndteres? Like deldoser, svelging, knusing, åpning, oppløsning eller fortynning; «ikke dokumentert» må kunne vises.',
   'mandatory', 'O',
   null, null,
   array['table']::knowledge.monograph_answer_form[],
   false,
   array['product']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN06', 6,
   '3.1 Identitet og norske preparater',
   'Hvilke hjelpestoffer, væskekonsentrasjoner, måleredskaper eller administrasjonsforhold har praktisk klinisk betydning?',
   'mandatory', 'O; detaljposter bare ved relevant forhold',
   'detaljposter bare ved relevant forhold', null,
   array['table']::knowledge.monograph_answer_form[],
   false,
   array['product']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN07', 7,
   '3.1 Identitet og norske preparater',
   'Hvilke små doser kan faktisk gis med dokumenterte norske produktmuligheter? Skill ordinært markedsførte, importerte og apotektilvirkede alternativer.',
   'mandatory', 'O',
   null, null,
   array['table']::knowledge.monograph_answer_form[],
   false,
   array['product']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN08', 8,
   '3.1 Identitet og norske preparater',
   'Hvilke norske refusjonsvilkår er relevante for aktuelle produkter/indikasjoner? Skill refusjon fra godkjenning og oppgi kontrolltidspunkt.',
   'mandatory', 'O',
   null, null,
   array['table']::knowledge.monograph_answer_form[],
   false,
   array['product', 'indication']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN09', 9,
   '3.2 Indikasjoner og behandlingsrolle',
   'Hvilke indikasjoner og aldersgrupper er godkjent i Norge for relevante produkter? Behold ordlyd og avgrensning.',
   'mandatory', 'O',
   null, null,
   array['table']::knowledge.monograph_answer_form[],
   false,
   array[]::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN10', 10,
   '3.2 Indikasjoner og behandlingsrolle',
   'Hvilken annen klinisk relevant bruk bør vurderes? Indikasjon, begrunnelse for inkludering, evidens og eventuelle frarådinger; ikke likestill bruk med anbefaling.',
   'mandatory', 'O',
   null, null,
   array['table']::knowledge.monograph_answer_form[],
   false,
   array[]::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN11', 11,
   '3.2 Indikasjoner og behandlingsrolle',
   'Hvilken plass har virkestoffet i relevante behandlingsanbefalinger? Første/senere behandlingsvalg, monoterapi/tillegg og hvilke pasienter rådet gjelder.',
   'conditional', 'B: identifisert godkjent eller relevant annen indikasjon',
   'identifisert godkjent eller relevant annen indikasjon', null,
   array['advice']::knowledge.monograph_answer_form[],
   false,
   array['indication']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN12', 12,
   '3.3 Dokumentert effekt',
   'Hvor stor er endringen i relevante symptomer sammenlignet med komparator? Instrument, absolutt/standardisert forskjell, tidsrom og presisjon.',
   'conditional', 'B: aktiv indikasjon',
   'aktiv indikasjon', null,
   array['estimate']::knowledge.monograph_answer_form[],
   false,
   array['indication', 'outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN13', 13,
   '3.3 Dokumentert effekt',
   'Hvor mange oppnår respons? Kildens responsdefinisjon, hendelser/nevnere og absolutt/relativ forskjell.',
   'conditional', 'B: aktiv indikasjon',
   'aktiv indikasjon', null,
   array['estimate']::knowledge.monograph_answer_form[],
   false,
   array['indication', 'outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN14', 14,
   '3.3 Dokumentert effekt',
   'Hvor mange oppnår remisjon? Definisjon, varighet og sammenligning; ikke bytt ut med respons.',
   'conditional', 'B: aktiv indikasjon',
   'aktiv indikasjon', null,
   array['estimate']::knowledge.monograph_answer_form[],
   false,
   array['indication', 'outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN15', 15,
   '3.3 Dokumentert effekt',
   'Hva er dokumentert om tid til bedring eller klinisk viktig effekt? Skill første statistiske utslag fra pasientrelevant bedring.',
   'conditional', 'B: aktiv indikasjon',
   'aktiv indikasjon', null,
   array['estimate', 'summary']::knowledge.monograph_answer_form[],
   false,
   array['indication', 'outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN16', 16,
   '3.3 Dokumentert effekt',
   'Hva er effekten på funksjon, livskvalitet og andre pasientviktige utfall? Ikke utled disse av symptomskår alene.',
   'conditional', 'B: aktiv indikasjon',
   'aktiv indikasjon', null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['indication', 'outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN17', 17,
   '3.3 Dokumentert effekt',
   'Hva er dokumentert om fortsatt behandling og tilbakefalls-/residivforebygging? Utvalgsberikelse, tidligere respons, varighet og seponering i kontrollarmen.',
   'conditional', 'B: aktiv indikasjon der videre behandling er aktuelt',
   'aktiv indikasjon der videre behandling er aktuelt', null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['indication', 'outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN18', 18,
   '3.3 Dokumentert effekt',
   'Hvordan varierer nytte og belastning med dose? Skill dose–respons-data fra godkjent doseområde og farmakologiske antakelser.',
   'conditional', 'B: aktiv indikasjon',
   'aktiv indikasjon', null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['indication', 'outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN19', 19,
   '3.3 Dokumentert effekt',
   'Hva vet vi ved tidligere utilstrekkelig effekt eller behandlingsresistens? Behold definisjon, antall tidligere forsøk og mono-/tilleggsbehandling.',
   'conditional', 'B: relevant behandlingssituasjon identifisert',
   'relevant behandlingssituasjon identifisert', null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['indication', 'outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN20', 20,
   '3.3 Dokumentert effekt',
   'Hva kan faktisk sammenlignes med andre antidepressiver? Navngitt par, direkte/indirekte grunnlag, utfall, tidsrom, forskjell og usikkerhet.',
   'conditional', 'B: aktiv indikasjon',
   'aktiv indikasjon', null,
   array['estimate', 'summary']::knowledge.monograph_answer_form[],
   false,
   array['indication', 'comparator', 'outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN21', 21,
   '3.4 Dosering, oppstart og oppfølging',
   'Hva er godkjent startdose per indikasjon, alder og formulering, og finnes separate faglige råd?',
   'mandatory', 'O; gjentas per relevant bruk',
   'gjentas per relevant bruk', null,
   array['table']::knowledge.monograph_answer_form[],
   false,
   array['indication', 'population', 'formulation']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN22', 22,
   '3.4 Dosering, oppstart og oppfølging',
   'Hvordan titreres behandlingen? Trinn, minste intervall, vurderingspunkter og dosebegrensende forhold; merk rådets opphav.',
   'mandatory', 'O',
   null, null,
   array['advice']::knowledge.monograph_answer_form[],
   false,
   array[]::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN23', 23,
   '3.4 Dosering, oppstart og oppfølging',
   'Hva er vanlig behandlingsområde og godkjent maksimaldose? Avgrens til produkt, indikasjon og gruppe; høyere faglig foreslått dose er et separat utsagn.',
   'mandatory', 'O',
   null, null,
   array['table']::knowledge.monograph_answer_form[],
   false,
   array['indication', 'population']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN24', 24,
   '3.4 Dosering, oppstart og oppfølging',
   'Hvordan tas legemidlet? Doseringshyppighet, tidspunkt, mat og praktisk administrasjon; koble til MN05.',
   'mandatory', 'O',
   null, null,
   array['advice']::knowledge.monograph_answer_form[],
   false,
   array[]::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN25', 25,
   '3.4 Dosering, oppstart og oppfølging',
   'Hvilke dokumenterte råd gjelder glemt dose, behandlingsavbrudd og eventuell gjenoppstart? Ikke gi én regel for alle avbruddslengder.',
   'mandatory', 'O',
   null, null,
   array['advice']::knowledge.monograph_answer_form[],
   false,
   array[]::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN26', 26,
   '3.4 Dosering, oppstart og oppfølging',
   'Hva bør avklares før oppstart? Relevante symptomer/risikofaktorer, legemidler, undersøkelser og prøver; rutinekrav skilles fra risikobasert kontroll.',
   'mandatory', 'O',
   null, null,
   array['advice']::knowledge.monograph_answer_form[],
   false,
   array[]::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN27', 27,
   '3.4 Dosering, oppstart og oppfølging',
   'Hva bør følges opp, når og med hvilke reaksjoner på funn? Effekt, tolerabilitet, sikkerhet og behandlingsvarighet; kildegrunnlag for eventuelle terskler.',
   'mandatory', 'O',
   null, null,
   array['advice']::knowledge.monograph_answer_form[],
   false,
   array[]::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN28', 28,
   '3.5 Klinisk bivirkningsprofil',
   'Hva vet vi om seksuell funksjon? Lyst, opphisselse, orgasme og andre relevante delutfall; baselineplager og målemetode.',
   'mandatory', 'O',
   null, null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN29', 29,
   '3.5 Klinisk bivirkningsprofil',
   'Hva vet vi om vekt og appetitt? Endring i kg/prosent, klinisk definert vektøkning/-tap og tidsforløp holdes atskilt.',
   'mandatory', 'O',
   null, null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN30', 30,
   '3.5 Klinisk bivirkningsprofil',
   'Hva vet vi om søvn og våkenhet? Søvnighet, tretthet, søvnløshet og søvnkvalitet er egne delutfall.',
   'mandatory', 'O',
   null, null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN31', 31,
   '3.5 Klinisk bivirkningsprofil',
   'Hva vet vi om aktivering, uro, angstforverring og akatisi? Skill tidlig reaksjon, vedvarende plager og grunnsykdom.',
   'mandatory', 'O',
   null, null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN32', 32,
   '3.5 Klinisk bivirkningsprofil',
   'Hva vet vi om gastrointestinale plager? Kvalme, oppkast, diaré og obstipasjon vurderes hver for seg.',
   'mandatory', 'O',
   null, null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN33', 33,
   '3.5 Klinisk bivirkningsprofil',
   'Hva vet vi om svette, munntørrhet og andre autonome/antikolinerge plager? Ikke utled hele profilen av reseptorbinding alene.',
   'mandatory', 'O',
   null, null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN34', 34,
   '3.5 Klinisk bivirkningsprofil',
   'Hva vet vi om kognisjon, emosjonell avflatning og daglig funksjon som mulige bivirkninger? Skill sykdomseffekt og legemiddeleffekt.',
   'mandatory', 'O',
   null, null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN35', 35,
   '3.5 Klinisk bivirkningsprofil',
   'Hvilke andre vanlige eller særlig plagsomme bivirkninger er relevante? Eksempelvis hodepine, svimmelhet og tremor; opprett navngitte delutfall.',
   'mandatory', 'O',
   null, null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN36', 36,
   '3.5 Klinisk bivirkningsprofil',
   'Hvor ofte avsluttes behandling på grunn av bivirkninger, og hvor ofte uansett årsak? Separate utfall med tidsrom og komparator.',
   'mandatory', 'O',
   null, null,
   array['estimate']::knowledge.monograph_answer_form[],
   false,
   array['outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN37', 37,
   '3.6 Alvorlig risiko og forholdsregler',
   'Hvilke kontraindikasjoner og vesentlige forholdsregler gjelder? Skill absolutt kontraindikasjon fra forsiktighet og manglende data.',
   'mandatory', 'O',
   null, null,
   array['table']::knowledge.monograph_answer_form[],
   false,
   array[]::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN38', 38,
   '3.6 Alvorlig risiko og forholdsregler',
   'Hva er dokumentert om hvert forhåndsdefinert alvorlig risikoområde nedenfor? Risiko, disponerende forhold, kunnskapstype og praktisk konsekvens.',
   'mandatory', 'O; ett behov per risikoområde',
   'ett behov per risikoområde', null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['risk_area', 'outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN39', 39,
   '3.6 Alvorlig risiko og forholdsregler',
   'Hva vet vi om suicidalitet og selvskading? Alder, behandlingsfase, grunnrisiko, hendelsesdefinisjon og datakilde; absolutt risiko når mulig.',
   'mandatory', 'O',
   null, null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN40', 40,
   '3.6 Alvorlig risiko og forholdsregler',
   'Finnes dokumentasjon på vedvarende symptomer eller skader etter avslutning? Skill sikkerhetssignal, observasjon og etablert risiko.',
   'mandatory', 'O',
   null, null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN41', 41,
   '3.6 Alvorlig risiko og forholdsregler',
   'Hvilken betydning har behandlingen for kjøring, maskiner og sikkerhetskritisk arbeid? Klinisk påvirkning skilles fra eventuelle norske rettslige helsekrav.',
   'mandatory', 'O',
   null, null,
   array['advice']::knowledge.monograph_answer_form[],
   false,
   array[]::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN42', 42,
   '3.6 Alvorlig risiko og forholdsregler',
   'Hvilke faresignaler eller funn krever rask vurdering, behandlingsendring eller spesialistkontakt? Koble rådet til den konkrete risikoen.',
   'mandatory', 'O',
   null, null,
   array['advice']::knowledge.monograph_answer_form[],
   false,
   array[]::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN43', 43,
   '3.7 Særlige pasientgrupper',
   'Hva gjelder for barn og ungdom? Indikasjon, aldersgrupper, nytte, risiko og godkjent/annen bruk.',
   'mandatory', 'O',
   null, null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN44', 44,
   '3.7 Særlige pasientgrupper',
   'Hva gjelder for eldre og skrøpelige? Dose, effektgrunnlag, multimorbiditet, fall, natrium og annen relevant oppfølging.',
   'mandatory', 'O',
   null, null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN45', 45,
   '3.7 Særlige pasientgrupper',
   'Hva gjelder i svangerskap? Tidlig/sen eksponering, foster-/svangerskaps-/neonatale utfall og risiko ved grunnsykdom/stopp; vurder videreføring separat fra nyoppstart.',
   'mandatory', 'O',
   null, null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN46', 46,
   '3.7 Særlige pasientgrupper',
   'Hva gjelder ved amming? Melkeovergang og barnets eksponering/utfall, alder/prematuritet og praktisk oppfølging; ett eksponeringsmål er ikke alene en trygghetsdom.',
   'mandatory', 'O',
   null, null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN47', 47,
   '3.7 Særlige pasientgrupper',
   'Hva vet vi om fertilitet og bruk rundt konsepsjon hos relevante grupper? Human dokumentasjon skilles fra dyredata og fra seksuelle bivirkninger.',
   'mandatory', 'O',
   null, null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN48', 48,
   '3.7 Særlige pasientgrupper',
   'Hva gjelder ved nedsatt leverfunksjon? Kildens alvorlighetsinndeling, dose, kontraindikasjoner og oppfølging.',
   'mandatory', 'O',
   null, null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN49', 49,
   '3.7 Særlige pasientgrupper',
   'Hva gjelder ved nedsatt nyrefunksjon eller dialyse? Kildens funksjonsmål, terskler/enheter, aktive metabolitter og dose-/oppfølgingsråd.',
   'mandatory', 'O',
   null, null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN50', 50,
   '3.7 Særlige pasientgrupper',
   'Hvilke psykiatriske tilleggstilstander endrer vurderingen? Minst bipolaritet/mani, psykose, rusmiddelproblemer og relevante angsttilstander undersøkes; utdyp ved betydning.',
   'mandatory', 'O screening; B fordypning',
   null, 'B fordypning',
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['comorbidity', 'outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN51', 51,
   '3.7 Særlige pasientgrupper',
   'Hvilke somatiske forhold endrer vurderingen? Minst hjerte-/karsykdom, epilepsi, blødningsrisiko, metabolsk sykdom, glaukom/urinretensjon og endret gastrointestinal anatomi/absorpsjon vurderes.',
   'mandatory', 'O screening; B fordypning',
   null, 'B fordypning',
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['comorbidity', 'outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN52', 52,
   '3.8 Interaksjoner',
   'Hvilke enzymer/transportører er relevante for substrat-, hemmer- eller induserrolle? Dokumentert klinisk betydning og styrke skilles fra in vitro-funn.',
   'mandatory', 'O',
   null, null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN53', 53,
   '3.8 Interaksjoner',
   'Hvilke farmakokinetiske kombinasjoner har praktisk betydning? Motpart, påvirket stoff, eksponeringsendring, klinisk utfall/råd og tidsforløp.',
   'conditional', 'B: identifisert relevant kombinasjon',
   'identifisert relevant kombinasjon', null,
   array['relation']::knowledge.monograph_answer_form[],
   false,
   array['interaction_partner']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN54', 54,
   '3.8 Interaksjoner',
   'Hvilke farmakodynamiske kombinasjoner krever handling? Kontraindikasjon, unngåelse, dose-/monitoreringsråd og begrunnelse.',
   'mandatory', 'O screening; B per kombinasjon',
   null, 'B per kombinasjon',
   array['relation']::knowledge.monograph_answer_form[],
   false,
   array['interaction_partner']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN55', 55,
   '3.8 Interaksjoner',
   'Hvilke interaksjoner gjelder mat, alkohol, andre rusmidler, røykestatus og natur-/kosttilskudd? Ikke gi generelle frikjennelser når data mangler.',
   'mandatory', 'O screening; B per relevant eksponering',
   null, 'B per relevant eksponering',
   array['relation']::knowledge.monograph_answer_form[],
   false,
   array['exposure']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN56', 56,
   '3.9 Farmakokinetikk og utdypende farmakologi',
   'Hva vet vi om absorpsjon? Biotilgjengelighet, Tmax, mat-/formuleringseffekt, undersøkt dose og populasjon.',
   'mandatory', 'O',
   null, null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN57', 57,
   '3.9 Farmakokinetikk og utdypende farmakologi',
   'Hva vet vi om distribusjon? Distribusjonsvolum og proteinbinding, samt dokumentert klinisk betydning.',
   'mandatory', 'O',
   null, null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN58', 58,
   '3.9 Farmakokinetikk og utdypende farmakologi',
   'Hvordan metaboliseres og elimineres stoffet? Relevante enzymer, uendret renal utskillelse, metabolittdannelse og datagrunnlag.',
   'mandatory', 'O',
   null, null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN59', 59,
   '3.9 Farmakokinetikk og utdypende farmakologi',
   'Hvilke metabolitter bidrar farmakologisk? Aktivitet, eksponering, halveringstid og klinisk betydning; ingen automatisk likestilling med moderstoffet.',
   'mandatory', 'O',
   null, null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN60', 60,
   '3.9 Farmakokinetikk og utdypende farmakologi',
   'Hvilke halveringstider er relevante? Moderstoff/metabolitt, enkelt-/gjentatt dose, terminal/annen fase og populasjon.',
   'mandatory', 'O',
   null, null,
   array['estimate', 'profile']::knowledge.monograph_answer_form[],
   false,
   array['outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN61', 61,
   '3.9 Farmakokinetikk og utdypende farmakologi',
   'Hva vet vi om likevekt, akkumulering og doseproporsjonalitet? Målte funn skilles fra modellberegninger.',
   'mandatory', 'O',
   null, null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN62', 62,
   '3.9 Farmakokinetikk og utdypende farmakologi',
   'Hvilke eksponerings-/PD-forhold har praktisk betydning utover dette? Doseavhengig hemming, vedvarende farmakologisk effekt eller klinisk relevante reseptor-/transportørdata når dokumentert.',
   'mandatory', 'O screening; B fordypning',
   null, 'B fordypning',
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['finding', 'outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN63', 63,
   '3.10 TDM og farmakogenetikk',
   'Når kan konsentrasjonsmåling være nyttig, og hva kan den ikke avklare? Klinisk indikasjon og evidens/veiledning.',
   'mandatory', 'O',
   null, null,
   array['advice']::knowledge.monograph_answer_form[],
   false,
   array[]::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN64', 64,
   '3.10 TDM og farmakogenetikk',
   'Hvordan tas og tolkes prøven? Analytt eller sum, matriks, prøvetid, likevekt, enheter, referanseområde og begrensninger.',
   'conditional', 'B: relevant TDM-anvendelse',
   'relevant TDM-anvendelse', null,
   array['table', 'advice']::knowledge.monograph_answer_form[],
   false,
   array['finding']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN65', 65,
   '3.10 TDM og farmakogenetikk',
   'Hvordan kan et eksisterende genetisk resultat påvirke valg/dose? Gen, fenotype, eksakt retningslinjeversjon, interaksjoner/fenokonversjon og usikkerhet.',
   'mandatory', 'O screening; B per relevant gen–legemiddel-par',
   null, 'B per relevant gen–legemiddel-par',
   array['relation', 'advice']::knowledge.monograph_answer_form[],
   false,
   array['gene']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN66', 66,
   '3.10 TDM og farmakogenetikk',
   'Når bør testing vurderes, og er klinisk nytte av teststrategien undersøkt? Ikke utled testindikasjon fra MN65 alene.',
   'mandatory', 'O',
   null, null,
   array['advice']::knowledge.monograph_answer_form[],
   false,
   array[]::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN67', 67,
   '3.11 Seponering og nedtrapping',
   'Hvilke seponeringssymptomer, forekomster og tidsforløp er dokumentert? Tidligere behandlingslengde, dose, seponeringsmåte og registreringsmetode.',
   'mandatory', 'O',
   null, null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN68', 68,
   '3.11 Seponering og nedtrapping',
   'Hva påvirker risiko eller behov for langsommere nedtrapping? Dokumentasjon for dose, varighet, tidligere erfaring og øvrige forhold.',
   'mandatory', 'O',
   null, null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN69', 69,
   '3.11 Seponering og nedtrapping',
   'Hvordan vurderes mulig seponering, tilbakefall og annen årsak? Typiske kjennetegn, begrensninger og oppfølging; ingen sikker automatisk klassifikasjon.',
   'mandatory', 'O',
   null, null,
   array['advice']::knowledge.monograph_answer_form[],
   false,
   array[]::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN70', 70,
   '3.11 Seponering og nedtrapping',
   'Hvilke nedtrappingsprinsipper er anbefalt og/eller undersøkt? Reduksjonsgrunnlag, trinn, intervaller, pauser og tilpasning etter symptomer.',
   'mandatory', 'O',
   null, null,
   array['advice']::knowledge.monograph_answer_form[],
   false,
   array[]::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN71', 71,
   '3.11 Seponering og nedtrapping',
   'Hvordan kan et dokumentert prinsipp realiseres med norske produkter? Kobling til MN05–MN07, faktiske doser og begrensninger, ikke bare ideelle prosenttrinn.',
   'mandatory', 'O',
   null, null,
   array['relation', 'summary']::knowledge.monograph_answer_form[],
   false,
   array['product']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN72', 72,
   '3.11 Seponering og nedtrapping',
   'Hvilken oppfølging og håndtering anbefales ved plager under/etter nedtrapping? Pause, ny vurdering, eventuell endring og når spesialist bør involveres.',
   'mandatory', 'O',
   null, null,
   array['advice']::knowledge.monograph_answer_form[],
   false,
   array[]::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN73', 73,
   '3.12 Bytte mellom antidepressiver',
   'Hvilken strategi er dokumentert/anbefalt fra A til B? Retning, dose-/formuleringsforutsetninger, direkte bytte, nedtrapping, overlapp eller legemiddelfritt intervall.',
   'conditional', 'B: bestilt eller klinisk relevant identifisert byttepar',
   'bestilt eller klinisk relevant identifisert byttepar', null,
   array['directed_relation']::knowledge.monograph_answer_form[],
   false,
   array['switch_target']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN74', 74,
   '3.12 Bytte mellom antidepressiver',
   'Hvilke overlapp eller intervaller er kontraindisert, nødvendige eller usikre? Begrunnelse, aktive metabolitter og vedvarende farmakologisk virkning.',
   'conditional', 'B: samme byttepar som MN73',
   'samme byttepar som MN73', null,
   array['directed_relation']::knowledge.monograph_answer_form[],
   false,
   array['switch_target']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN75', 75,
   '3.12 Bytte mellom antidepressiver',
   'Hva skal følges opp under og etter dette byttet, og når skal planen ikke brukes? Seponering, tilbakefall, interaksjoner og særgrupper.',
   'conditional', 'B: samme byttepar som MN73',
   'samme byttepar som MN73', null,
   array['advice']::knowledge.monograph_answer_form[],
   false,
   array['switch_target']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN76', 76,
   '3.13 Overdosering og toksisitet',
   'Hvilke forgiftningsbilder og tidsforløp er relevante? Formulering, dose når kjent, isolert/blandet inntak og usikkerhet.',
   'mandatory', 'O',
   null, null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN77', 77,
   '3.13 Overdosering og toksisitet',
   'Hva vet vi om alvorlighetsgrad ved overdose og eventuelle forskjeller fra andre antidepressiver? Sammenlignbare data, eksponeringsgrunnlag og begrensninger.',
   'mandatory', 'O',
   null, null,
   array['profile']::knowledge.monograph_answer_form[],
   false,
   array['outcome']::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN78', 78,
   '3.13 Overdosering og toksisitet',
   'Hvilke faresignaler og norske faglige ressurser skal klinikeren henvises til? Ikke erstatt akutt vurdering med en beregnet «trygg dose».',
   'mandatory', 'O',
   null, null,
   array['advice']::knowledge.monograph_answer_form[],
   false,
   array[]::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN79', 79,
   '3.14 Samlet klinisk oversikt og blindsoner',
   'Hva er de viktigste kliniske egenskapene, begrensningene og kunnskapshullene i denne utgaven? Kortversjon fra kontrollerte svar, uten udokumentert rangering.',
   'derived', 'A: bygges når underliggende svar finnes',
   'bygges når underliggende svar finnes', null,
   array['derived']::knowledge.monograph_answer_form[],
   false,
   array[]::knowledge.monograph_scope_axis[]),
  ('1.0.0', 'MN80', 80,
   '3.14 Samlet klinisk oversikt og blindsoner',
   'Finnes andre klinisk viktige forhold standardfeltene ikke fanger? Åpent sikkerhets-/særtrekksøk; opprett navngitte behov ved funn.',
   'mandatory', 'O',
   null, null,
   array['profile']::knowledge.monograph_answer_form[],
   true,
   array['finding', 'outcome']::knowledge.monograph_scope_axis[])
;

insert into knowledge.monograph_template_profiles (template_id, profile_id, ordinal)
select t.id, p.id, v.ordinal
from (values
  ('MN01', 'REG', 1),
  ('MN01', 'PROD', 2),
  ('MN02', 'REG', 1),
  ('MN02', 'PK', 2),
  ('MN03', 'PROD', 1),
  ('MN04', 'PROD', 1),
  ('MN05', 'REG', 1),
  ('MN05', 'PROD', 2),
  ('MN06', 'REG', 1),
  ('MN06', 'PROD', 2),
  ('MN07', 'PROD', 1),
  ('MN07', 'REG', 2),
  ('MN08', 'PROD', 1),
  ('MN09', 'REG', 1),
  ('MN10', 'EFF', 1),
  ('MN10', 'POP', 2),
  ('MN10', 'REG', 3),
  ('MN11', 'EFF', 1),
  ('MN11', 'POP', 2),
  ('MN12', 'EFF', 1),
  ('MN13', 'EFF', 1),
  ('MN14', 'EFF', 1),
  ('MN15', 'EFF', 1),
  ('MN16', 'EFF', 1),
  ('MN17', 'EFF', 1),
  ('MN17', 'STOP', 2),
  ('MN18', 'EFF', 1),
  ('MN18', 'AE', 2),
  ('MN19', 'EFF', 1),
  ('MN20', 'EFF', 1),
  ('MN21', 'REG', 1),
  ('MN21', 'POP', 2),
  ('MN22', 'REG', 1),
  ('MN22', 'POP', 2),
  ('MN23', 'REG', 1),
  ('MN23', 'EFF', 2),
  ('MN23', 'POP', 3),
  ('MN24', 'REG', 1),
  ('MN24', 'PK', 2),
  ('MN25', 'REG', 1),
  ('MN25', 'STOP', 2),
  ('MN26', 'REG', 1),
  ('MN26', 'SAFE', 2),
  ('MN26', 'POP', 3),
  ('MN27', 'REG', 1),
  ('MN27', 'EFF', 2),
  ('MN27', 'SAFE', 3),
  ('MN28', 'AE', 1),
  ('MN29', 'AE', 1),
  ('MN30', 'AE', 1),
  ('MN31', 'AE', 1),
  ('MN31', 'SAFE', 2),
  ('MN32', 'AE', 1),
  ('MN33', 'AE', 1),
  ('MN33', 'PK', 2),
  ('MN34', 'AE', 1),
  ('MN35', 'AE', 1),
  ('MN36', 'AE', 1),
  ('MN36', 'EFF', 2),
  ('MN37', 'REG', 1),
  ('MN37', 'SAFE', 2),
  ('MN38', 'SAFE', 1),
  ('MN38', 'REG', 2),
  ('MN39', 'SAFE', 1),
  ('MN39', 'EFF', 2),
  ('MN40', 'SAFE', 1),
  ('MN40', 'STOP', 2),
  ('MN41', 'REG', 1),
  ('MN41', 'SAFE', 2),
  ('MN42', 'REG', 1),
  ('MN42', 'SAFE', 2),
  ('MN43', 'POP', 1),
  ('MN43', 'REG', 2),
  ('MN44', 'POP', 1),
  ('MN45', 'POP', 1),
  ('MN45', 'SAFE', 2),
  ('MN46', 'POP', 1),
  ('MN46', 'PK', 2),
  ('MN47', 'POP', 1),
  ('MN47', 'PK', 2),
  ('MN48', 'POP', 1),
  ('MN48', 'REG', 2),
  ('MN48', 'PK', 3),
  ('MN49', 'POP', 1),
  ('MN49', 'REG', 2),
  ('MN49', 'PK', 3),
  ('MN50', 'POP', 1),
  ('MN50', 'SAFE', 2),
  ('MN50', 'EFF', 3),
  ('MN51', 'POP', 1),
  ('MN51', 'REG', 2),
  ('MN51', 'PK', 3),
  ('MN52', 'INT', 1),
  ('MN52', 'PK', 2),
  ('MN53', 'INT', 1),
  ('MN54', 'INT', 1),
  ('MN54', 'SAFE', 2),
  ('MN55', 'INT', 1),
  ('MN56', 'PK', 1),
  ('MN57', 'PK', 1),
  ('MN58', 'PK', 1),
  ('MN59', 'PK', 1),
  ('MN60', 'PK', 1),
  ('MN61', 'PK', 1),
  ('MN62', 'PK', 1),
  ('MN62', 'INT', 2),
  ('MN63', 'TDM', 1),
  ('MN64', 'TDM', 1),
  ('MN64', 'PK', 2),
  ('MN65', 'PGX', 1),
  ('MN66', 'PGX', 1),
  ('MN66', 'EFF', 2),
  ('MN67', 'STOP', 1),
  ('MN67', 'SAFE', 2),
  ('MN68', 'STOP', 1),
  ('MN69', 'STOP', 1),
  ('MN70', 'STOP', 1),
  ('MN71', 'STOP', 1),
  ('MN71', 'REG', 2),
  ('MN71', 'PROD', 3),
  ('MN72', 'STOP', 1),
  ('MN72', 'SAFE', 2),
  ('MN73', 'STOP', 1),
  ('MN73', 'REG', 2),
  ('MN73', 'INT', 3),
  ('MN73', 'PK', 4),
  ('MN74', 'STOP', 1),
  ('MN74', 'REG', 2),
  ('MN74', 'INT', 3),
  ('MN74', 'PK', 4),
  ('MN75', 'STOP', 1),
  ('MN75', 'POP', 2),
  ('MN75', 'SAFE', 3),
  ('MN76', 'TOX', 1),
  ('MN77', 'TOX', 1),
  ('MN78', 'TOX', 1),
  ('MN78', 'REG', 2),
  ('MN79', 'SYN', 1)
) as v(template_code, profile_code, ordinal)
join knowledge.monograph_question_templates t
  on t.standard_version = '1.0.0' and t.code = v.template_code
join knowledge.monograph_source_profiles p
  on p.standard_version = '1.0.0' and p.code = v.profile_code;

insert into knowledge.monograph_search_tracks (standard_version, code, ordinal, label)
values
  ('1.0.0', 'norwegian_authority_source', 1, 'Direkte kontroll i relevant norsk myndighetskilde og kildeversjon'),
  ('1.0.0', 'all_identified_products', 2, 'Alle identifiserte relevante produkter og formuleringer'),
  ('1.0.0', 'change_and_shortage_check', 3, 'Kontroll av endrings- og mangelopplysninger når slike skal vises'),
  ('1.0.0', 'bibliographic_database', 4, 'PubMed/MEDLINE eller et tilsvarende bibliografisk søk'),
  ('1.0.0', 'systematic_review_search', 5, 'Et særskilt oversiktssøk'),
  ('1.0.0', 'independent_second_database', 6, 'Et supplerende uavhengig søkespor, som CENTRAL eller en egnet annen database'),
  ('1.0.0', 'reference_lists', 7, 'Referanselister for sentrale kilder'),
  ('1.0.0', 'citing_works', 8, 'Nyere siterende arbeider for sentrale kilder'),
  ('1.0.0', 'trial_registries', 9, 'Forsøksregistre, for oversette, uavsluttede eller upubliserte studier'),
  ('1.0.0', 'regulatory_or_specialist_guidance', 10, 'Relevant regulatorisk eller spesialisert veiledning'),
  ('1.0.0', 'observational_safety_search', 11, 'Målrettet søk etter egnede observasjons- og sikkerhetsdata'),
  ('1.0.0', 'product_information', 12, 'Preparatomtalen for de relevante produktene'),
  ('1.0.0', 'human_primary_studies', 13, 'Målrettet søk etter humane originalstudier'),
  ('1.0.0', 'update_search', 14, 'Oppdateringssøk etter nye eller motstridende studier'),
  ('1.0.0', 'dependent_profile_controls', 15, 'Nødvendige REG-, PROD-, PK- og INT-kontroller for konkrete tiltak'),
  ('1.0.0', 'reuse_validity_check', 16, 'Kontroll av at hvert brukt svar fortsatt gjelder den samme avgrensningen')
;

insert into knowledge.monograph_search_track_profiles (track_id, profile_id)
select k.id, p.id
from (values
  ('norwegian_authority_source', 'REG'),
  ('norwegian_authority_source', 'PROD'),
  ('all_identified_products', 'REG'),
  ('all_identified_products', 'PROD'),
  ('change_and_shortage_check', 'REG'),
  ('change_and_shortage_check', 'PROD'),
  ('bibliographic_database', 'EFF'),
  ('bibliographic_database', 'AE'),
  ('bibliographic_database', 'SAFE'),
  ('bibliographic_database', 'POP'),
  ('bibliographic_database', 'PK'),
  ('bibliographic_database', 'INT'),
  ('bibliographic_database', 'PGX'),
  ('bibliographic_database', 'TDM'),
  ('bibliographic_database', 'STOP'),
  ('bibliographic_database', 'TOX'),
  ('systematic_review_search', 'EFF'),
  ('systematic_review_search', 'AE'),
  ('systematic_review_search', 'SAFE'),
  ('systematic_review_search', 'POP'),
  ('systematic_review_search', 'STOP'),
  ('systematic_review_search', 'TOX'),
  ('independent_second_database', 'EFF'),
  ('independent_second_database', 'AE'),
  ('reference_lists', 'EFF'),
  ('reference_lists', 'AE'),
  ('reference_lists', 'PK'),
  ('reference_lists', 'INT'),
  ('citing_works', 'EFF'),
  ('citing_works', 'AE'),
  ('trial_registries', 'EFF'),
  ('trial_registries', 'AE'),
  ('regulatory_or_specialist_guidance', 'SAFE'),
  ('regulatory_or_specialist_guidance', 'POP'),
  ('regulatory_or_specialist_guidance', 'STOP'),
  ('regulatory_or_specialist_guidance', 'TOX'),
  ('regulatory_or_specialist_guidance', 'PGX'),
  ('regulatory_or_specialist_guidance', 'TDM'),
  ('observational_safety_search', 'SAFE'),
  ('observational_safety_search', 'POP'),
  ('product_information', 'PK'),
  ('product_information', 'INT'),
  ('human_primary_studies', 'PK'),
  ('human_primary_studies', 'INT'),
  ('update_search', 'PGX'),
  ('update_search', 'TDM'),
  ('dependent_profile_controls', 'STOP'),
  ('reuse_validity_check', 'SYN')
) as v(track_code, profile_code)
join knowledge.monograph_search_tracks k
  on k.standard_version = '1.0.0' and k.code = v.track_code
join knowledge.monograph_source_profiles p
  on p.standard_version = '1.0.0' and p.code = v.profile_code;

insert into knowledge.monograph_prescribed_scope_values
  (template_id, axis, label, ordinal)
select t.id, v.axis::knowledge.monograph_scope_axis, v.label, v.ordinal
from (values
  ('MN38', 'risk_area', 'rytme-/ledningsforstyrrelser og QT', 1),
  ('MN38', 'risk_area', 'blodtrykksendring/ortostase', 2),
  ('MN38', 'risk_area', 'hyponatremi', 3),
  ('MN38', 'risk_area', 'blødning', 4),
  ('MN38', 'risk_area', 'kramper', 5),
  ('MN38', 'risk_area', 'mani/hypomani', 6),
  ('MN38', 'risk_area', 'serotonerg toksisitet', 7),
  ('MN38', 'risk_area', 'lever-/annen organskade', 8),
  ('MN38', 'risk_area', 'alvorlige overfølsomhetsreaksjoner', 9),
  ('MN38', 'risk_area', 'fall', 10),
  ('MN38', 'risk_area', 'klinisk betydningsfull antikolinerg belastning', 11),
  ('MN50', 'comorbidity', 'bipolaritet/mani', 12),
  ('MN50', 'comorbidity', 'psykose', 13),
  ('MN50', 'comorbidity', 'rusmiddelproblemer', 14),
  ('MN50', 'comorbidity', 'relevante angsttilstander', 15),
  ('MN51', 'comorbidity', 'hjerte-/karsykdom', 16),
  ('MN51', 'comorbidity', 'epilepsi', 17),
  ('MN51', 'comorbidity', 'blødningsrisiko', 18),
  ('MN51', 'comorbidity', 'metabolsk sykdom', 19),
  ('MN51', 'comorbidity', 'glaukom/urinretensjon', 20),
  ('MN51', 'comorbidity', 'endret gastrointestinal anatomi/absorpsjon', 21),
  ('MN55', 'exposure', 'mat', 22),
  ('MN55', 'exposure', 'alkohol', 23),
  ('MN55', 'exposure', 'andre rusmidler', 24),
  ('MN55', 'exposure', 'røykestatus', 25),
  ('MN55', 'exposure', 'natur-/kosttilskudd', 26)
) as v(template_code, axis, label, ordinal)
join knowledge.monograph_question_templates t
  on t.standard_version = '1.0.0' and t.code = v.template_code;

-- >>> SLUTTEN PÅ DEN GENERERTE SEEDEN <<<

-- ----------------------------------------------------------------------------
-- 8. Kontrollene mot avvik mellom den faglige standarden og registeret
--
-- Seeden er generert, og prøvene på TypeScript-siden holder den mot dokumentet.
-- Disse kontrollene står likevel her, fordi de er de eneste som kjører i
-- databasen selv: en seed som ble avkortet av en feil under migrering, ville
-- ellers gitt et dekningskart med hull ingen la merke til før et spørsmål
-- manglet i en ferdig monografi.
-- ----------------------------------------------------------------------------
do $$
declare
  v_templates integer;
  v_profiles integer;
  v_tracks integer;
  v_missing text;
begin
  select count(*) into v_templates
  from knowledge.monograph_question_templates where standard_version = '1.0.0';
  if v_templates <> 80 then
    raise exception using
      errcode = 'no_data_found',
      message = format('Monografistandard 1.0.0 skal ha 80 spørsmålsmaler, men registeret har %s.', v_templates),
      hint = 'MONOGRAPH_STANDARD.md §3 har 80 maler, MN01–MN80. En seed som mangler en mal, gir et dekningskart med et hull ingen ser før et spørsmål mangler i en ferdig monografi.';
  end if;

  select count(*) into v_profiles
  from knowledge.monograph_source_profiles where standard_version = '1.0.0';
  if v_profiles <> 13 then
    raise exception using
      errcode = 'no_data_found',
      message = format('Monografistandard 1.0.0 skal ha 13 kildeprofiler, men registeret har %s.', v_profiles),
      hint = 'SOURCE_POLICY.md §3 har 13 profiler.';
  end if;

  -- Malidentitetene skal være sammenhengende MN01–MN80. Et hull ville betydd en
  -- mal som aldri ble lagt inn, og en kode som aldri kan aktiveres.
  select string_agg(format('MN%s', lpad(n::text, 2, '0')), ', ' order by n)
    into v_missing
  from generate_series(1, 80) as n
  where not exists (
    select 1 from knowledge.monograph_question_templates t
    where t.standard_version = '1.0.0'
      and t.code = format('MN%s', lpad(n::text, 2, '0'))
  );
  if v_missing is not null then
    raise exception using
      errcode = 'no_data_found',
      message = format('Monografistandard 1.0.0 mangler malene %s.', v_missing),
      hint = 'Malidentitetene MN01–MN80 er stabile og sammenhengende (MONOGRAPH_STANDARD.md §9).';
  end if;

  -- Hver mal skal ha minst én kildeprofil, eller være erklært åpen. En mal uten
  -- noen av delene ville vært et spørsmål uten et sted å lete.
  select string_agg(t.code, ', ' order by t.ordinal) into v_missing
  from knowledge.monograph_question_templates t
  where t.standard_version = '1.0.0'
    and not t.open_source_profiles
    and not exists (
      select 1 from knowledge.monograph_template_profiles l where l.template_id = t.id
    );
  if v_missing is not null then
    raise exception using
      errcode = 'no_data_found',
      message = format('Malene %s har ingen kildeprofil og er ikke erklært åpne.', v_missing),
      hint = 'En mal uten kildeprofil er et spørsmål uten et sted å lete. MN80 er den ene som med vilje har en åpen profil (MONOGRAPH_STANDARD.md §3.14).';
  end if;

  -- Og motsatt: en åpen mal skal ikke ha en forhåndsbestemt profil likevel.
  select string_agg(t.code, ', ' order by t.ordinal) into v_missing
  from knowledge.monograph_question_templates t
  where t.standard_version = '1.0.0'
    and t.open_source_profiles
    and exists (
      select 1 from knowledge.monograph_template_profiles l where l.template_id = t.id
    );
  if v_missing is not null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Malene %s er erklært åpne, men har likevel en forhåndsbestemt kildeprofil.', v_missing);
  end if;

  -- Hver profil skal brukes av minst én mal. En ubrukt profil ville betydd at en
  -- rad i koblingstabellen manglet.
  select string_agg(p.code, ', ' order by p.ordinal) into v_missing
  from knowledge.monograph_source_profiles p
  where p.standard_version = '1.0.0'
    and not exists (
      select 1 from knowledge.monograph_template_profiles l where l.profile_id = p.id
    );
  if v_missing is not null then
    raise exception using
      errcode = 'no_data_found',
      message = format('Kildeprofilene %s brukes ikke av noen mal.', v_missing);
  end if;

  -- Hver profil skal ha minst ett obligatorisk søkespor, ellers kunne
  -- søkedekningen erklæres ferdig uten at noe måtte være forsøkt.
  select string_agg(p.code, ', ' order by p.ordinal) into v_missing
  from knowledge.monograph_source_profiles p
  where p.standard_version = '1.0.0'
    and not exists (
      select 1
      from knowledge.monograph_search_track_profiles l
      where l.profile_id = p.id
    );
  if v_missing is not null then
    raise exception using
      errcode = 'no_data_found',
      message = format('Kildeprofilene %s har ingen obligatoriske søkespor.', v_missing),
      hint = 'Uten et spor som må være forsøkt, kunne søkedekningen erklæres ferdig uten at noe var gjort (SOURCE_POLICY.md §4.2, §8.1).';
  end if;

  select count(*) into v_tracks
  from knowledge.monograph_search_tracks where standard_version = '1.0.0';
  if v_tracks < 13 then
    raise exception using
      errcode = 'no_data_found',
      message = format('Monografistandard 1.0.0 har bare %s søkespor.', v_tracks);
  end if;

  -- Screeningslistene standarden skriver ut, skal være komplette. Mangler én
  -- risiko, blir den ikke et åpent behov noen ser: den blir et spørsmål ingen
  -- stilte (MONOGRAPH_STANDARD.md §3.6).
  select string_agg(format('%s: %s', x.code, x.n), ', ' order by x.code) into v_missing
  from (values ('MN38', 11), ('MN50', 4), ('MN51', 6), ('MN55', 5)) as expected(code, n)
  cross join lateral (
    select expected.code as code, expected.n as n,
           (select count(*) from knowledge.monograph_prescribed_scope_values v
            join knowledge.monograph_question_templates t on t.id = v.template_id
            where t.standard_version = '1.0.0' and t.code = expected.code) as actual
  ) x
  where x.actual <> x.n;
  if v_missing is not null then
    raise exception using
      errcode = 'no_data_found',
      message = format('Screeningslistene er ikke komplette; forventet antall per mal: %s.', v_missing),
      hint = 'MN38 navngir elleve risikoområder, MN50 fire psykiatriske tilstander, MN51 seks somatiske forhold og MN55 fem eksponeringer (MONOGRAPH_STANDARD.md §3.6, §3.7, §3.8). Mangler én, blir den et spørsmål ingen stilte.';
  end if;
end;
$$;
