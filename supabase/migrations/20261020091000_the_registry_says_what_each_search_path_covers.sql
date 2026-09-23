-- ============================================================================
-- Migrasjon 014c — registeret sier hva hver søkevei faktisk dekker, og hvordan
--
-- Hva som var galt
--
-- Etter 013x var registeret over søkeveier sant, og det var nettopp derfor det
-- ble synlig hvor lite Antidep kunne søke i: Europe PMC, PubMed og Crossref
-- dekket bare det bibliografiske sporet. En vanlig bestilling av sertralin ga
-- 70 søkeplaner, og hver eneste av dem hadde minst ett obligatorisk spor ført
-- som `no_machine_path` — 217 spor til sammen. Hvert av dem ventet på at en
-- redaktør skulle søke selv og registrere passeringen for hånd. Registeret var
-- ærlig. Arbeidsdelingen det beskrev, var det ikke: Peder var blitt Antideps
-- søkemotor for alt som ikke var PubMed.
--
-- Og de fleste av sporene *har* en maskinell kilde. Den var bare ikke koblet
-- til:
--
--   norsk myndighetskilde, alle         DMPs FEST — den nasjonale, åpne
--   produkter, endrings- og mangel-     distribusjonen av legemiddeldata (NLOD),
--   opplysninger, preparatomtalen,      med produktene, pakningene, markedsførings-
--   REG/PROD-kontrollene for tiltak     status, midlertidig utgåtte varer, DMPs
--                                       egne sikkerhets- og mangelvarsler og
--                                       lenken til gjeldende preparatomtale
--   forsøksregistre                     ClinicalTrials.gov, API v2
--   referanselister, siterende arbeider Europe PMC (references, citations) og
--                                       Crossrefs åpne referanser
--   regulatorisk/spesialisert           EMAs publiserte datasett (PSUSA,
--   veiledning                          referrals, DHPC, mangler), ClinPGx for
--                                       CPIC/DPWG, PubMeds retningslinjefilter
--   oversiktssøk, observasjons- og      PubMed og Europe PMC med dokumenterte,
--   sikkerhetsdata, humane original-    navngitte filtre — det samme endepunktet,
--   studier, oppdateringssøk            men et annet søk
--   uavhengig annen database            Crossref, som ikke bygger på MEDLINE
--
-- Hva denne migrasjonen gjør
--
-- 1. Registeret får en dimensjon til: *metoden*. Et PubMed-søk med
--    oversiktsfilter er ikke et PubMed-søk uten, og bare det første dekker
--    oversiktssporet. Å registrere «PubMed dekker oversiktssøk» ville latt
--    ethvert PubMed-søk erklære sporet; å finne på en egen «plattform» for
--    hvert filter ville vært et register som lyver om hvor mange tjenester
--    Antidep kaller. Sannheten er paret (plattform, metode), og det er det
--    raden nå bærer. Et spor kan i tillegg være dekket av en metode bare for
--    bestemte profiler: ClinPGx er veiledning for farmakogenetikk, ikke for
--    sikkerhet.
-- 2. Hver metode har en beskrivelse av hva den dekker og hva den *ikke* dekker,
--    og grunnlaget for at automatisert tilgang er i tråd med vilkårene. En
--    erstattende søkevei skal begrunnes (SOURCE_POLICY.md §4.2), og
--    begrunnelsen hører til raden, ikke til en kommentar i koden.
-- 3. Søkeloggen bærer metoden, og porten på tabellen måler (plattform, metode,
--    spor, profil) mot registeret. Et søk kan fortsatt ikke erklære et spor
--    søkeveien ikke står oppført for.
-- 4. En søkeforespørsel kan navngi en metode og — for referanser og siterende
--    arbeider — de sentrale kildene som skal følges. Listen over plattformer
--    er ikke lenger skrevet i en CHECK: den er registeret.
-- 5. En kandidatkilde kan høre til flere planer. Fram til nå var en kilde unik
--    per utgave og knyttet til den *første* planen som fant den; neste plan
--    som fant den samme preparatomtalen, fikk den ikke, og leddet der kunne
--    verken se eller vurdere den. Med én FEST-kilde for atten REG-planer ville
--    sytten av dem stått tomme. Koblingen er nå en egen tabell, og hver plan
--    som fant kilden, står der med søket som fant den.
-- 6. Sporet «hvert brukt svar gjelder fortsatt» er ikke et søk. Det er en
--    kontroll, og svarkontrollen utfører den allerede (`derivation_basis`).
--    Det står nå som det, og ikke som et søk ingen har en vei til.
--
-- Hva som ikke er gjort
--
-- Ingen modell har fått nettilgang, og ingen agent har fått et verktøy til.
-- Søke-I/O er fortsatt Antideps deterministiske kode; modellen vurderer det
-- koden hentet. Ingen spor er erklært dekket uten et søk som faktisk gikk, og
-- redaktørens vei (`api.record_monograph_track_by_editor`) står som den
-- kontrollerte reserven den er ment å være — for spor som reelt ikke har noen
-- forsvarlig maskinell kilde.
--
-- Styrende dokumenter: docs/SOURCE_POLICY.md §4.2, §4.3, §4.4, §6, §8,
-- docs/ANTIDEP_CONSTITUTION.md regel 3, 4, 7, AGENTS.md.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Metodene: hva Antideps kode faktisk gjør mot hver tjeneste
-- ----------------------------------------------------------------------------

create table knowledge.monograph_search_methods (
  id uuid primary key default gen_random_uuid(),

  platform text not null,
  method text not null,

  -- Adressen Antideps kode kaller. Speiles av src/ops/monograph-search.ts og
  -- holdes lik av en prøve: en metode registrert her som koden ikke kaller,
  -- ville vært en evne ingen har.
  endpoint_base text not null,

  -- En metode som følger kilder (referanser, siterende arbeider) trenger
  -- kildene å følge. Hvilke kilder som er sentrale, er en faglig vurdering, og
  -- den er kildeoppdagelsens — ikke kjørerens.
  requires_seeds boolean not null default false,
  -- Hvilke identifikatorformer metoden kan følge. Europe PMC slår opp en kilde
  -- på DOI, PubMed-nummer eller PMC-nummer; Crossref bare på DOI.
  seed_identifier_kinds text[] not null default array[]::text[],

  -- Hva en søkeforespørsel uten en navngitt metode betyr. Det er de tre
  -- bibliografiske fritekstsøkene, slik det var før metoden fantes: en eldre
  -- forespørsel skal bety det samme etter denne migrasjonen som før.
  default_for_requests boolean not null default false,

  description text not null,
  -- Hva metoden dekker, og hva den ikke dekker. Står på raden fordi en
  -- erstattende søkevei skal begrunnes og kontrolleres separat
  -- (SOURCE_POLICY.md §4.2), og fordi oppgaven agenten leser, viser nettopp
  -- denne setningen.
  coverage_note text not null,
  -- Hvorfor automatisert tilgang er i tråd med tjenestens vilkår.
  terms_note text not null,

  created_at timestamptz not null default now(),

  constraint monograph_search_methods_platform_method_key unique (platform, method),
  constraint monograph_search_methods_platform_shape_check
    check (platform = btrim(platform) and length(platform) between 2 and 80),
  constraint monograph_search_methods_method_shape_check
    check (method ~ '^[a-z][a-z0-9_]{2,60}$'),
  constraint monograph_search_methods_endpoint_shape_check
    check (endpoint_base ~ '^https://[A-Za-z0-9.-]+\.[A-Za-z]{2,}(/|$)'
           and endpoint_base !~ '\s'),
  constraint monograph_search_methods_seeds_are_not_default_check
    check (not (requires_seeds and default_for_requests)),
  constraint monograph_search_methods_seed_kinds_check
    check (requires_seeds = (cardinality(seed_identifier_kinds) > 0)
           and seed_identifier_kinds <@ array['doi', 'pmid', 'pmcid']::text[]),
  constraint monograph_search_methods_description_shape_check
    check (description = btrim(description) and length(description) between 20 and 1000),
  constraint monograph_search_methods_coverage_note_shape_check
    check (coverage_note = btrim(coverage_note) and length(coverage_note) between 20 and 2000),
  constraint monograph_search_methods_terms_note_shape_check
    check (terms_note = btrim(terms_note) and length(terms_note) between 20 and 1000)
);

