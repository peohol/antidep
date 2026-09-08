-- ============================================================================
-- Migrasjon 006h — publiseringen får en redaksjonell handling
--
-- knowledge.publish_claim_revision(uuid, uuid, text) har fantes siden migrasjon
-- 006 og er den kontrollerte publiseringsoperasjonen: den låser påstanden og
-- revisjonen, kontrollerer publisher-rettigheten, kjører hele publiseringsgaten,
-- flytter publiseringspekeren og registrerer hendelsen — alt i én transaksjon.
-- EXECUTE er revokert fra PUBLIC og er ikke gitt til noen klientrolle, og
-- funksjonen ligger i `knowledge`, som ikke er eksponert i Data API-et. Det
-- finnes derfor ingen vei til den fra et redaksjonelt grensesnitt.
--
-- ANTIDEP_CONSTITUTION.md §15 krever at en kvalifisert redaktør kan publisere
-- uten Claude, ChatGPT eller direkte databaseinngrep. Denne migrasjonen bygger
-- den ene veien inn, og bare den.
--
-- ----------------------------------------------------------------------------
-- Hva funksjonen IKKE gjør
--
-- Den regner ikke ut om revisjonen kan publiseres. Publiseringsgaten er fasiten,
-- og den kjøres av knowledge.publish_claim_revision(uuid, uuid, text) inne i den
-- samme transaksjonen som skriver hendelsen, etter at låsene er tatt. En
-- forhåndskontroll her ville vært en andre formulering av gaten, og den ville
-- dessuten vært verdiløs som garanti: mellom en kontroll utenfor transaksjonen
-- og selve publiseringen kan grunnlaget endre seg.
--
-- Flaten leser gatens svar gjennom api.claim_review_workspace(uuid), som kaller
-- gaten på ekte og returnerer avvisningen ordrett (migrasjon 005o/005p). Det er
-- en visning av tilstanden, ikke en beslutning om den — og det er derfor
-- fullstendig ufarlig at den kan være foreldet når knappen trykkes: gaten
-- avgjør på nytt.
--
-- ----------------------------------------------------------------------------
-- Aktøren er ikke en parameter
--
-- knowledge.publish_claim_revision(uuid, uuid, text) tar publisher-aktøren som
-- argument, fordi den er en intern operasjon som også skal kunne kalles fra en
-- framtidig administrativ vei. api-funksjonen har ingen slik parameter: aktøren
-- utledes fra den innloggede brukerens egen aktørrad. En kallerstyrt aktør ville
-- gjort attribusjonen til en påstand fra den som skriver framfor en observasjon
-- (ANTIDEP_CONSTITUTION.md §14) — og knowledge.assert_publisher_authorized(uuid,
-- uuid) ville uansett avvist enhver annen aktør enn kallerens egen.
--
-- ----------------------------------------------------------------------------
-- Godkjenning og publisering er fortsatt to handlinger og to rettigheter
--
-- Denne funksjonen registrerer ingen godkjenning og leser ingen inn. Den krever
-- `publisher` (gjennom gaten), mens godkjenningen krever `reviewer` og ligger i
-- api.register_publication_approval(uuid, text, text, text). At samme person kan
-- ha begge rollene, endrer ikke at det er to kall, to rader og to beslutninger
-- (MVP_IMPLEMENTATION_PLAN.md §16).
--
-- Auditraden skrives av triggeren på knowledge.publication_events (migrasjon
-- 008), i samme transaksjon.
--
-- ----------------------------------------------------------------------------
-- Hvorfor bare publisering, og ikke avpublisering og rollback
--
-- De to andre operasjonene finnes i `knowledge` fra migrasjon 006 og trenger
-- hver sin flate med sine egne spørsmål — avpublisering er en sikkerhetshandling
-- uten gate, og rollback peker på to revisjoner. Å eksponere alle tre her ville
-- vært å bygge tre redaksjonelle flyter i én PR uten at noen av dem er prøvd.
-- De hører til sin egen leveranse.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §12, §13, §14, §15
--   docs/CONTENT_GOVERNANCE.md §12
--   docs/DATABASE_ARCHITECTURE.md §38, §40, §43, §46, §50, §61
--   docs/MVP_IMPLEMENTATION_PLAN.md §14, §15, §16, §74.36
-- ============================================================================

