-- ============================================================================
-- Migrasjon 013g — fra valgt kilde til kontrollert grunnlag, og avgrensningen
--                  som følger påstanden
--
-- Søkeloggen sier hvilke kilder som er valgt. Denne migrasjonen fører dem
-- videre — automatisk, innen den godkjente arbeidsflyten — og lukker den ene
-- grensen i den eksisterende kjeden som ellers ville stoppet monografien:
--
--   > Kjeden synteserer ikke om igjen en påstand som allerede finnes for det
--   > samme temaet og virkestoffet.
--
-- Den grensen er riktig for den artikkelbaserte flyten, og feil for en
-- monografi. Effekten ved én indikasjon og effekten ved en annen er to svar
-- (MONOGRAPH_STANDARD.md §2), og de kolliderte fordi påstandens identitet bare
-- var tema og virkestoff.
--
-- ----------------------------------------------------------------------------
-- Hvorfor avgrensningen blir en kolonne på påstanden
--
-- Fordi det er identiteten som må bære den. Et avtrykk på revisjonen ville ikke
-- hjulpet: porten spør «finnes det allerede en påstand for dette», og den spør
-- på identiteten. `knowledge.claims.monograph_need_id` er den avgrensningen —
-- kunnskapsbehovet påstanden svarer på — og den settes av databasen av
-- evidenslenkene, ikke av en kaller.
--
-- Legacy-påstander har NULL, og den artikkelbaserte flyten oppfører seg presis
-- som før: to funn om det samme paret, uten en monografi, gir fortsatt den
-- redaksjonelle revisjonsoppgaven. Det er bare de monografidrevne påstandene
-- som får sin egen identitet per behov.
--
-- ----------------------------------------------------------------------------
-- Hvorfor behovet utledes av evidensen og ikke oppgis
--
-- Fordi en kaller som kunne oppgi det, kunne oppgi feil — og da ville et
-- kontrollert funn havnet under et spørsmål det aldri ble kontrollert for.
-- `knowledge.monograph_need_for_evidence_item(uuid)` utleder behovet av tre
-- rader som allerede finnes: den godkjente kildebruken, funnets eget endepunkt
-- og funnets populasjon. Er svaret tvetydig, er det NULL — og da gjelder den
-- gamle, forsiktige oppførselen.
--
-- ----------------------------------------------------------------------------
-- Hvorfor en betalingsmur ikke stopper arbeidet
--
-- Fordi den er en tilgangsbegrensning. Innhentingen leter først i det private
-- kildebiblioteket, deretter etter en registrert kildeversjon Antidep allerede
-- har, og først når ingen av dem finnes, blir det en samlet forespørsel til et
-- menneske — med artikkelidentiteten og den faglige grunnen, og uten et eneste
-- teknisk felt (SOURCE_POLICY.md §5).
--
-- Styrende dokumenter: docs/SOURCE_POLICY.md §1, §5, §7,
-- docs/MONOGRAPH_STANDARD.md §2, §9, docs/ANTIDEP_CONSTITUTION.md regel 1, 2, 4,
-- docs/EVIDENCE_PIPELINE.md, docs/KNOWLEDGE_MODEL.md.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Den godkjente kildebruken
--
-- «Kilder godkjennes for en bestemt bruk og avgrensning, ikke universelt»
-- (SOURCE_POLICY.md §2). Raden er nettopp det: én kildeversjon, ett behov, og
-- hva den er godkjent for der.
-- ----------------------------------------------------------------------------

create table knowledge.monograph_source_uses (
  id uuid primary key default gen_random_uuid(),

  need_id uuid not null
    references knowledge.monograph_needs (id) on update restrict on delete restrict,
  source_version_id uuid not null
    references knowledge.source_versions (id) on update restrict on delete restrict,

  -- Hva kildeversjonen er godkjent for i nettopp dette behovet.
  approved_use text not null,
  -- Avgrensningen den ble godkjent under. En kilde godkjent for et behov med en
  -- annen avgrensning er en annen godkjenning.
  scope_digest text not null,

  approved_by_actor_id uuid
    references provenance.actors (id) on update restrict on delete restrict,
  approved_by_agent_run_id uuid
    references provenance.agent_runs (id) on update restrict on delete restrict,
  created_at timestamptz not null default now(),

  constraint monograph_source_uses_pair_key unique (need_id, source_version_id),
  constraint monograph_source_uses_use_shape_check
    check (approved_use = btrim(approved_use) and length(approved_use) between 1 and 1000),
  constraint monograph_source_uses_scope_digest_shape_check
    check (scope_digest ~ '^sha256:[0-9a-f]{64}$'),
  constraint monograph_source_uses_origin_check
    check (num_nonnulls(approved_by_actor_id, approved_by_agent_run_id) = 1)
);

comment on table knowledge.monograph_source_uses is
  'Én kildeversjon godkjent for én bestemt bruk i ett kunnskapsbehov, under den avgrensningen behovet hadde da godkjenningen ble gjort. Finnes fordi en godkjent kilde ikke er en universell godkjenning: den samme artikkelen kan være egnet for farmakokinetikk og uegnet for sammenlignende klinisk effekt (SOURCE_POLICY.md §2). Mange-til-mange, fordi én kilde kan bidra til flere behov og ett behov kan kreve flere kilder (§1). Raden er også det som lar databasen utlede hvilket kunnskapsbehov et senere evidensfunn svarer på.';
comment on column knowledge.monograph_source_uses.scope_digest is
  'Behovets avgrensningsavtrykk da kilden ble godkjent. Står på godkjenningen og ikke bare på behovet, fordi en godkjenning gjelder den avgrensningen den ble gitt under — og behovets avgrensning er uforanderlig, så et avvik her betyr at godkjenningen gjelder et annet behov.';

alter table knowledge.monograph_source_uses enable row level security;

create index monograph_source_uses_version_idx
  on knowledge.monograph_source_uses (source_version_id);

create trigger monograph_source_uses_set_created_at
  before insert or update on knowledge.monograph_source_uses
  for each row execute function catalog.set_created_at();

create trigger monograph_source_uses_are_append_only
  before update or delete on knowledge.monograph_source_uses
  for each row execute function knowledge.reject_append_only_mutation();

-- ----------------------------------------------------------------------------
-- 2. Studien og rapportene om den
--
-- Flere publikasjoner fra samme studie og overlappende systematiske oversikter
-- må ikke telles som uavhengige deltakerutvalg (SOURCE_POLICY.md §7). Objektet
-- har stått som «planlagt, ikke implementert» i kunnskapsmodellen; her er det.
--
-- Koblingen krever et dokumentert grunnlag. Tittel-likhet er ikke nok, og en
-- usikker kobling skal være synlig framfor å bli løst ved en udokumentert
-- sammenslåing.
-- ----------------------------------------------------------------------------

create type knowledge.study_link_certainty as enum ('documented', 'uncertain');

revoke usage on type knowledge.study_link_certainty from public;

comment on type knowledge.study_link_certainty is
  'Hvor sikker koblingen mellom en rapport og en studie er (SOURCE_POLICY.md §7): documented (koblingen hviler på en identifikator eller en uttrykkelig henvisning i rapporten selv) eller uncertain (koblingen er sannsynlig, men ikke dokumentert). En usikker kobling skal være synlig og aldri løses ved en udokumentert sammenslåing — den hindrer at rapportene regnes som uavhengige, men den påstår ikke at de er den samme studien.';

create type knowledge.study_report_role as enum (
  'primary_report',
  'secondary_analysis',
  'protocol',
  'registry_record',
  'long_term_followup',
  'correction',
  'review_inclusion'
);

revoke usage on type knowledge.study_report_role from public;

comment on type knowledge.study_report_role is
  'Hva én rapport er for studien (SOURCE_POLICY.md §7): primary_report (hovedartikkelen), secondary_analysis (en sekundæranalyse), protocol (protokollen), registry_record (registeroppføringen), long_term_followup (en langtidsoppfølging), correction (en rettelse) eller review_inclusion (studien er inkludert i en systematisk oversikt). Vokabularet er poenget: én studie kan ha alle sju, og de er ikke sju uavhengige deltakerutvalg.';

create table knowledge.studies (
  id uuid primary key default gen_random_uuid(),

  -- Studiens egen identitet, når den har en: et forsøksregisternummer.
  registry_kind text,
  registry_id text,
  -- Og et lesbart navn når registernummeret mangler.
  label text not null,

  created_by_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,
  created_at timestamptz not null default now(),

  constraint studies_registry_pairing_check
    check ((registry_kind is null) = (registry_id is null)),
  constraint studies_registry_key unique (registry_kind, registry_id),
  constraint studies_registry_kind_check
    check (registry_kind is null
           or registry_kind in ('clinicaltrials_gov', 'euctr', 'isrctn', 'who_ictrp', 'other')),
  constraint studies_registry_id_shape_check
    check (registry_id is null
           or (registry_id = btrim(registry_id) and length(registry_id) between 1 and 100)),
  constraint studies_label_shape_check
    check (label = btrim(label) and length(label) between 1 and 500)
);

comment on table knowledge.studies is
  'Studien som sådan, atskilt fra rapportene om den (SOURCE_POLICY.md §7, KNOWLEDGE_MODEL.md). Objektet finnes fordi én studie kan ha protokoll, registeroppføring, hovedartikkel, sekundæranalyse, langtidsoppfølging og rettelse — og flere rapporter blir ikke flere uavhengige deltakerutvalg. Registernummeret er identiteten når den finnes; ellers står et lesbart navn.';

alter table knowledge.studies enable row level security;

create trigger studies_set_created_at
  before insert or update on knowledge.studies
  for each row execute function catalog.set_created_at();

create table knowledge.study_reports (
  id uuid primary key default gen_random_uuid(),

  study_id uuid not null
    references knowledge.studies (id) on update restrict on delete restrict,
  source_id uuid not null
    references knowledge.sources (id) on update restrict on delete restrict,

  report_role knowledge.study_report_role not null,
  -- Grunnlaget for koblingen, ordrett. Tittel-likhet er ikke nok.
  linkage_basis text not null,
  certainty knowledge.study_link_certainty not null,

  linked_by_actor_id uuid
    references provenance.actors (id) on update restrict on delete restrict,
  linked_by_agent_run_id uuid
    references provenance.agent_runs (id) on update restrict on delete restrict,
  created_at timestamptz not null default now(),

  constraint study_reports_pair_key unique (study_id, source_id),
  constraint study_reports_basis_shape_check
    check (linkage_basis = btrim(linkage_basis) and length(linkage_basis) between 1 and 2000),
  constraint study_reports_origin_check
    check (num_nonnulls(linked_by_actor_id, linked_by_agent_run_id) = 1)
);

comment on table knowledge.study_reports is
  'Koblingen mellom én rapport (kilde) og studien den handler om, med grunnlaget for koblingen og hvor sikkert det er (SOURCE_POLICY.md §7). Grunnlaget er påkrevd fordi tittel-likhet ikke er nok: en kobling uten dokumentasjon ville kunnet slå sammen to studier, og da ville deltakerne blitt telt én gang for mye eller én gang for lite. En usikker kobling er synlig som usikker framfor å bli løst ved en udokumentert sammenslåing.';

alter table knowledge.study_reports enable row level security;

create index study_reports_source_idx on knowledge.study_reports (source_id);

create trigger study_reports_set_created_at
  before insert or update on knowledge.study_reports
  for each row execute function catalog.set_created_at();

-- Én kilde kan høre til høyst én studie. Uten den regelen kunne den samme
-- artikkelen ha vært hovedrapport for to studier, og da ville
-- dobbelttellingsvernet vært uten virkning.
create unique index study_reports_one_study_per_source
  on knowledge.study_reports (source_id);

comment on index knowledge.study_reports_one_study_per_source is
  'Én kilde hører til høyst én studie. Uten regelen kunne den samme artikkelen vært hovedrapport for to studier, og vernet mot å telle det samme deltakerutvalget to ganger ville vært uten virkning.';

-- ----------------------------------------------------------------------------
-- 3. Avgrensningen som følger påstanden
-- ----------------------------------------------------------------------------

alter table knowledge.claims
  add column monograph_need_id uuid
    references knowledge.monograph_needs (id) on update restrict on delete restrict;