comment on table knowledge.monograph_search_methods is
  'Hva Antideps deterministiske søkekode faktisk gjør mot hver tjeneste: plattformen, metoden, adressen den kaller, om den følger sentrale kilder, hva den dekker og ikke dekker, og grunnlaget for at automatisert tilgang er i tråd med vilkårene. En metode er ikke en plattform: et PubMed-søk med oversiktsfilter og et uten er to forskjellige søk mot den samme tjenesten, og bare det første dekker oversiktssporet. Speiles av src/ops/monograph-search.ts, og en prøve holder de to like (migrasjon 014c).';

alter table knowledge.monograph_search_methods enable row level security;

create trigger monograph_search_methods_set_created_at
  before insert or update on knowledge.monograph_search_methods
  for each row execute function catalog.set_created_at();

create policy monograph_search_methods_read on knowledge.monograph_search_methods
  for select to authenticated using (true);

insert into knowledge.monograph_search_methods
  (platform, method, endpoint_base, requires_seeds, seed_identifier_kinds,
   default_for_requests, description, coverage_note, terms_note)
values
  ('Europe PMC', 'keyword',
   'https://www.ebi.ac.uk/europepmc/webservices/rest/search', false, array[]::text[], true,
   'Fritekstsøk i Europe PMC over virkestoffet, synonymene og avgrensningen.',
   'MEDLINE, PubMed Central, preprinter og andre biomedisinske kilder Europe PMC indekserer. Første side leses; en lengre treffliste står som avkortet.',
   'Europe PMC RESTful API er et åpent, dokumentert API fra EMBL-EBI uten nøkkel, ment for programmatisk bruk.'),
  ('PubMed', 'keyword',
   'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi', false, array[]::text[], true,
   'Fritekstsøk i PubMed gjennom E-utilities esearch.',
   'MEDLINE og PubMed. Gir identifikatorer, ikke titler; første side leses, og en lengre treffliste står som avkortet.',
   'NCBI E-utilities er et offentlig API for programmatisk bruk; uten nøkkel holdes kallene under tre per sekund.'),
  ('Crossref', 'keyword',
   'https://api.crossref.org/works', false, array[]::text[], true,
   'Fritekstsøk i Crossrefs register over DOI-er.',
   'Metadata utgiverne selv har registrert, også for tidsskrift MEDLINE ikke indekserer. Et uavhengig søkespor fra MEDLINE-indekseringen, men ikke et forsøksregister som CENTRAL; relevansrangert, og første side leses.',
   'Crossref REST API er åpent og dokumentert for programmatisk bruk; metadataene er fritt gjenbrukbare.'),
  ('PubMed', 'systematic_review_filter',
   'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi', false, array[]::text[], false,
   'PubMed-søk over avgrensningen med NLMs eget filter for systematiske oversikter (systematic[sb]).',
   'Systematiske oversikter og metaanalyser slik NLM klassifiserer dem. Dekker ikke Cochrane Library direkte, men Cochrane-oversiktene er indeksert i PubMed.',
   'Samme endepunkt og samme vilkår som PubMed-fritekstsøket.'),
  ('Europe PMC', 'systematic_review_filter',
   'https://www.ebi.ac.uk/europepmc/webservices/rest/search', false, array[]::text[], false,
   'Europe PMC-søk over avgrensningen avgrenset til publikasjonstypen systematisk oversikt.',
   'Systematiske oversikter Europe PMC klassifiserer som det, også utenfor MEDLINE. Et andre utførende søk for det samme sporet, slik at én tjeneste som er nede, ikke stanser det.',
   'Samme endepunkt og samme vilkår som Europe PMC-fritekstsøket.'),
  ('PubMed', 'observational_filter',
   'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi', false, array[]::text[], false,
   'PubMed-søk over avgrensningen avgrenset til observasjonelle design og legemiddelovervåking.',
   'Kohort-, kasus-kontroll- og registerstudier, observasjonsstudier og legemiddelovervåking slik de er indeksert i MEDLINE. Meldedata gir signaler og ikke insidens (SOURCE_POLICY.md §3, S11); filteret er ikke et RCT-filter.',
   'Samme endepunkt og samme vilkår som PubMed-fritekstsøket.'),
  ('PubMed', 'human_primary_filter',
   'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi', false, array[]::text[], false,
   'PubMed-søk over avgrensningen avgrenset til humane originalstudier, uten oversikter.',
   'Studier indeksert som humane, med oversikter, systematiske oversikter og metaanalyser holdt utenfor. Arts- og in vitro-studier faller utenfor med vilje.',
   'Samme endepunkt og samme vilkår som PubMed-fritekstsøket.'),
  ('PubMed', 'guideline_filter',
   'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi', false, array[]::text[], false,
   'PubMed-søk over avgrensningen avgrenset til retningslinjer og konsensusdokumenter.',
   'Publiserte retningslinjer og konsensusanbefalinger indeksert i MEDLINE, for eksempel CPIC- og AGNP-dokumentene. Nettbaserte nasjonale råd som NICE, NHS SPS, Helsedirektoratet og Giftinformasjonen er ikke med: de har ingen åpen maskinell søkevei Antidep kan bruke uten en egen avtale.',
   'Samme endepunkt og samme vilkår som PubMed-fritekstsøket.'),
  ('PubMed', 'update_window',
   'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi', false, array[]::text[], false,
   'PubMed-søk over avgrensningen, avgrenset til publikasjoner fra de tre siste hele årene og inneværende år.',
   'Nye eller motstridende studier etter en kjent veiledning. Vinduet er fast og står i filteret på søket; en eldre veiledning krever et eget, målrettet søk.',
   'Samme endepunkt og samme vilkår som PubMed-fritekstsøket.'),
  ('Europe PMC', 'references',
   'https://www.ebi.ac.uk/europepmc/webservices/rest', true, array['doi', 'pmid', 'pmcid'], false,
   'Referanselisten til hver sentral kilde kildeoppdagelsen har valgt, hentet fra Europe PMC.',
   'Referanser Europe PMC har registrert for kilden. Har Europe PMC ingen referanseliste for en kilde, står det som en begrensning og ikke som null referanser.',
   'Samme API og samme vilkår som Europe PMC-fritekstsøket.'),
  ('Europe PMC', 'citations',
   'https://www.ebi.ac.uk/europepmc/webservices/rest', true, array['doi', 'pmid', 'pmcid'], false,
   'Arbeidene som siterer hver sentral kilde kildeoppdagelsen har valgt, hentet fra Europe PMC.',
   'Siterende arbeider Europe PMC kjenner. Det er ikke hele verdens siteringer, og null siteringer betyr null i Europe PMC på søketidspunktet.',
   'Samme API og samme vilkår som Europe PMC-fritekstsøket.'),
  ('Crossref', 'references',
   'https://api.crossref.org/works', true, array['doi'], false,
   'Referanselisten utgiveren har registrert i Crossref for hver sentral kilde med DOI.',
   'Åpne referanser utgiveren har deponert. Har kilden ingen deponert referanseliste, står det som en begrensning og ikke som null referanser.',
   'Crossref REST API er åpent; referansene er åpne metadata.'),
  ('ClinicalTrials.gov', 'registry_search',
   'https://clinicaltrials.gov/api/v2/studies', false, array[]::text[], false,
   'Søk i ClinicalTrials.gov etter studier med virkestoffet som intervensjon, avgrenset av tilstanden og de øvrige aksene.',
   'Registrerte studier i ClinicalTrials.gov, også uavsluttede og upubliserte. WHO ICTRP og EU CTR er ikke med: de har ingen åpent API med stabile vilkår for automatisert søk. Registeroppføringer er oppdagelse, ikke ekstraksjonsgrunnlag (SOURCE_POLICY.md §5).',
   'ClinicalTrials.gov API v2 er et offentlig API fra NLM for programmatisk bruk; kallene holdes godt under den publiserte grensen.'),
  ('DMP FEST', 'product_register',
   'https://www.dmp.no/globalassets/documents/om-oss/distribusjon-av-legemiddeldata/fest/festfiler/fest251.zip', false, array[]::text[], false,
   'Oppslag på virkestoffets ATC-kode i DMPs FEST, den nasjonale distribusjonen av legemiddeldata: legemiddelmerkevarer, pakninger, markedsføringsstatus, midlertidig utgåtte varer, uregistrerte preparater med godkjenningsfritak, DMPs egne sikkerhets- og leveringssviktvarsler og lenken til gjeldende preparatomtale.',
   'Den direkte, gjeldende norske myndighetskilden og dens versjon (FEST-filens publiseringsdato), alle markedsførte produkter og formuleringer, endrings- og mangelopplysningene DMP distribuerer, og lenken til preparatomtalen for hvert produkt — som bærer avsnittene om farmakokinetikk og interaksjoner. Selve lesningen av preparatomtalen er svarleddets. Lokal lagerstatus på apotek er ikke med (SOURCE_POLICY.md §2).',
   'FEST er fritt tilgjengelig fra DMP under Norsk lisens for offentlige data (NLOD). DMP ber om at systemer henter siste versjon; filen oppdateres to ganger i måneden.'),
  ('EMA', 'regulatory_data',
   'https://www.ema.europa.eu/en/documents/report', false, array[]::text[], false,
   'Oppslag på virkestoffet i EMAs publiserte datasett: periodiske sikkerhetsvurderinger (PSUSA), referrals, direkte helsepersonellbrev (DHPC) og legemiddelmangel.',
   'Den europeiske legemiddelmyndighetens regulatoriske og sikkerhetsmessige vurderinger, også for nasjonalt godkjente legemidler. Nasjonale kliniske retningslinjer er ikke med.',
   'EMA publiserer datasettene i JSON for gjenbruk og automatisert nedlasting; innholdet kan gjengis med kildehenvisning.'),
  ('ClinPGx', 'guideline_annotations',
   'https://api.clinpgx.org/v1/data/guidelineAnnotation', false, array[]::text[], false,
   'Oppslag på virkestoffet i ClinPGx (PharmGKB) sine annoterte farmakogenetiske retningslinjer, blant dem CPIC og DPWG.',
   'Gjeldende farmakogenetiske anbefalinger med retningslinjeeier og gen. Gjelder farmakogenetikk og ingenting annet.',
   'ClinPGx API er åpent med en grense på to kall i sekundet; dataene er lisensiert CC BY-SA 4.0.');

