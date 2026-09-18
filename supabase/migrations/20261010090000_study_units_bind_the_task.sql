-- Migrasjon 013m — vernet mot dobbelttelling gjennom hele evidensflyten
--
-- 013l gjorde studiekoblingen virksom, men bare på ett sted i kjeden, og med to
-- feil i identiteten. Gjennomgangen av 013l fant fem ting, og alle fem var
-- reelle:
--
--   1. **Grupperingen lå utenfor bindingen.** `study_units` sto i materialet
--      agenten leser, og ikke i det forespørselsavtrykket svaret bindes til.
--      Resten av handoff-kontrakten lover det motsatte: endres grunnlaget,
--      endres avtrykket, og et svar avgitt på det gamle grunnlaget avvises.
--      To rapporter som først så ut som to uavhengige kilder og siden ble
--      koblet til den samme studien, kunne derfor få et svar bygget på den
--      dobbelttelte tilstanden registrert i ettertid.
--   2. **Den automatiske veien laget et annet navnerom enn redaktørveien.**
--      Kildeoppdagelsen sendte alltid `other`, også for et NCT-nummer, mens en
--      redaktør ville sagt `clinicaltrials_gov`. Unikheten er
--      `(registry_kind, registry_id)`, så det samme forsøket ble to studier —
--      og da var vernet mot dobbelttelling borte igjen.
--   3. **Evidensvurderingen fikk ikke grupperingen.** Syntesen visste at tre
--      funn kom fra to studier; GRADE-leddet leste dem fortsatt som tre.
--   4. **Overlapp gjennom systematiske oversikter kunne ikke uttrykkes.**
--      SOURCE_POLICY.md §7 og §11 krever at en oversikt og primærstudiene den
--      inkluderer, ikke telles som uavhengige. `study_reports` håndhever én
--      kilde → høyst én studie, og kan derfor ikke bære mange-til-mange.
--   5. **Redaktørveien slo opp kilden på tittel.** Repoet sier selv at en
--      tittel ikke er en identitet: to kilder kan hete det samme, og
--      `order by created_at limit 1` ville koblet feil artikkel i stillhet.
--
-- ----------------------------------------------------------------------------
-- Hvorfor sammenslåingen alltid går i retning færre uavhengige enheter
--
-- Et overlapp Antidep ikke kjenner, er farligere enn et overlapp den kjenner:
-- det første får grunnlaget til å se sterkere ut enn det er. Når to enheter
-- viser seg å dele deltakere, slås de derfor sammen — aldri motsatt. En
-- oversikt som inkluderer to primærstudier som begge er i grunnlaget, blir én
-- enhet med dem, og ikke to.

-- ----------------------------------------------------------------------------
-- 1. Registernummeret har ett navnerom, uansett hvem som registrerer det
-- ----------------------------------------------------------------------------
create function knowledge.registry_kind_for_identifier(p_registry_id text)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  select case
    when p_registry_id is null then null
    -- ClinicalTrials.gov: NCT etterfulgt av åtte siffer.
    when upper(btrim(p_registry_id)) ~ '^NCT[0-9]{8}$' then 'clinicaltrials_gov'
    -- ISRCTN-registeret.
    when upper(btrim(p_registry_id)) ~ '^ISRCTN[0-9]{8}$' then 'isrctn'
    -- EudraCT/EU CTR: 2020-123456-12.
    when btrim(p_registry_id) ~ '^[0-9]{4}-[0-9]{6}-[0-9]{2}$' then 'euctr'
    else null
  end;
$$;

comment on function knowledge.registry_kind_for_identifier(text) is
  'Registeret et forsøksregisternummer hører til, utledet av nummerets egen form, eller NULL når formen ikke er kjent. Finnes fordi identiteten til en studie er paret (register, nummer): sier kildeoppdagelsen «other» og redaktøren «clinicaltrials_gov» om det samme NCT-nummeret, blir det samme forsøket to studier — og da er vernet mot å telle det samme deltakerutvalget to ganger uten virkning.';

revoke execute on function knowledge.registry_kind_for_identifier(text) from public;

create function knowledge.normalized_registry_id(p_registry_id text)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  select case
    when p_registry_id is null then null
    -- NCT- og ISRCTN-numre skrives med store bokstaver. Uten normaliseringen
    -- ville «nct00000001» og «NCT00000001» vært to studier.
    when upper(btrim(p_registry_id)) ~ '^(NCT|ISRCTN)[0-9]+$'
      then upper(btrim(p_registry_id))
    else nullif(btrim(p_registry_id), '')
  end;
$$;

comment on function knowledge.normalized_registry_id(text) is
  'Forsøksregisternummeret i den formen studien lagres under. NCT- og ISRCTN-numre skrives med store bokstaver, slik at den samme studien skrevet med små bokstaver ikke blir en studie til.';

revoke execute on function knowledge.normalized_registry_id(text) from public;

-- ----------------------------------------------------------------------------
-- 2. Overlapp gjennom en systematisk oversikt
--
-- Egen tabell og ikke en rolle på `study_reports`, fordi relasjonen er
-- mange-til-mange: én oversikt inkluderer mange studier, og én studie inngår i
-- mange oversikter. `study_reports` håndhever med rette at én kilde hører til
-- høyst én studie, og den regelen kan ikke bære dette.
-- ----------------------------------------------------------------------------
create table knowledge.review_included_studies (
  id uuid primary key default gen_random_uuid(),

  -- Oversikten. En kilde, ikke en studie: oversikten er en publikasjon.
  review_source_id uuid not null
    references knowledge.sources (id) on update restrict on delete restrict,
  -- Studien oversikten inkluderer.
  study_id uuid not null
    references knowledge.studies (id) on update restrict on delete restrict,

  -- Grunnlaget, ordrett. Samme krav som på rapportkoblingen, og av samme grunn.
  inclusion_basis text not null,
  certainty knowledge.study_link_certainty not null,

  linked_by_actor_id uuid
    references provenance.actors (id) on update restrict on delete restrict,
  linked_by_agent_run_id uuid
    references provenance.agent_runs (id) on update restrict on delete restrict,
  created_at timestamptz not null default now(),

  constraint review_included_studies_pair_key unique (review_source_id, study_id),
  constraint review_included_studies_basis_shape_check
    check (inclusion_basis = btrim(inclusion_basis)
           and length(inclusion_basis) between 1 and 2000),
  constraint review_included_studies_origin_check
    check (num_nonnulls(linked_by_actor_id, linked_by_agent_run_id) = 1)
);

