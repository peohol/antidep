-- ============================================================================
-- Migrasjon 005l — dekningskontrollen må kunne kjøre der den faktisk kjører
--
-- Migrasjon 005j la dekningskontrollen på workflow.claim_verifications som en
-- `constraint trigger ... deferrable initially deferred`. Utsettelsen er riktig
-- og nødvendig — kontrollradene finnes ikke ennå når moderraden settes inn — men
-- den har en konsekvens funksjonene ikke tok høyde for:
--
--   **En utsatt trigger kjører ved commit, og da er SECURITY DEFINER-konteksten
--   forlatt.**
--
-- api.register_claim_verification(...) er SECURITY DEFINER, så alt den gjør,
-- gjør den som funksjonens eier. Den utsatte kontrollen kjører derimot ikke
-- inne i kallet: den kjører når transaksjonen commiter, og da er den effektive
-- brukeren igjen den som gjorde forespørselen — `anon` for en agentkjører uten
-- brukerkonto (§74.31). `anon` har ingen `usage` på schemaet `workflow`
-- (migrasjon 001, og det skal den ikke ha), så kontrollen feilet med
-- «permission denied for schema workflow» — etter at hele operasjonen ellers
-- var utført.
--
-- Feilen er avlest og ikke resonnert: den slo ut første gang kjøreren ble kjørt
-- mot det hostede prosjektet, på nøyaktig det kallet. Den kunne ikke slått ut i
-- databasetestene, fordi de avsluttes med `rollback` og en utsatt trigger aldri
-- kjører i en transaksjon som rulles tilbake. Testen som nå dekker den, tvinger
-- kontrollen fram med `set constraints all immediate` *mens rollen er `anon`*,
-- som er den samme situasjonen commit ville gitt.
--
-- ----------------------------------------------------------------------------
-- Rettelsen, og hvorfor den er trygg
--
-- Begge funksjonene blir SECURITY DEFINER. Det er den samme begrunnelsen
-- workflow.enforce_reviewer_qualification() (migrasjon 005) og
-- workflow.set_review_evidence_set_digest() (migrasjon 006) har: de leser bare,
-- validerer bare, og returnerer ingen data. En kaller som utløser kontrollen,
-- får ikke se en eneste rad den leser — den kan bare passere eller bli avvist,
-- og avvisningen navngir bare id-er kalleren allerede oppga.
--
-- Ingen ny rettighet følger av dette: EXECUTE er fortsatt revokert fra PUBLIC på
-- begge, og ingen klientrolle har fått EXECUTE på noen av dem. Den eneste veien
-- inn i kontrollen er å faktisk sette inn en rad i workflow.claim_verifications,
-- og den veien er uendret.
--
-- ----------------------------------------------------------------------------
-- Fremover-skrivende, ikke en retusjert linje i 005j
--
-- Migrasjon 20260908092000 er allerede kjørt i det hostede prosjektet, og
-- Supabase kjører aldri en registrert migrasjonsversjon på nytt (§74.32). En
-- endring i den filen ville derfor bare nådd et miljø som starter fra bunnen —
-- altså CI, og ikke produksjon. Rettelsen ligger her, som en
-- `create or replace function` som bytter kroppen og sikkerhetsmodusen uten å
-- endre signatur, eier eller rettigheter. Triggeren peker på funksjonen ved navn
-- og trenger ikke opprettes på nytt.
-- ============================================================================