-- ----------------------------------------------------------------------------
-- 2. Registeret: hvilket spor hver metode dekker, og for hvilke profiler
-- ----------------------------------------------------------------------------

alter table knowledge.monograph_search_platforms
  add column method text not null default 'keyword';

alter table knowledge.monograph_search_platforms
  alter column method drop default;

-- NULL er «hver profil som krever sporet». En liste er en reell begrensning:
-- ClinPGx er veiledning for farmakogenetikk, og et PGx-oppslag for en
-- sikkerhetsplan ville dekket veiledningssporet med noe som ikke er veiledning
-- for sikkerhet.
alter table knowledge.monograph_search_platforms
  add column profile_codes text[];

alter table knowledge.monograph_search_platforms
  drop constraint monograph_search_platforms_pair_key;

alter table knowledge.monograph_search_platforms
  add constraint monograph_search_platforms_method_track_key
    unique (platform, method, track_code),
  add constraint monograph_search_platforms_method_fkey
    foreign key (platform, method)
    references knowledge.monograph_search_methods (platform, method)
    on update restrict on delete restrict,
  add constraint monograph_search_platforms_profile_codes_shape_check
    check (profile_codes is null
           or (cardinality(profile_codes) between 1 and 13
               and array_to_string(profile_codes, ',') ~ '^[A-Z]{2,5}(,[A-Z]{2,5})*$'));

comment on table knowledge.monograph_search_platforms is
  'Hvilke obligatoriske søkespor hver søkemetode Antidep faktisk kaller, kan dekke — og for hvilke kildeprofiler, når dekningen ikke gjelder alle. Sannhetskilden porten hviler på: et maskinelt søk kan ikke erklære et spor (plattform, metode) ikke står oppført for, og et obligatorisk spor ingen metode dekker, føres som no_machine_path. Fra migrasjon 014c er nøkkelen (plattform, metode, spor) og ikke (plattform, spor): et PubMed-søk med oversiktsfilter og ett uten er to forskjellige søk, og bare det første dekker oversiktssporet. Speiler src/ops/monograph-search.ts.';
comment on column knowledge.monograph_search_platforms.profile_codes is
  'Kildeprofilene metoden dekker sporet for, når det ikke gjelder alle. NULL er hver profil som krever sporet.';

insert into knowledge.monograph_search_platforms (platform, method, track_code, profile_codes)
values
  ('Crossref', 'keyword', 'independent_second_database', null),
  ('PubMed', 'systematic_review_filter', 'systematic_review_search', null),
  ('Europe PMC', 'systematic_review_filter', 'systematic_review_search', null),
  ('PubMed', 'observational_filter', 'observational_safety_search', null),
  ('PubMed', 'human_primary_filter', 'human_primary_studies', null),
  ('PubMed', 'guideline_filter', 'regulatory_or_specialist_guidance', null),
  ('PubMed', 'update_window', 'update_search', null),
  ('Europe PMC', 'references', 'reference_lists', null),
  ('Crossref', 'references', 'reference_lists', null),
  ('Europe PMC', 'citations', 'citing_works', null),
  ('ClinicalTrials.gov', 'registry_search', 'trial_registries', null),
  ('DMP FEST', 'product_register', 'norwegian_authority_source', null),
  ('DMP FEST', 'product_register', 'all_identified_products', null),
  ('DMP FEST', 'product_register', 'change_and_shortage_check', null),
  ('DMP FEST', 'product_register', 'product_information', null),
  ('DMP FEST', 'product_register', 'dependent_profile_controls', null),
  ('EMA', 'regulatory_data', 'regulatory_or_specialist_guidance',
   array['SAFE', 'POP', 'STOP', 'TOX']),
  ('ClinPGx', 'guideline_annotations', 'regulatory_or_specialist_guidance',
   array['PGX']);