comment on table knowledge.review_included_studies is
  'Hvilke studier en systematisk oversikt inkluderer (SOURCE_POLICY.md §7, §11). En oversikt og primærstudiene den bygger på, er ikke uavhengige kilder: teller man begge, teller man de samme deltakerne to ganger. Relasjonen er mange-til-mange og kan derfor ikke bæres av knowledge.study_reports, som med rette håndhever at én kilde hører til høyst én studie. Grunnlaget for inklusjonen er påkrevd, og en usikker inklusjon er lagret som usikker framfor å bli utelatt — en oversikt som kanskje inneholder studien, er fortsatt en grunn til ikke å telle begge som uavhengige.';

alter table knowledge.review_included_studies enable row level security;

create index review_included_studies_study_idx
  on knowledge.review_included_studies (study_id);

create trigger review_included_studies_set_created_at
  before insert or update on knowledge.review_included_studies
  for each row execute function catalog.set_created_at();


-- ----------------------------------------------------------------------------
-- 3. Grupperingen, nå med overlapp gjennom oversikter
--
-- Sammenslåingen er en transitiv lukking og ikke ett hopp: inkluderer en
-- oversikt to primærstudier som begge er i grunnlaget, er alle tre én enhet.
-- Ett hopp ville latt den andre primærstudien stå igjen som uavhengig, og det
-- er nettopp den retningen som overdriver grunnlaget.
--
-- `studies` er en liste og ikke ett felt, fordi en sammenslått enhet hviler på
-- flere registrerte studier. Ett navn på en slik enhet ville vært et valg
-- mellom dem, og et valg leseren ikke kunne se at var tatt.
-- ----------------------------------------------------------------------------
create or replace function knowledge.study_units_for_evidence(p_evidence_item_ids uuid[])
  returns jsonb
  language sql
  stable
  set search_path = ''
as $$
  with recursive funn as (
    select e.id as evidence_item_id, v.source_id
    from unnest(coalesce(p_evidence_item_ids, array[]::uuid[])) as i(id)
    join knowledge.evidence_items e on e.id = i.id
    left join knowledge.source_versions v on v.id = e.source_version_id
  ),
  -- Studien kilden hører til, når koblingen er registrert. Er den ikke det, er
  -- kilden sin egen enhet: et fravær er ikke en opplysning om at to kilder
  -- deler deltakerutvalg.
  enheter as (
    select
      f.evidence_item_id,
      f.source_id,
      r.study_id,
      r.certainty,
      coalesce(r.study_id::text,
               'kilde:' || coalesce(f.source_id::text, f.evidence_item_id::text)) as unit_key
    from funn f
    left join knowledge.study_reports r on r.source_id = f.source_id
  ),
  -- Kantene: en oversikt som er i grunnlaget, og en studie som også er i
  -- grunnlaget og som oversikten inkluderer. Begge må være med — en oversikt
  -- over studier ingen har lagt fram her, overlapper ikke med noe her.
  kanter as (
    select distinct oversikt.unit_key as a, primaer.unit_key as b
    from enheter oversikt
    join knowledge.review_included_studies ri
      on ri.review_source_id = oversikt.source_id
    join enheter primaer on primaer.study_id = ri.study_id
    where oversikt.unit_key <> primaer.unit_key
  ),
  symmetriske as (
    select a, b from kanter
    union
    select b, a from kanter
  ),
  noder as (select distinct unit_key from enheter),
  -- Den transitive lukkingen. Hver node når alle nodene den henger sammen med,
  -- og gruppen navngis etter den minste av dem.
  naadd as (
    select n.unit_key as node, n.unit_key as root from noder n
    union
    select k.b, c.root
    from naadd c
    join symmetriske k on k.a = c.node
  ),
  kanonisk as (
    select node, min(root) as root from naadd group by node
  ),
  gruppert as (
    select
      k.root as unit_key,
      count(distinct u.evidence_item_id)::integer as evidence_items,
      count(distinct u.source_id)::integer as reports,
      bool_or(u.certainty = 'uncertain') as uncertain,
      bool_or(exists (select 1 from symmetriske s where s.a = u.unit_key)) as review_overlap,
      array_agg(distinct u.evidence_item_id) as evidence_item_ids,
      array_remove(array_agg(distinct u.study_id), null) as study_ids
    from enheter u
    join kanonisk k on k.node = u.unit_key
    group by k.root
  )
  select jsonb_build_object(
    'evidence_items', (select count(*)::integer from enheter),
    'independent_units', (select count(*)::integer from gruppert),
    'shared_studies', (select count(*)::integer from gruppert g where g.reports > 1),
    'uncertain_linkage', (select count(*)::integer from gruppert g where g.uncertain),
    'review_overlaps', (select count(*)::integer from gruppert g where g.review_overlap),
    'units', coalesce((
      select jsonb_agg(jsonb_build_object(
               'studies', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'label', s.label,
                          'registry', case when s.registry_kind is null then null
                                           else s.registry_kind || ':' || s.registry_id end)
                        order by coalesce(s.registry_kind || ':' || s.registry_id, s.label))
                 from knowledge.studies s
                 where s.id = any (g.study_ids)), '[]'::jsonb),
               'evidence_items', g.evidence_items,
               'reports', g.reports,
               'uncertain_linkage', g.uncertain,
               'review_overlap', g.review_overlap,
               'evidence_item_ids', to_jsonb(g.evidence_item_ids))
             order by g.unit_key)
      from gruppert g), '[]'::jsonb));