create function api.publish_claim_revision(
  p_claim_revision_id uuid,
  p_reason text
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_publisher_actor_id uuid;
begin
  -- Aktøren er kallerens egen. KI-aktørene har auth_user_id NULL
  -- (actors_auth_user_is_human_check), så et treff her er alltid et menneske.
  select a.id into v_publisher_actor_id
  from provenance.actors a
  where a.auth_user_id = auth.uid();

  if v_publisher_actor_id is null then
    raise exception using
      errcode = 'insufficient_privilege',
      message = 'Kontoen din er ikke knyttet til en aktør i Antidep.',
      hint = 'En publisering skal attribueres til en navngitt person (ANTIDEP_CONSTITUTION.md §14). En kaller uten aktørrad kan ikke publisere i sitt eget navn. Ta kontakt med en administrator for å få kontoen din knyttet til en aktør.';
  end if;

  -- Alt annet — at aktøren ikke er tilbaketrukket, at den innloggede brukeren er
  -- nettopp den aktøren, at publisher-rollen er gyldig på setningens eget
  -- tidspunkt, og hele publiseringsgaten — avgjøres av
  -- knowledge.publish_claim_revision(uuid, uuid, text), inne i den transaksjonen
  -- som skriver hendelsen. Ingen av de kontrollene er gjentatt her: en kopi ville
  -- kunnet komme i utakt med originalen, og en forhåndskontroll utenfor låsene
  -- ville uansett ikke vært en garanti.
  return knowledge.publish_claim_revision(
    p_claim_revision_id, v_publisher_actor_id, p_reason
  );
end;
$$;

comment on function api.publish_claim_revision(uuid, text) is
  'Den redaksjonelle handlingen som publiserer én påstandsrevisjon (ANTIDEP_CONSTITUTION.md §13, §15, MVP_IMPLEMENTATION_PLAN.md §14, §15). Den eneste veien fra et grensesnitt inn i knowledge.publish_claim_revision(uuid, uuid, text), som er og forblir den kontrollerte operasjonen: den låser påstanden og deretter revisjonen, kontrollerer publisher-rettigheten (knowledge.assert_publisher_authorized(uuid, uuid)), kjører hele publiseringsgaten (knowledge.assert_claim_revision_publishable(uuid)), flytter publiseringspekeren og registrerer hendelsen — alt i én transaksjon som enten lykkes fullstendig eller ikke endrer noe. Registrerer publish når ingenting var publisert og replace ellers. Ingen del av gaten er gjentatt her: en andre formulering kunne sagt «klar» om noe gaten stenger, og en kontroll utenfor transaksjonens låser ville uansett ikke vært en garanti. Publisher-aktøren er ikke en parameter — den utledes fra den innloggede brukerens egen aktørrad, slik at attribusjonen er en observasjon og ikke en påstand fra den som skriver (§14). Krever publisher-rollen, som er en annen rettighet enn reviewer: å godkjenne og å publisere er to forskjellige handlinger med hver sin rad og hvert sitt kall (§16). Auditraden skrives av triggeren på knowledge.publication_events, i samme transaksjon. SECURITY DEFINER fordi knowledge, workflow og provenance har RLS med default deny; tomt search_path, og kalleren autoriseres på funksjonens eget kall (DATABASE_ARCHITECTURE.md §50). EXECUTE gis bare til authenticated: en uinnlogget kaller har ingen aktør og kan ikke ha en publisher-rolle.';

revoke execute on function api.publish_claim_revision(uuid, text) from public;
grant execute on function api.publish_claim_revision(uuid, text) to authenticated;