-- ----------------------------------------------------------------------------
-- 3. Sporene som ikke er søk, men en kontroll svarleddet utfører
-- ----------------------------------------------------------------------------

create table knowledge.monograph_answer_control_tracks (
  id uuid primary key default gen_random_uuid(),
  track_code text not null,
  check_field workflow.monograph_answer_check_field not null,
  rationale text not null,
  created_at timestamptz not null default now(),

  constraint monograph_answer_control_tracks_code_key unique (track_code),
  constraint monograph_answer_control_tracks_code_shape_check
    check (track_code ~ '^[a-z][a-z0-9_]*$'),
  constraint monograph_answer_control_tracks_rationale_shape_check
    check (rationale = btrim(rationale) and length(rationale) between 20 and 2000)
);

comment on table knowledge.monograph_answer_control_tracks is
  'Obligatoriske søkespor som ikke er søk, men en kontroll den deterministiske svarkontrollen allerede utfører for hvert svar av den kunnskapstypen sporet gjelder. Et slikt spor er verken dekket av et søk eller uten en maskinell vei: det står som answer_control, og det er svarkontrollens kontrollfelt som er utførelsen. En profil der hvert spor er et slikt, får ingen søkeplan — den gjør ingen selvstendig litteraturjakt (SOURCE_POLICY.md §4.2), og en søkeplan for den ville vært kunstig søkearbeid (migrasjon 014c).';

alter table knowledge.monograph_answer_control_tracks enable row level security;

create trigger monograph_answer_control_tracks_set_created_at
  before insert or update on knowledge.monograph_answer_control_tracks
  for each row execute function catalog.set_created_at();

create policy monograph_answer_control_tracks_read on knowledge.monograph_answer_control_tracks
  for select to authenticated using (true);

insert into knowledge.monograph_answer_control_tracks (track_code, check_field, rationale)
values
  ('reuse_validity_check', 'derivation_basis',
   'Kontrollen av at hvert brukt svar fortsatt gjelder den samme avgrensningen, er svarkontrollens derivation_basis: et avledet svar registreres bare når det hviler på andre kontrollerte svar i den samme utgaven. Sammendragsleddet gjør ingen selvstendig litteraturjakt (SOURCE_POLICY.md §4.2), og en søkeplan for det ville vært søkearbeid uten et spørsmål bak seg.');

-- ----------------------------------------------------------------------------
-- 4. Hva registeret kan, lest per profil
-- ----------------------------------------------------------------------------

create function knowledge.monograph_machine_track_codes(p_profile_id uuid)
  returns text[]
  language sql
  stable
  set search_path = ''
as $$
  select coalesce(array_agg(distinct c.track_code order by c.track_code), array[]::text[])
  from knowledge.monograph_search_platforms c
  join knowledge.monograph_source_profiles sp on sp.id = p_profile_id
  where c.profile_codes is null or sp.code = any (c.profile_codes);
$$;

comment on function knowledge.monograph_machine_track_codes(uuid) is
  'Søkesporene Antideps deterministiske kode kan utføre for én kildeprofil, utledet av registeret over søkemetoder. Profilbevisst fra migrasjon 014c: en metode kan dekke et spor for noen profiler og ikke for andre, og en global liste ville sagt at et spor var utførbart for en profil der ingen metode faktisk dekker det.';

revoke execute on function knowledge.monograph_machine_track_codes(uuid) from public;

create function knowledge.monograph_answer_control_track_codes()
  returns text[]
  language sql
  stable
  set search_path = ''
as $$
  select coalesce(array_agg(t.track_code order by t.track_code), array[]::text[])
  from knowledge.monograph_answer_control_tracks t;
$$;

comment on function knowledge.monograph_answer_control_track_codes() is
  'Sporene som er en kontroll svarleddet utfører, og ikke et søk.';

revoke execute on function knowledge.monograph_answer_control_track_codes() from public;

create function knowledge.monograph_profile_has_search_tracks(p_profile_id uuid)
  returns boolean
  language sql
  stable
  set search_path = ''
as $$
  select exists (
    select 1
    from knowledge.monograph_search_track_profiles kp
    join knowledge.monograph_search_tracks k on k.id = kp.track_id
    where kp.profile_id = p_profile_id
      and not (k.code = any (knowledge.monograph_answer_control_track_codes()))
  );
$$;

comment on function knowledge.monograph_profile_has_search_tracks(uuid) is
  'Om kildeprofilen har minst ett obligatorisk spor som er et søk. En profil uten gjør ingen selvstendig litteraturjakt og får ingen søkeplan (migrasjon 014c).';

revoke execute on function knowledge.monograph_profile_has_search_tracks(uuid) from public;

-- Hvilke metoder en forespørsel betyr. NULL-metoden betyr det den betydde før
-- metoden fantes: de bibliografiske fritekstsøkene, på den navngitte
-- plattformen eller på alle tre. En plattform uten et slikt søk betyr sine egne
-- metoder som ikke følger kilder.
create function workflow.monograph_request_methods(p_platform text, p_method text)
  returns table (platform text, method text, requires_seeds boolean)
  language sql
  stable
  set search_path = ''
as $$
  select m.platform, m.method, m.requires_seeds
  from knowledge.monograph_search_methods m
  where (p_platform is null or m.platform = p_platform)
    and case
          when p_method is not null then m.method = p_method
          when exists (
            select 1 from knowledge.monograph_search_methods d
            where d.default_for_requests
              and (p_platform is null or d.platform = p_platform))
            then m.default_for_requests
          else not m.requires_seeds
        end
  order by m.platform, m.method;
$$;

comment on function workflow.monograph_request_methods(text, text) is
  'Søkemetodene én maskinell søkeforespørsel betyr, utledet av registeret. En forespørsel uten metode betyr de bibliografiske fritekstsøkene — på den navngitte plattformen, eller på alle tre — slik den gjorde før metoden fantes. Kjøreren utfører nøyaktig denne listen, og søket registreres bare når (plattform, metode) står i den.';

revoke execute on function workflow.monograph_request_methods(text, text) from public;

-- ----------------------------------------------------------------------------
-- 5. Søkeloggen bærer metoden
-- ----------------------------------------------------------------------------

alter table workflow.monograph_searches
  add column search_method text;

alter table workflow.monograph_searches
  add constraint monograph_searches_method_shape_check
    check (search_method is null or search_method ~ '^[a-z][a-z0-9_]{2,60}$');