$$;

comment on function knowledge.study_units_for_evidence(uuid[]) is
  'Hvor mange uavhengige studier et evidenssett hviler på, og hvilke funn som deler deltakerutvalg (SOURCE_POLICY.md §7, §11). Grupperer funnene på studien kilden er registrert som en rapport om, og slår i tillegg sammen en systematisk oversikt med primærstudiene den inkluderer når begge er i grunnlaget — de er ikke uavhengige, og å telle begge ville telt de samme deltakerne to ganger. Sammenslåingen er en transitiv lukking: inkluderer en oversikt to primærstudier som begge er med, er alle tre én enhet. En kilde uten registrert kobling er sin egen enhet, fordi et fravær verken beviser overlapp eller uavhengighet. Sletter ingenting: hvert funn står fortsatt i enheten sin.';

-- ----------------------------------------------------------------------------
-- 4. Avtrykket oppgaven bindes til
--
-- Deterministisk over strukturen og ikke over rekkefølgen: den samme
-- uavhengighetsstrukturen gir det samme avtrykket, og en endring i den gir et
-- annet. Det er nettopp den endringen som skal gjøre et utestående svar
-- foreldet.
-- ----------------------------------------------------------------------------
create function knowledge.study_unit_digest(p_evidence_item_ids uuid[])
  returns text
  language sql
  stable
  set search_path = ''
as $$
  select 'sha256-v1:' || encode(
    sha256(convert_to(
      coalesce(
        (select string_agg(linje, '|' order by linje)
         from (
           select (u.value ->> 'evidence_items') || ':' || (u.value ->> 'reports')
                  || ':' || (u.value ->> 'review_overlap')
                  || ':' || coalesce(u.value ->> 'uncertain_linkage', '~')
                  || ':' || coalesce((
                       select string_agg(nokkel, ',' order by nokkel)
                       from (
                         select coalesce(s.value ->> 'registry',
                                         'navn:' || (s.value ->> 'label')) as nokkel
                         from jsonb_array_elements(u.value -> 'studies') as s(value)
                       ) studienavn), '~')
                  || ':' || coalesce((
                       select string_agg(x, ',' order by x)
                       from jsonb_array_elements_text(
                              u.value -> 'evidence_item_ids') as e(x)), '~')
             as linje
           from jsonb_array_elements(
                  knowledge.study_units_for_evidence(p_evidence_item_ids) -> 'units') as u(value)
         ) rader),
        'tom'),
      'UTF8')), 'hex');
$$;

comment on function knowledge.study_unit_digest(uuid[]) is
  'Avtrykket av uavhengighetsstrukturen i et evidenssett. Ligger i bindingen til synteseoppgaven og evidensvurderingen, slik at en studiekobling registrert etter at oppgaven ble hentet ut, gjør det gamle svaret foreldet — akkurat som en utvidelse av evidenssettet gjør det. Uten avtrykket kunne et svar bygget på en dobbelttelt tilstand blitt registrert i ettertid, og grunnlaget ville sett sterkere ut enn det er. Deterministisk over strukturen og ikke over rekkefølgen.';

revoke execute on function knowledge.study_unit_digest(uuid[]) from public;

-- ----------------------------------------------------------------------------
-- 5. Evidenssettet til én påstandsrevisjon
--
-- Evidensvurderingen kjenner revisjonen og ikke funnlisten. Uten denne
-- oppslagsveien måtte begge grenene i workflow.agent_task hatt hver sin
-- utledning av det samme settet.
-- ----------------------------------------------------------------------------
create function knowledge.claim_revision_evidence_items(p_claim_revision_id uuid)
  returns uuid[]
  language sql
  stable
  set search_path = ''
as $$
  select coalesce(
    array_agg(l.evidence_item_id order by l.evidence_item_id::text),
    array[]::uuid[])
  from knowledge.claim_evidence_links l
  where l.claim_revision_id = p_claim_revision_id;
$$;

comment on function knowledge.claim_revision_evidence_items(uuid) is
  'Evidensfunnene én påstandsrevisjon hviler på, i en fast rekkefølge. Finnes for at grupperingen og avtrykket av den skal kunne regnes ut fra en revisjon like enkelt som fra en funnliste, uten at to steder utleder det samme settet hver for seg.';

revoke execute on function knowledge.claim_revision_evidence_items(uuid) from public;

-- ----------------------------------------------------------------------------
-- 6. Én normalisering av kildeidentifikatoren, ikke to
--
-- Normaliseringen lå i workflow og var kildeoppdagelsens egen. Redaktørveien
-- trenger nøyaktig den samme — ellers ville en DOI skrevet med store bokstaver
-- ikke funnet igjen kilden kildeoppdagelsen alt har registrert. Den kanoniske
-- formen flyttes derfor til knowledge, og workflow-funksjonen blir det den nå
-- er: et navn på den samme regelen.
-- ----------------------------------------------------------------------------
create function knowledge.normalized_source_identifier(p_kind text, p_value text)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  select case p_kind
    -- DOI-er er ikke bokstavstørrelsesfølsomme, og raden lagrer dem med små
    -- bokstaver. «10.1234/ABC» og «10.1234/abc» er den samme artikkelen.
    when 'doi' then regexp_replace(
      lower(btrim(p_value)), '^https?://(dx\.)?doi\.org/', '')
    when 'pmcid' then upper(btrim(p_value))
    -- Samme regel som studien lagres under, og av samme grunn: uten den ville
    -- «nct00000001» og «NCT00000001» vært to kilder om det samme forsøket.
    when 'registry_id' then knowledge.normalized_registry_id(p_value)
    else btrim(p_value)
  end;
