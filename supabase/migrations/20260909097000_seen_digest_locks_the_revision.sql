-- ============================================================================
-- Migrasjon 006f — kontrollen av «det du faktisk så» tar låsen selv
--
-- Migrasjon 005n innførte workflow.assert_evidence_set_unchanged(uuid, text):
-- de menneskelige skriveveiene skal registrere en vurdering av nøyaktig det
-- evidenssettet revieweren så. Kontrollen sammenlignet, men tok ingen lås — og
-- avtrykket som faktisk lagres, beregnes senere, av triggeren på raden
-- (workflow.set_review_evidence_set_digest() fra migrasjon 006 og
-- workflow.set_claim_verification_evidence_set_digest() fra 005j). Begge
-- triggerne tar FOR UPDATE på revisjonen før de beregner, men den låsen
-- beskytter bare beregningen — ikke gapet mellom kontrollen og den.
--
-- Vinduet var reelt:
--
--   1. Revieweren har sett evidenssett A og sender avtrykket av A.
--   2. assert_evidence_set_unchanged(...) sammenligner mot A og passerer. Ingen
--      lås holdes.
--   3. En annen transaksjon rekker å legge til evidenslenke B og commite.
--   4. INSERT-en når triggeren, tar låsen, og beregner avtrykket på A+B.
--   5. Beslutningen lagres som om den gjaldt A+B — og publiseringsgatens G13 og
--      G9b passerer siden, fordi det lagrede avtrykket allerede inneholder den
--      lenken revieweren aldri så.
--
-- Det er nøyaktig luken p_seen_evidence_set_digest finnes for å lukke
-- (ANTIDEP_CONSTITUTION.md §9, KNOWLEDGE_MODEL.md §19.2). Funnet i teknisk
-- review av PR #59.
--
-- ----------------------------------------------------------------------------
-- Rettelsen: én atomisk grense
--
-- Låsen tas nå *før* sammenligningen, i den samme funksjonen, og holdes ut
-- transaksjonen. Da er kontrollen og den senere beregningen på innsiden av den
-- samme låsen, og de to mulige rekkefølgene er begge riktige:
--
--   Kontrollen først  Lenken må vente til beslutningen er ferdig. Avtrykket som
--                     lagres, er det revieweren så.
--   Lenken først      Kontrollen får det nye settet og avviser registreringen
--                     som utdatert, med den samme setningen som før.
--
-- Serialiseringen er ikke ny logikk: hver innsetting i
-- knowledge.claim_evidence_links tar allerede FOR UPDATE på nøyaktig den samme
-- raden, i knowledge.reject_evidence_link_after_assessment() (migrasjon 004) og
-- knowledge.reject_evidence_link_after_publication() (migrasjon 006). Denne
-- migrasjonen legger seg på den eksisterende låsen framfor å innføre en ny
-- mekanisme. Merk avhengigheten: forsvinner de triggerne, forsvinner
-- serialiseringen med dem.
--
-- Låserekkefølge: funksjonen tar bare revisjonslåsen, som første handling i
-- skriveveien. Publiseringsfunksjonene tar påstand og deretter revisjon; ingen
-- kodevei tar dem i motsatt rekkefølge, så låsene kan ikke danne en syklus.
--
-- ----------------------------------------------------------------------------
-- Funksjonen kan ikke lenger være STABLE
--
-- PostgreSQL tillater ikke SELECT ... FOR UPDATE i en ikke-VOLATILE funksjon.
-- Merkelappen er derfor tatt bort, og det er en fordel: skulle noen sette den
-- tilbake til STABLE, feiler funksjonen ved kjøring framfor å miste låsen i
-- stillhet.
--
-- Fremover-skrivende: ingen kjørt migrasjon er redigert.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §9, §11, §12
--   docs/DATABASE_ARCHITECTURE.md §30, §31, §38, §50, §59, §60
--   docs/KNOWLEDGE_MODEL.md §19.2
--   docs/MVP_IMPLEMENTATION_PLAN.md §42, §74.36
-- ============================================================================

create or replace function workflow.assert_evidence_set_unchanged(
  p_claim_revision_id uuid,
  p_seen_evidence_set_digest text
)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_current text;
begin
  -- Låsen først, sammenligningen etterpå, og låsen holdes ut transaksjonen.
  -- Uten den rekkefølgen er kontrollen bare et øyeblikksbilde: en lenke kunne
  -- commite mellom sammenligningen og innsettingen, og avtrykket som lagres —
  -- beregnet av triggeren på raden — ville beskrevet et sett revieweren aldri
  -- så (migrasjon 006f).
  perform 1
  from knowledge.claim_revisions r
  where r.id = p_claim_revision_id
  for update;

  v_current := knowledge.claim_evidence_set_digest(p_claim_revision_id);

  if v_current is distinct from p_seen_evidence_set_digest then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Evidensgrunnlaget er endret etter at du hentet det fram.',
      hint = 'Vurderingen din gjelder det evidenssettet du faktisk så. Hent revisjonen fram på nytt, gå gjennom det som er kommet til, og registrer vurderingen på det fullstendige grunnlaget (ANTIDEP_CONSTITUTION.md §9, KNOWLEDGE_MODEL.md §19.2).';
  end if;
end;
$$;

comment on function workflow.assert_evidence_set_unchanged(uuid, text) is
  'Krever at evidenssettet til en påstandsrevisjon fortsatt er det kalleren oppgir å ha sett (knowledge.claim_evidence_set_digest). Brukes av de menneskelige skriveveiene, der det går tid mellom å lese grunnlaget og å konkludere: en lenke som kommer til i det vinduet, ville ellers blitt stilltiende dekket av en vurdering som aldri så den (ANTIDEP_CONSTITUTION.md §9). Funksjonen tar FOR UPDATE på revisjonsraden før den sammenligner, og holder låsen ut transaksjonen (migrasjon 006f). Uten det var kontrollen bare et øyeblikksbilde: avtrykket som faktisk lagres, beregnes senere av triggeren på raden, og en lenke som commitet i mellomtiden ville blitt en del av det lagrede avtrykket — og dermed passert både G9b og G13 uten at noe menneske hadde sett den. Låsen er den samme raden hver innsetting i knowledge.claim_evidence_links allerede låser, så de to serialiseres mot hverandre uten ny mekanisme. Funksjonen er derfor VOLATILE: PostgreSQL tillater ikke SELECT ... FOR UPDATE i en ikke-VOLATILE funksjon, og en tilbakeføring til STABLE ville feilet ved kjøring framfor å fjerne låsen i stillhet. Kommer i tillegg til publiseringsgatens G9b og G13, som er fasiten ved publisering. SECURITY DEFINER fordi evidenslenkene og revisjonene ligger bak RLS med default deny; funksjonen leser bare og returnerer ingen data.';

revoke execute on function workflow.assert_evidence_set_unchanged(uuid, text) from public;