comment on column workflow.monograph_searches.search_method is
  'Søkemetoden Antideps kode utførte mot plattformen (knowledge.monograph_search_methods). Påkrevd for et maskinelt utført søk fra migrasjon 014c; NULL på en eldre maskinell rad er det bibliografiske fritekstsøket, som var den eneste metoden som fantes. NULL for en agentrapportert eller redaktørregistrert passering: metoden er et navn på noe Antideps kode gjør.';

drop function workflow.assert_search_tracks_within_platform(text, text[]);

create function workflow.assert_search_tracks_within_platform(
  p_platform text,
  p_method text,
  p_track_codes text[],
  p_profile_id uuid
)
  returns void
  language plpgsql
  stable
  set search_path = ''
as $$
declare
  v_profile text;
  v_outside text;
begin
  if not exists (
    select 1 from knowledge.monograph_search_methods m
    where m.platform = btrim(p_platform) and m.method = p_method
  ) then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('%s med metoden %s er ikke en registrert søkevei.', p_platform, p_method),
      hint = 'Et maskinelt søk kan bare registreres når plattformen og metoden står i knowledge.monograph_search_methods. En søkevei ingen har vurdert, kan ikke dekke et krav (ANTIDEP_CONSTITUTION.md regel 7).';
  end if;

  if cardinality(coalesce(p_track_codes, array[]::text[])) = 0 then
    return;
  end if;

  select sp.code into v_profile
  from knowledge.monograph_source_profiles sp where sp.id = p_profile_id;

  select string_agg(w.code, ', ' order by w.code) into v_outside
  from unnest(p_track_codes) as w(code)
  where not exists (
    select 1 from knowledge.monograph_search_platforms c
    where c.platform = btrim(p_platform)
      and c.method = p_method
      and c.track_code = w.code
      and (c.profile_codes is null or v_profile = any (c.profile_codes))
  );

  if v_outside is not null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format(
        'Søket erklærer søkespor %s (%s) ikke dekker for denne kildeprofilen: %s.',
        btrim(p_platform), p_method, v_outside),
      hint = 'Hva hver søkemetode kan dekke, er registrert i knowledge.monograph_search_platforms. Et bibliografisk søk som erklærte forsøksregistre dekket, ville gjort porten blind for spor ingen hadde søkt i (SOURCE_POLICY.md §4.2).';
  end if;
end;
$$;

comment on function workflow.assert_search_tracks_within_platform(text, text, text[], uuid) is
  'Avviser et maskinelt søk med en plattform og metode som ikke er registrert, eller som erklærer et obligatorisk søkespor (plattform, metode) ikke er registrert for for planens kildeprofil. Fra migrasjon 014c måles metoden og profilen: et PubMed-søk uten oversiktsfilter dekker ikke oversiktssporet, og et farmakogenetisk oppslag dekker ikke sikkerhetsprofilens veiledningsspor.';

revoke execute on function workflow.assert_search_tracks_within_platform(text, text, text[], uuid) from public;

create or replace function workflow.enforce_search_track_platform() returns trigger
  language plpgsql
  set search_path = ''
as $$
declare
  v_actor_type provenance.actor_type;
  v_profile_id uuid;
begin
  -- Registeret sier hva Antideps *deterministiske kode* kan dekke. Et menneske
  -- kan søke der Antidep ikke kan, og å måle en menneskelig passering mot
  -- maskinens register ville stengt den veien igjen (013z).
  if new.execution_evidence = 'machine_executed' then
    -- Et nytt maskinelt søk sier hvilken metode det brukte. En eldre rad uten
    -- metode var det bibliografiske fritekstsøket, fordi det var det eneste
    -- som fantes; en ny rad uten metode er en kjører som ikke sier hva den
    -- gjorde, og den avvises.
    if tg_op = 'INSERT' and new.search_method is null then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Et maskinelt utført søk må si hvilken søkemetode det brukte.',
        hint = 'Plattformen alene sier ikke hva som ble søkt: et PubMed-søk med oversiktsfilter og et uten dekker forskjellige spor (migrasjon 014c).';
    end if;

    select p.profile_id into v_profile_id
    from workflow.monograph_search_plans p where p.id = new.plan_id;

    perform workflow.assert_search_tracks_within_platform(
      new.platform, coalesce(new.search_method, 'keyword'), new.track_codes, v_profile_id);
  end if;

  if new.execution_evidence = 'editor_recorded' then
    select a.actor_type into v_actor_type
    from provenance.actors a where a.id = new.recorded_by_actor_id;

    if v_actor_type is distinct from 'human'::provenance.actor_type then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Et redaktørregistrert søk må være registrert av et menneske.',
        hint = 'editor_recorded er et menneskes dokumenterte arbeid. En agent som kunne skrive det, ville hatt en vei til å erklære et søk uten hverken kjøring eller endepunkt.';
    end if;
  end if;

  return new;
end;
$$;

comment on function workflow.enforce_search_track_platform() is
  'Avviser et maskinelt utført søk uten en registrert (plattform, metode), eller som erklærer et obligatorisk søkespor metoden ikke er registrert for for planens profil, og et redaktørregistrert søk som ikke er registrert av et menneske. Ligger på tabellen framfor i én kaller, slik at regelen gjelder alle veier inn. Registeret måler maskinen og ikke mennesket.';

drop trigger monograph_searches_enforce_track_platform on workflow.monograph_searches;

create trigger monograph_searches_enforce_track_platform
  before insert or update of track_codes, platform, search_method, execution_evidence,
                             recorded_by_actor_id
  on workflow.monograph_searches
  for each row execute function workflow.enforce_search_track_platform();

-- ----------------------------------------------------------------------------
-- 6. Søkeforespørselen kan navngi metoden og kildene som skal følges
-- ----------------------------------------------------------------------------

alter table workflow.monograph_search_requests
  add column method text,
  add column seed_identifiers text[] not null default array[]::text[];

comment on column workflow.monograph_search_requests.method is
  'Søkemetoden forespørselen gjelder, når den gjelder én bestemt. NULL betyr de bibliografiske fritekstsøkene på den navngitte plattformen eller på alle tre, slik forespørselen betydde før metoden fantes (workflow.monograph_request_methods).';
comment on column workflow.monograph_search_requests.seed_identifiers is
  'De sentrale kildene en metode som følger kilder skal følge, som «doi:…», «pmid:…» eller «pmcid:…». Hver av dem er en kandidatkilde på planen: hvilke kilder som er sentrale, er kildeoppdagelsens faglige avgjørelse, og kjøreren følger bare det den ble bedt om.';

-- Den ene listen over plattformer sto i en CHECK. Nå er det registeret som
-- avgjør, og en CHECK kan ikke lese en tabell. Regelen flyttes til en trigger
-- på raden, slik at den fortsatt gjelder hver vei inn.
alter table workflow.monograph_search_requests
  drop constraint monograph_search_requests_platform_check;

-- Formen en kilde å følge må ha. Egen funksjon, fordi en CHECK ikke kan
-- inneholde en delspørring — samme grep som for søketermene (013v).
create function workflow.monograph_seed_identifiers_shaped(p_seeds text[])
  returns boolean
  language sql
  immutable
  set search_path = ''
as $$
  select p_seeds is not null
     and cardinality(p_seeds) <= 10
     and not exists (
       select 1
       from unnest(p_seeds) as s(value)
       where s.value is null
          or s.value !~ '^(doi:10\.[0-9]{4,9}/[^\s"]{1,200}|pmid:[0-9]{1,9}|pmcid:PMC[0-9]{1,9})$'
     );