$$;

comment on function knowledge.normalized_source_identifier(text, text) is
  'Kildeidentifikatoren på den formen identifikatorraden lagrer den. Normaliseringen finnes fordi to skrivemåter av den samme DOI-en eller det samme forsøksregisternummeret ellers ville blitt to kilder, og da ville verken det private kildebiblioteket eller redaktørens oppslag funnet igjen noe Antidep alt har.';

revoke execute on function knowledge.normalized_source_identifier(text, text) from public;

create or replace function workflow.monograph_normalized_identifier(p_kind text, p_value text)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  select knowledge.normalized_source_identifier(p_kind, p_value);
$$;

comment on function workflow.monograph_normalized_identifier(text, text) is
  'Kandidatens identifikator på den formen identifikatorraden lagrer den. Er nå bare et navn på knowledge.normalized_source_identifier: kildeoppdagelsen og redaktørens oppslag må bruke nøyaktig den samme regelen, ellers finner den ene ikke igjen det den andre har registrert.';

-- ----------------------------------------------------------------------------
-- 7. Studiens identitet på ett sted
--
-- «Finn eller opprett studien» lå inne i rapportkoblingen. Oversiktskoblingen
-- trenger nøyaktig det samme oppslaget, og to utgaver av det ville vært to
-- navnerom igjen. Overstyringen av registertypen ligger her, slik at den
-- gjelder uansett hvem som skriver.
-- ----------------------------------------------------------------------------
create function knowledge.find_or_create_study(
  p_registry_kind text,
  p_registry_id text,
  p_label text,
  p_actor_id uuid,
  p_agent_run_id uuid)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_registry_id text;
  v_kind text;
  v_derived text;
  v_label text;
  v_study_id uuid;
begin
  v_registry_id := knowledge.normalized_registry_id(p_registry_id);
  v_label := nullif(btrim(coalesce(p_label, '')), '');
  v_kind := nullif(btrim(lower(coalesce(p_registry_kind, ''))), '');

  if v_registry_id is null and v_label is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Studien må ha enten et registernummer eller et lesbart navn.';
  end if;

  -- Formen på nummeret avgjør registeret når den kan det, uansett hva kalleren
  -- oppgav. Uten overstyringen ble det samme forsøket to studier: kildeoppdagelsen
  -- sa «other» om NCT00000001, redaktøren sa «clinicaltrials_gov» om det samme
  -- nummeret, og unikheten står på paret (register, nummer).
  v_derived := knowledge.registry_kind_for_identifier(v_registry_id);
  if v_derived is not null then
    v_kind := v_derived;
  end if;

  -- Et registernummer uten et register er ingen identitet: NCT00000000 og
  -- ISRCTN00000000 er ikke det samme nummeret, og uten registeret vet ingen
  -- hvilket av dem raden mener.
  if v_registry_id is not null and v_kind is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Et forsøksregisternummer må si hvilket register det er fra.',
      hint = 'Gyldige registre er clinicaltrials_gov, euctr, isrctn, who_ictrp og other. Et NCT-, ISRCTN- eller EudraCT-nummer trenger ingen angivelse: formen sier selv hvilket register det er.';
  end if;

  -- Låsen gjør «finn eller opprett» til én udelelig handling, og den står på
  -- identiteten og ikke på en rad — nettopp fordi raden ennå ikke finnes. Uten
  -- den ville to samtidige koblinger til den samme studien begge sett
  -- «finnes ikke», og den ene ville tapt på unikhetskravet.
  if v_registry_id is not null then
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('antidep:studie:' || v_kind || ':' || v_registry_id, 0));

    select s.id into v_study_id
    from knowledge.studies s
    where s.registry_kind = v_kind and s.registry_id = v_registry_id;
  else
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('antidep:studie:navn:' || lower(v_label), 0));

    select s.id into v_study_id
    from knowledge.studies s
    where s.registry_kind is null and lower(s.label) = lower(v_label);
  end if;

  if v_study_id is null then
    insert into knowledge.studies
      (registry_kind, registry_id, label, created_by_actor_id)
    values (
      case when v_registry_id is null then null else v_kind end,
      v_registry_id,
      coalesce(v_label, v_kind || ':' || v_registry_id),
      coalesce(p_actor_id,
               (select r.actor_id from provenance.agent_runs r where r.id = p_agent_run_id)))
    returning id into v_study_id;
  end if;

  return v_study_id;
end;
$$;

comment on function knowledge.find_or_create_study(text, text, text, uuid, uuid) is
  'Studien med den identiteten, opprettet hvis den ikke finnes (SOURCE_POLICY.md §7). Identiteten er forsøksregisternummeret når det finnes, ellers navnet. Registeret utledes av nummerets egen form når formen er kjent, og overstyrer da det kalleren oppgav — ellers ville kildeoppdagelsens «other» og redaktørens «clinicaltrials_gov» blitt to studier om det samme forsøket, og vernet mot dobbelttelling uten virkning. Felles for rapportkoblingen og oversiktskoblingen, slik at begge veier inn gir den samme studien.';

revoke execute on function knowledge.find_or_create_study(text, text, text, uuid, uuid) from public;