comment on column knowledge.claims.monograph_need_id is
  'Kunnskapsbehovet påstanden svarer på, når den er bygget av en monografibestilling. Er en del av identiteten: to behov med forskjellig indikasjon, populasjon eller utfall gir to påstander, og porten som spør «finnes det allerede en påstand for dette» spør på behovet og ikke bare på tema og virkestoff (MONOGRAPH_STANDARD.md §2). NULL for de artikkelbaserte påstandene, som oppfører seg presis som før. Settes av databasen av evidenslenkene og aldri av en kaller: en kaller som kunne oppgi den, kunne oppgi feil, og et kontrollert funn ville havnet under et spørsmål det aldri ble kontrollert for.';

create index claims_monograph_need_idx on knowledge.claims (monograph_need_id);

-- Uforanderlig når den er satt, men den kan settes én gang fra NULL: verdien
-- utledes av evidenslenkene, og de finnes først etter at påstanden er opprettet.
create or replace function knowledge.freeze_claim_identity()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if new.knowledge_type is distinct from old.knowledge_type
    or new.topic_concept_id is distinct from old.topic_concept_id
    or new.subject_drug_id is distinct from old.subject_drug_id
    or new.created_by_actor_id is distinct from old.created_by_actor_id
  then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Identiteten til påstand %L er uforanderlig og kan ikke endres.', old.id
      ),
      hint = 'Opprett en ny påstand for det endrede temaet, virkestoffet eller kunnskapstypen, og trekk den gamle tilbake med retired_at og en begrunnelse. Revisjoner, evidenslenker og publiseringshistorikk som peker på den gamle påstanden skal beholde sin opprinnelige betydning. Opphavet til en påstand kan ikke skrives om i ettertid.';
  end if;

  -- Avgrensningen kan settes én gang, fra NULL. Den utledes av evidenslenkene,
  -- og de finnes først etter at påstanden er opprettet — men når den først er
  -- satt, er den identitet som alt annet over.
  if old.monograph_need_id is not null
     and new.monograph_need_id is distinct from old.monograph_need_id then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Kunnskapsbehovet påstand %L svarer på, er uforanderlig.', old.id),
      hint = 'Behovet er påstandens avgrensning, og en endret avgrensning er en annen påstand. Et kontrollert svar skal ikke kunne flyttes til et spørsmål det aldri ble kontrollert for (MONOGRAPH_STANDARD.md §9).';
  end if;

  return new;
end;
$$;

-- ----------------------------------------------------------------------------
-- 4. Hvilket kunnskapsbehov et evidensfunn svarer på
--
-- Utledet av tre rader som allerede finnes: den godkjente kildebruken, funnets
-- eget endepunkt, og funnets populasjon med den indikasjonen populasjonen hører
-- under. Er svaret tvetydig, er det NULL — og da gjelder den gamle, forsiktige
-- oppførselen.
-- ----------------------------------------------------------------------------

create function knowledge.monograph_need_for_evidence_item(p_evidence_item_id uuid)
  returns uuid
  language sql
  stable
  set search_path = ''
as $$
  with kandidater as (
    select distinct u.need_id
    from knowledge.evidence_items e
    join knowledge.monograph_source_uses u on u.source_version_id = e.source_version_id
    join knowledge.monograph_needs n on n.id = u.need_id
    join knowledge.monograph_editions ed on ed.id = n.edition_id
    left join catalog.populations pop on pop.id = e.population_id
    where e.id = p_evidence_item_id
      -- Behovet gjelder virkestoffet funnet handler om.
      and ed.drug_id = e.intervention_drug_id
      -- Endepunktet må være nøyaktig funnets. Et behov uten et endepunkt kan
      -- ikke bære et forskningsfunn: ekstraksjonen har ingen avgrensning å
      -- kontrolleres mot.
      and n.outcome_concept_id = e.outcome_concept_id
      -- Populasjonen må være funnets, eller åpen på behovet.
      and (n.population_id is null or n.population_id = e.population_id)
      -- Og indikasjonen må stemme med den populasjonens indikasjon, når behovet
      -- er avgrenset til en.
      and (n.indication_concept_id is null
           or n.indication_concept_id = pop.indication_concept_id)
      and n.relevance = 'relevant'
  )
  -- Nøyaktig én, eller ingen. En tvetydig avgrensning er ikke en avgrensning,
  -- og en gjetning ville plassert et kontrollert funn under et spørsmål ingen
  -- kontrollerte det for.
  select k.need_id
  from kandidater k
  where (select count(*) from kandidater) = 1;
$$;

comment on function knowledge.monograph_need_for_evidence_item(uuid) is
  'Kunnskapsbehovet ett evidensfunn svarer på, eller NULL. Utledet av den godkjente kildebruken (knowledge.monograph_source_uses), funnets eget endepunkt, funnets populasjon og indikasjonen den populasjonen hører under — alle rader som allerede finnes. Svarer NULL når ingen eller flere behov passer: en tvetydig avgrensning er ikke en avgrensning, og en gjetning ville plassert et kontrollert funn under et spørsmål ingen kontrollerte det for. Et behov uten et endepunkt kan ikke bære et forskningsfunn i det hele tatt, fordi ekstraksjonen da ikke har noen avgrensning å kontrolleres mot.';

revoke execute on function knowledge.monograph_need_for_evidence_item(uuid) from public;

-- Og for et helt evidenssett: det ene behovet alle funnene svarer på, eller
-- NULL. Brukes av triggeren som setter avgrensningen på påstanden.
create function knowledge.monograph_need_for_evidence_set(p_evidence_item_ids uuid[])
  returns uuid
  language sql
  stable
  set search_path = ''
as $$
  -- Alle funnene, også de som ikke hører til noe behov.
  --
  -- NULL-treffene *skal* telles med. Et sett der ett funn entydig hører til
  -- behov X og et annet ikke hører til noe monografibehov i det hele tatt, er
  -- et blandet sett, og da er svaret NULL. Å filtrere bort NULL-ene før
  -- tellingen ville gjort «ett av funnene passer» til «alle funnene passer» —
  -- og et legacy-funn ville dratt hele påstanden inn under et spørsmål det
  -- aldri ble kontrollert for.
  with kandidater as (
    select distinct knowledge.monograph_need_for_evidence_item(i.id) as need_id
    from unnest(coalesce(p_evidence_item_ids, array[]::uuid[])) as i(id)
  )
  select k.need_id
  from kandidater k
  where k.need_id is not null
    and (select count(*) from kandidater) = 1;
$$;

comment on function knowledge.monograph_need_for_evidence_set(uuid[]) is
  'Det ene kunnskapsbehovet *alle* funnene i et evidenssett svarer på, eller NULL når de svarer på flere, på ingen, eller når bare noen av dem hører til et behov. NULL-treffene telles med i tvetydigheten: et sett der ett funn hører til behov X og et annet ikke hører til noe monografibehov, er blandet, og da er påstanden ikke monografiavgrenset. Brukes til å sette avgrensningen på påstanden, og den gamle forsiktige oppførselen gjelder for alt annet.';

revoke execute on function knowledge.monograph_need_for_evidence_set(uuid[]) from public;

-- Avgrensningen settes av databasen når evidenslenkene finnes.
--
-- En AFTER ROW-trigger på lenkene: de settes inn i én setning, og AFTER
-- ROW-triggere kjøres etter at hele setningen er skrevet, så den ser alle
-- lenkene. Den er idempotent, så den kan kjøre én gang per lenke uten å gjøre
-- noe mer enn én gang.
create function knowledge.set_claim_monograph_need()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
declare
  v_claim_id uuid;
  v_revision_number integer;
  v_current uuid;
  v_ids uuid[];
  v_need uuid;
begin
  select r.claim_id, r.revision_number into v_claim_id, v_revision_number
  from knowledge.claim_revisions r
  where r.id = new.claim_revision_id;

  if v_claim_id is null then
    return null;
  end if;

  -- Bare den første revisjonen kan sette avgrensningen.
  --
  -- Avgrensningen er en del av påstandens *identitet*, og en identitet
  -- etableres når påstanden etableres. Uten denne grensen kunne en eksisterende
  -- artikkelbasert påstand — som har stått uavgrenset siden den ble laget —
  -- blitt permanent omklassifisert til ett monografibehov den dagen en senere
  -- revisjon tilfeldigvis bare lenket monografievidens. Da ville et spørsmål
  -- ingen stilte, fått et svar ingen skrev for det.
  if v_revision_number <> 1 then
    return null;
  end if;

  select c.monograph_need_id into v_current
  from knowledge.claims c where c.id = v_claim_id;

  if v_current is not null then
    return null;
  end if;

  select array_agg(distinct l.evidence_item_id) into v_ids
  from knowledge.claim_evidence_links l
  where l.claim_revision_id = new.claim_revision_id;

  v_need := knowledge.monograph_need_for_evidence_set(v_ids);
  if v_need is null then
    return null;
  end if;

  update knowledge.claims set monograph_need_id = v_need where id = v_claim_id;
  return null;
end;
$$;

comment on function knowledge.set_claim_monograph_need() is
  'Setter kunnskapsbehovet påstanden svarer på, utledet av evidenslenkene. Ligger på lenkene og ikke på påstanden fordi lenkene finnes først: påstanden opprettes før grunnlaget er knyttet til den. Bare fra påstandens *første* revisjon: avgrensningen er en del av identiteten, og en eksisterende uavgrenset påstand skal ikke kunne omklassifiseres av en senere revisjon. Idempotent, og gjør ingenting når settet er blandet eller ikke monografidrevet — da er påstanden ikke monografiavgrenset, og den artikkelbaserte oppførselen gjelder presis som før.';

revoke execute on function knowledge.set_claim_monograph_need() from public;

create trigger claim_evidence_links_set_monograph_need
  after insert on knowledge.claim_evidence_links
  for each row execute function knowledge.set_claim_monograph_need();

-- ----------------------------------------------------------------------------
-- 5. Ett navn på det faglige subjektet en synteseoppgave gjelder
--
-- Subjektet har to lesere som må være enige: låsen i kjeden, og oppslaget som
-- spør om det allerede står en oppgave på det samme subjektet. Var de uenige,
-- ville låsen ikke beskyttet det oppslaget beskytter, og to samtidige
-- kontroller kunne lagt inn hver sin oppgave om det samme.
--
-- Uten et kunnskapsbehov er navnet nøyaktig det det var før. Det er med vilje:
-- de oppgavene som alt står i køen, skal ikke skifte subjekt under føttene.
-- ----------------------------------------------------------------------------

create function workflow.claim_synthesis_subject(
  p_subject_drug text,
  p_topic_concept text,
  p_monograph_need text)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  select format('%s+%s%s',
    coalesce(p_subject_drug, '?'),
    coalesce(p_topic_concept, '?'),
    case when p_monograph_need is null then '' else '+' || p_monograph_need end);
$$;

comment on function workflow.claim_synthesis_subject(text, text, text) is
  'Navnet på det faglige subjektet en synteseoppgave gjelder: virkestoff, tema og — når påstanden er monografiavgrenset — kunnskapsbehovet. Finnes som én funksjon fordi låsen i kjeden og oppslaget «står det allerede en oppgave på dette subjektet» må være enige; var de uenige, ville låsen ikke beskyttet det oppslaget beskytter. Uten et kunnskapsbehov er navnet ordrett det samme som før, slik at oppgaver som alt står i køen, ikke skifter subjekt.';

revoke execute on function workflow.claim_synthesis_subject(text, text, text) from public;

-- ----------------------------------------------------------------------------
-- 6. Avgrensningen, lesbar
--
-- To revisjonsoppgaver for det samme virkestoffet og det samme temaet ville
-- sett identiske ut for et menneske uten dette. Da ville flaten bedt om to
-- avgjørelser uten å si hva som skilte dem (ANTIDEP_CONSTITUTION.md regel 4).
-- ----------------------------------------------------------------------------

create function knowledge.monograph_need_scope_label(p_need_id uuid)
  returns text
  language sql
  stable
  set search_path = ''