$$;

comment on function workflow.monograph_seed_identifiers_shaped(text[]) is
  'Om en liste med kilder å følge har formen en søkeforespørsel kan bære: høyst ti, hver en DOI, et PubMed-nummer eller et PMC-nummer med sitt prefiks. Kjøreren slår dem opp i navngitte offentlige tjenester, og en identifikator uten form er et inndatafelt og ikke en identifikator.';

revoke execute on function workflow.monograph_seed_identifiers_shaped(text[]) from public;

alter table workflow.monograph_search_requests
  add constraint monograph_search_requests_method_shape_check
    check (method is null or method ~ '^[a-z][a-z0-9_]{2,60}$'),
  add constraint monograph_search_requests_seeds_shape_check
    check (workflow.monograph_seed_identifiers_shaped(seed_identifiers));

create function workflow.validate_monograph_search_request()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
declare
  v_resolved integer;
  v_seeded integer;
begin
  select count(*), count(*) filter (where rm.requires_seeds)
    into v_resolved, v_seeded
  from workflow.monograph_request_methods(new.platform, new.method) rm;

  if v_resolved = 0 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('%s er ikke en søkevei Antidep kaller.',
                       concat_ws(' med metoden ', coalesce(new.platform, 'Ingen plattform'), new.method)),
      hint = 'Plattformene og metodene står i knowledge.monograph_search_methods. En forespørsel kan ikke oppgi en adresse: en tjeneste ingen har vurdert, finnes ikke å be om (ANTIDEP_CONSTITUTION.md regel 7).';
  end if;

  if v_seeded > 0 and v_seeded <> v_resolved then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Forespørselen blander metoder som følger kilder med metoder som søker.',
      hint = 'Referanser og siterende arbeider følger navngitte kilder; et søk gjør ikke det. Be om dem hver for seg.';
  end if;

  if v_seeded > 0 and cardinality(new.seed_identifiers) = 0 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Å følge referanser eller siterende arbeider krever kildene som skal følges.',
      hint = 'Hvilke kilder som er sentrale, er kildeoppdagelsens avgjørelse. Navngi dem som kandidatkilder på planen.';
  end if;

  if v_seeded = 0 and cardinality(new.seed_identifiers) > 0 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Et søk tar ikke imot kilder å følge.',
      hint = 'Kilder å følge hører til metodene «references» og «citations».';
  end if;

  return new;
end;
$$;

comment on function workflow.validate_monograph_search_request() is
  'Avviser en maskinell søkeforespørsel som navngir en plattform eller metode registeret ikke kjenner, som blander metoder som følger kilder med metoder som søker, eller som ber om å følge kilder uten å si hvilke. Erstatter den skrevne plattformlisten i en CHECK: det er registeret som vet hva Antidep kaller (migrasjon 014c).';

revoke execute on function workflow.validate_monograph_search_request() from public;

create trigger monograph_search_requests_validate
  before insert on workflow.monograph_search_requests
  for each row execute function workflow.validate_monograph_search_request();

-- Identiteten til en bestilling er innholdet, og metoden og kildene er en del
-- av innholdet. To bestillinger mot PubMed — den ene med oversiktsfilter og den
-- andre uten — er to søk.
alter table workflow.monograph_search_requests
  drop constraint monograph_search_requests_round_key;

alter table workflow.monograph_search_requests
  drop column request_key;

drop function workflow.monograph_search_request_key(
  workflow.monograph_search_strategy, text, text[], text[]);

create function workflow.monograph_search_request_key(
  p_strategy workflow.monograph_search_strategy,
  p_platform text,
  p_method text,
  p_drug_aliases text[],
  p_query_terms text[],
  p_seed_identifiers text[]
)
  returns text
  language sql
  immutable
as $$
  select encode(
    sha256(convert_to(
      p_strategy::text
        || '|' || coalesce(p_platform, '')
        || '|' || coalesce(p_method, '')
        || '|' || coalesce(array_to_string(p_drug_aliases, chr(31)), '')
        || '|' || coalesce(array_to_string(p_query_terms, chr(31)), '')
        || '|' || coalesce(array_to_string(p_seed_identifiers, chr(31)), ''),
      'UTF8')),
    'hex');
$$;

comment on function workflow.monograph_search_request_key(workflow.monograph_search_strategy, text, text, text[], text[], text[]) is
  'Avtrykket som gjør én bestilt søkerunde til en annen: strategien, plattformen, metoden, virkestoffsynonymene, termene og kildene som skal følges. To bestillinger med forskjellig metode er to søk, og den andre skal ikke forsvinne i en konflikt fordi den delte plattform med den første.';

revoke execute on function workflow.monograph_search_request_key(workflow.monograph_search_strategy, text, text, text[], text[], text[]) from public;

alter table workflow.monograph_search_requests
  add column request_key text not null generated always as (
    workflow.monograph_search_request_key(
      strategy, platform, method, drug_aliases, query_terms, seed_identifiers)
  ) stored;

alter table workflow.monograph_search_requests
  add constraint monograph_search_requests_round_key
    unique (plan_id, plan_version, requested_for_role, search_round, request_key);

create or replace function workflow.freeze_monograph_search_request()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if new.id is distinct from old.id
     or new.reference is distinct from old.reference
     or new.plan_id is distinct from old.plan_id
     or new.plan_version is distinct from old.plan_version
     or new.requested_for_role is distinct from old.requested_for_role
     or new.search_round is distinct from old.search_round
     or new.origin is distinct from old.origin
     or new.strategy is distinct from old.strategy
     or new.rationale is distinct from old.rationale
     or new.platform is distinct from old.platform
     or new.method is distinct from old.method
     or new.drug_aliases is distinct from old.drug_aliases
     or new.query_terms is distinct from old.query_terms
     or new.seed_identifiers is distinct from old.seed_identifiers
     or new.track_codes is distinct from old.track_codes
     or new.requested_by_agent_run_id is distinct from old.requested_by_agent_run_id
     or new.created_at is distinct from old.created_at then
    raise exception using
      errcode = 'restrict_violation',
      message = 'En maskinell søkeforespørsel er uforanderlig i det den bestiller.',
      hint = 'Bestillingen er det søkeloggen dokumenterer at ble utført. En endret bestilling er en ny runde, ikke en omskrevet gammel.';
  end if;

  if old.state in ('fulfilled', 'abandoned') and new.state <> old.state then
    raise exception using
      errcode = 'restrict_violation',
      message = 'En avsluttet søkeforespørsel kan ikke gjenåpnes.',
      hint = 'En utført eller oppgitt runde er et historisk faktum søkeloggen hviler på. Trengs det flere søk, er det en ny runde.';
  end if;

  return new;
end;
$$;

-- ----------------------------------------------------------------------------
-- 7. En kandidatkilde kan høre til flere planer
-- ----------------------------------------------------------------------------