-- ----------------------------------------------------------------------------
-- 8. Rapportkoblingen bruker den felles identiteten
--
-- Uendret bortsett fra at «finn eller opprett studien» nå ligger ett sted.
-- ----------------------------------------------------------------------------
create or replace function knowledge.register_study_report(
  p_source_id uuid,
  p_registry_kind text,
  p_registry_id text,
  p_label text,
  p_report_role knowledge.study_report_role,
  p_linkage_basis text,
  p_certainty knowledge.study_link_certainty,
  p_actor_id uuid,
  p_agent_run_id uuid)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_study_id uuid;
  v_existing uuid;
begin
  if p_source_id is null or not exists (
    select 1 from knowledge.sources s where s.id = p_source_id) then
    raise exception using
      errcode = 'no_data_found',
      message = 'Kilden finnes ikke.';
  end if;

  if btrim(coalesce(p_linkage_basis, '')) = '' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En rapportkobling må si hva den hviler på.',
      hint = 'Tittel-likhet er ikke et grunnlag: en udokumentert kobling kan slå sammen to studier, og da telles deltakerne én gang for mye eller én gang for lite (SOURCE_POLICY.md §7).';
  end if;

  v_study_id := knowledge.find_or_create_study(
    p_registry_kind, p_registry_id, p_label, p_actor_id, p_agent_run_id);

  -- Én kilde hører til høyst én studie. Den samme koblingen på nytt er den
  -- samme koblingen; en *annen* studie er en motsetning, og den skal si fra.
  select r.study_id into v_existing
  from knowledge.study_reports r
  where r.source_id = p_source_id;

  if v_existing is not null then
    if v_existing <> v_study_id then
      raise exception using
        errcode = 'restrict_violation',
        message = 'Kilden er allerede registrert som en rapport om en annen studie.',
        hint = 'Én kilde hører til høyst én studie. Er den forrige koblingen feil, er det den som må rettes — to studier på den samme artikkelen ville gjort vernet mot dobbelttelling uten virkning (SOURCE_POLICY.md §7).';
    end if;
    return v_study_id;
  end if;

  insert into knowledge.study_reports
    (study_id, source_id, report_role, linkage_basis, certainty,
     linked_by_actor_id, linked_by_agent_run_id)
  values (v_study_id, p_source_id, p_report_role, btrim(p_linkage_basis), p_certainty,
          p_actor_id, p_agent_run_id);

  return v_study_id;
end;
$$;

-- ----------------------------------------------------------------------------
-- 9. Kilden slås opp entydig, eller ikke i det hele tatt
--
-- Tittel er ikke en identitet — det sier repoet selv om kandidattreffene. Det
-- gjaldt ikke mindre for redaktørveien, som slo opp på tittel og tok den
-- eldste. To artikler med samme tittel ville da gitt en stille feilkobling, og
-- en feilkobling er nettopp det som lager en dobbelttelling.
-- ----------------------------------------------------------------------------
create function knowledge.source_id_for_reference(p_reference text)
  returns uuid
  language plpgsql
  stable
  set search_path = ''
as $$
declare
  v_reference text := btrim(coalesce(p_reference, ''));
  v_kind text;
  v_value text;
  v_source_id uuid;
  v_matches integer;
begin
  if v_reference = '' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Kilden må navngis.';
  end if;

  -- «system:verdi» når referansen sier det selv, ellers utledet av formen. En
  -- redaktør skal kunne lime inn en DOI, et PubMed-nummer eller et
  -- forsøksregisternummer uten å vite hva systemet heter i databasen.
  if v_reference ~ '^(doi|pmid|pmcid|url|registry_id):' then
    v_kind := split_part(v_reference, ':', 1);
    v_value := btrim(substr(v_reference, length(v_kind) + 2));
  elsif v_reference ~ '^10\.[0-9]{4,9}/'
     or v_reference ~* '^https?://(dx\.)?doi\.org/' then
    v_kind := 'doi';
    v_value := v_reference;
  elsif v_reference ~ '^[0-9]{1,8}$' then
    v_kind := 'pmid';
    v_value := v_reference;
  elsif v_reference ~* '^PMC[0-9]+$' then
    v_kind := 'pmcid';
    v_value := v_reference;
  elsif knowledge.registry_kind_for_identifier(v_reference) is not null then
    v_kind := 'registry_id';
    v_value := v_reference;
  elsif v_reference ~* '^https?://' then
    v_kind := 'url';
    v_value := v_reference;
  end if;

  if v_kind is not null then
    v_value := knowledge.normalized_source_identifier(v_kind, v_value);

    select i.source_id into v_source_id
    from knowledge.source_identifiers i
    where i.identifier_system = v_kind::knowledge.source_identifier_system
      and i.identifier_value = v_value;

    if v_source_id is null then
      raise exception using
        errcode = 'no_data_found',
        message = format('Antidep har ingen kilde med identifikatoren %s.', v_reference);
    end if;

    return v_source_id;
  end if;

  -- Ingen identifikator: tittelen får slå opp, men bare når den er entydig.
  select count(*)::integer into v_matches
  from knowledge.sources s
  where lower(s.title) = lower(v_reference);

  if v_matches = 0 then
    raise exception using
      errcode = 'no_data_found',
      message = 'Antidep har ingen kilde med den tittelen.';
  end if;

  if v_matches > 1 then
    raise exception using
      errcode = 'restrict_violation',
      message = format('%s kilder har den tittelen, og Antidep vet ikke hvilken som menes.', v_matches),
      hint = 'Oppgi DOI, PubMed-nummer, PMCID, adresse eller forsøksregisternummer i stedet. En tittel er ikke en identitet, og et gjett her ville koblet feil artikkel til en studie — nettopp det som lager en dobbelttelling (SOURCE_POLICY.md §4.3, §7).';
  end if;

  select s.id into v_source_id
  from knowledge.sources s
  where lower(s.title) = lower(v_reference);

  return v_source_id;
