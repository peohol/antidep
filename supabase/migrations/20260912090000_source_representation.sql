-- ============================================================================
-- Migrasjon 003b — hvilken representasjon ekstraksjonen faktisk bygger på
--
-- EVIDENCE_PIPELINE.md §13 krever at pipeline vet om en vurdering bygger på
-- fulltekst, abstrakt, registerdata, et regulatorisk sammendrag, en sekundær
-- omtale eller en annen begrenset representasjon — og at «agenten aldri skal
-- beskrive kildeinnhold som ikke faktisk var tilgjengelig i kjøringen».
--
-- `knowledge.source_versions` har hatt henteadressen og fingeravtrykket, men
-- ikke *hva slags* representasjon som ble hentet. Uten den opplysningen kan et
-- evidensfunn hvile på et sammendrag uten at noe sier det, og en manglende
-- fulltekst kan verken stoppe eller nedgradere en vurdering — fordi ingenting
-- vet at fullteksten manglet.
--
-- ----------------------------------------------------------------------------
-- Dette er en annen opplysning enn kildetilgangen i en kontroll
--
-- `workflow.verification_source_access` sier hva *kontrolløren* hadde tilgang
-- til da hen kontrollerte. Kolonnen her sier hva *ekstraksjonen* ble laget av.
-- De to kan være forskjellige — en kliniker med fulltekst kan kontrollere en
-- ekstraksjon laget av et abstrakt — og å slå dem sammen ville skjult nettopp
-- den forskjellen §13 finnes for å synliggjøre.
--
-- ----------------------------------------------------------------------------
-- Nullbar, og hvorfor
--
-- Kildeversjonene som allerede finnes, ble registrert uten opplysningen, og en
-- NOT NULL med en gjettet standardverdi ville skrevet en påstand ingen har gjort
-- om hva de faktisk var. NULL betyr derfor «ikke registrert», aldri «ukjent
-- representasjon som likevel kan brukes» — og den nye agentekstraksjonen
-- (migrasjon 005v) avviser en kildeversjon uten verdien. Kravet er dermed
-- håndhevet der det har konsekvenser, framfor å bli en bakoverrettet gjetning.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §6, §8, §11
--   docs/DATABASE_ARCHITECTURE.md §18, §43, §50
--   docs/EVIDENCE_PIPELINE.md §13, §14
--   docs/KNOWLEDGE_MODEL.md §11.2
-- ============================================================================

create type knowledge.source_representation as enum (
  'full_text',
  'abstract',
  'registry_record',
  'regulatory_summary',
  'secondary_report',
  'other_limited'
);

comment on type knowledge.source_representation is
  'Hva slags representasjon av kilden som faktisk ble hentet og lest (EVIDENCE_PIPELINE.md §13): fulltekst, abstrakt, registerdata, regulatorisk sammendrag, sekundær omtale eller en annen begrenset representasjon. Vokabularet er §13 sin egen liste, ord for ord. Verdien beskriver hva ekstraksjonen bygger på, ikke hva en senere kontrollør tilfeldigvis har tilgang til — det siste er workflow.verification_source_access, og de to skal ikke slås sammen.';

revoke usage on type knowledge.source_representation from public;

alter table knowledge.source_versions
  add column representation knowledge.source_representation;

comment on column knowledge.source_versions.representation is
  'Hva slags representasjon som ble hentet (EVIDENCE_PIPELINE.md §13). NULL betyr at opplysningen ikke er registrert — tilstanden alle versjoner registrert før migrasjon 003b er i — aldri at representasjonen er ukjent men brukbar. En agentekstraksjon avviser en kildeversjon uten verdien (migrasjon 005v), slik at kravet håndheves der det har konsekvenser framfor å bli en bakoverrettet gjetning.';