create table workflow.monograph_candidate_source_plans (
  id uuid primary key default gen_random_uuid(),

  candidate_source_id uuid not null
    references workflow.monograph_candidate_sources (id) on update restrict on delete restrict,
  plan_id uuid not null
    references workflow.monograph_search_plans (id) on update restrict on delete restrict,
  -- Søket som fant kilden for nettopp denne planen først. NULL for en kilde
  -- som ble lagt til uten et søk.
  search_id uuid
    references workflow.monograph_searches (id) on update restrict on delete restrict,
  created_at timestamptz not null default now(),

  constraint monograph_candidate_source_plans_pair_key unique (candidate_source_id, plan_id)
);

comment on table workflow.monograph_candidate_source_plans is
  'Hvilke søkeplaner som har funnet en kandidatkilde, og med hvilket søk. En kilde er unik per utgave, men den samme preparatomtalen, det samme forsøket og den samme oversikten finnes av mange planer, og hver av dem skal kunne se og vurdere den for sine egne behov. Fram til migrasjon 014c var kilden knyttet bare til den første planen som fant den, og de neste stod tomme. Søket er det som fant kilden for planen først: metningssignalet spør om noe er nytt for planen, ikke for utgaven.';

alter table workflow.monograph_candidate_source_plans enable row level security;

create index monograph_candidate_source_plans_plan_idx
  on workflow.monograph_candidate_source_plans (plan_id);
create index monograph_candidate_source_plans_search_idx
  on workflow.monograph_candidate_source_plans (search_id);

create trigger monograph_candidate_source_plans_set_created_at
  before insert or update on workflow.monograph_candidate_source_plans
  for each row execute function catalog.set_created_at();

create trigger monograph_candidate_source_plans_are_append_only
  before update or delete on workflow.monograph_candidate_source_plans
  for each row execute function knowledge.reject_append_only_mutation(
    'At en plan fant en kilde med et søk, er et historisk faktum søkeloggen hviler på.');

insert into workflow.monograph_candidate_source_plans
  (candidate_source_id, plan_id, search_id, created_at)
select c.id, c.plan_id, c.search_id, c.created_at
from workflow.monograph_candidate_sources c
where c.plan_id is not null;

-- Planen en kandidat ble registrert på, står alltid på koblingen — uansett
-- hvilken vei raden kom inn. En kilde som kan endre hovedkonklusjonen og ble
-- lagt til uten om `record_monograph_candidate_source`, skal ikke kunne falle
-- utenfor porten fordi koblingen manglet.
create function workflow.link_candidate_to_its_plan()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if new.plan_id is not null then
    insert into workflow.monograph_candidate_source_plans (candidate_source_id, plan_id, search_id)
    values (new.id, new.plan_id, new.search_id)
    on conflict (candidate_source_id, plan_id) do nothing;
  end if;
  return new;
end;
$$;

comment on function workflow.link_candidate_to_its_plan() is
  'Fører planen en kandidatkilde ble registrert på, inn i workflow.monograph_candidate_source_plans i den samme transaksjonen, uansett vei inn.';

revoke execute on function workflow.link_candidate_to_its_plan() from public;

create trigger monograph_candidate_sources_link_plan
  after insert on workflow.monograph_candidate_sources
  for each row execute function workflow.link_candidate_to_its_plan();

create or replace function workflow.record_monograph_candidate_source(
  p_plan_id uuid,
  p_search_id uuid,
  p_identifier_kind text,
  p_identifier_value text,
  p_title text,
  p_authors_or_issuer text,
  p_publisher_or_journal text,
  p_publication_year integer,
  p_discovery_path text,
  p_access_limited boolean,
  p_access_limitation_note text,
  p_could_change_conclusion boolean,
  p_materiality_reason text,
  p_agent_run_id uuid,
  p_actor_id uuid
)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_plan workflow.monograph_search_plans;
  v_id uuid;
begin
  select p.* into v_plan
  from workflow.monograph_search_plans p where p.id = p_plan_id;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Søkeplanen finnes ikke.';
  end if;

  insert into workflow.monograph_candidate_sources (
    edition_id, plan_id, search_id,
    identifier_kind, identifier_value, title,
    authors_or_issuer, publisher_or_journal, publication_year,
    discovery_path, access_limited, access_limitation_note,
    could_change_conclusion, materiality_reason,
    proposed_by_agent_run_id, recorded_by_actor_id
  )
  values (
    v_plan.edition_id, p_plan_id, p_search_id,
    p_identifier_kind, btrim(p_identifier_value), btrim(p_title),
    nullif(btrim(coalesce(p_authors_or_issuer, '')), ''),
    nullif(btrim(coalesce(p_publisher_or_journal, '')), ''),
    p_publication_year,
    btrim(p_discovery_path),
    coalesce(p_access_limited, false),
    nullif(btrim(coalesce(p_access_limitation_note, '')), ''),
    coalesce(p_could_change_conclusion, false),
    nullif(btrim(coalesce(p_materiality_reason, '')), ''),
    p_agent_run_id, p_actor_id
  )
  on conflict (edition_id, identifier_kind, identifier_value) do nothing
  returning id into v_id;

  if v_id is null then
    -- Den samme kilden funnet av to søk er én kandidat. Oppdagelsesveien til
    -- den første beholdes på kilden: det var den som faktisk fant den.
    select c.id into v_id
    from workflow.monograph_candidate_sources c
    where c.edition_id = v_plan.edition_id
      and c.identifier_kind = p_identifier_kind
      and c.identifier_value = btrim(p_identifier_value);
  end if;

  -- Og planen som fant den, står på koblingen — også når en annen plan fant
  -- den først. Søket er det første som fant den for nettopp denne planen.
  insert into workflow.monograph_candidate_source_plans (candidate_source_id, plan_id, search_id)
  values (v_id, p_plan_id, p_search_id)
  on conflict (candidate_source_id, plan_id) do nothing;

  return v_id;
end;
$$;

comment on function workflow.record_monograph_candidate_source(uuid, uuid, text, text, text, text, text, integer, text, boolean, text, boolean, text, uuid, uuid) is
  'Registrerer én identifisert kandidatkilde med bibliografi, oppdagelsesvei, eventuell tilgangsbegrensning og eventuell vesentlighet, og knytter den til planen som fant den. Idempotent på (utgave, identifikatorform, identifikator): den samme kilden funnet av to søk er én kandidat, og oppdagelsesveien til det første søket beholdes. Fra migrasjon 014c står hver plan som fant kilden, på workflow.monograph_candidate_source_plans med søket som fant den for den planen, slik at en kilde funnet av mange planer kan vurderes i hver av dem.';

-- ----------------------------------------------------------------------------
-- 8. Sporets tilstand, ført mot registeret per profil
-- ----------------------------------------------------------------------------

comment on type workflow.monograph_track_state is
  'Om et obligatorisk søkespor er forsøkt (SOURCE_POLICY.md §4.2): pending (ikke forsøkt ennå), covered (et dokumentert søk dekker det), unavailable (sporet ble forsøkt, men søkeveien svarte ikke), no_machine_path (ingen registrert søkemetode dekker sporet for denne profilen) eller answer_control (sporet er ikke et søk, men en kontroll svarkontrollen utfører for hvert svar — knowledge.monograph_answer_control_tracks). unavailable er forbigående og prøves på nytt; no_machine_path blir ikke bedre av et nytt forsøk og krever et menneske; answer_control er utført der svaret registreres og hindrer ingenting. Et pending eller no_machine_path spor hindrer at søkedekningen kan erklæres ferdig.';