end;
$$;

comment on function knowledge.source_id_for_reference(text) is
  'Kilden en menneskelig referanse peker på: en DOI, et PubMed-nummer, en PMCID, en adresse eller et forsøksregisternummer — med eller uten «system:»-prefiks — ellers en tittel. Tittelen godtas bare når den er entydig: to kilder kan hete det samme, og å ta den eldste ville koblet feil artikkel i stillhet (SOURCE_POLICY.md §4.3). Ingen intern id går inn eller ut.';

revoke execute on function knowledge.source_id_for_reference(text) from public;

-- ----------------------------------------------------------------------------
-- 10. Redaktørens vei inn til rapportkoblingen
--
-- Erstattes framfor å endres, fordi parameteren skifter betydning: den tar nå
-- en referanse og ikke bare en tittel. Et navn som lover noe annet enn det
-- funksjonen gjør, er verre enn et nytt navn.
-- ----------------------------------------------------------------------------
drop function api.register_study_report(text, text, text, text, text, text, boolean);

create function api.register_study_report(
  p_source_reference text,
  p_registry_kind text,
  p_registry_id text,
  p_study_label text,
  p_report_role text,
  p_linkage_basis text,
  p_certain boolean default true)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_source_id uuid;
  v_study_id uuid;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  v_source_id := knowledge.source_id_for_reference(p_source_reference);

  v_study_id := knowledge.register_study_report(
    v_source_id, p_registry_kind, p_registry_id, p_study_label,
    coalesce(p_report_role, 'primary_report')::knowledge.study_report_role,
    p_linkage_basis,
    case when p_certain then 'documented'::knowledge.study_link_certainty
         else 'uncertain'::knowledge.study_link_certainty end,
    v_actor_id, null);

  return jsonb_build_object(
    'study', (select s.label from knowledge.studies s where s.id = v_study_id),
    'registry', (select case when s.registry_kind is null then null
                             else s.registry_kind || ':' || s.registry_id end
                 from knowledge.studies s where s.id = v_study_id),
    'reports', (select count(*)::integer from knowledge.study_reports r
                where r.study_id = v_study_id),
    'certain', p_certain);
end;
$$;

comment on function api.register_study_report(text, text, text, text, text, text, boolean) is
  'Redaktørens vei til å si at en artikkel er en rapport om en studie Antidep alt kjenner, eller om en ny (SOURCE_POLICY.md §7). Kilden navngis med en DOI, et PubMed-nummer, en adresse, et forsøksregisternummer eller en entydig tittel, og aldri med en intern id: teknisk registrering er ikke klinikerens arbeid. En tittel som treffer flere kilder, avvises framfor å gjettes. Grunnlaget for koblingen er påkrevd, og en usikker kobling registreres som usikker framfor å bli utelatt — en kobling ingen tør stå for, er fortsatt en opplysning om at de to kan dele deltakerutvalg. Krever redaktørmandat.';

revoke execute on function api.register_study_report(text, text, text, text, text, text, boolean) from public;
grant execute on function api.register_study_report(text, text, text, text, text, text, boolean) to authenticated;

-- ----------------------------------------------------------------------------
-- 11. Oversikten og studiene den inkluderer
-- ----------------------------------------------------------------------------
create function knowledge.link_review_included_study(
  p_review_source_id uuid,
  p_study_id uuid,
  p_inclusion_basis text,
  p_certainty knowledge.study_link_certainty,
  p_actor_id uuid,
  p_agent_run_id uuid)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_own_study uuid;
begin
  if p_review_source_id is null or not exists (
    select 1 from knowledge.sources s where s.id = p_review_source_id) then
    raise exception using
      errcode = 'no_data_found',
      message = 'Oversikten finnes ikke som kilde.';
  end if;

  if p_study_id is null or not exists (
    select 1 from knowledge.studies s where s.id = p_study_id) then
    raise exception using
      errcode = 'no_data_found',
      message = 'Studien finnes ikke.';
  end if;

  if btrim(coalesce(p_inclusion_basis, '')) = '' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En inklusjonskobling må si hva den hviler på.',
      hint = 'Samme krav som for rapportkoblingen: si hvor i oversikten studien står oppført (SOURCE_POLICY.md §7, §11).';
  end if;

  -- Oversikten kan ikke inkludere den studien den selv er en rapport om. Det
  -- ville vært en påstand om at kilden overlapper med seg selv, og den sier
  -- ingenting om uavhengighet.
  select r.study_id into v_own_study
  from knowledge.study_reports r
  where r.source_id = p_review_source_id;

  if v_own_study is not null and v_own_study = p_study_id then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Oversikten er selv registrert som en rapport om den studien.',
      hint = 'En kilde overlapper alltid med seg selv, og opplysningen sier derfor ingenting om uavhengighet. Er den ene av de to koblingene feil, er det den som må rettes.';
  end if;

  -- Den samme inklusjonen på nytt er den samme inklusjonen. Grunnlaget for den
  -- første står; en ny skriving overskriver ikke et registrert grunnlag.
  insert into knowledge.review_included_studies
    (review_source_id, study_id, inclusion_basis, certainty,
     linked_by_actor_id, linked_by_agent_run_id)
  values (p_review_source_id, p_study_id, btrim(p_inclusion_basis), p_certainty,
          p_actor_id, p_agent_run_id)
  on conflict on constraint review_included_studies_pair_key do nothing;

  return p_study_id;
end;
$$;

comment on function knowledge.link_review_included_study(uuid, uuid, text, knowledge.study_link_certainty, uuid, uuid) is
  'Registrerer at en systematisk oversikt inkluderer en studie (SOURCE_POLICY.md §7, §11), slik at oversikten og primærstudien ikke telles som to uavhengige deltakerutvalg. Grunnlaget er påkrevd og proveniensen er enten et menneske eller en agentkjøring. Idempotent: den samme inklusjonen på nytt endrer ingenting, og et registrert grunnlag overskrives ikke.';