-- ----------------------------------------------------------------------------
-- Skriveveien tar imot verdien
--
-- Begge funksjonene slippes og lages på nytt: en ny parameter med standardverdi
-- ville laget en *ny* funksjon ved siden av den gamle, og PostgREST ville da
-- hatt to kandidater for samme navn — hvilken som ble valgt, ville avhengt av
-- hvilke argumenter klienten tilfeldigvis sendte, altså av klienten og ikke av
-- kontrakten. DROP + CREATE er den eneste operasjonen som bytter signatur uten
-- å etterlate to. Rettighetene gjenopprettes identisk.
--
-- Parameteren er valgfri utad og påkrevd der den betyr noe. En editor som
-- registrerer en kildeversjon for hånd, kan la den stå — men da kan ingen
-- agentekstraksjon bygge på versjonen.
-- ----------------------------------------------------------------------------
drop function api.create_source_version(uuid, timestamptz, text, text, text, text);
drop function knowledge.record_source_version(uuid, timestamptz, text, text, text, text, uuid);

create function knowledge.record_source_version(
  p_source_id uuid,
  p_retrieved_at timestamptz,
  p_retrieved_from text,
  p_retrieved_content text,
  p_external_version text,
  p_storage_reference text,
  p_representation text,
  p_retrieved_by_actor_id uuid
)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_source_version_id uuid;
  v_representation knowledge.source_representation;
begin
  -- Innholdet er påkrevd fordi hashen er det. En tom representasjon ville gitt
  -- hashen av den tomme strengen, altså et fingeravtrykk som er likt for enhver
  -- kilde og derfor ikke identifiserer noe. Kontrollen er på fravær av innhold,
  -- ikke på formen: hva en representasjon *er*, avgjøres av kilden.
  if nullif(btrim(coalesce(p_retrieved_content, '')), '') is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Den hentede representasjonen mangler, og da kan ingen kildeversjon registreres.',
      hint = 'Oppgi innholdet nøyaktig slik det ble hentet fra adressen. Databasen beregner content_hash av det, og hashen er det som gjør versjonen etterprøvbar (ANTIDEP_CONSTITUTION.md §11).';
  end if;

  begin
    v_representation := nullif(btrim(coalesce(p_representation, '')), '')::knowledge.source_representation;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke en kjent representasjonstype.', p_representation),
        hint = 'Gyldige verdier er full_text, abstract, registry_record, regulatory_summary, secondary_report og other_limited (EVIDENCE_PIPELINE.md §13).';
  end;

  insert into knowledge.source_versions (
    source_id, retrieved_at, retrieved_from, external_version,
    content_hash, storage_reference, representation, retrieved_by_actor_id
  )
  values (
    p_source_id,
    p_retrieved_at,
    p_retrieved_from,
    p_external_version,
    -- Ubeskåret innhold: btrim over er bare en tomhetskontroll, aldri en
    -- normalisering av det som hashes.
    knowledge.source_version_content_hash(p_retrieved_content),
    p_storage_reference,
    v_representation,
    p_retrieved_by_actor_id
  )
  returning id into v_source_version_id;

  return v_source_version_id;
exception
  -- source_versions_source_content_key. Den eneste oversatte avvisningen, og
  -- samme resonnement som dubletten i api.create_evidence_item(...): dette er en
  -- forventet utgang av en riktig utfylt form — den samme representasjonen hentet
  -- en gang til — og databasens egen tekst navngir en mekanisme framfor å si hva
  -- som skjedde.
  when unique_violation then
    raise exception using
      errcode = 'unique_violation',
      message = 'Nøyaktig samme innhold er allerede registrert som en kildeversjon for denne kilden.',
      hint = 'At hashen er lik betyr at kilden er uendret siden forrige henting. Bruk den registrerte versjonen framfor å lage en ny; en ny rad ville vært den samme observasjonen om igjen.';
end;
$$;

comment on function knowledge.record_source_version(
  uuid, timestamptz, text, text, text, text, text, uuid
) is
  'Innsettingen av én kildeversjon, uten autorisasjon: hasher den hentede representasjonen med knowledge.source_version_content_hash(text), setter inn raden attribuert til aktøren kalleren oppgir, og returnerer versjonens id. p_representation sier hva slags representasjon som ble hentet (EVIDENCE_PIPELINE.md §13); tom eller utelatt betyr at opplysningen ikke er registrert, og en agentekstraksjon kan da ikke bygge på versjonen (migrasjon 005v). Autorisasjonen ligger hos inngangspunktet som kaller den, slik at en senere skrivevei med en annen autorisasjonsmodell kan gjenbruke innsettingen framfor å kopiere den. Kalles fra innsiden av en SECURITY DEFINER-funksjon og trenger derfor ikke være det selv. Avviser en tom representasjon og en ukjent representasjonstype, og oversetter dubletten til en setning på norsk uten å endre regelen.';