alter table workflow.monograph_search_track_attempts
  drop constraint monograph_search_track_attempts_state_shape_check;

alter table workflow.monograph_search_track_attempts
  add constraint monograph_search_track_attempts_state_shape_check
    check (
      case state
        when 'pending' then
          search_id is null and note is null and resolved_by_actor_id is null
        when 'covered' then search_id is not null
        when 'unavailable' then search_id is null and note is not null
        when 'no_machine_path' then
          search_id is null and note is not null and resolved_by_actor_id is null
        -- En kontroll svarleddet utfører, har ingen søkerad og ingen som løste
        -- den for hånd: begrunnelsen sier hvor den skjer.
        when 'answer_control' then
          search_id is null and note is not null and resolved_by_actor_id is null
        else false
      end
    );

create function workflow.monograph_track_note(p_track_code text, p_profile_id uuid)
  returns text
  language sql
  stable
  set search_path = ''
as $$
  select case
    when p_track_code = any (knowledge.monograph_answer_control_track_codes()) then
      (select format(
         'Sporet er ikke et søk. Det er svarkontrollens %s, som utføres deterministisk hver gang et svar av denne typen registreres: %s',
         t.check_field, t.rationale)
       from knowledge.monograph_answer_control_tracks t where t.track_code = p_track_code)
    else format(
      'Ingen av Antideps registrerte søkemetoder dekker dette sporet for denne kildeprofilen. Maskinelt utførbare spor for profilen er nå: %s. Sporet krever at en redaktør gjør og registrerer søket.',
      case when cardinality(knowledge.monograph_machine_track_codes(p_profile_id)) = 0
           then 'ingen'
           else array_to_string(knowledge.monograph_machine_track_codes(p_profile_id), ', ')
      end)
  end;
$$;

comment on function workflow.monograph_track_note(text, uuid) is
  'Begrunnelsen et spor uten en maskinell søkemetode får: enten hvilken svarkontroll som utfører det, eller hva Antidep faktisk kan søke i for profilen.';

revoke execute on function workflow.monograph_track_note(text, uuid) from public;

create or replace function workflow.set_track_machine_path() returns trigger
  language plpgsql
  set search_path = ''
as $$
declare
  v_code text;
  v_profile_id uuid;
begin
  if new.state <> 'pending' then
    return new;
  end if;

  select k.code into v_code
  from knowledge.monograph_search_tracks k where k.id = new.track_id;
  select p.profile_id into v_profile_id
  from workflow.monograph_search_plans p where p.id = new.plan_id;

  if v_code is null then
    return new;
  end if;

  if v_code = any (knowledge.monograph_answer_control_track_codes()) then
    new.state := 'answer_control';
  elsif not (v_code = any (knowledge.monograph_machine_track_codes(v_profile_id))) then
    new.state := 'no_machine_path';
  else
    return new;
  end if;

  new.search_id := null;
  new.resolved_by_actor_id := null;
  new.note := workflow.monograph_track_note(v_code, v_profile_id);
  return new;
end;
$$;

comment on function workflow.set_track_machine_path() is
  'Setter et nytt obligatorisk søkespor til answer_control når det er en kontroll svarleddet utfører, og til no_machine_path når ingen registrert søkemetode dekker det for planens profil — med én gang, og med en begrunnelse. Uten dette ville sporet stått som «ikke forsøkt ennå» om noe som aldri blir forsøkt maskinelt.';

create or replace function workflow.mark_tracks_without_machine_path(p_plan_id uuid)
  returns integer
  language plpgsql
  set search_path = ''
as $$
declare
  v_plan workflow.monograph_search_plans;
  v_edition knowledge.monograph_editions;
  v_executable text[];
  v_controls text[] := knowledge.monograph_answer_control_track_codes();
  v_marked integer := 0;
  v_freed integer := 0;
  v_controlled integer := 0;
begin
  select p.* into v_plan
  from workflow.monograph_search_plans p where p.id = p_plan_id;
  if not found then
    return 0;
  end if;

  select e.* into v_edition
  from knowledge.monograph_editions e where e.id = v_plan.edition_id;

  v_executable := knowledge.monograph_machine_track_codes(v_plan.profile_id);

  -- Sporene som er en kontroll svarleddet utfører. Også fra no_machine_path:
  -- der sto de fordi ingen hadde skilt en kontroll fra et søk.
  update workflow.monograph_search_track_attempts a
  set state = 'answer_control',
      search_id = null,
      resolved_by_actor_id = null,
      note = workflow.monograph_track_note(k.code, v_plan.profile_id)
  from knowledge.monograph_search_tracks k
  where k.id = a.track_id
    and a.plan_id = p_plan_id
    and a.state in ('pending', 'no_machine_path')
    and k.code = any (v_controls);

  get diagnostics v_controlled = row_count;

  -- Et obligatorisk spor ingen registrert søkemetode dekker for profilen,
  -- blir ikke dekket av å vente.
  update workflow.monograph_search_track_attempts a
  set state = 'no_machine_path',
      search_id = null,
      resolved_by_actor_id = null,
      note = workflow.monograph_track_note(k.code, v_plan.profile_id)
  from knowledge.monograph_search_tracks k
  where k.id = a.track_id
    and a.plan_id = p_plan_id
    and a.state = 'pending'
    and k.standard_version = v_edition.standard_version
    and not (k.code = any (v_executable))
    and not (k.code = any (v_controls));

  get diagnostics v_marked = row_count;

  -- Og motsatt vei: et spor som har fått en maskinell søkemetode, går tilbake
  -- til den maskinelle køen.
  update workflow.monograph_search_track_attempts a
  set state = 'pending', search_id = null, note = null, resolved_by_actor_id = null
  from knowledge.monograph_search_tracks k
  where k.id = a.track_id
    and a.plan_id = p_plan_id
    and a.state = 'no_machine_path'
    and k.standard_version = v_edition.standard_version
    and k.code = any (v_executable);

  get diagnostics v_freed = row_count;

  -- «Tilbake i køen» er ikke nok alene. Et ventende spor uten en runde som
  -- utfører det, venter for alltid — det var halvparten av det 013x lovet. Nå
  -- åpner registeret selv en runde for sporene det har fått en vei til, i den
  -- runden planen står i. Porten holder den semantiske oppgaven tilbake til
  -- runden er utført, slik at vurderingen skjer på det nye grunnlaget.
  if v_freed > 0 and v_plan.closed_at is null and v_plan.paused_at is null then
    perform workflow.open_monograph_machine_rounds(
      p_plan_id, v_plan.discovery_round,
      'registry_opened'::workflow.monograph_search_request_origin,
      v_plan.created_by_actor_id, null);
  end if;

  return v_marked + v_freed + v_controlled;
end;
$$;

comment on function workflow.mark_tracks_without_machine_path(uuid) is
  'Fører planens obligatoriske søkespor mot registeret over søkemetoder, per profil: en kontroll svarleddet utfører, blir answer_control; et spor uten maskinell metode blir no_machine_path med en begrunnelse; og et spor som har fått en metode, går tilbake til pending — og får en maskinell runde åpnet for seg i den runden planen står i, slik at det faktisk blir utført og ikke bare står i kø. Rører aldri covered eller unavailable: et utført søk og en registrert begrensning er historiske fakta.';