create or replace function workflow.assert_claim_verification_complete(p_claim_verification_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_revision_id uuid;
  v_outcome workflow.verification_outcome;
  v_source_access workflow.verification_source_access;
  v_citations integer;
  v_uncovered text;
  v_weakest workflow.verification_source_access;
  v_offending text;
begin
  select cv.claim_revision_id, cv.outcome, cv.source_access
    into v_revision_id, v_outcome, v_source_access
  from workflow.claim_verifications cv
  where cv.id = p_claim_verification_id;

  if not found then
    return;
  end if;

  select count(*) into v_citations
  from workflow.claim_verification_citations c
  where c.claim_verification_id = p_claim_verification_id;

  if v_citations = 0 then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Claim-verifikasjon %L oppgir ikke hvilke evidenslenker den kontrollerte.',
        p_claim_verification_id
      ),
      hint = 'En kontroll av en påstand er en kontroll mot et bestemt grunnlag. Registrer én rad i workflow.claim_verification_citations per evidenslenke på revisjonen (ANTIDEP_CONSTITUTION.md §4, §11).';
  end if;

  select string_agg(distinct l.id::text, ', ' order by l.id::text)
    into v_uncovered
  from knowledge.claim_evidence_links l
  where l.claim_revision_id = v_revision_id
    and not exists (
      select 1
      from workflow.claim_verification_citations c
      where c.claim_verification_id = p_claim_verification_id
        and c.claim_evidence_link_id = l.id
    );

  if v_uncovered is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Evidenslenker som ikke er kontrollert: %s.', v_uncovered),
      hint = 'Kontrollen skal dekke hele evidenssettet til revisjonen, også lenkene som motsier påstanden (ANTIDEP_CONSTITUTION.md §9). En kontroll som hoppet over en lenke, har ikke sett det som kunne felt påstanden.';
  end if;

  if v_outcome = 'verified' then
    select string_agg(distinct c.claim_evidence_link_id::text, ', '
                      order by c.claim_evidence_link_id::text)
      into v_offending
    from workflow.claim_verification_citations c
    where c.claim_verification_id = p_claim_verification_id
      and c.relationship_supported <> 'ok';

    if v_offending is not null then
      raise exception using
        errcode = 'restrict_violation',
        message = format(
          'En bekreftet claim-verifikasjon kan ikke ha uavklarte eller avvikende evidenslenker: %s.',
          v_offending
        ),
        hint = 'Samme regel som for de sju kontrollpunktene: et punkt som ikke lot seg bedømme er ikke et bestått punkt (ANTIDEP_CONSTITUTION.md §6, §11). Registrer utfallet som uncertain eller needs_correction.';
    end if;
  end if;

  select c.source_access into v_weakest
  from workflow.claim_verification_citations c
  where c.claim_verification_id = p_claim_verification_id
  order by workflow.source_access_strength(c.source_access), c.source_access
  limit 1;

  if v_weakest is distinct from v_source_access then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Claim-verifikasjonens kildetilgang er %L, men den svakeste kontrollerte lenken har %L.',
        v_source_access, v_weakest
      ),
      hint = 'Den samlede kildetilgangen er den svakeste av lenkenes, ikke den sterkeste. Ellers ville en bekreftelse kunnet hvile på en lenke der verifikatoren bare hadde et sammendrag (ANTIDEP_CONSTITUTION.md §11).';
  end if;
end;
$$;

comment on function workflow.assert_claim_verification_complete(uuid) is
  'Kontrollerer at en claim-verifikasjon dekker hele evidenssettet til revisjonen, at en bekreftelse ikke har uavklarte eller avvikende lenker under seg, og at radens kildetilgang er den svakeste av lenkenes (ANTIDEP_CONSTITUTION.md §4, §9, §11). Kalles to steder: av den utsatte constraint-triggeren claim_verifications_assert_complete ved commit, som er garantien uansett hvordan raden kom dit, og direkte av api.register_claim_verification(text, text, uuid, uuid, text, text, text, text, text, text, text, text, jsonb, text, text), slik at skriveveien avviser umiddelbart og kan prøves i en transaksjon som rulles tilbake. SECURITY DEFINER fordi den utsatte triggeren kjører ved commit, altså etter at SECURITY DEFINER-konteksten i skriveveien er forlatt: den effektive brukeren er da klientrollen, som ikke har og ikke skal ha usage på workflow (migrasjon 005l). Funksjonen leser bare, validerer bare, og returnerer ingen data — samme begrunnelse som workflow.enforce_reviewer_qualification().';

revoke execute on function workflow.assert_claim_verification_complete(uuid) from public;

create or replace function workflow.assert_claim_verification_complete_trigger()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  perform workflow.assert_claim_verification_complete(new.id);
  return null;
end;
$$;

comment on function workflow.assert_claim_verification_complete_trigger() is
  'Triggerinnpakningen rundt workflow.assert_claim_verification_complete(uuid). Egen funksjon fordi regelen også kalles direkte fra skriveveien, og en regel skrevet to ganger er en regel som kan komme i utakt. SECURITY DEFINER av samme grunn som funksjonen den kaller: en utsatt constraint-trigger kjører ved commit, som klientrollen, og ville ellers manglet usage på schemaet den leser i (migrasjon 005l).';

revoke execute on function workflow.assert_claim_verification_complete_trigger() from public;