as $$
  select nullif(array_to_string(array_remove(array[
    (select 'indikasjon: ' || c.canonical_label from catalog.clinical_concepts c
      where c.id = n.indication_concept_id),
    (select 'utfall: ' || c.canonical_label from catalog.clinical_concepts c
      where c.id = n.outcome_concept_id),
    (select 'populasjon: ' || p.canonical_label from catalog.populations p
      where p.id = n.population_id),
    (select 'komparator: ' || d.canonical_name from catalog.drugs d
      where d.id = n.comparator_drug_id),
    (select 'bytte til: ' || d.canonical_name from catalog.drugs d
      where d.id = n.switch_target_drug_id),
    (select string_agg(k.key || ': ' || (k.value #>> '{}'), ' · ' order by k.key)
     from jsonb_each(n.scope_labels) as k(key, value))
  ], null), ' · '), '')
  from knowledge.monograph_needs n
  where n.id = p_need_id;
$$;

comment on function knowledge.monograph_need_scope_label(uuid) is
  'Behovets avgrensning som én lesbar setning, eller NULL når behovet ikke er avgrenset på noen akse. Finnes for flatene: to oppgaver for det samme virkestoffet og det samme temaet, men med forskjellig indikasjon eller utfall, ville ellers sett identiske ut, og et menneske ville blitt bedt om to avgjørelser uten å få vite hva som skilte dem (MONOGRAPH_STANDARD.md §2).';

revoke execute on function knowledge.monograph_need_scope_label(uuid) from public;

-- ----------------------------------------------------------------------------
-- 7. Grunnlaget, avgrenset til behovet
--
-- Den gamle formen beholdes med nøyaktig sin gamle betydning: uten et
-- kunnskapsbehov er avgrensningen paret, og den artikkelbaserte flyten
-- oppfører seg presis som før.
-- ----------------------------------------------------------------------------

create function workflow.claim_subject_evidence(
  p_subject_drug_id uuid,
  p_topic_concept_id uuid,
  p_monograph_need_id uuid)
  returns uuid[]
  language sql
  stable
  set search_path = ''
as $$
  select coalesce(array_agg(e.id order by e.id), array[]::uuid[])
  from knowledge.evidence_items e
  where e.intervention_drug_id = p_subject_drug_id
    and e.outcome_concept_id = p_topic_concept_id
    and (p_monograph_need_id is null
         or knowledge.monograph_need_for_evidence_item(e.id) = p_monograph_need_id)
    and workflow.evidence_usable_problem(array[e.id], 'x') is null;
$$;

comment on function workflow.claim_subject_evidence(uuid, uuid, uuid) is
  'Alle brukbare evidensfunn om ett virkestoff og ett tema, avgrenset til ett kunnskapsbehov. Uten et behov er avgrensningen paret — nøyaktig som før monografien fantes — fordi en påstand uten monografiavgrensning gjelder hele paret. Med et behov er grunnlaget bare de funnene som faktisk svarer på det spørsmålet: en syntese av effekten ved én indikasjon skal ikke bygges av funn fra en annen (MONOGRAPH_STANDARD.md §2).';

revoke execute on function workflow.claim_subject_evidence(uuid, uuid, uuid) from public;

create or replace function workflow.claim_subject_evidence(
  p_subject_drug_id uuid,
  p_topic_concept_id uuid)
  returns uuid[]
  language sql
  stable
  set search_path = ''
as $$
  select workflow.claim_subject_evidence(
    p_subject_drug_id, p_topic_concept_id, null::uuid);
$$;

create function workflow.claim_awaiting_revision(
  p_subject_drug_id uuid,
  p_topic_concept_id uuid,
  p_monograph_need_id uuid)
  returns uuid
  language sql
  stable
  set search_path = ''
as $$
  select c.id
  from knowledge.claims c
  where c.subject_drug_id = p_subject_drug_id
    and c.topic_concept_id = p_topic_concept_id
    and c.monograph_need_id is not distinct from p_monograph_need_id
    and c.knowledge_type = 'evidence_synthesis'
    and c.retired_at is null
  order by c.created_at, c.id
  limit 1;
$$;

comment on function workflow.claim_awaiting_revision(uuid, uuid, uuid) is
  'Påstanden ny evidens om dette virkestoffet, temaet og kunnskapsbehovet ville endret, eller NULL. Avgrensningen er med fordi en påstand om effekten ved én indikasjon ikke er den påstanden ny evidens om en annen indikasjon utfordrer — og fordi en eksisterende påstand for det samme paret ellers ville stanset syntesen av et annet spørsmål helt (MONOGRAPH_STANDARD.md §2).';

revoke execute on function workflow.claim_awaiting_revision(uuid, uuid, uuid) from public;

create or replace function workflow.claim_awaiting_revision(
  p_subject_drug_id uuid,
  p_topic_concept_id uuid)
  returns uuid
  language sql
  stable
  set search_path = ''
as $$
  select workflow.claim_awaiting_revision(
    p_subject_drug_id, p_topic_concept_id, null::uuid);
$$;

-- Og den nye evidensen en påstand ikke hviler på, lest med påstandens egen
-- avgrensning. Uten den ville en monografiavgrenset påstand fått «ny evidens»
-- om et annet spørsmål, og et menneske ville blitt bedt om å revidere den i
-- lys av funn den aldri handlet om.
create or replace function workflow.claim_revision_new_evidence(p_claim_id uuid)
  returns uuid[]
  language sql
  stable
  set search_path = ''
as $$
  select coalesce(array_agg(wanted.id order by wanted.id), array[]::uuid[])
  from knowledge.claims c
  cross join lateral unnest(
    workflow.claim_subject_evidence(
      c.subject_drug_id, c.topic_concept_id, c.monograph_need_id)) as wanted(id)
  where c.id = p_claim_id
    and not exists (
      select 1
      from knowledge.claim_evidence_links l
      join knowledge.claim_revisions r on r.id = l.claim_revision_id
      where r.claim_id = c.id and l.evidence_item_id = wanted.id
    );
$$;

-- Og hele spørsmålet, kort, slik en agentoppgave kan bære det.
create function knowledge.monograph_need_brief(p_need_id uuid)
  returns jsonb
  language sql
  stable
  set search_path = ''
as $$
  select jsonb_build_object(
    'need_reference', n.reference,
    'template_code', t.code,
    'question', t.prompt,
    'answer_form', n.answer_form::text,
    'requirement', t.requirement::text,
    'scope', knowledge.monograph_need_scope_label(n.id),
    'scope_not_applicable', to_jsonb(n.scope_not_applicable::text[]),
    'standard_version', e.standard_version)
  from knowledge.monograph_needs n
  join knowledge.monograph_question_templates t on t.id = n.template_id
  join knowledge.monograph_editions e on e.id = n.edition_id
  where n.id = p_need_id;
$$;

comment on function knowledge.monograph_need_brief(uuid) is
  'Spørsmålet ett kunnskapsbehov stiller, ordrett fra standarden, med malens identitet, svarformen, avgrensningen og standardversjonen. NULL for NULL. Finnes fordi en agentoppgave som bare bar grunnlaget, ville gitt agenten evidens uten å si hvilket spørsmål evidensen er grunnlag for (MONOGRAPH_STANDARD.md §2). Bærer ikke et forventet svar.';

revoke execute on function knowledge.monograph_need_brief(uuid) from public;

-- ----------------------------------------------------------------------------
-- 8. Begge avgrensningene et funn hører til
--
-- Et funn hører til paret — den artikkelbaserte påstanden om virkestoffet og
-- endepunktet — og til kunnskapsbehovet det svarer på. Begge påstandene kan
-- finnes, og begge skal få vite at det er kommet ny evidens.
--
-- Rekkefølgen er med vilje: den uavgrensede først, den monografiavgrensede
-- etterpå. Alle veier som tar begge subjektlåsene, tar dem i den rekkefølgen,
-- og da kan ikke to samtidige kall vente på hverandre.
-- ----------------------------------------------------------------------------

create or replace function workflow.sync_claim_revision_for_evidence(p_evidence_item_id uuid)
  returns void
  language plpgsql
  set search_path = ''
as $$
declare
  v_item knowledge.evidence_items;
  v_need_id uuid;
begin
  select e.* into v_item
  from knowledge.evidence_items e
  where e.id = p_evidence_item_id;

  if not found then
    return;
  end if;

  perform workflow.notice_claim_revision_need(
    v_item.intervention_drug_id, v_item.outcome_concept_id, null::uuid);

  v_need_id := knowledge.monograph_need_for_evidence_item(p_evidence_item_id);
  if v_need_id is not null then
    perform workflow.notice_claim_revision_need(
      v_item.intervention_drug_id, v_item.outcome_concept_id, v_need_id);
  end if;
end;
$$;

-- ----------------------------------------------------------------------------
-- 9. Porten som stanset monografien
--
-- Den gamle regelen var: finnes det allerede en påstand for det samme temaet og
-- virkestoffet, er videre syntese en redaksjonell avgjørelse. Det er riktig for
-- den artikkelbaserte flyten — en påstand skal ikke skrives om av automatikken
-- — og feil for en monografi, fordi effekten ved én indikasjon og effekten ved
-- en annen aldri var den samme påstanden. Porten spør nå på avgrensningen.
--
-- Og når funnet også hører til en uavgrenset påstand om det samme paret, får
-- *den* sin revisjonsoppgave likevel. Monografien går videre, og den
-- artikkelbaserte påstanden blir ikke stille stående med et grunnlag som er
-- blitt et annet (ANTIDEP_CONSTITUTION.md regel 4).
-- ----------------------------------------------------------------------------

create or replace function workflow.chain_task_for_verified_extraction(p_evidence_item_id uuid)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_item knowledge.evidence_items;
  v_verification workflow.evidence_verifications;
  v_origin record;
  v_manifest jsonb;
  v_subject text;
  v_need_id uuid;
begin
  select e.* into v_item
  from knowledge.evidence_items e
  where e.id = p_evidence_item_id;

  if not found then
    return null;
  end if;

  -- Den gjeldende kontrollen er den siste. Et senere avvik opphever en tidligere
  -- bekreftelse, og da er porten ikke bestått (ANTIDEP_CONSTITUTION.md regel 4).
  select ev.* into v_verification
  from workflow.evidence_verifications ev
  where ev.evidence_item_id = p_evidence_item_id
  order by ev.registration_ordinal desc
  limit 1;

  if not found or v_verification.outcome <> 'verified' then
    return null;
  end if;

  v_need_id := knowledge.monograph_need_for_evidence_item(p_evidence_item_id);

  -- Den uavgrensede påstanden om paret, når funnet også hører til den. Kallet
  -- står før den avgrensede porten nedenfor, slik at låsene alltid tas i samme
  -- rekkefølge.
  if v_need_id is not null then
    perform workflow.notice_claim_revision_need(
      v_item.intervention_drug_id, v_item.outcome_concept_id, null::uuid);
  end if;

  -- En påstand som allerede finnes for den samme avgrensningen, er ikke
  -- automatikkens å skrive om. Å revidere den i lys av ny evidens er en
  -- redaksjonell avgjørelse om hva påstanden skal si — og den avgjørelsen skal
  -- være synlig og mulig å ta, framfor å være et stille stopp (migrasjon 012d).
  if exists (
    select 1
    from knowledge.claims c
    where c.topic_concept_id = v_item.outcome_concept_id
      and c.subject_drug_id = v_item.intervention_drug_id
      and c.monograph_need_id is not distinct from v_need_id
  ) then
    perform workflow.notice_claim_revision_need(
      v_item.intervention_drug_id, v_item.outcome_concept_id, v_need_id);
    return null;
  end if;

  -- Låsen først, og deretter spørsmålet. Uten den rekkefølgen kan to samtidige
  -- kontroller av forskjellige funn på det samme subjektet begge lese «ingen
  -- oppgave» og legge inn hver sin, fordi evidenssettet — og dermed nøkkelen —
  -- blir forskjellig.
  v_subject := workflow.claim_synthesis_subject(
    v_item.intervention_drug_id::text, v_item.outcome_concept_id::text,
    v_need_id::text);
  perform workflow.lock_chain_subject('claim_synthesis'::provenance.agent_role, v_subject);

  if workflow.agent_task_subject_queued('claim_synthesis'::provenance.agent_role, v_subject) then
    return null;
  end if;

  -- Hele grunnlaget som er brukbart nå for nettopp denne avgrensningen, og ikke
  -- bare funnet som utløste overgangen: en syntese som utelot et funn som
  -- motsier påstanden, ville hvilt på et annet grunnlag enn det som finnes
  -- (ANTIDEP_CONSTITUTION.md regel 4). Settet leses én gang, og jobben lages
  -- bare én gang, så manifestet er stabilt.
  v_manifest := workflow.claim_synthesis_manifest(
    v_item.intervention_drug_id, v_item.outcome_concept_id, null, v_need_id);

  if v_manifest is null then
    return null;
  end if;

  v_origin := workflow.chain_origin(
    v_verification.agent_run_id, v_verification.verifier_actor_id);

  return workflow.chain_enqueue_job(
    'claim_synthesis'::provenance.agent_role,
    workflow.agent_task_job_key('claim_synthesis'::provenance.agent_role, v_manifest),
    v_manifest,
    v_origin.actor_id,
    v_origin.agent_identity_id,
    true,
    'Synteseoppgaven lagt i køen av den beståtte ekstraksjonskontrollen.');
end;
$$;

-- Og subjektnavnet oppgaveflaten leser, fra det samme stedet.
create or replace function workflow.agent_task_manifest_subject(
  p_agent_role provenance.agent_role,
  p_input_manifest jsonb)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  select case p_agent_role
    when 'evidence_extraction' then coalesce(p_input_manifest ->> 'source_version_id', '?')
    when 'claim_synthesis' then workflow.claim_synthesis_subject(
      p_input_manifest ->> 'subject_drug_id',
      p_input_manifest ->> 'topic_concept_id',
      p_input_manifest ->> 'monograph_need_id')
    when 'source_discovery' then coalesce(p_input_manifest ->> 'search_plan_id', '?')
    when 'source_quality_assessment' then coalesce(p_input_manifest ->> 'search_plan_id', '?')
    else coalesce(p_input_manifest ->> 'claim_revision_id', '?')
  end;
$$;
CREATE OR REPLACE FUNCTION workflow.claim_synthesis_manifest(p_subject_drug_id uuid, p_topic_concept_id uuid, p_claim_id uuid, p_monograph_need_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_evidence_ids uuid[];
  v_population_ids uuid[];
  v_manifest jsonb;
begin
  v_evidence_ids := workflow.claim_subject_evidence(
    p_subject_drug_id, p_topic_concept_id, p_monograph_need_id);
  if v_evidence_ids is null or cardinality(v_evidence_ids) = 0 then
    return null;
  end if;

  select array_agg(distinct e.population_id) filter (where e.population_id is not null)
    into v_population_ids
  from knowledge.evidence_items e
  where e.id = any (v_evidence_ids);

  v_manifest := jsonb_build_object(
    'topic_concept_id', p_topic_concept_id,
    'subject_drug_id', p_subject_drug_id,
    'evidence_item_ids', to_jsonb(v_evidence_ids));

  if p_claim_id is not null then
    v_manifest := v_manifest || jsonb_build_object('claim_id', p_claim_id);
  end if;

  if v_population_ids is not null and cardinality(v_population_ids) > 0 then
    v_manifest := v_manifest || jsonb_build_object(
      'population_ids', to_jsonb(workflow.sorted_unique(v_population_ids)));
  end if;

  -- Avgrensningen står i manifestet, og derfor i avtrykket oppgavenøkkelen
  -- regnes av: to behov om det samme paret er to oppgaver, og ikke én
  -- oppgave som overskriver den andre.
  if p_monograph_need_id is not null then
    v_manifest := v_manifest || jsonb_build_object(
      'monograph_need_id', p_monograph_need_id);
  end if;

  return v_manifest;
end;
$function$;


comment on function workflow.claim_synthesis_manifest(uuid, uuid, uuid, uuid) is
  'Manifestet en synteseoppgave bygges av: virkestoffet, temaet, hele det brukbare evidensgrunnlaget for avgrensningen og — når påstanden er monografiavgrenset — kunnskapsbehovet. Behovet står i manifestet fordi oppgavenøkkelen regnes av manifestets avtrykk: to behov om det samme paret skal bli to oppgaver, ikke én som overskriver den andre.';

revoke execute on function workflow.claim_synthesis_manifest(uuid, uuid, uuid, uuid) from public;

create or replace function workflow.claim_synthesis_manifest(
  p_subject_drug_id uuid,
  p_topic_concept_id uuid,
  p_claim_id uuid)
  returns jsonb
  language sql
  stable
  set search_path = ''
as $$
  select workflow.claim_synthesis_manifest(
    p_subject_drug_id, p_topic_concept_id, p_claim_id, null::uuid);
$$;

CREATE OR REPLACE FUNCTION workflow.notice_claim_revision_need(p_subject_drug_id uuid, p_topic_concept_id uuid, p_monograph_need_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_claim_id uuid;
  v_review workflow.claim_revision_reviews;
  v_new_ids uuid[];
  v_count integer;
  v_digest text;
  v_job_state workflow.pipeline_job_state;
  v_decision workflow.claim_revision_review_events;
begin
  v_claim_id := workflow.claim_awaiting_revision(
    p_subject_drug_id, p_topic_concept_id, p_monograph_need_id);
  if v_claim_id is null then
    return null;
  end if;

  perform workflow.lock_chain_subject(
    'claim_synthesis'::provenance.agent_role,
    workflow.claim_synthesis_subject(
      p_subject_drug_id::text, p_topic_concept_id::text,
      p_monograph_need_id::text));

  -- Og en radlås på påstanden selv. Den serialiserer mot den eksplisitte
  -- redaksjonelle fjerningen av påstanden
  -- (knowledge.discard_unpublished_claim_artifacts(uuid[], text)), som låser
  -- den samme raden: uten den kunne en oppgave bli opprettet i vinduet mellom
  -- fjerningens lesning og dens sletting, og fjerningen ville endt på en
  -- fremmednøkkel framfor på en setning. Er påstanden borte når låsen gis,
  -- finnes det ingen revisjon å be om.
  perform 1 from knowledge.claims c where c.id = v_claim_id for update;
  if not found then
    return null;
  end if;

  -- Grunnlaget leses *før* raden vurderes, og ikke bare når det finnes noe nytt:
  -- en oppgave som står åpen mens den siste nye evidensen faller bort, skal
  -- lukkes, ikke bli stående som planlagt arbeid ingen kan fullføre.
  v_new_ids := workflow.claim_revision_new_evidence(v_claim_id);
  v_count := cardinality(coalesce(v_new_ids, array[]::uuid[]));
  v_digest := workflow.evidence_set_digest(
    workflow.claim_subject_evidence(
      p_subject_drug_id, p_topic_concept_id, p_monograph_need_id));

  select r.* into v_review
  from workflow.claim_revision_reviews r
  where r.claim_id = v_claim_id
  for update;

  if not found then
    if v_count = 0 then
      return null;
    end if;

    insert into workflow.claim_revision_reviews
      (claim_id, pending_evidence_digest, pending_evidence_count)
    values (v_claim_id, v_digest, v_count)
    returning * into v_review;

    perform workflow.record_claim_revision_review_event(
      v_review.id, 'opened'::workflow.claim_revision_review_transition,
      v_digest, v_count, null, null);
    return v_review.id;
  end if;

  -- ------------------------------------------------------------------------
  -- Det er ikke lenger noe å ta stilling til
  --
  -- Et funn kan bli trukket tilbake, få et åpent avvik eller bli kastet etter at
  -- oppgaven ble åpnet. Da er den nye kunnskapen borte, og en oppgave om den er
  -- en menneskeoppgave uten et utfall: beslutningsveien ville uansett avvist
  -- den. Tilstanden sier det eksplisitt framfor at raden blir stående åpen
  -- (ANTIDEP_CONSTITUTION.md regel 4).
  --
  -- Bare en åpen oppgave lukkes slik. En avgjort oppgave er allerede avgjort, og
  -- et grunnlag som senere krymper, opphever ikke det et menneske bestemte.
  -- ------------------------------------------------------------------------
  if v_count = 0 then
    if v_review.state = 'open'::workflow.claim_revision_review_state then
      update workflow.claim_revision_reviews r
      set state = 'lapsed'::workflow.claim_revision_review_state,
          pending_evidence_digest = v_digest,
          pending_evidence_count = 0
      where r.id = v_review.id;

      perform workflow.record_claim_revision_review_event(
        v_review.id, 'lapsed'::workflow.claim_revision_review_transition,
        v_digest, 0, null, null);
    end if;
    return null;
  end if;

  if v_review.state = 'open'::workflow.claim_revision_review_state then
    -- ----------------------------------------------------------------------
    -- Grunnlaget kan ha gått tilbake til noe som allerede er avgjort
    --
    -- En konklusjon om at den nye forskningen ikke endrer påstanden, gjelder
    -- nøyaktig det grunnlaget den gjaldt. Kommer det så et funn til, er
    -- grunnlaget et annet, og oppgaven åpner seg igjen — men faller *det*
    -- funnet siden bort, er grunnlaget igjen nøyaktig det redaktøren allerede
    -- konkluderte på. Å be om den samme avgjørelsen om det samme en gang til
    -- ville vært menneskearbeid Antidep selv hadde funnet på
    -- (ANTIDEP_CONSTITUTION.md regel 4), og det ville dessuten motsagt det
    -- avgjørelsen er bundet til.
    --
    -- Konklusjonen hentes fra sporet, som er append-only og derfor er det ene
    -- stedet som fortsatt vet hva som ble bestemt på hvilket grunnlag: raden
    -- selv ble nullstilt da oppgaven åpnet seg. Bare `set_aside` gjenopprettes.
    -- En besluttet revisjon som faktisk ble bygget, lenker funnene sine, og da
    -- kan grunnlaget ikke gå tilbake til det samme; en som ikke ble bygget,
    -- ville gjenopprettet en revisjon som ikke finnes.
    -- ----------------------------------------------------------------------
    if v_review.pending_evidence_digest is distinct from v_digest then
      select e.* into v_decision
      from workflow.claim_revision_review_events e
      where e.claim_revision_review_id = v_review.id
        and e.transition = 'set_aside'::workflow.claim_revision_review_transition
        and e.evidence_digest = v_digest
      order by e.occurred_at desc, e.created_at desc
      limit 1;

      if found then
        update workflow.claim_revision_reviews r
        set state = 'set_aside'::workflow.claim_revision_review_state,
            pending_evidence_digest = v_digest,
            pending_evidence_count = v_count,
            decided_evidence_digest = v_digest,
            decided_at = v_decision.occurred_at,
            decided_by_actor_id = v_decision.actor_id,
            decision_note = v_decision.note,
            pipeline_job_id = null
        where r.id = v_review.id;

        perform workflow.record_claim_revision_review_event(
          v_review.id, 'restored'::workflow.claim_revision_review_transition,
          v_digest, v_count, null, null);
        return null;
      end if;

      -- Grunnlaget har endret seg på en oppgave som alt står åpen. Fortsatt én
      -- avgjørelse å ta, og derfor fortsatt én rad. Svaret er NULL, fordi ingen
      -- oppgave ble åpnet — den sto åpen fra før.
      update workflow.claim_revision_reviews r
      set pending_evidence_digest = v_digest,
          pending_evidence_count = v_count
      where r.id = v_review.id;

      perform workflow.record_claim_revision_review_event(
        v_review.id,
        case when v_count >= v_review.pending_evidence_count
             then 'widened'::workflow.claim_revision_review_transition
             else 'narrowed'::workflow.claim_revision_review_transition end,
        v_digest, v_count, null, null);
    end if;
    return null;
  end if;

  -- En oppgave som falt bort, åpnes igjen så snart det finnes ny evidens igjen.
  -- Ingen tok stilling til noe forrige gang, så det er ingen avgjørelse å veie
  -- det nye grunnlaget mot.
  if v_review.state = 'lapsed'::workflow.claim_revision_review_state then
    update workflow.claim_revision_reviews r
    set state = 'open'::workflow.claim_revision_review_state,
        pending_evidence_digest = v_digest,
        pending_evidence_count = v_count,
        opened_at = now()
    where r.id = v_review.id;

    perform workflow.record_claim_revision_review_event(
      v_review.id, 'reopened'::workflow.claim_revision_review_transition,
      v_digest, v_count, null, null);
    return v_review.id;
  end if;

  -- Avgjort. En avgjørelse gjelder det grunnlaget den gjaldt, og oppgaven
  -- åpner seg bare når grunnlaget er blitt et annet.
  if v_review.decided_evidence_digest is not distinct from v_digest then
    return null;
  end if;

  -- Og for en besluttet revisjon: bare når revisjonen faktisk ble bygget. En
  -- synteseoppgave som stoppet teknisk, er et teknisk problem og stoppet
  -- arbeid i den åpne oversikten — ikke en grunn til å be et menneske om den
  -- samme avgjørelsen en gang til (ANTIDEP_CONSTITUTION.md regel 4).
  if v_review.state = 'revision_ordered'::workflow.claim_revision_review_state then
    select j.state into v_job_state
    from workflow.pipeline_jobs j
    where j.id = v_review.pipeline_job_id;

    if v_job_state is distinct from 'succeeded'::workflow.pipeline_job_state then
      return null;
    end if;
  end if;

  update workflow.claim_revision_reviews r
  set state = 'open'::workflow.claim_revision_review_state,
      pending_evidence_digest = v_digest,
      pending_evidence_count = v_count,
      decided_evidence_digest = null,
      decided_at = null,
      decided_by_actor_id = null,
      decision_note = null,
      pipeline_job_id = null,
      opened_at = now()
  where r.id = v_review.id;

  perform workflow.record_claim_revision_review_event(
    v_review.id, 'reopened'::workflow.claim_revision_review_transition,
    v_digest, v_count, null, null);
  return v_review.id;
end;
$function$;


comment on function workflow.notice_claim_revision_need(uuid, uuid, uuid) is
  'Holder den redaksjonelle revisjonsoppgaven i takt med grunnlaget for ett virkestoff, ett tema og én monografiavgrensning. Avgrensningen er med fordi en påstand om effekten ved én indikasjon ikke er den påstanden ny evidens om en annen utfordrer; uten et kunnskapsbehov er avgrensningen paret, og oppførselen er ordrett den fra migrasjon 012d.';

revoke execute on function workflow.notice_claim_revision_need(uuid, uuid, uuid) from public;

create or replace function workflow.notice_claim_revision_need(
  p_subject_drug_id uuid,
  p_topic_concept_id uuid)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
begin
  return workflow.notice_claim_revision_need(
    p_subject_drug_id, p_topic_concept_id, null::uuid);
end;
$$;

CREATE OR REPLACE FUNCTION workflow.claim_revision_task(p_review workflow.claim_revision_reviews, p_with_evidence boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_claim knowledge.claims;
  v_revision knowledge.claim_revisions;
  v_new_ids uuid[];
  v_task jsonb;
begin
  select c.* into v_claim from knowledge.claims c where c.id = p_review.claim_id;
  if not found then
    return null;
  end if;

  -- ------------------------------------------------------------------------
  -- «Det Antidep sier i dag» er det publiserte, når det finnes noe publisert
  --
  -- Den siste revisjonen er ikke nødvendigvis den som er i bruk: en revisjon
  -- kan være bygget og ligge til sluttkontroll uten å være publisert, og en
  -- flate som viste den under «det Antidep sier i dag» ville sagt at et utkast
  -- er det klinikeren får se. Det er klinisk feil (ANTIDEP_CONSTITUTION.md
  -- regel 5, 6). Er ingenting publisert, er den siste bygde revisjonen det
  -- nærmeste som finnes, og flaten sier da at den ikke er publisert.
  -- ------------------------------------------------------------------------
  select r.* into v_revision
  from knowledge.claim_revisions r
  where r.id = v_claim.current_published_revision_id;

  if not found then
    select r.* into v_revision
    from knowledge.claim_revisions r
    where r.claim_id = v_claim.id
    order by r.revision_number desc
    limit 1;

    if not found then
      return null;
    end if;
  end if;

  v_new_ids := workflow.claim_revision_new_evidence(v_claim.id);

  v_task := jsonb_build_object(
    'reference', p_review.reference,
    'subject_drug', (select d.canonical_name from catalog.drugs d where d.id = v_claim.subject_drug_id),
    'topic', (select c.canonical_label from catalog.clinical_concepts c
              where c.id = v_claim.topic_concept_id),
    'statement', v_revision.statement,
    'scope', v_revision.scope,
    'uncertainty_summary', v_revision.uncertainty_summary,
    'revision_number', v_revision.revision_number,
    'published', v_claim.current_published_revision_id is not null,
    -- En nyere formulering som er bygget, men ikke publisert. Redaktøren skal
    -- vite at den finnes: den er neste ledd i den samme historien, og en
    -- revisjon besluttet uten den kunnskapen ville vært tatt på et ufullstendig
    -- bilde.
    'newer_unpublished_revision', exists (
      select 1 from knowledge.claim_revisions r
      where r.claim_id = v_claim.id and r.revision_number > v_revision.revision_number),
    'certainty_level', (
      select a.certainty_level::text
      from knowledge.evidence_assessments a
      where a.claim_revision_id = v_revision.id
      order by a.created_at desc
      limit 1),
    'existing_evidence_count', (
      select count(distinct l.evidence_item_id)::integer
      from knowledge.claim_evidence_links l
      where l.claim_revision_id = v_revision.id),
    -- To tall, fordi de betyr to forskjellige ting: én artikkel kan bære flere
    -- funn, og «to nye artikler» og «to nye funn» er ikke det samme. Ett tall
    -- som het begge deler, ville fått flaten til å si at den samme studien var
    -- to studier.
    'new_article_count', (
      select count(distinct e.source_id)::integer
      from knowledge.evidence_items e where e.id = any (v_new_ids)),
    'new_finding_count', cardinality(v_new_ids),
    'noticed_at', p_review.opened_at,
    -- Hvilket spørsmål påstanden svarer på, når den er monografiavgrenset.
    -- To oppgaver for det samme virkestoffet og temaet ville ellers sett
    -- identiske ut, og mennesket ville tatt to avgjørelser uten å få vite
    -- hva som skilte dem (ANTIDEP_CONSTITUTION.md regel 4).
    'monograph_scope', knowledge.monograph_need_scope_label(v_claim.monograph_need_id),
    -- Avtrykket flaten sender uendret tilbake. Regnes av hele det brukbare
    -- grunnlaget her og nå, og ikke av den lagrede verdien: den som åpner
    -- siden, skal ta stilling til det som faktisk finnes.
    'evidence_basis', workflow.evidence_set_digest(
      workflow.claim_subject_evidence(
        v_claim.subject_drug_id, v_claim.topic_concept_id, v_claim.monograph_need_id)));

  if not p_with_evidence then
    return v_task;
  end if;

  -- Gruppert per artikkel, fordi det er artikler en redaktør leser. Et
  -- evidensfunn er ett konkret funn, og flere funn kan komme fra den samme
  -- studien; en liste som viste funn som om de var artikler, ville vist den
  -- samme studien flere ganger og latt den telle flere ganger i vurderingen.
  return v_task || jsonb_build_object('new_evidence', coalesce((
    select jsonb_agg(g.article order by g.title, g.authors)
    from (
      select
        s.title,
        s.authors_or_issuer as authors,
        jsonb_build_object(
          'article_title', s.title,
          'article_authors', s.authors_or_issuer,
          'published_year', case when s.publication_date is null then null
                                 else extract(year from s.publication_date)::integer end,
          'findings', jsonb_agg(
            jsonb_build_object(
              'study_design', e.design_code::text,
              'population', (select p.canonical_label from catalog.populations p
                             where p.id = e.population_id),
              'population_detail', e.population_detail,
              'participants', e.sample_size,
              'finding', e.outcome_detail,
              'direction', e.reported_direction::text,
              'effect_measure', e.effect_measure::text,
              'estimate', e.estimate,
              'estimate_unit', e.estimate_unit::text,
              'ci_lower', e.ci_lower,
              'ci_upper', e.ci_upper,
              'ci_level_percent', e.ci_level_percent,
              'limitations', e.limitations_text)
            order by e.id::text)
        ) as article
      from knowledge.evidence_items e
      join knowledge.sources s on s.id = e.source_id
      where e.id = any (v_new_ids)
      group by s.id, s.title, s.authors_or_issuer, s.publication_date
    ) g), '[]'::jsonb));
end;
$function$;

CREATE OR REPLACE FUNCTION api.record_claim_revision_decision(p_reference text, p_decision text, p_seen_evidence_basis text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_review workflow.claim_revision_reviews;
  v_claim knowledge.claims;
  v_actor_id uuid;
  v_subject text;
  v_new_ids uuid[];
  v_digest text;
  v_manifest jsonb;
  v_job_key text;
  v_job workflow.pipeline_jobs;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if p_decision is null or p_decision not in ('revise', 'set_aside') then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Avgjørelsen må være enten revise eller set_aside.',
      hint = 'Enten skal påstanden revideres med det oppdaterte evidensgrunnlaget, eller så er konklusjonen at den nye evidensen ikke endrer den. Et tredje utfall ville vært en utsettelse uten en tilstand.';
  end if;

  perform knowledge.assert_editor_authorized();

  select r.* into v_review
  from workflow.claim_revision_reviews r
  where r.reference = p_reference;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Det finnes ingen revisjonsvurdering med denne referansen.',
      hint = 'Hent listen på nytt.';
  end if;

  select c.* into v_claim from knowledge.claims c where c.id = v_review.claim_id;

  -- Mandatet leses mot endepunktet påstanden hører under. En avgrenset
  -- editor-tildeling gjelder det området den ble gitt for, og å avgjøre hva en
  -- påstand skal si, er like mye et faglig inngrep i det området som å
  -- registrere et evidensfunn i det.
  v_actor_id := knowledge.assert_editor_authorized(v_claim.topic_concept_id);

  v_subject := format('%s+%s', v_claim.subject_drug_id, v_claim.topic_concept_id);
  perform workflow.lock_chain_subject('claim_synthesis'::provenance.agent_role, v_subject);

  select r.* into v_review
  from workflow.claim_revision_reviews r
  where r.id = v_review.id
  for update;

  -- Raden kan ha forsvunnet mens vi ventet på låsen: påstanden kan være
  -- eksplisitt fjernet i mellomtiden, og da rives oppgaven ned med den. Det er
  -- ikke en feil, men det er heller ikke noe å avgjøre.
  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Revisjonsvurderingen finnes ikke lenger slik du så den.',
      hint = 'Påstanden kan ha blitt fjernet i mellomtiden. Hent listen på nytt.';
  end if;

  if v_review.state <> 'open' then
    -- Den samme avgjørelsen på det samme grunnlaget er den samme avgjørelsen.
    -- To redaktører som trykket samtidig, har begge gjort riktig.
    if v_review.decided_evidence_digest = p_seen_evidence_basis
       and ((v_review.state = 'revision_ordered' and p_decision = 'revise')
            or (v_review.state = 'set_aside' and p_decision = 'set_aside')) then
      return jsonb_build_object(
        'reference', v_review.reference, 'decision', p_decision, 'recorded', false);
    end if;
    raise exception using
      errcode = 'restrict_violation',
      message = 'Denne revisjonsvurderingen er allerede avgjort.',
      hint = 'Hent listen på nytt. En avgjort oppgave åpner seg igjen av seg selv dersom det kommer enda mer ny evidens.';
  end if;

  v_new_ids := workflow.claim_revision_new_evidence(v_claim.id);
  if v_new_ids is null or cardinality(v_new_ids) = 0 then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Det finnes ikke lenger ny evidens som venter på en avgjørelse for denne påstanden.',
      hint = 'Funnene kan ha blitt trukket tilbake eller fått et åpent avvik. Hent listen på nytt.';
  end if;

  v_digest := workflow.evidence_set_digest(
    workflow.claim_subject_evidence(
      v_claim.subject_drug_id, v_claim.topic_concept_id, v_claim.monograph_need_id));

  if p_seen_evidence_basis is distinct from v_digest then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Evidensgrunnlaget er endret siden oppgaven ble åpnet.',
      hint = 'Beslutningen er bundet til nøyaktig det grunnlaget som ble lest (ANTIDEP_CONSTITUTION.md regel 5). Hent oppgaven på nytt, og ta stilling til det som faktisk finnes nå.';
  end if;

  if p_decision = 'set_aside' then
    if v_note is null then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'En konklusjon om at den nye evidensen ikke endrer påstanden, krever en begrunnelse.',
        hint = 'Begrunnelsen er den faglige vurderingen, og den er det eneste som skiller en konklusjon fra en utsettelse.';
    end if;

    update workflow.claim_revision_reviews r
    set state = 'set_aside'::workflow.claim_revision_review_state,
        pending_evidence_digest = v_digest,
        decided_evidence_digest = v_digest,
        decided_at = now(),
        decided_by_actor_id = v_actor_id,
        decision_note = v_note
    where r.id = v_review.id;

    perform workflow.record_claim_revision_review_event(
      v_review.id, 'set_aside'::workflow.claim_revision_review_transition,
      v_digest, cardinality(v_new_ids), v_actor_id, v_note);

    return jsonb_build_object(
      'reference', v_review.reference, 'decision', p_decision, 'recorded', true);
  end if;

  v_manifest := workflow.claim_synthesis_manifest(
    v_claim.subject_drug_id, v_claim.topic_concept_id, v_claim.id,
    v_claim.monograph_need_id);

  if v_manifest is null then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Det finnes ikke noe brukbart evidensgrunnlag å bygge revisjonen av.',
      hint = 'Hent oppgaven på nytt.';
  end if;

  v_job_key := workflow.agent_task_job_key(
    'claim_synthesis'::provenance.agent_role, v_manifest);

  -- Ett faglig subjekt, én oppgave. Er det allerede en annen synteseoppgave
  -- underveis om det samme virkestoffet og endepunktet, ville en til vært den
  -- andre automatiske revisjonen av det samme subjektet.
  if exists (
    select 1
    from workflow.pipeline_jobs j
    where j.agent_role = 'claim_synthesis'::provenance.agent_role
      and j.job_key like 'agent-handoff:' || v_subject || ':%'
      and j.job_key <> v_job_key
      and j.state in ('ready'::workflow.pipeline_job_state,
                      'leased'::workflow.pipeline_job_state)
  ) then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Antidep arbeider allerede med en påstand om dette virkestoffet og endepunktet.',
      hint = 'Vent til det arbeidet er ferdig. Den nye evidensen blir liggende, og oppgaven kommer tilbake dersom den fortsatt ikke er dekket.';
  end if;

  -- Innleggingen er kjedens egen: samme rad, samme spor, samme idempotens og
  -- den samme forhåndskontrollen av grunnlaget. Svarer den NULL, fantes jobben
  -- fra før, og oppslaget under finner den samme raden.
  perform workflow.chain_enqueue_job(
    'claim_synthesis'::provenance.agent_role,
    v_job_key,
    v_manifest,
    v_actor_id,
    null,
    true,
    'Synteseoppgaven lagt i køen av den redaksjonelle beslutningen om å revidere påstanden.');

  select j.* into v_job
  from workflow.pipeline_jobs j
  where j.agent_role = 'claim_synthesis'::provenance.agent_role and j.job_key = v_job_key;

  if not found then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Synteseoppgaven lot seg ikke legge inn.',
      hint = 'Hent oppgaven på nytt.';
  end if;

  update workflow.claim_revision_reviews r
  set state = 'revision_ordered'::workflow.claim_revision_review_state,
      pending_evidence_digest = v_digest,
      decided_evidence_digest = v_digest,
      decided_at = now(),
      decided_by_actor_id = v_actor_id,
      decision_note = v_note,
      pipeline_job_id = v_job.id
  where r.id = v_review.id;

  perform workflow.record_claim_revision_review_event(
    v_review.id, 'revision_ordered'::workflow.claim_revision_review_transition,
    v_digest, cardinality(v_new_ids), v_actor_id, v_note);

  return jsonb_build_object(
    'reference', v_review.reference, 'decision', p_decision, 'recorded', true);
end;
$function$;

CREATE OR REPLACE FUNCTION workflow.chain_after_evidence_verification()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_state text;
  v_item knowledge.evidence_items;
begin
  if new.outcome <> 'verified' then
    -- Kjeden går ikke videre, men den redaksjonelle tilstanden kan ha endret
    -- seg: falt det siste nye funnet bort, er det ikke lenger noe å avgjøre.
    begin
      select e.* into v_item
      from knowledge.evidence_items e
      where e.id = new.evidence_item_id;

      if found then
        -- Begge avgrensningene funnet hører til: paret, og kunnskapsbehovet
        -- det svarer på. Et funn som faller bort, kan ha vært den siste nye
        -- evidensen for begge.
        perform workflow.sync_claim_revision_for_evidence(new.evidence_item_id);
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('paastandsrevisjon', new.evidence_item_id, v_state);
    end;
    return null;
  end if;

  begin
    perform workflow.chain_task_for_verified_extraction(new.evidence_item_id);
  exception
    -- Grunnlaget er ikke klart. Kjeden står, og det er porten som gjør jobben
    -- sin — ikke en teknisk svikt. Nøyaktig de tre klassene
    -- workflow.evidence_usable_problem(uuid[], text) fanger, og av samme grunn.
    when restrict_violation or no_data_found or invalid_parameter_value then
      null;
    when others then
      get stacked diagnostics v_state = returned_sqlstate;
      perform workflow.chain_note_failure('syntese', new.evidence_item_id, v_state);
  end;
  return null;
end;
$function$;

CREATE OR REPLACE FUNCTION workflow.claim_revision_after_source_status()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_state text;
  v_subject record;
begin
  if new.source_status is not distinct from old.source_status then
    return null;
  end if;

  -- Ett par per gang, og ikke ett funn per gang: oppgaven er én per påstand,
  -- og en kilde kan bære flere funn om det samme paret.
  for v_subject in
    select distinct e.intervention_drug_id as drug_id,
           e.outcome_concept_id as topic_id,
           s.need_id
    from knowledge.evidence_items e
    cross join lateral (
      values (null::uuid), (knowledge.monograph_need_for_evidence_item(e.id))
    ) as s(need_id)
    where e.source_id = new.id
      and e.intervention_drug_id is not null
      and e.outcome_concept_id is not null
  loop
    begin
      perform workflow.notice_claim_revision_need(
        v_subject.drug_id, v_subject.topic_id, v_subject.need_id);
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('paastandsrevisjon', new.id, v_state);
    end;
  end loop;
  return null;
end;
$function$;

CREATE OR REPLACE FUNCTION knowledge.discard_unpublished_extraction_artifacts(p_evidence_item_ids uuid[], p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_actor_id uuid;
  v_id uuid;
  v_snapshots jsonb := '{}'::jsonb;
  v_removed jsonb := '[]'::jsonb;
  v_verifications bigint := 0;
  v_groundings bigint := 0;
  v_items bigint := 0;
  -- Virkestoffet og endepunktet hvert funn gjaldt. Leses *før* slettingen,
  -- fordi etterpå finnes det ingen rad å lese det av: en hard sletting tar
  -- også bort veien tilbake til subjektet (migrasjon 012d).
  v_subjects jsonb := '[]'::jsonb;
  v_subject jsonb;
  v_locked_keys text[];
  v_key text;
begin
  -- Fjerningen er en redaksjonell handling med en ansvarlig, ikke en
  -- driftsoperasjon: auditraden skal navngi den som bestemte den.
  v_actor_id := knowledge.assert_editor_authorized();

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Fjerningen mangler en begrunnelse, og da kan den ikke registreres.',
      hint = 'Oppgi hvorfor funnene fjernes. Begrunnelsen er det som gjør en hard sletting rapporterbar i ettertid (ANTIDEP_CONSTITUTION.md §14).';
  end if;

  if p_evidence_item_ids is null or cardinality(p_evidence_item_ids) = 0 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Ingen evidensfunn er oppgitt.',
      hint = 'Veien tar en eksplisitt liste med id-er. Den kan ikke kalles med et predikat, og den kan ikke feie: hvilke rader som fjernes, skal være skrevet ned før kallet, ikke utledet av det.';
  end if;

  if cardinality(p_evidence_item_ids) > 50 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('%s evidensfunn er oppgitt, og grensen er 50.', cardinality(p_evidence_item_ids)),
      hint = 'En reset er en navngitt liste noen har gått gjennom. Er listen lengre enn dette, er den ikke gjennomgått.';
  end if;

  if (select count(distinct x) from unnest(p_evidence_item_ids) as x)
     <> cardinality(p_evidence_item_ids) then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Listen inneholder samme evidensfunn mer enn én gang.',
      hint = 'En dublett betyr at listen ikke er den gjennomgåtte listen. Rett den framfor å la kallet gjøre noe annet enn det som ble bestemt.';
  end if;


  -- ------------------------------------------------------------------------
  -- Låsen. Den tas før kontrollene, ikke som en følge av slettingen, og det er
  -- rekkefølgen som gjør at kontrollen under faktisk feiler lukket: en
  -- menneskelig kildekontroll commitet etter at kontrollen har lest tabellen,
  -- men før slettingen hadde låst den, ville blitt lest som fraværende og så
  -- slettet av kallet — og øyeblikksbildet ville ikke hatt den. Tilstanden
  -- kontrollene leser, skal være den samme tilstanden slettingen møter.
  --
  -- ACCESS EXCLUSIVE er den samme låsen ALTER TABLE trenger nedenfor, tatt i
  -- den samme rekkefølgen, slik at slettingen ikke må oppgradere en lås
  -- underveis. En egen LOCK-setning framfor å flytte ALTER-setningene hit:
  -- ALTER TABLE krever i tillegg at køen av utsatte triggerhendelser er tom,
  -- og det er et annet krav enn å låse.
  --
  -- De tre øvrige kontrollene — påstandslenke, reviewbeslutning og claim-sitat
  -- — trenger ingen egen lås: de tabellene peker på knowledge.evidence_items
  -- med `on delete restrict`, så en rad commitet underveis stopper slettingen
  -- framfor å forsvinne med den.
  -- ------------------------------------------------------------------------
  lock table workflow.evidence_verifications in access exclusive mode;
  lock table knowledge.evidence_field_groundings in access exclusive mode;
  lock table knowledge.evidence_items in access exclusive mode;

  -- ------------------------------------------------------------------------
  -- Subjektlåsene, og hvorfor de tas uten å vente
  --
  -- Fjerningen ender med å lese den redaksjonelle tilstanden på nytt, og den
  -- lesningen tar subjektlåsen (workflow.notice_claim_revision_need(uuid, uuid)).
  -- Alle de andre veiene inn i den tilstanden tar den låsen *etter* at de har
  -- rørt evidenstabellene: en ekstraksjonskontroll har allerede radlåsen på
  -- workflow.evidence_verifications når triggeren kjører, og beslutningsveien
  -- leser evidensgrunnlaget under låsen. Fjerningen må ha tabellåsene for i det
  -- hele tatt å kunne slette, og den kan derfor ikke ta subjektlåsen først uten
  -- å snu rekkefølgen for alle de andre.
  --
  -- Derfor tas den ikke ved å vente. En vranglås krever at noen *venter*: holder
  -- en annen transaksjon subjektet, gir fjerningen opp med en gang og feiler
  -- lukket, framfor å stille seg i en kø der den andre venter på tabellene
  -- fjerningen selv holder. En fjerning er en eksplisitt, gjennomgått handling
  -- som trygt kan gjøres om igjen et øyeblikk senere; en vranglås kan ikke
  -- velge hvem den avbryter.
  --
  -- Subjektene leses her og ikke før tabellåsene, slik at de er lest under den
  -- låsen som gjør tilstanden stabil. Sortert rekkefølge, slik at to fjerninger
  -- som overlapper, tar dem i den samme rekkefølgen.
  -- ------------------------------------------------------------------------
  select coalesce(
           array_agg(distinct format('%s+%s', e.intervention_drug_id, e.outcome_concept_id)
                     order by format('%s+%s', e.intervention_drug_id, e.outcome_concept_id)),
           array[]::text[])
    into v_locked_keys
  from knowledge.evidence_items e
  where e.id = any(p_evidence_item_ids)
    and e.intervention_drug_id is not null
    and e.outcome_concept_id is not null;

  foreach v_key in array v_locked_keys loop
    if not workflow.try_lock_chain_subject(
             'claim_synthesis'::provenance.agent_role, v_key) then
      raise exception using
        errcode = 'lock_not_available',
        message = 'Et av virkestoffene og endepunktene fjerningen gjelder, er opptatt av en annen operasjon akkurat nå.',
        hint = 'Ingenting er fjernet. En kontroll eller en redaksjonell avgjørelse om det samme faglige subjektet holder på; prøv igjen om et øyeblikk. Fjerningen venter ikke med vilje: den holder tabellåsene den andre trenger, og en venting ville vært den ene halvdelen av en vranglås.';
    end if;
  end loop;

  -- ------------------------------------------------------------------------
  -- Kontrollene. Alle kjøres før noe slettes, og én rad som feiler stopper
  -- hele kallet: en delvis reset ville etterlatt en tilstand ingen bestemte.
  -- ------------------------------------------------------------------------
  foreach v_id in array p_evidence_item_ids loop
    if not exists (select 1 from knowledge.evidence_items e where e.id = v_id) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('Evidensfunnet %s finnes ikke.', v_id),
        hint = 'Listen er ikke den databasen har. Hent køen på nytt framfor å fjerne noe annet enn det som ble gjennomgått.';
    end if;

    if exists (
      select 1
      from workflow.evidence_verifications ev
      join provenance.actors a on a.id = ev.verifier_actor_id
      where ev.evidence_item_id = v_id
        and a.actor_type = 'human'
    ) then
      raise exception using
        errcode = 'restrict_violation',
        message = format('Evidensfunnet %s er menneskelig kildekontrollert, og fjernes ikke.', v_id),
        hint = 'En utført menneskelig kontroll er en faglig handling med en ansvarlig bak. Den skal ikke kunne forsvinne (ANTIDEP_CONSTITUTION.md §12, §14).';
    end if;

    if exists (select 1 from knowledge.claim_evidence_links l where l.evidence_item_id = v_id) then
      raise exception using
        errcode = 'restrict_violation',
        message = format('Evidensfunnet %s bærer en påstandsrevisjon, og fjernes ikke.', v_id),
        hint = 'Funnet er lenket til en claim-revisjon. Å fjerne det ville gjort revisjonen til en påstand uten det grunnlaget den ble laget av — publisert eller ikke (ANTIDEP_CONSTITUTION.md §4, §8).';
    end if;

    if exists (select 1 from workflow.review_decisions rd where rd.evidence_item_id = v_id) then
      raise exception using
        errcode = 'restrict_violation',
        message = format('Evidensfunnet %s har en registrert reviewbeslutning, og fjernes ikke.', v_id),
        hint = 'En beslutning er en utført faglig handling, og tabellen er append-only av samme grunn som kontrollene.';
    end if;

    if exists (
      select 1 from workflow.claim_verification_citations c where c.evidence_item_id = v_id
    ) then
      raise exception using
        errcode = 'restrict_violation',
        message = format('Evidensfunnet %s er sitert i en claim-verifikasjon, og fjernes ikke.', v_id),
        hint = 'Kontrollen registrerte hva den faktisk leste. Å fjerne funnet ville skrevet om den nedtegnelsen.';
    end if;

    -- En besluttet revisjon som ennå ikke er bygget, bærer funnet i manifestet
    -- sitt uten å ha lenket det: lenken finnes først når syntesen er registrert.
    -- Ble funnet slettet i det vinduet, ville oppgaven stått som besluttet mens
    -- jobben pekte på evidens som ikke finnes — og den ville svikte teknisk
    -- framfor å bli avvist her (migrasjon 012d, ANTIDEP_CONSTITUTION.md regel 4).
    if exists (
      select 1
      from workflow.pipeline_jobs j
      where j.agent_role = 'claim_synthesis'::provenance.agent_role
        and j.state in ('ready'::workflow.pipeline_job_state,
                        'leased'::workflow.pipeline_job_state)
        and j.input_manifest -> 'evidence_item_ids' @> to_jsonb(v_id)
    ) then
      raise exception using
        errcode = 'restrict_violation',
        message = format('Evidensfunnet %s inngår i en besluttet revisjon som ennå ikke er bygget, og fjernes ikke.', v_id),
        hint = 'En redaktør har bestemt at påstanden skal skrives om med dette grunnlaget, og oppgaven ligger i køen. Vent til den er ferdig, eller la den feile først — en revisjon bygget på evidens som er borte, ville uansett ikke kunne registreres.';
    end if;

    -- Øyeblikksbildet tas før slettingen, og er hele kontrollgrunnlaget: det som
    -- fjernes, skal fortsatt kunne leses av den som spør hva som sto der.
    v_snapshots := v_snapshots || jsonb_build_object(
      v_id::text,
      jsonb_build_object(
        -- `id` er påkrevd av events_snapshot_identifies_object_check: et
        -- øyeblikksbilde skal navngi objektet raden handler om, slik at det
        -- ikke kan havne på feil objekt.
        'id', v_id,
        'dossier', workflow.evidence_extraction_dossier(v_id),
        'extraction_verifications', (
          select coalesce(jsonb_agg(to_jsonb(ev) order by ev.created_at), '[]'::jsonb)
          from workflow.evidence_verifications ev
          where ev.evidence_item_id = v_id
        )
      )
    );
  end loop;

  -- ------------------------------------------------------------------------
  -- Subjektene, lest mens radene fortsatt finnes
  --
  -- Et funn som fjernes her, kan være nettopp det funnet som åpnet en
  -- redaksjonell revisjonsoppgave: et maskinkontrollert funn uten påstandslenke
  -- er både det denne veien får fjerne, og det oppgaven er laget av. Etter
  -- slettingen finnes ingen evidensrad som fører tilbake til virkestoffet og
  -- endepunktet, så subjektet må leses nå (migrasjon 012d).
  -- ------------------------------------------------------------------------
  select coalesce(jsonb_agg(distinct jsonb_build_object(
           'drug', e.intervention_drug_id, 'topic', e.outcome_concept_id,
           'need', s.need_id)), '[]'::jsonb)
    into v_subjects
  from knowledge.evidence_items e
  cross join lateral (
    values (null::uuid), (knowledge.monograph_need_for_evidence_item(e.id))
  ) as s(need_id)
  where e.id = any(p_evidence_item_ids)
    and e.intervention_drug_id is not null
    and e.outcome_concept_id is not null;

  -- ------------------------------------------------------------------------
  -- Slettingen. Append-only-vernet er fasiten for enhver annen skrivevei, og
  -- skrus av bare her, bare i denne transaksjonen, og slås på igjen også når
  -- noe går galt.
  -- ------------------------------------------------------------------------
  begin
    -- `ALTER TABLE` kan ikke kjøre på en tabell med utsatte triggerhendelser i
    -- kø, og forankringskontrollen på knowledge.evidence_items er utsatt til
    -- commit (migrasjon 003d). I en reset som kjører alene er køen tom og
    -- setningen en nulloperasjon; ligger det en registrering foran i den samme
    -- transaksjonen, kjøres kontrollen av den nå — og en registrering som ikke
    -- holder, stopper fjerningen framfor å bli commitet etter den.
    --
    -- Modusen settes tilbake etterpå, også når noe går galt. Uten det ville en
    -- registrering *senere* i den samme transaksjonen blitt kontrollert før
    -- forankringen sin var skrevet, og en lovlig registrering ville blitt
    -- avvist av et valg denne funksjonen gjorde.
    set constraints all immediate;

    alter table workflow.evidence_verifications disable trigger evidence_verifications_reject_mutation;
    alter table knowledge.evidence_field_groundings disable trigger evidence_field_groundings_reject_mutation;
    alter table knowledge.evidence_items disable trigger evidence_items_reject_mutation;

    delete from workflow.evidence_verifications ev
    where ev.evidence_item_id = any(p_evidence_item_ids);
    get diagnostics v_verifications = row_count;

    delete from knowledge.evidence_field_groundings g
    where g.evidence_item_id = any(p_evidence_item_ids);
    get diagnostics v_groundings = row_count;

    delete from knowledge.evidence_items e
    where e.id = any(p_evidence_item_ids);
    get diagnostics v_items = row_count;

    alter table knowledge.evidence_items enable trigger evidence_items_reject_mutation;
    alter table knowledge.evidence_field_groundings enable trigger evidence_field_groundings_reject_mutation;
    alter table workflow.evidence_verifications enable trigger evidence_verifications_reject_mutation;
    set constraints all deferred;
  exception
    when others then
      alter table knowledge.evidence_items enable trigger evidence_items_reject_mutation;
      alter table knowledge.evidence_field_groundings enable trigger evidence_field_groundings_reject_mutation;
      alter table workflow.evidence_verifications enable trigger evidence_verifications_reject_mutation;
      set constraints all deferred;
      raise;
  end;

  if v_items <> cardinality(p_evidence_item_ids) then
    -- Kan i praksis ikke skje: eksistensen er kontrollert over, og
    -- transaksjonen holder låsen. En påstand som ikke kontrolleres, er likevel
    -- ikke en påstand noen kan stole på.
    raise exception using
      errcode = 'restrict_violation',
      message = format('%s av %s evidensfunn ble fjernet. Ingenting er lagret.',
                       v_items, cardinality(p_evidence_item_ids));
  end if;

  -- ------------------------------------------------------------------------
  -- Sporet. Én rad per fjernet funn, med det som sto der.
  -- ------------------------------------------------------------------------
  foreach v_id in array p_evidence_item_ids loop
    insert into audit.events
      (operation, object_id, actor_id, old_revision_or_snapshot, reason, occurred_at)
    values
      ('extraction_artifact_discarded', v_id, v_actor_id,
       v_snapshots -> v_id::text, btrim(p_reason), now());
    v_removed := v_removed || to_jsonb(v_id::text);
  end loop;

  -- ------------------------------------------------------------------------
  -- Den redaksjonelle tilstanden, i den samme transaksjonen
  --
  -- Var dette den siste nye evidensen om et par som allerede har en påstand,
  -- er det ikke lenger noe å avgjøre, og oppgaven lukkes. Uten dette ville den
  -- blitt stående åpen for alltid: beslutningsveien ville avvist den, og
  -- rekonsilieringen ville ikke funnet den gjennom en evidensrad som ikke
  -- finnes mer. En oppgave et menneske ikke kan fullføre, skal ikke stå i den
  -- åpne arbeidsoversikten (ANTIDEP_CONSTITUTION.md regel 4).
  --
  -- Ingen feil fanges her. Lar ikke tilstanden seg holde i takt, skal
  -- fjerningen feile lukket framfor å etterlate en oppgave om ingenting.
  -- ------------------------------------------------------------------------
  for v_subject in select value from jsonb_array_elements(v_subjects) loop
    perform workflow.notice_claim_revision_need(
      (v_subject ->> 'drug')::uuid, (v_subject ->> 'topic')::uuid,
      (v_subject ->> 'need')::uuid);
  end loop;

  return jsonb_build_object(
    'discarded_evidence_item_ids', v_removed,
    'resynced_claim_revision_subjects', jsonb_array_length(v_subjects),
    'deleted_extraction_verifications', v_verifications,
    'deleted_field_groundings', v_groundings,
    'discarded_by_actor_id', v_actor_id,
    'reason', btrim(p_reason)
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

  return jsonb_build_object('queued', v_queued, 'candidates_built', v_candidates,
                            'revision_reviews', v_reviews);
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

CREATE OR REPLACE FUNCTION knowledge.record_monograph_term_proposal(p_edition_id uuid, p_axis knowledge.monograph_scope_axis, p_label text, p_rationale text, p_actor_id uuid, p_agent_run_id uuid, p_need_id uuid, p_source_version_id uuid, p_source_quote text, p_concept_id uuid, p_population_id uuid, p_drug_id uuid)
 RETURNS workflow.monograph_term_proposals
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_proposal workflow.monograph_term_proposals;
begin
  -- Et ordrett utdrag skal faktisk stå i den registrerte representasjonen.
  -- Kontrollen er den samme evidenskjeden bruker; uten den ville et
  -- «dokumentert grunnlag» vært en tekst agenten fant på, og utvidelsen av
  -- mandatet ville hvilt på den (ANTIDEP_CONSTITUTION.md regel 2).
  if p_source_quote is not null then
    if knowledge.source_version_text(p_source_version_id) is null then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Kildeversjonen forslaget viser til, har ingen registrert representasjon å kontrollere utdraget mot.';
    end if;
    if position(p_source_quote in knowledge.source_version_text(p_source_version_id)) = 0 then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Det ordrette utdraget står ikke i den registrerte representasjonen av kildeversjonen.',
        hint = 'Et grunnlag som ikke kan kontrolleres mot kilden, er en påstand. En påstand skal ikke kunne utvide dekningskartet (ANTIDEP_CONSTITUTION.md regel 2).';
    end if;
  end if;

  -- Behovet forslaget kommer fra, må høre til utgaven forslaget gjelder.
  -- Uten kravet kunne arbeidet med én monografi utvidet avgrensningen i en
  -- annen, og et svar ville fått et spørsmål ingen stilte der.
  if p_need_id is not null and not exists (
    select 1 from knowledge.monograph_needs n
    where n.id = p_need_id and n.edition_id = p_edition_id
  ) then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Behovet forslaget kommer fra, hører ikke til denne monografiutgaven.',
      hint = 'Et forslag utvider den utgaven det kom fra.';
  end if;

  insert into workflow.monograph_term_proposals (
    edition_id, axis, label, rationale,
    proposed_by_actor_id, proposed_by_agent_run_id, proposed_from_need_id,
    source_version_id, source_quote,
    concept_id, population_id, drug_id
  )
  values (
    p_edition_id, p_axis, p_label, p_rationale,
    p_actor_id, p_agent_run_id, p_need_id,
    p_source_version_id, p_source_quote,
    p_concept_id, p_population_id, p_drug_id
  )
  on conflict (edition_id, axis, label) do nothing
  returning * into v_proposal;

  if v_proposal.id is null then
    -- Den samme verdien foreslått to ganger er ett forslag. Et andre forslag
    -- ville gitt to avgjørelser om den samme utvidelsen.
    select p.* into v_proposal
    from workflow.monograph_term_proposals p
    where p.edition_id = p_edition_id and p.axis = p_axis and p.label = p_label;
  end if;

  return v_proposal;
end;
$function$;

CREATE OR REPLACE FUNCTION knowledge.decide_monograph_term_proposal(p_proposal_id uuid, p_accept boolean, p_note text, p_actor_id uuid, p_agent_run_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_proposal workflow.monograph_term_proposals;
  v_proposing_role provenance.agent_role;
  v_deciding_role provenance.agent_role;
  v_proposing_model provenance.role_model_assignments;
  v_deciding_model provenance.role_model_assignments;
  v_concept_id uuid;
  v_population_id uuid;
  v_needs integer := 0;
begin
  select p.* into v_proposal
  from workflow.monograph_term_proposals p
  where p.id = p_proposal_id
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Forslaget finnes ikke.';
  end if;

  if v_proposal.state <> 'open' then
    -- Den samme avgjørelsen sendt inn igjen svarer med det som ble registrert.
    -- En annen avgjørelse på et avgjort forslag avvises av fryseren.
    return jsonb_build_object(
      'reference', v_proposal.reference,
      'decided', false,
      'already_decided', true,
      'state', v_proposal.state::text,
      'needs_created', 0);
  end if;

  if p_agent_run_id is not null and v_proposal.proposed_by_agent_run_id is not null then
    select r.agent_role into v_proposing_role
    from provenance.agent_runs r where r.id = v_proposal.proposed_by_agent_run_id;
    select r.agent_role into v_deciding_role
    from provenance.agent_runs r where r.id = p_agent_run_id;

    if v_proposing_role = v_deciding_role then
      raise exception using
        errcode = 'restrict_violation',
        message = 'Et agentledd kan ikke akseptere sitt eget forslag om en utvidelse.',
        hint = 'Den som skal finne et svar, skal ikke kunne endre sitt eget mandat for å få funnet godkjent (MONOGRAPH_STANDARD.md §4). Aksepten hører til et annet agentledd eller til et menneske med redaktørmandat.';
    end if;

    -- To navn på den samme modellen er ikke to uavhengige modeller
    -- (ANTIDEP_CONSTITUTION.md regel 3).
    v_proposing_model := provenance.current_semantic_model(v_proposing_role);
    v_deciding_model := provenance.current_semantic_model(v_deciding_role);
    if v_proposing_model.id is not null and v_deciding_model.id is not null
       and v_proposing_model.provider = v_deciding_model.provider
       and v_proposing_model.model = v_deciding_model.model
       and v_proposing_model.model_version = v_deciding_model.model_version then
      raise exception using
        errcode = 'restrict_violation',
        message = 'Den aksepterende modellen er den samme som den foreslående.',
        hint = 'To navn på den samme modellen er ikke to uavhengige modeller (ANTIDEP_CONSTITUTION.md regel 3).';
    end if;
  end if;

  if not p_accept then
    update workflow.monograph_term_proposals
    set state = 'declined',
        decided_at = now(),
        decided_by_actor_id = p_actor_id,
        decided_by_agent_run_id = p_agent_run_id,
        decision_note = p_note
    where id = p_proposal_id;

    return jsonb_build_object(
      'reference', v_proposal.reference,
      'decided', true,
      'already_decided', false,
      'state', 'declined',
      'needs_created', 0);
  end if;

  -- Katalogaksene trenger en katalograd for å kunne bære et behov. Finnes den
  -- ikke, opprettes den her — av databasen, i den samme transaksjonen som
  -- aksepten, og bare når aksepten faktisk skjer. Et åpent forslag skal ikke
  -- etterlate en katalograd ingen har tatt stilling til.
  if v_proposal.axis = 'indication' then
    v_concept_id := v_proposal.concept_id;
    if v_concept_id is null then
      select c.id into v_concept_id
      from catalog.clinical_concepts c
      where lower(c.canonical_label) = lower(v_proposal.label)
        and c.concept_type = 'condition';
      if v_concept_id is null then
        insert into catalog.clinical_concepts (canonical_label, concept_type)
        values (v_proposal.label, 'condition')
        returning id into v_concept_id;
      end if;
    end if;
  elsif v_proposal.axis = 'outcome' then
    v_concept_id := v_proposal.concept_id;
    if v_concept_id is null then
      select c.id into v_concept_id
      from catalog.clinical_concepts c
      where lower(c.canonical_label) = lower(v_proposal.label)
        and c.concept_type = 'outcome';
      if v_concept_id is null then
        insert into catalog.clinical_concepts (canonical_label, concept_type)
        values (v_proposal.label, 'outcome')
        returning id into v_concept_id;
      end if;
    end if;
  elsif v_proposal.axis = 'population' then
    v_population_id := v_proposal.population_id;
    if v_population_id is null then
      select p.id into v_population_id
      from catalog.populations p
      where lower(p.canonical_label) = lower(v_proposal.label);
      if v_population_id is null then
        insert into catalog.populations (canonical_label)
        values (v_proposal.label)
        returning id into v_population_id;
      end if;
    end if;
  elsif v_proposal.axis in ('comparator', 'switch_target') and v_proposal.drug_id is null then
    -- Et virkestoff opprettes ikke av en monografiutvidelse. Legemiddelidentitet
    -- er katalogens eget ansvar med sine egne identifikatorer, og en rad
    -- opprettet av et byttepar ville manglet dem alle.
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Verdien peker på et virkestoff som ikke finnes i katalogen.',
      hint = 'Legemiddelidentitet med navn, salt og identifikatorer er katalogens eget ansvar. Et virkestoff opprettes ikke som en bieffekt av en monografiutvidelse.';
  end if;

  update workflow.monograph_term_proposals
  set state = 'accepted',
      decided_at = now(),
      decided_by_actor_id = p_actor_id,
      decided_by_agent_run_id = p_agent_run_id,
      decision_note = p_note,
      concept_id = coalesce(v_concept_id, concept_id),
      population_id = coalesce(v_population_id, population_id)
  where id = p_proposal_id;

  -- Og dekningskartet utvides med den nye verdien, i den samme transaksjonen.
  -- Et akseptert begrep som ikke førte til et behov, ville vært en utvidelse
  -- ingen kunne se.
  if v_proposal.proposed_from_need_id is not null then
    -- Verdien kom fra et konkret behov, og den forgrener nettopp det.
    -- Utvidelsen av hele utgaven ville laget kryssproduktet av alle aksene,
    -- og det er ikke det standarden ber om: delutfallet hører til det
    -- spørsmålet det ble dokumentert under (MONOGRAPH_STANDARD.md §3).
    --
    -- Et ulovlig par — en akse malen ikke gjentas på, eller et behov som alt
    -- er avgrenset på den aksen — stopper aksepten her. Da er det ingen
    -- utvidelse å godta.
    if knowledge.refine_monograph_need(
         v_proposal.proposed_from_need_id, v_proposal.axis, v_proposal.label,
         coalesce(v_concept_id, v_proposal.concept_id),
         coalesce(v_population_id, v_proposal.population_id),
         v_proposal.drug_id,
         format('Aktivert av den aksepterte verdien %L på aksen %s: %s',
                v_proposal.label, v_proposal.axis, v_proposal.rationale)) is null then
      v_needs := 0;
    else
      v_needs := 1;
    end if;

    -- Og søkeplanene for det nye behovet, i den samme transaksjonen.
    perform workflow.build_monograph_search_plans(v_proposal.edition_id);
  else
    v_needs := knowledge.expand_monograph_edition(v_proposal.edition_id);
  end if;

  return jsonb_build_object(
    'reference', v_proposal.reference,
    'decided', true,
    'already_decided', false,
    'state', 'accepted',
    'needs_created', v_needs);
end;
$function$;

-- ----------------------------------------------------------------------------
-- 11. Tilgangene
--
-- Ingen leserett og ingen leseregel. De nye radene er interne — de sier hvilke
-- kilder som er godkjent for hvilke spørsmål, og hvilke publikasjoner som hører
-- til den samme studien — og de forlater databasen bare gjennom en kontrollert
-- funksjon, som resten av monografiradene fra migrasjon 013c. En leseregel uten
-- en leserett bak ville ikke gitt noen tilgang, men den ville sett ut som om den
-- gjorde det.
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- 12. Et forslag som navngir behovet det kom fra
--
-- Et delutfall hører til det spørsmålet det ble dokumentert under. Uten
-- muligheten til å si hvilket behov verdien kom fra, ville en ny utfallsverdi
-- måttet utvide hele utgaven — og det ville laget kryssproduktet av alle akser
-- framfor det ene svaret standarden ber om (MONOGRAPH_STANDARD.md §3).
--
-- Den gamle formen beholdes: fire argumenter betyr fortsatt «utvid utgaven på
-- malenes primære akse», og det er nøyaktig det de gjorde før.
-- ----------------------------------------------------------------------------

drop function api.propose_monograph_term(text, text, text, text);

create function api.propose_monograph_term(
  p_edition_reference text,
  p_axis text,
  p_label text,
  p_rationale text,
  p_from_need_reference text default null)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_edition knowledge.monograph_editions;
  v_axis knowledge.monograph_scope_axis;
  v_need_id uuid;
  v_proposal workflow.monograph_term_proposals;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  select e.* into v_edition
  from knowledge.monograph_editions e
  where e.reference = p_edition_reference and e.superseded_at is null;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Det finnes ingen gjeldende monografiutgave med denne referansen.';
  end if;

  begin
    v_axis := p_axis::knowledge.monograph_scope_axis;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke en avgrensningsakse.', p_axis);
  end;

  if p_from_need_reference is not null then
    select n.id into v_need_id
    from knowledge.monograph_needs n
    where n.reference = btrim(p_from_need_reference);

    if not found then
      raise exception using
        errcode = 'no_data_found',
        message = 'Det finnes ingen kunnskapsbehov med denne referansen.',
        hint = 'Referansen er den behovet har i dekningskartet. Uten et behov utvider forslaget utgaven på malenes egen akse.';
    end if;
  end if;

  v_proposal := knowledge.record_monograph_term_proposal(
    v_edition.id, v_axis, btrim(p_label), btrim(p_rationale),
    v_actor_id, null, v_need_id, null, null, null, null, null);

  return jsonb_build_object(
    'reference', v_proposal.reference,
    'axis', v_proposal.axis::text,
    'label', v_proposal.label,
    'from_need', (select n.reference from knowledge.monograph_needs n
                  where n.id = v_proposal.proposed_from_need_id),
    'state', v_proposal.state::text);
end;
$$;

comment on function api.propose_monograph_term(text, text, text, text, text) is
  'Foreslår en ny verdi på en avgrensningsakse i en monografiutgave, eventuelt med det kunnskapsbehovet verdien ble dokumentert under. Uten et behov utvider en akseptert verdi utgaven på malenes primære akse — nøyaktig som før. Med et behov forgrener den nettopp det behovet, fordi et delutfall hører til det spørsmålet det ble funnet under og ikke til alle spørsmål på den aksen (MONOGRAPH_STANDARD.md §3). Forslaget utvider ingenting i seg selv: aksepten er en egen, kontrollert avgjørelse.';

revoke execute on function api.propose_monograph_term(text, text, text, text, text) from public;
grant execute on function api.propose_monograph_term(text, text, text, text, text) to authenticated;
