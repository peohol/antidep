-- ============================================================================
-- Migrasjon 003c — golden slicens kildeversjoner sier hva de er, og så fryses
--                  opplysningen
--
-- Migrasjon 003b innførte `knowledge.source_versions.representation`: hva slags
-- representasjon som faktisk ble hentet (EVIDENCE_PIPELINE.md §13). De to
-- kildeversjonene fra migrasjon 003 er eldre enn kolonnen og står med NULL.
--
-- ----------------------------------------------------------------------------
-- Hvorfor verdien kan settes her
--
-- Begge er hentet med EUtils efetch, som gir MEDLINE-posten: tittel, forfattere
-- og sammendrag, ikke fulltekstartikkelen. `abstract` er derfor ikke en
-- gjetning, men en avlesning av noe migrasjon 003 selv dokumenterer i
-- `retrieved_from` og i det hashede innholdet.
--
-- Opplysningen har ingen aktørattribusjon: den sier hva dokumentet *er*, ikke
-- hvem som mente noe om det. Å sette den i ettertid konstruerer derfor ingen
-- proveniens. Det er den avgjørende forskjellen fra kildeforankringen, som er
-- ekstraksjonens eget produkt og bare kan bli til sammen med ekstraksjonen
-- (migrasjon 005u, 005v).
--
-- ----------------------------------------------------------------------------
-- …og hvorfor den fryses umiddelbart etterpå
--
-- `representation` er historisk metadata om et øyeblikksbilde, akkurat som
-- `retrieved_at`, `retrieved_from` og `content_hash`.
-- `knowledge.freeze_source_version()` vernet allerede de fire, men ikke den
-- nye kolonnen: en kildeversjon kunne derfor stille endres fra `abstract` til
-- `full_text` etterpå, og da ville en ekstraksjon sett ut som om den bygde på
-- noe annet enn den gjorde. Kolonnen legges derfor til vernet her, etter
-- oppdateringen over, som er den eneste gangen den skal kunne settes på en
-- eksisterende rad.
--
-- Rekkefølgen i filen er dermed ikke tilfeldig: UPDATE først, frysing etterpå.
-- En senere kildeversjon får verdien ved innsetting og kan aldri endre den.
--
-- ----------------------------------------------------------------------------
-- Hva som IKKE endres
--
-- Ingen ekstraksjonsverdi, ingen forankring, ingen `content_hash`, ingen
-- `raw_extraction`, ingen constraint, policy eller grant. De to evidensfunnene
-- fra migrasjon 003 forblir uforankret og dermed ukontrollerbare felt for felt
-- — det er den sanne tilstanden, og den skal beskrives framfor å repareres med
-- rader som ser ut som et produkt av en ekstraksjonskjøring som aldri fant
-- sted.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §4, §6, §8, §11
--   docs/DATABASE_ARCHITECTURE.md §18, §36, §57, §60
--   docs/EVIDENCE_PIPELINE.md §13
--   docs/MVP_IMPLEMENTATION_PLAN.md §12, §20
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Representasjonstypen på de to seedede kildeversjonene
--
-- Radene identifiseres av kildens PubMed-ID, ikke av en id: id-ene i migrasjon
-- 003 er databasegenererte, og en migrasjon som navnga dem, ville truffet en
-- annen rad i hver database.
-- ----------------------------------------------------------------------------
update knowledge.source_versions sv
set representation = 'abstract'
where sv.representation is null
  and sv.source_id in (
    select si.source_id
    from knowledge.source_identifiers si
    where si.identifier_system = 'pmid'
      and si.identifier_value in ('11105740', '15697327')
  );

do $$
declare
  v_unset integer;
begin
  select count(*)
    into v_unset
  from knowledge.evidence_items e
  join knowledge.source_versions sv on sv.id = e.source_version_id
  join knowledge.source_identifiers si on si.source_id = e.source_id
  where si.identifier_system = 'pmid'
    and si.identifier_value in ('11105740', '15697327')
    and sv.representation is null;

  if v_unset > 0 then
    raise exception
      '% av golden slicens kildeversjoner mangler fortsatt representasjonstype.', v_unset;
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- 2. Kolonnen legges til det som allerede er uforanderlig
--
-- Fremover-skrivende med `create or replace function`: signatur, eier og
-- rettigheter er uendret, og triggeren som kaller den er den samme.
-- ----------------------------------------------------------------------------
create or replace function knowledge.freeze_source_version()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if new.source_id is distinct from old.source_id
    or new.retrieved_at is distinct from old.retrieved_at
    or new.retrieved_from is distinct from old.retrieved_from
    or new.external_version is distinct from old.external_version
    or new.content_hash is distinct from old.content_hash
    or new.representation is distinct from old.representation
    or new.retrieved_by_actor_id is distinct from old.retrieved_by_actor_id
  then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Et hentet øyeblikksbilde av en kilde er uforanderlig og kan ikke endres.',
      hint = 'Registrer en ny kildeversjon for det nye innholdet. Evidensfunn som peker på den gamle versjonen skal beholde sin opprinnelige dokumentasjon.';
  end if;

  return new;
end;
$$;

comment on function knowledge.freeze_source_version() is
  'Nekter enhver endring av de kolonnene som til sammen utgjør øyeblikksbildet av en hentet kilde: source_id, retrieved_at, retrieved_from, external_version, content_hash, representation og retrieved_by_actor_id (DATABASE_ARCHITECTURE.md §18, §36). representation kom til i migrasjon 003b og er vernet fra 003c: den sier hva ekstraksjonen faktisk bygde på (EVIDENCE_PIPELINE.md §13), og en rad som stille kunne endres fra abstract til full_text ville latt en ekstraksjon se ut som om den hvilte på noe annet enn den gjorde. storage_reference er med vilje utenfor vernet: hvor kopien ligger, er driftsinformasjon og ikke en påstand om kilden.';