revoke execute on function knowledge.link_review_included_study(uuid, uuid, text, knowledge.study_link_certainty, uuid, uuid) from public;

create function api.link_review_included_study(
  p_review_reference text,
  p_registry_kind text,
  p_registry_id text,
  p_study_label text,
  p_inclusion_basis text,
  p_certain boolean default true)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_review_source_id uuid;
  v_study_id uuid;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  v_review_source_id := knowledge.source_id_for_reference(p_review_reference);

  -- Den inkluderte studien identifiseres på nøyaktig samme måte som i
  -- rapportkoblingen, og opprettes hvis Antidep ikke kjenner den fra før: en
  -- oversikt kan godt liste en studie ingen har lagt fram artikkelen til ennå,
  -- og når artikkelen senere kommer inn, lander den på den samme studien.
  v_study_id := knowledge.find_or_create_study(
    p_registry_kind, p_registry_id, p_study_label, v_actor_id, null);

  perform knowledge.link_review_included_study(
    v_review_source_id, v_study_id, p_inclusion_basis,
    case when p_certain then 'documented'::knowledge.study_link_certainty
         else 'uncertain'::knowledge.study_link_certainty end,
    v_actor_id, null);

  return jsonb_build_object(
    'review', (select s.title from knowledge.sources s where s.id = v_review_source_id),
    'study', (select s.label from knowledge.studies s where s.id = v_study_id),
    'registry', (select case when s.registry_kind is null then null
                             else s.registry_kind || ':' || s.registry_id end
                 from knowledge.studies s where s.id = v_study_id),
    'included_studies', (select count(*)::integer
                         from knowledge.review_included_studies ri
                         where ri.review_source_id = v_review_source_id),
    'certain', p_certain);
end;
$$;

comment on function api.link_review_included_study(text, text, text, text, text, boolean) is
  'Redaktørens vei til å si at en systematisk oversikt inkluderer en bestemt studie (SOURCE_POLICY.md §7, §11). Uten den kunne en oversikt og primærstudiene den bygger på, telles som uavhengige kilder, og de samme deltakerne ville talt to ganger. Oversikten navngis med en identifikator eller en entydig tittel, studien med forsøksregisternummeret sitt eller navnet sitt — og studien opprettes hvis Antidep ikke kjenner den, slik at artikkelen om den lander på den samme studien når den senere kommer inn. Krever redaktørmandat.';

revoke execute on function api.link_review_included_study(text, text, text, text, text, boolean) from public;
grant execute on function api.link_review_included_study(text, text, text, text, text, boolean) to authenticated;

-- ----------------------------------------------------------------------------
-- 12. Kildeoppdagelsen registrerer studien i riktig register
--
-- Uendret bortsett fra utledningen av registertypen.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION workflow.ensure_monograph_candidate_source(p_candidate_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_cand workflow.monograph_candidate_sources;
  v_system knowledge.source_identifier_system;
  v_value text;
  v_profile_code text;
  v_source_id uuid;
begin
  select c.* into v_cand
  from workflow.monograph_candidate_sources c
  where c.id = p_candidate_id
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Kandidatkilden finnes ikke.';
  end if;

  if v_cand.source_id is not null then
    return v_cand.source_id;
  end if;

  v_system := workflow.monograph_candidate_identifier_system(v_cand.identifier_kind);
  if v_system is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Kandidaten er bare identifisert med en tittel, og kan ikke registreres som en kilde.',
      hint = 'En tittel er ikke en identitet: to publikasjoner kan hete det samme. Registrer treffets DOI, PMID, PMCID, adresse eller forsøksregisternummer først (SOURCE_POLICY.md §4.3).';
  end if;

  v_value := workflow.monograph_normalized_identifier(
    v_cand.identifier_kind, v_cand.identifier_value);

  select sp.code into v_profile_code
  from workflow.monograph_search_plans p
  join knowledge.monograph_source_profiles sp on sp.id = p.profile_id
  where p.id = v_cand.plan_id;

  -- Låsen gjør «finn eller opprett» til én udelelig handling, og den står på
  -- den normaliserte identifikatoren og ikke på en rad — nettopp fordi raden
  -- ennå ikke finnes. Uten den ville to samtidige innhentinger av den samme
  -- artikkelen begge sett «finnes ikke», og begge opprettet hver sin.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'antidep:kilde-identifikator:' || v_system::text || ':' || v_value, 0));

  select i.source_id into v_source_id
  from knowledge.source_identifiers i
  where i.identifier_system = v_system and i.identifier_value = v_value;

  if v_source_id is null then
    -- Kilden og identifikatoren settes inn i den samme underblokken med vilje:
    -- taper vi kappløpet mot en annen skrivevei, skal *begge* innsettingene
    -- rulles tilbake. Lå kilderaden utenfor, ville taperen etterlatt en
    -- publikasjon uten identifikator — en rad den neste innhentingen ikke
    -- ville funnet igjen.
    begin
      insert into knowledge.sources (
        source_type, title, authors_or_issuer, publisher_or_journal,
        publication_date, publication_date_precision, created_by_actor_id
      )
      values (
        coalesce(workflow.monograph_profile_source_type(v_profile_code),
                 'journal_article'::knowledge.source_type),
        v_cand.title,
        -- Det treffet faktisk oppgav. Taushet er ikke en forfatterliste, og
        -- den står som det den er framfor å bli fylt inn ved gjetning.
        coalesce(nullif(btrim(coalesce(v_cand.authors_or_issuer, '')), ''),
                 nullif(btrim(coalesce(v_cand.publisher_or_journal, '')), ''),
                 'ikke oppgitt i søketreffet'),
        v_cand.publisher_or_journal,
        case when v_cand.publication_year is null then null
             else make_date(v_cand.publication_year, 1, 1) end,
        case when v_cand.publication_year is null then null
             else 'year'::knowledge.date_precision end,
        v_cand.recorded_by_actor_id
      )
      returning id into v_source_id;

      insert into knowledge.source_identifiers
        (source_id, identifier_system, identifier_value)
      values (v_source_id, v_system, v_value);
    exception
      when unique_violation then
        select i.source_id into v_source_id
        from knowledge.source_identifiers i
        where i.identifier_system = v_system and i.identifier_value = v_value;
        if v_source_id is null then
          raise exception using
            errcode = 'restrict_violation',
            message = 'Kilden kunne ikke registreres nå.',
            hint = 'Unikhetskravet på identifikatoren slo til, men raden som vant, fantes ikke da den ble slått opp igjen. Det er en tilstand innhentingen ikke kan tolke, og den stopper framfor å opprette en publikasjon til.';
        end if;
    end;
  end if;

  -- Forsøksregisternummeret er studiens identitet, ikke bare kildens.
  --
  -- Fant kildeoppdagelsen treffet på et registernummer, vet Antidep i det samme
  -- øyeblikket hvilken studie rapporten handler om. Koblingen registreres her,
  -- gjennom den kontrollerte veien og med kjøringen som fant den som proveniens
  -- — ellers ville opplysningen vært kastet, og hovedartikkel og
  -- langtidsoppfølging fra samme studie ville senere sett ut som to uavhengige
  -- deltakerutvalg (SOURCE_POLICY.md §7).
  if v_cand.identifier_kind = 'registry_id' then
    perform knowledge.register_study_report(
      v_source_id,
      -- Registeret slik kildeoppdagelsen leser treffets eget nummer. Er formen
      -- ukjent, står «other» som det den er: et ukjent register. Er den kjent,
      -- avgjør knowledge.find_or_create_study uansett — identiteten er paret
      -- (register, nummer), og to navnerom for det samme nummeret ga to studier
      -- om det samme forsøket, og dermed intet vern mot dobbelttelling.
      coalesce(knowledge.registry_kind_for_identifier(v_value), 'other'),
      v_value,
      v_cand.title,
      'registry_record'::knowledge.study_report_role,
      format('Kildeoppdagelsen fant treffet på forsøksregisternummeret %s, som er studiens egen identitet.', v_value),
      'documented'::knowledge.study_link_certainty,
      case when v_cand.proposed_by_agent_run_id is null
           then v_cand.recorded_by_actor_id end,
      v_cand.proposed_by_agent_run_id);
  end if;

  update workflow.monograph_candidate_sources c
  set source_id = v_source_id
  where c.id = p_candidate_id;

  return v_source_id;