revoke execute on function knowledge.record_source_version(
  uuid, timestamptz, text, text, text, text, text, uuid
) from public;

create function api.create_source_version(
  p_source_id uuid,
  p_retrieved_at timestamptz,
  p_retrieved_from text,
  p_retrieved_content text,
  p_external_version text default null,
  p_storage_reference text default null,
  p_representation text default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
begin
  -- Uten begrep: en kildeversjon er, som kilden selv, ikke avgrenset til noe
  -- klinisk begrep, og en avgrenset editor-tildeling er derfor tilstrekkelig.
  v_actor_id := knowledge.assert_editor_authorized();

  return knowledge.record_source_version(
    p_source_id,
    p_retrieved_at,
    p_retrieved_from,
    p_retrieved_content,
    p_external_version,
    p_storage_reference,
    p_representation,
    v_actor_id
  );
end;
$$;

comment on function api.create_source_version(
  uuid, timestamptz, text, text, text, text, text
) is
  'Den kontrollerte skriveveien for å registrere en kildeversjon (DATABASE_ARCHITECTURE.md §18, §43, MVP_IMPLEMENTATION_PLAN.md §15, §74.30 punkt 1, issue #44). Kontrollerer at kalleren har en registrert, aktiv aktør og en gyldig editor-rolle (knowledge.assert_editor_authorized(uuid), kalt uten begrep), setter inn raden gjennom knowledge.record_source_version(uuid, timestamptz, text, text, text, text, text, uuid) attribuert til kallerens egen aktør, og returnerer versjonens id. content_hash er ikke en parameter: databasen beregner den av p_retrieved_content, slik at hashen aldri er en påstand kalleren skriver om seg selv. p_retrieved_content er påkrevd; en versjon uten fingeravtrykk kvalifiserer ikke som verifiserbart grunnlag (§74.32). p_representation sier hva slags representasjon som ble hentet (EVIDENCE_PIPELINE.md §13) og er valgfri utad, men en kildeversjon uten den kan ikke bære en agentekstraksjon (migrasjon 005v). Erstatter signaturen fra migrasjon 007f, som er sluppet: en overload ville latt klienten og ikke kontrakten avgjøre hvilken funksjon PostgREST kaller. Auditraden skrives av triggeren på tabellen, i samme transaksjon. SECURITY DEFINER fordi knowledge.source_versions, workflow.user_roles og provenance.actors har RLS med default deny for authenticated; tomt search_path, og kalleren valideres på funksjonens eget kall (§50). Ingen feltvalidering er duplisert her: constraintene på knowledge.source_versions er fasiten, og deres avvisninger propageres uendret.';

revoke execute on function api.create_source_version(
  uuid, timestamptz, text, text, text, text, text
) from public;
grant execute on function api.create_source_version(
  uuid, timestamptz, text, text, text, text, text
) to authenticated;

-- ----------------------------------------------------------------------------
-- Kolonnekommentaren som navngir signaturen, oppdatert
--
-- knowledge.source_versions.content_hash sin kommentar navngir skriveveien med
-- full signatur, og den signaturen finnes ikke lenger. En kommentar som navngir
-- en funksjon som ikke finnes, er nettopp det vakten i
-- supabase/tests/280_content_hash_serialization_test.sql fanger. Innholdet er
-- ordrett det samme; bare signaturen er den nye.
-- ----------------------------------------------------------------------------
comment on column knowledge.source_versions.content_hash is
  'sha256 av innholdet som ble hentet, med algoritmen som prefiks. Beregnet av databasen selv når raden skrives gjennom api.create_source_version(uuid, timestamptz, text, text, text, text, text): hashen er aldri en verdi en klient oppgir, og kan derfor ikke være en garanti uten dekning. NULL betyr at det ikke ble hashet noe øyeblikksbilde — mulig for de seedede radene fra migrasjon 003, men ikke gjennom skriveveien. Uten hash er raden et sporet besøk og ikke en etterprøvbar representasjon (MVP_IMPLEMENTATION_PLAN.md §74.32).';