end;
$function$;

-- ----------------------------------------------------------------------------
-- 13. Begge oppgavene bindes til uavhengighetsstrukturen
--
-- Uendret bortsett fra `study_unit_digest` i bindingen til både syntesen og
-- evidensvurderingen, og `study_units` i materialet evidensvurderingen leser.
-- Bindingen er det forespørselsavtrykket regnes av, og et svar avgitt på en
-- annen uavhengighetsstruktur enn den som gjelder nå, skal avvises.
-- ----------------------------------------------------------------------------
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
             ),
             -- Uavhengighetsstrukturen hører til forespørselen og ikke bare til
             -- materialet. Blir to rapporter koblet til den samme studien etter
             -- at oppgaven ble hentet ut, er grunnlaget et annet enn det svaret
             -- ble bygget på, og forespørselsavtrykket skal avvise det gamle
             -- svaret (SOURCE_POLICY.md §7). Avtrykket ligger i bindingen og
             -- ikke i manifestet: en ny studiekobling gjør et utestående svar
             -- foreldet, men den lager ingen ny oppgave — oppgavenøkkelen
             -- regnes av manifestet, og oppgaven er fortsatt den samme.
             'study_unit_digest', knowledge.study_unit_digest(v_evidence_ids)
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
             -- Hvor mange uavhengige studier grunnlaget hviler på, og hvilke
             -- funn som deler deltakerutvalg. Uten dette ville agenten fått N
             -- funn uten å få vite at to av dem er to rapporter om det samme
             -- utvalget, og en syntese som talte dem som uavhengige, ville
             -- overdrevet grunnlaget (SOURCE_POLICY.md §7).
             'study_units', knowledge.study_units_for_evidence(v_evidence_ids),
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
             'evidence_set_digest', knowledge.claim_evidence_set_digest(r.id),
             -- Samme grunn som i syntesen. GRADE-leddet leser presisjon,
             -- konsistens og publikasjonsskjevhet av hvor mange uavhengige
             -- utvalg grunnlaget hviler på, og en studiekobling registrert i
             -- etterkant endrer nettopp det tallet (SOURCE_POLICY.md §7).
             'study_unit_digest', knowledge.study_unit_digest(
               knowledge.claim_revision_evidence_items(r.id))
           ),
           jsonb_build_object(
             'dossier', workflow.claim_evidence_dossier(r.id),
             'seen_evidence_set_digest', knowledge.claim_evidence_set_digest(r.id),
             -- Uten dette leste evidensvurderingen tre rapporter om den samme
             -- studien som tre uavhengige utvalg, selv om syntesen visste
             -- bedre. Grupperingen sletter ingenting: hvert funn står fortsatt
             -- i dossieret, og feltet sier bare hvilke av dem som deler utvalg.
             'study_units', knowledge.study_units_for_evidence(
               knowledge.claim_revision_evidence_items(r.id))
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
