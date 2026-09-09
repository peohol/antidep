-- ============================================================================
-- Migrasjon 006i — «gjeldende beslutning» avgjøres av registreringsrekkefølgen
--
-- ----------------------------------------------------------------------------
-- Hullet
--
-- Migrasjon 005å lukket det samme hullet på de to verifikasjonstabellene, og
-- navnga samtidig det som stod igjen: workflow.review_decisions har nøyaktig
-- samme form på «den gjeldende beslutningen», og dermed samme svakhet.
--
-- Beslutningen hentes overalt med
--
--   order by rd.decided_at desc, rd.created_at desc, rd.id desc
--
-- og decided_at settes med now(), som i PostgreSQL er *transaksjonens
-- starttidspunkt* — ikke tidspunktet raden faktisk ble skrevet. To samtidige
-- registreringer kan derfor starte i én rekkefølge og skrive i den motsatte:
--
--   Transaksjon A   begynner (now() = 10:00:00), gjør noe annet en stund.
--   Transaksjon B   begynner (now() = 10:00:05), tar radlåsen, skriver
--                   `approved`, og commiter.
--   Transaksjon A   tar radlåsen etterpå, skriver `rejected`, commiter.
--
-- Raden som faktisk ble skrevet sist, bærer det eldste tidsstempelet. Sortert
-- på klokka blir B den gjeldende, og A — en reell avvisning, tatt på det samme
-- grunnlaget — forsvinner bak en godkjenning som ble skrevet før den.
-- Publiseringsgatens G12 ville lest godkjenningen som gjeldende og sluppet
-- gjennom en publisering avvisningen skulle ha stoppet. Retningen er verre enn
-- på verifikasjonstabellene: der kunne et avvik forsvinne, her kan et menneskes
-- nei forsvinne.
--
-- Den samme formen finnes i den andre retningen, på tilbaketrekkingen av en
-- ekstraksjon: en `extraction_withdrawn` skrevet sist kunne forsvinne bak en
-- `extraction_upheld` skrevet før den, og et underkjent evidensfunn ville stått
-- som gyldig evidens i den publiserte lesemodellen.
--
-- Innsettingen er allerede serialisert for publiseringsgodkjenninger:
-- workflow.set_review_evidence_set_digest() tar `for update` på
-- påstandsrevisjonen. Låsen serialiserer skrivingene korrekt; det er
-- *rekkefølgen de leses i* som ikke følger den. Tidsstemplene er riktige som
-- opplysninger om når beslutningen ble tatt, og beholdes uendret — decided_at
-- er dessuten det rollekontrollen leser, og skal fortsatt være det. De er bare
-- ikke en fasit for rekkefølge.
--
-- ----------------------------------------------------------------------------
-- Rettingen
--
-- Hver beslutningsrad får et registreringsnummer fra en sekvens, tildelt *etter*
-- at radlåsen på objektet er tatt. Låsen holdes ut transaksjonen, så to
-- registreringer som rører det samme objektet, får numrene sine i nøyaktig den
-- rekkefølgen de skriver i.
--
-- Låsen tas for begge review_type-variantene, og ikke bare for den ene der en
-- annen trigger allerede tar den:
--
--   publication_approval   låser knowledge.claim_revisions
--   extraction_withdrawal  låser knowledge.evidence_items
--
-- Begge trenger en entydig «gjeldende» beslutning, og begge leses av
-- publiseringsgaten. En variant uten lås ville hatt nummeret uten garantien.
-- Peker beslutningen på ingenting, avvises den framfor å få et nummer som ikke
-- betyr noe; en framtidig objekttype må ta stilling til sin egen lås.
--
-- Alle aktive lesere av «den gjeldende beslutningen» bytter til nummeret i den
-- samme migrasjonen. Å bytte dem hver for seg ville betydd at gaten og flaten
-- kunne svare forskjellig i mellomtiden:
--
--   knowledge.assert_claim_revision_publishable          G11, G12
--   knowledge.assert_claim_revision_ready_for_approval   G6
--   knowledge.set_publication_approval_decided_at        frysingen på hendelsen
--   api.claim_review_workspace                           reviewerens kø
--   workflow.claim_review_history                        reviewerflaten
--   api.published_claims                                 withdrawn_evidence_count
--   api.published_claim_evidence                         extraction_withdrawn
--
-- De to siste er den publiserte lesemodellen, og er grunnen til at rettingen
-- ikke ble gjort i migrasjon 005å: den mest sikkerhetsfølsomme flaten i basen
-- fortjener å bli endret i en migrasjon som handler om den, ikke som et avsnitt
-- til i en som allerede var stor.
--
-- Ingen regel er myket opp. Ingen CHECK, constraint, trigger, policy eller grant
-- er fjernet eller svekket, og ingen ny tabelltilgang er gitt. Kolonnen føyer
-- seg inn under det tabellvide lesegrantet review_decisions allerede har, og
-- radpolicyen som avgrenser klientroller til extraction_withdrawal er uendret.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Sekvensen og kolonnen
--
-- `cache 1` er en del av garantien, ikke en ytelsesdetalj: en bufret sekvens
-- deler ut blokker per økt, og to økter kunne da fått numre i motsatt rekkefølge
-- av skrivingene — nøyaktig det denne migrasjonen finnes for å hindre.
--
-- Ingen DEFAULT, med vilje: en default evalueres før BEFORE-triggerne fyrer,
-- altså før radlåsen er tatt.
-- ----------------------------------------------------------------------------
create sequence workflow.review_decision_registration_seq
  as bigint start with 1 increment by 1 no cycle cache 1;

revoke all on sequence workflow.review_decision_registration_seq from public;

comment on sequence workflow.review_decision_registration_seq is
  'Kilden til registreringsnummeret på workflow.review_decisions. cache 1 er en del av garantien: en bufret sekvens deler ut blokker per økt, og to økter kunne da fått numre i motsatt rekkefølge av skrivingene — nøyaktig det migrasjon 006i lukker. Hull i rekken er uten betydning; en tilbakerullet transaksjon har ikke skrevet noen rad.';

alter table workflow.review_decisions add column registration_ordinal bigint;

alter sequence workflow.review_decision_registration_seq
  owned by workflow.review_decisions.registration_ordinal;

-- ----------------------------------------------------------------------------
-- 2. De historiske radene
--
-- Rekkefølgen de eksisterende radene faktisk ble skrevet i, finnes ikke lenger.
-- (decided_at, created_at, id) er den beste tilgjengelige tilnærmingen, og er
-- riktig for alt som er skrevet sekvensielt — som alt som finnes nå, er.
-- Nummereringen endrer ikke hvilken rad som er den gjeldende for noen av dem.
--
-- Append-only-triggeren slås av for backfillen og på igjen etterpå. Alternativet
-- ville vært å myke opp regelen, og den skal ikke mykes opp.
-- ----------------------------------------------------------------------------
alter table workflow.review_decisions disable trigger review_decisions_reject_mutation;

with ordered as (
  select id, row_number() over (order by decided_at, created_at, id) as n
  from workflow.review_decisions
)
update workflow.review_decisions rd
set registration_ordinal = ordered.n
from ordered
where ordered.id = rd.id;

alter table workflow.review_decisions enable trigger review_decisions_reject_mutation;

select setval(
  'workflow.review_decision_registration_seq',
  coalesce((select max(registration_ordinal) from workflow.review_decisions), 0) + 1,
  false
);

-- ----------------------------------------------------------------------------
-- 3. Kontrakten
--
-- NOT NULL og UNIQUE står sammen: uten NOT NULL kunne en rad uten nummer bli
-- usynlig for enhver `order by registration_ordinal desc`, og uten UNIQUE kunne
-- to rader dele plass og gjøre «den siste» tvetydig igjen.
-- ----------------------------------------------------------------------------
alter table workflow.review_decisions
  alter column registration_ordinal set not null,
  add constraint review_decisions_registration_ordinal_key
    unique (registration_ordinal);

comment on column workflow.review_decisions.registration_ordinal is
  'Rekkefølgen beslutningen ble registrert i, tildelt av databasen fra en sekvens etter at radlåsen på objektet beslutningen gjelder er tatt (migrasjon 006i). Fasiten for «senere» og «gjeldende» overalt: publiseringsgatens G6, G11 og G12, frysingen av godkjenningstidspunktet på publiseringshendelsen, reviewerflaten og den publiserte lesemodellens withdrawn_evidence_count og extraction_withdrawn leser alle den samme nøkkelen. decided_at kan ikke brukes til det, fordi now() er transaksjonens starttidspunkt: to samtidige registreringer kan starte i én rekkefølge og skrive i den motsatte, og et menneskes avvisning ville da kunnet gjemme seg bak en godkjenning som ble skrevet før den. Ikke en parameter: triggeren overskriver enhver oppgitt verdi, av samme grunn som approved_evidence_set_digest ikke er det.';

-- ----------------------------------------------------------------------------
-- 4. Nummeret tildeles på innsiden av radlåsen
--
-- Triggernavnet er valgt slik at den fyrer etter
-- review_decisions_set_evidence_set_digest; rekkefølgen er alfabetisk, og de to
-- er uavhengige av hverandre. Låsen tas her uansett, og ikke i tillit til den
-- andre triggeren: for extraction_withdrawal tar den ingen lås i det hele tatt,
-- og en garanti som hviler på en annen triggers navn er ingen garanti.
-- ----------------------------------------------------------------------------
create function workflow.set_review_decision_registration_ordinal()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  -- Låsen først, nummeret etterpå, og låsen holdes ut transaksjonen. Rekkefølgen
  -- er hele poenget: tildeles nummeret før låsen, kan to registreringer få dem i
  -- motsatt rekkefølge av skrivingene.
  --
  -- review_decisions_single_object_check garanterer at nøyaktig én peker er
  -- satt, og den CHECK-en er fasiten for hvilke rader som kan finnes. En rad
  -- uten objektpeker avvises derfor av den, ikke av en RAISE her: en trigger som
  -- rakk å avvise først, ville byttet ut constraintens egen avvisning med en
  -- annen SQLSTATE og gjort det uklart hvilken regel som faktisk sviktet.
  --
  -- Nummeret tildeles likevel i det tilfellet, slik at raden ikke i stedet
  -- feiler på NOT NULL. Sekvenshullet er uten betydning: raden blir ikke til.
  -- At det bare finnes to objekttyper å låse, er en påstand pgTAP 610 holder
  -- fast — en tredje peker må ta stilling til sin egen lås her.
  if new.claim_revision_id is not null then
    perform 1
    from knowledge.claim_revisions r
    where r.id = new.claim_revision_id
    for update;
  elsif new.evidence_item_id is not null then
    perform 1
    from knowledge.evidence_items e
    where e.id = new.evidence_item_id
    for update;
  end if;

  new.registration_ordinal :=
    nextval('workflow.review_decision_registration_seq');

  return new;
end;
$$;

comment on function workflow.set_review_decision_registration_ordinal() is
  'Gir databasen eierskap til registreringsrekkefølgen på en reviewbeslutning, og tildeler nummeret på innsiden av radlåsen på objektet beslutningen gjelder — påstandsrevisjonen ved en publiseringsgodkjenning, evidensfunnet ved en tilbaketrekking av en ekstraksjon — slik at det følger den rekkefølgen radene faktisk skrives i (migrasjon 006i). Begge variantene låses, og ikke bare den ene workflow.set_review_evidence_set_digest() allerede låser: begge trenger en entydig gjeldende beslutning, og en garanti som hviler på en annen triggers navn er ingen garanti. Funksjonen avviser ingenting: en rad uten objektpeker er review_decisions_single_object_check sin avvisning, og den skal være den kalleren ser. Overskriver enhver verdi kalleren måtte ha oppgitt: en verdi kalleren kunne valgt, ville vært nøyaktig den påstanden kolonnen finnes for å binde. SECURITY DEFINER fordi knowledge har RLS med default deny; funksjonen leser bare og skriver bare til raden som settes inn.';

revoke execute on function workflow.set_review_decision_registration_ordinal() from public;

create trigger review_decisions_set_registration_ordinal
  before insert on workflow.review_decisions
  for each row execute function workflow.set_review_decision_registration_ordinal();

-- ----------------------------------------------------------------------------
-- 5. Leserne
--
-- Alle sju bytter samtidig. Innholdet er ellers ordrett som før: samme vilkår i
-- samme rekkefølge, samme SQLSTATE, setning og hint på hver avvisning, samme
-- kolonner i samme rekkefølge i de to viewene.
-- ----------------------------------------------------------------------------
-- --------------------------------------------------------------------------
-- 5.1 Publiseringsgatens G1 til G10 — G6 leser den gjeldende tilbaketrekkingen
--
-- Uendret fra migrasjon 005å bortsett fra ett uttrykk: G6 spør fortsatt om den
-- siste beslutningen av typen extraction_withdrawal for hvert lenket
-- evidensfunn, men «siste» leses nå av registreringsrekkefølgen.
-- --------------------------------------------------------------------------
create or replace function knowledge.assert_claim_revision_ready_for_approval(p_claim_revision_id uuid)
  returns void
  language plpgsql
  set search_path = ''
as $$
declare
  v_claim_id uuid;
  v_knowledge_type knowledge.knowledge_type;
  v_retired_at timestamptz;
  v_offenders text;
  v_claim_verification_outcome workflow.verification_outcome;
  v_claim_verifier_actor_id uuid;
  v_claim_verified_at timestamptz;
  v_claim_verified_digest text;
begin
  -- G1: revisjonen finnes.
  select r.claim_id, r.knowledge_type, c.retired_at
    into v_claim_id, v_knowledge_type, v_retired_at
  from knowledge.claim_revisions r
  join knowledge.claims c on c.id = r.claim_id
  where r.id = p_claim_revision_id;

  if not found then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Påstandsrevisjon %L finnes ikke.', p_claim_revision_id),
      hint = 'Publisering peker på en eksakt revisjon, ikke på påstandsidentiteten (KNOWLEDGE_MODEL.md §19.3). Kontroller revisjons-ID-en.';
  end if;

  -- G2: påstanden er ikke trukket tilbake.
  if v_retired_at is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Påstanden bak revisjon %L er trukket tilbake og kan ikke publiseres.',
        p_claim_revision_id
      ),
      hint = 'En tilbaketrukket påstand er tatt ut av bruk. Opprett en ny påstand dersom temaet fortsatt skal dekkes; historikken til den gamle bevares (DATABASE_ARCHITECTURE.md §36).';
  end if;

  -- G3: nødvendige EvidenceItems finnes.
  -- ANTIDEP_CONSTITUTION.md §4: ingen publisert klinisk relevant påstand skal
  -- eksistere uten eksplisitt kobling til én eller flere identifiserbare kilder.
  -- Kravet gjelder alle tre kunnskapstypene; også et deterministisk faktum skal
  -- kunne spores til kilden sin.
  if not exists (
    select 1
    from knowledge.claim_evidence_links l
    where l.claim_revision_id = p_claim_revision_id
  ) then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Revisjon %L har ingen registrerte evidenslenker og kan ikke publiseres.',
        p_claim_revision_id
      ),
      hint = 'Registrer minst ett evidensfunn med en begrunnet relasjon til revisjonen. En publisert påstand uten kobling til en identifiserbar kilde er ikke etterprøvbar (ANTIDEP_CONSTITUTION.md §4).';
  end if;

  -- G4: hvert lenket evidensfunn er faktisk kontrollert av noen.
  select string_agg(distinct l.evidence_item_id::text, ', ' order by l.evidence_item_id::text)
    into v_offenders
  from knowledge.claim_evidence_links l
  where l.claim_revision_id = p_claim_revision_id
    and not exists (
      select 1
      from workflow.evidence_verifications ev
      where ev.evidence_item_id = l.evidence_item_id
    );

  if v_offenders is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Evidensfunn uten registrert ekstraksjonsverifikasjon: %s.', v_offenders
      ),
      hint = 'En separat kontrollfase skal ha gått gjennom ekstraksjonen mot kildematerialet før påstanden publiseres (ANTIDEP_CONSTITUTION.md §11, DATABASE_ARCHITECTURE.md §29). Registrer verifikasjonen i workflow.evidence_verifications.';
  end if;

  -- G5: den gjeldende ekstraksjonsverifikasjonen bekrefter funnet.
  -- Den siste kontrollen er den gjeldende: et senere needs_correction, rejected
  -- eller uncertain er et åpent blokkerende verifikasjonsfunn, uansett hvor mange
  -- bekreftelser som ligger foran det.
  select string_agg(distinct l.evidence_item_id::text, ', ' order by l.evidence_item_id::text)
    into v_offenders
  from knowledge.claim_evidence_links l
  where l.claim_revision_id = p_claim_revision_id
    and (
      select ev.outcome
      from workflow.evidence_verifications ev
      where ev.evidence_item_id = l.evidence_item_id
      order by ev.registration_ordinal desc
      limit 1
    ) <> 'verified';

  if v_offenders is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Evidensfunn med åpent verifikasjonsfunn: %s.', v_offenders
      ),
      hint = 'Den siste registrerte ekstraksjonsverifikasjonen konkluderer ikke med verified. Rett ekstraksjonen i et nytt evidensfunn og registrer en ny kontroll; en tidligere bekreftelse opphever ikke et senere avvik.';
  end if;

  -- G5b: kontrollene dekker til sammen det raden faktisk påstår.
  --
  -- G5 leste bare `outcome`. En kontroll som *med vilje* lar felter stå
  -- ukontrollert — den deterministiske ekstraksjonsverifikatoren bedømmer
  -- verken tidspunkt, retning, effektmål, availability-semantikk eller
  -- forbehold — kunne dermed tilfredsstille en gate som er ment å bety at
  -- ekstraksjonen er kontrollert. `checked_fields` sa sannheten, men ingen
  -- leste den (DATABASE_ARCHITECTURE.md §29).
  --
  -- Regelen er uendret fra migrasjon 005i, inkludert at dekningen har samme
  -- gjeldende-semantikk som utfallet: en ikke-bekreftende kontroll nullstiller
  -- den, slik at et senere avvik ikke kan omgås av en enda senere delkontroll
  -- som aldri så på det omstridte feltet. Selve unionen står nå i
  -- workflow.covered_check_fields(uuid), fordi reviewerflaten skal vise nøyaktig
  -- den dekningen gaten krever (migrasjon 005q).
  select string_agg(distinct l.evidence_item_id::text, ', ' order by l.evidence_item_id::text)
    into v_offenders
  from knowledge.claim_evidence_links l
  where l.claim_revision_id = p_claim_revision_id
    and exists (
      select 1
      from unnest(workflow.required_check_fields(l.evidence_item_id)) as required(field)
      where required.field <> all (workflow.covered_check_fields(l.evidence_item_id))
    );

  if v_offenders is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Evidensfunn uten fullstendig kontrollert ekstraksjon: %s.', v_offenders
      ),
      hint = 'De registrerte kontrollene dekker ikke alle feltene funnet påstår noe om. workflow.required_check_fields(evidence_item_id) viser hva som kreves; en delkontroll kan ikke alene tilfredsstille publiseringsgaten (ANTIDEP_CONSTITUTION.md §11, DATABASE_ARCHITECTURE.md §29). Merk at en ikke-bekreftende kontroll nullstiller dekningen: bekreftelser som ligger foran den, teller ikke lenger.';
  end if;

  -- G5c: den gjeldende ekstraksjonskontrollen ble gjort av noen med mandat.
  --
  -- Speilbildet av G9c, og det finnes av samme grunn. Migrasjon 005q håndhever
  -- mandatet ved innsetting, og dette vilkåret er den andre lesningen av den
  -- samme regelen — den samme funksjonen, slik at de to ikke kan komme i utakt.
  -- At begge finnes, er bevisst: gaten er stedet der konsekvensen inntreffer, og
  -- en rad skrevet før regelen fantes, gjennom en senere skrivevei, eller av en
  -- vedlikeholdsoperasjon, skal ikke kunne bære en publisering fordi den slapp
  -- forbi det ene laget.
  --
  -- «Den gjeldende» er den samme raden G5 leser, hentet med den samme
  -- rekkefølgen. G4 har allerede slått fast at det finnes minst én.
  select string_agg(distinct l.evidence_item_id::text, ', ' order by l.evidence_item_id::text)
    into v_offenders
  from knowledge.claim_evidence_links l
  cross join lateral (
    select ev.verifier_actor_id, ev.verified_at
    from workflow.evidence_verifications ev
    where ev.evidence_item_id = l.evidence_item_id
    order by ev.registration_ordinal desc
    limit 1
  ) as current_check
  where l.claim_revision_id = p_claim_revision_id
    and not workflow.evidence_verifier_has_mandate(
          current_check.verifier_actor_id, l.evidence_item_id, current_check.verified_at
        );

  if v_offenders is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Evidensfunn der den gjeldende ekstraksjonskontrollen mangler mandat: %s.', v_offenders
      ),
      hint = 'Kontroll av en ekstraksjon mot kilden er et eget mandat (ANTIDEP_CONSTITUTION.md §10): en agent må ha rollen extraction_verification, og et menneske må ha hatt gyldig reviewer-rolle for endepunktet funnet rapporterer om da kontrollen ble gjort. Registrer en ny kontroll fra en aktør som har mandatet.';
  end if;

  -- G6: ingen lenket ekstraksjon er trukket tilbake.
  -- Overlevert eksplisitt fra migrasjon 005: «er dette evidensfunnet trukket
  -- tilbake?» er ikke en statuskolonne, men en avledet tilstand — den siste
  -- beslutningen av typen extraction_withdrawal for funnet.
  select string_agg(distinct l.evidence_item_id::text, ', ' order by l.evidence_item_id::text)
    into v_offenders
  from knowledge.claim_evidence_links l
  where l.claim_revision_id = p_claim_revision_id
    and (
      select rd.decision
      from workflow.review_decisions rd
      where rd.evidence_item_id = l.evidence_item_id
        and rd.review_type = 'extraction_withdrawal'
      order by rd.registration_ordinal desc
      limit 1
    ) = 'extraction_withdrawn';

  if v_offenders is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Evidensfunn med tilbaketrukket ekstraksjon: %s.', v_offenders
      ),
      hint = 'En tilbaketrukket ekstraksjon skal ikke bære en publisert påstand. Opprett en ny revisjon uten det tilbaketrukne funnet, eller registrer en ny beslutning som opprettholder ekstraksjonen dersom tilbaketrekkingen var feil (DATABASE_ARCHITECTURE.md §29).';
  end if;

  -- G7: ingen lenket kilde er trukket tilbake eller tilbakekalt.
  -- DATABASE_ARCHITECTURE.md §58, siste kulepunkt: en withdrawn eller retracted
  -- kilde skal ikke ubemerket tilfredsstille en gate som om statusen var normal.
  select string_agg(distinct s.id::text, ', ' order by s.id::text)
    into v_offenders
  from knowledge.claim_evidence_links l
  join knowledge.evidence_items e on e.id = l.evidence_item_id
  join knowledge.sources s on s.id = e.source_id
  where l.claim_revision_id = p_claim_revision_id
    and s.source_status in ('retracted', 'withdrawn');

  if v_offenders is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Kilder med statusen retracted eller withdrawn i grunnlaget: %s.', v_offenders
      ),
      hint = 'En tilbaketrukket eller tilbakekalt kilde kan ikke bære en publisert påstand. Vurder grunnlaget på nytt i en ny revisjon (DATABASE_ARCHITECTURE.md §58).';
  end if;

  -- G8: påstanden er kontrollert mot grunnlaget.
  -- DATABASE_ARCHITECTURE.md §38 sitt «ClaimEvidenceLinks er kontrollert» er
  -- nettopp claim-verifikasjonen fra §30: den kontrollerer om grunnlaget faktisk
  -- støtter ordlyden, om populasjon, komparator, tidsramme, retning og størrelse
  -- stemmer, om vesentlige forbehold mangler og om motstridende evidens er
  -- representert. Migrasjon 005 håndhever allerede at en verifikasjon ikke kan
  -- konkludere med verified uten at alle sju punktene er bedømt og holder.
  if not exists (
    select 1
    from workflow.claim_verifications cv
    where cv.claim_revision_id = p_claim_revision_id
  ) then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Revisjon %L har ingen registrert claim-verifikasjon.', p_claim_revision_id
      ),
      hint = 'En separat kontrollfase skal ha forsøkt å falsifisere påstanden mot det registrerte grunnlaget før den publiseres (ANTIDEP_CONSTITUTION.md §11, DATABASE_ARCHITECTURE.md §30). Registrer kontrollen i workflow.claim_verifications.';
  end if;

  -- G9, G9b og G9c leser alle den *gjeldende* claim-verifikasjonen, altså den
  -- siste, med samme rekkefølge G5 bruker for ekstraksjonsverifikasjonene. Den
  -- leses én gang, slik at de tre vilkårene aldri kan bli uenige om hvilken rad
  -- de snakker om.
  select cv.outcome, cv.verifier_actor_id, cv.verified_at, cv.verified_evidence_set_digest
    into v_claim_verification_outcome, v_claim_verifier_actor_id,
         v_claim_verified_at, v_claim_verified_digest
  from workflow.claim_verifications cv
  where cv.claim_revision_id = p_claim_revision_id
  order by cv.registration_ordinal desc
  limit 1;

  -- G9: den gjeldende claim-verifikasjonen bekrefter påstanden.
  if v_claim_verification_outcome <> 'verified' then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Den gjeldende claim-verifikasjonen for revisjon %L konkluderer ikke med verified.',
        p_claim_revision_id
      ),
      hint = 'Den siste registrerte kontrollen er den gjeldende. Rett påstanden i en ny revisjon og få den kontrollert på nytt; en tidligere bekreftelse opphever ikke et senere avvik.';
  end if;

  -- G9b: kontrollen gjaldt det evidenssettet som faktisk ville blitt publisert.
  --
  -- En claim-verifikasjon er en vurdering av påstanden mot et bestemt grunnlag,
  -- og migrasjon 005j gir databasen eierskap til avtrykket av det grunnlaget.
  -- Uten dette vilkåret ville sekvensen «kontroller → legg til en lenke →
  -- publiser» sluppet gjennom en bekreftelse som aldri så den nye lenken — og
  -- den lenken kan være nettopp den motstridende evidensen kontrollen skulle
  -- lete etter (ANTIDEP_CONSTITUTION.md §9, §11, KNOWLEDGE_MODEL.md §19.2).
  --
  -- Sammenligningen er på avtrykk og ikke på tidspunkter, av samme grunn som
  -- G13: now() er transaksjonens starttidspunkt og ikke committidspunktet, så en
  -- lenke kan bære en created_at foran kontrollen og likevel ha blitt synlig
  -- etter den. Avtrykket er uavhengig av rekkefølge.
  if knowledge.claim_evidence_set_digest(p_claim_revision_id)
     is distinct from v_claim_verified_digest then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Evidensgrunnlaget for revisjon %L er endret etter den gjeldende claim-verifikasjonen.',
        p_claim_revision_id
      ),
      hint = 'Kontrollen gjaldt et annet evidenssett enn det som er registrert nå, og dekker derfor ikke grunnlaget påstanden ville blitt publisert på. Registrer en ny claim-verifikasjon som dekker hele det utvidede settet (ANTIDEP_CONSTITUTION.md §4, §9).';
  end if;

  -- G9c: kontrollen ble gjort av noen med mandat til det.
  --
  -- Migrasjon 005j håndhever mandatet ved innsetting, og dette vilkåret er den
  -- andre lesningen av den samme regelen — den samme funksjonen, slik at de to
  -- ikke kan komme i utakt. At begge finnes, er bevisst: gaten er stedet der
  -- konsekvensen inntreffer, og en rad skrevet før regelen fantes, gjennom en
  -- senere skrivevei, eller av en vedlikeholdsoperasjon, skal ikke kunne bære en
  -- publisering fordi den slapp forbi det ene laget.
  --
  -- Tidspunktet er radens eget verified_at, ikke now(): en rolletildeling som
  -- senere avsluttes, opphever ikke en kontroll som var legitim da den ble
  -- gjort. Historikken består (ANTIDEP_CONSTITUTION.md §14).
  if not workflow.claim_verifier_has_mandate(
       v_claim_verifier_actor_id, p_claim_revision_id, v_claim_verified_at
     ) then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Den gjeldende claim-verifikasjonen for revisjon %L er registrert av en aktør uten mandat til å kontrollere påstanden.',
        p_claim_revision_id
      ),
      hint = 'Sitat- og kildestøtteverifikasjon er et eget mandat (ANTIDEP_CONSTITUTION.md §10): en agent må ha rollen citation_support_verification, og et menneske må ha hatt gyldig reviewer-rolle for innholdsområdet da kontrollen ble gjort. Registrer en ny kontroll fra en aktør som har mandatet.';
  end if;

  -- G10: evidensvurderingen finnes for de typene som skal ha en.
  -- ANTIDEP_CONSTITUTION.md §6: en evidensbasert syntese skal ha en eksplisitt
  -- vurdering av sikkerheten i kunnskapsgrunnlaget. Migrasjon 004 tillater ikke
  -- en vurdering på et deterministisk faktum, så kravet gjelder de to typene som
  -- kan ha en.
  if v_knowledge_type in ('evidence_synthesis', 'clinical_recommendation')
     and not exists (
       select 1
       from knowledge.evidence_assessments a
       where a.claim_revision_id = p_claim_revision_id
     ) then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Revisjon %L mangler evidensvurdering og kan ikke publiseres som %s.',
        p_claim_revision_id, v_knowledge_type
      ),
      hint = 'En evidenssyntese eller klinisk anbefaling skal ha en eksplisitt vurdering av sikkerheten i kunnskapsgrunnlaget, med de fem GRADE-domenene vurdert (ANTIDEP_CONSTITUTION.md §6). Registrer vurderingen i knowledge.evidence_assessments.';
  end if;

end;
$$;

-- --------------------------------------------------------------------------
-- 5.2 Publiseringsgaten — G11 og G12 leser den gjeldende godkjenningen
--
-- Uendret fra migrasjon 006e bortsett fra det samme uttrykket. G12 er punktet
-- issue #64 navngir: en rejected skrevet sist skal gjelde foran en approved
-- skrevet før den, også når den bærer et eldre decided_at.
-- --------------------------------------------------------------------------
create or replace function knowledge.assert_claim_revision_publishable(p_claim_revision_id uuid)
  returns void
  language plpgsql
  set search_path = ''
as $$
declare
  v_latest_decision workflow.review_outcome;
  v_approved_digest text;
begin
  -- G1 til G10: alt som skal holde før et menneske i det hele tatt kan ta
  -- stilling. De samme vilkårene, lest av den samme funksjonen, som
  -- api.register_publication_approval(uuid, text, text, text) krever før den
  -- registrerer en godkjenning (migrasjon 006e).
  perform knowledge.assert_claim_revision_ready_for_approval(p_claim_revision_id);

  -- G11: menneskelig faglig godkjenning finnes.
  select rd.decision, rd.approved_evidence_set_digest
    into v_latest_decision, v_approved_digest
  from workflow.review_decisions rd
  where rd.claim_revision_id = p_claim_revision_id
    and rd.review_type = 'publication_approval'
  order by rd.registration_ordinal desc
  limit 1;

  if not found then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Revisjon %L er ikke godkjent av en kvalifisert redaktør og kan ikke publiseres.',
        p_claim_revision_id
      ),
      hint = 'KI kan foreslå, men mennesker har det faglige ansvaret (ANTIDEP_CONSTITUTION.md §12). Registrer en publication_approval i workflow.review_decisions fra en navngitt kvalifisert redaktør.';
  end if;

  -- G12: godkjenningen er fortsatt den gjeldende beslutningen.
  if v_latest_decision <> 'approved' then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Den gjeldende reviewbeslutningen for revisjon %L er %s, ikke approved.',
        p_claim_revision_id, v_latest_decision
      ),
      hint = 'En senere beslutning gjelder foran en tidligere. Rett revisjonen slik reviewer ba om, i en ny revisjon, og be om ny godkjenning. Både godkjenningen og omgjøringen bevares (DATABASE_ARCHITECTURE.md §31).';
  end if;

  -- G13: evidensgrunnlaget er det samme som godkjenningen ble gitt for.
  -- MVP_IMPLEMENTATION_PLAN.md §42: systemet skal nekte «review av en revisjon
  -- som senere er endret uten nytt review». Selve revisjonsraden kan ikke endres
  -- — den er append-only — men betydningen av en revisjon omfatter
  -- evidensgrunnlaget den hviler på (KNOWLEDGE_MODEL.md §19.2). Et grunnlag som
  -- er endret etter at reviewer sa ja, er nettopp en endring reviewer ikke har
  -- sett.
  --
  -- Kontrollen sammenligner avtrykk, ikke tidspunkter. Begrunnelsen står i
  -- avsnitt 5: en tidssammenligning er ikke samtidighetssikker, fordi now() er
  -- transaksjonens starttidspunkt og ikke committidspunktet, og en lenke derfor
  -- kan bære en created_at foran godkjenningen selv om den ble synlig etter den.
  -- Avtrykket er uavhengig av rekkefølge: er settet et annet nå enn da
  -- beslutningen ble lagret, avvises publiseringen.
  if knowledge.claim_evidence_set_digest(p_claim_revision_id)
     is distinct from v_approved_digest then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Evidensgrunnlaget for revisjon %L er endret etter godkjenningen.',
        p_claim_revision_id
      ),
      hint = 'Godkjenningen gjelder et annet evidenssett enn det som er registrert nå, og dekker derfor ikke grunnlaget påstanden ville blitt publisert på. Opprett en ny revisjon med det fullstendige evidenssettet og be om ny godkjenning, eller registrer en ny godkjenning som dekker det utvidede grunnlaget (KNOWLEDGE_MODEL.md §19.2).';
  end if;


end;
$$;

-- --------------------------------------------------------------------------
-- 5.3 Godkjenningstidspunktet som fryses på publiseringshendelsen
--
-- Triggeren speiler G11 og G12, og må derfor lese den samme raden som dem.
-- decided_at er fortsatt *verdien* som kopieres — spørsmålet «når ble
-- beslutningen tatt?» er det decided_at svarer på. Det er bare rekkefølgen som
-- ikke lenger leses av den.
-- --------------------------------------------------------------------------
create or replace function knowledge.set_publication_approval_decided_at()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_decision workflow.review_outcome;
  v_decided_at timestamptz;
begin
  if new.revision_id is null then
    new.approval_decided_at := null;
    return new;
  end if;

  select rd.decision, rd.decided_at
    into v_decision, v_decided_at
  from workflow.review_decisions rd
  where rd.claim_revision_id = new.revision_id
    and rd.review_type = 'publication_approval'
  order by rd.registration_ordinal desc
  limit 1;

  -- Ingen godkjenning, eller en gjeldende beslutning som ikke er «approved»,
  -- gir NULL framfor en feil. Publiseringsgaten er stedet som nekter — den har
  -- feilmeldingene som navngir hva som blokkerer (G11, G12), og en trigger som
  -- også nektet ville duplisert den kontrollen på et dårligere sted.
  --
  -- Derfor er heller ikke den motsatte pairing-regelen håndhevet: en hendelse
  -- kan skrives med revisjon og uten godkjenningsdato. Den veien går bare
  -- utenom publiseringsoperasjonen, og lesemodellen behandler NULL som ukjent
  -- dato, aldri som «nylig vurdert» (ANTIDEP_CONSTITUTION.md §17).
  if v_decision is distinct from 'approved' then
    new.approval_decided_at := null;
  else
    new.approval_decided_at := v_decided_at;
  end if;

  return new;
end;
$$;

-- --------------------------------------------------------------------------
-- 5.4 Reviewerflaten — den gjeldende beslutningen og rekkefølgen den vises i
--
-- current_review_decision_id peker på den raden gaten leser, og sorteringen av
-- listen bruker den samme nøkkelen. Uten begge deler kunne flaten vist en annen
-- «gjeldende» enn den gaten stopper på.
-- --------------------------------------------------------------------------
create or replace function workflow.claim_review_history(p_claim_revision_id uuid)
  returns jsonb
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select jsonb_build_object(
    'current_claim_verification_id', (
      select cv.id
      from workflow.claim_verifications cv
      where cv.claim_revision_id = p_claim_revision_id
      order by cv.registration_ordinal desc
      limit 1
    ),
    'claim_verifications', (
      select coalesce(jsonb_agg(v order by v ->> 'sort_key' desc), '[]'::jsonb)
      from (
        select jsonb_build_object(
          'claim_verification_id', cv.id,
          'sort_key', lpad(cv.registration_ordinal::text, 20, '0'),
          'outcome', cv.outcome::text,
          'source_access', cv.source_access::text,
          'verified_at', cv.verified_at,
          'created_at', cv.created_at,
          'verifier_actor_id', cv.verifier_actor_id,
          'verifier_actor_key', va.actor_key,
          'verifier_actor_type', va.actor_type::text,
          'verifier_display_name', va.display_name,
          'agent_run_id', cv.agent_run_id,
          'verified_evidence_set_digest', cv.verified_evidence_set_digest,
          'checks', jsonb_build_object(
            'source_support', cv.source_support::text,
            'population_match', cv.population_match::text,
            'comparator_match', cv.comparator_match::text,
            'timeframe_match', cv.timeframe_match::text,
            'direction_and_magnitude', cv.direction_and_magnitude::text,
            'qualifiers_complete', cv.qualifiers_complete::text,
            'contradictory_evidence_represented', cv.contradictory_evidence_represented::text
          ),
          'findings', cv.findings,
          'rationale', cv.rationale,
          'citations', (
            select coalesce(jsonb_agg(
              jsonb_build_object(
                'claim_evidence_link_id', c.claim_evidence_link_id,
                'evidence_item_id', c.evidence_item_id,
                'source_access', c.source_access::text,
                'source_version_id', c.source_version_id,
                'checked_content_hash', c.checked_content_hash,
                'relationship_supported', c.relationship_supported::text,
                'finding', c.finding
              )
              order by c.claim_evidence_link_id::text
            ), '[]'::jsonb)
            from workflow.claim_verification_citations c
            where c.claim_verification_id = cv.id
          )
        ) as v
        from workflow.claim_verifications cv
        join provenance.actors va on va.id = cv.verifier_actor_id
        where cv.claim_revision_id = p_claim_revision_id
      ) as verifications
    ),
    'current_review_decision_id', (
      select rd.id
      from workflow.review_decisions rd
      where rd.claim_revision_id = p_claim_revision_id
        and rd.review_type = 'publication_approval'
      order by rd.registration_ordinal desc
      limit 1
    ),
    'review_decisions', (
      select coalesce(jsonb_agg(d order by d ->> 'sort_key' desc), '[]'::jsonb)
      from (
        select jsonb_build_object(
          'review_decision_id', rd.id,
          'sort_key', lpad(rd.registration_ordinal::text, 20, '0'),
          'decision', rd.decision::text,
          'decided_at', rd.decided_at,
          'created_at', rd.created_at,
          'reviewer_actor_id', rd.reviewer_actor_id,
          'reviewer_actor_key', ra.actor_key,
          'reviewer_display_name', ra.display_name,
          'rationale', rd.rationale,
          'approved_evidence_set_digest', rd.approved_evidence_set_digest
        ) as d
        from workflow.review_decisions rd
        join provenance.actors ra on ra.id = rd.reviewer_actor_id
        where rd.claim_revision_id = p_claim_revision_id
          and rd.review_type = 'publication_approval'
      ) as decisions
    ),
    'evidence_assessment', (
      select jsonb_build_object(
        'evidence_assessment_id', a.id,
        'framework', a.framework::text,
        'certainty_level', a.certainty_level::text,
        'risk_of_bias', a.risk_of_bias::text,
        'inconsistency', a.inconsistency::text,
        'indirectness', a.indirectness::text,
        'imprecision', a.imprecision::text,
        'publication_bias', a.publication_bias::text,
        'other_considerations', a.other_considerations,
        'rationale', a.rationale,
        'evidence_gap', a.evidence_gap,
        'assessed_at', a.assessed_at
      )
      from knowledge.evidence_assessments a
      where a.claim_revision_id = p_claim_revision_id
    )
  );
$$;

-- --------------------------------------------------------------------------
-- 5.5 Reviewerens kø — statusen «gjeldende beslutning» per revisjon
-- --------------------------------------------------------------------------
create or replace function api.claim_review_workspace(p_claim_revision_id uuid default null)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_reviewer_actor_id uuid;
  v_dossier jsonb;
  v_topic_concept_id uuid;
  v_gate jsonb;
  v_readiness jsonb;
  v_state text;
  v_message text;
  v_hint text;
  v_queue jsonb;
begin
  -- Kalleren må være reviewer i det hele tatt. Avvisningen kommer fra
  -- workflow.assert_reviewer_authorized(uuid) og navngir hvilket krav som
  -- sviktet; uten et begrep godtas enhver gyldig tildeling, avgrenset eller ikke.
  v_reviewer_actor_id := workflow.assert_reviewer_authorized(null);

  if p_claim_revision_id is null then
    select coalesce(jsonb_agg(item order by item ->> 'created_at'), '[]'::jsonb)
    into v_queue
    from (
      select jsonb_build_object(
        'claim_revision_id', r.id,
        'claim_id', r.claim_id,
        'revision_number', r.revision_number,
        'knowledge_type', r.knowledge_type::text,
        'created_at', r.created_at,
        'created_by_actor_id', r.created_by_actor_id,
        'created_by_actor_key', author.actor_key,
        'statement', r.statement,
        'subject_drug_name', subject.canonical_name,
        'topic_label', topic.canonical_label,
        'topic_concept_id', cl.topic_concept_id,
        'evidence_link_count', (
          select count(*)
          from knowledge.claim_evidence_links l
          where l.claim_revision_id = r.id
        ),
        -- coalesce, ikke en naken sammenligning: uten en publisert revisjon er
        -- current_published_revision_id NULL, og NULL = uuid er ukjent — ikke
        -- usant. En klient som leste den ukjente verdien som «kanskje publisert»
        -- ville sagt noe annet enn «ikke publisert» (ANTIDEP_CONSTITUTION.md §17).
        'is_published_revision', coalesce(cl.current_published_revision_id = r.id, false),
        'current_claim_verification_outcome', (
          select cv.outcome::text
          from workflow.claim_verifications cv
          where cv.claim_revision_id = r.id
          order by cv.registration_ordinal desc
          limit 1
        ),
        'current_publication_decision', (
          select rd.decision::text
          from workflow.review_decisions rd
          where rd.claim_revision_id = r.id
            and rd.review_type = 'publication_approval'
          order by rd.registration_ordinal desc
          limit 1
        )
      ) as item
      from knowledge.claim_revisions r
      join knowledge.claims cl on cl.id = r.claim_id
      join provenance.actors author on author.id = r.created_by_actor_id
      join catalog.drugs subject on subject.id = cl.subject_drug_id
      join catalog.clinical_concepts topic on topic.id = cl.topic_concept_id
      where
        -- Radgrensen: en avgrenset reviewer-tildeling ser bare sitt eget
        -- innholdsområde. En uavgrenset ser alt.
        workflow.caller_is_active_reviewer(cl.topic_concept_id)
        -- Påstanden er ikke trukket tilbake.
        and cl.retired_at is null
        -- Revisjoner kalleren selv har formulert er utelatt: hen kan verken
        -- kontrollere dem (claim_verifications_separate_actor_check) eller
        -- godkjenne dem (review_decisions_separate_actor_check), så å ha dem i
        -- køen ville vært å be om et kall som må avvises. De er fortsatt
        -- adresserbare direkte, og flaten sier da hvorfor de ikke kan behandles.
        and r.created_by_actor_id <> v_reviewer_actor_id
        -- En kontroll av en påstand er en kontroll mot et grunnlag. Uten en
        -- eneste evidenslenke finnes det ikke noe å kontrollere mot, og både
        -- dekningskontrollen og publiseringsgatens G3 ville avvist.
        and exists (
          select 1
          from knowledge.claim_evidence_links l
          where l.claim_revision_id = r.id
        )
    ) as queue;

    return jsonb_build_object(
      'reviewer_actor_id', v_reviewer_actor_id,
      'queue', v_queue
    );
  end if;

  v_dossier := workflow.claim_evidence_dossier(p_claim_revision_id);

  if v_dossier is null then
    raise exception using
      errcode = 'no_data_found',
      message = format('Påstandsrevisjonen %L finnes ikke.', p_claim_revision_id),
      hint = 'Review peker på en eksakt revisjon, ikke på påstandsidentiteten (KNOWLEDGE_MODEL.md §19.3). Kontroller revisjons-ID-en.';
  end if;

  v_topic_concept_id := (v_dossier ->> 'topic_concept_id')::uuid;

  -- En avgrenset reviewer-tildeling gir ikke innsyn utenfor sitt eget
  -- innholdsområde, heller ikke ved direkte oppslag. Avvisningen er den samme
  -- som skriveveien ville gitt.
  perform workflow.assert_reviewer_authorized(v_topic_concept_id);

  -- Forutsetningene før godkjenningen, lest av den samme funksjonen skriveveien
  -- krever (migrasjon 006e). Den er ikke utledbar av `publication_gate`: gaten
  -- stopper på det første vilkåret som svikter, og rett før en godkjenning er
  -- det alltid G11 — «ikke godkjent av en kvalifisert redaktør». En flate som
  -- leste gaten alene, kunne derfor ikke skille «mangler bare godkjenningen» fra
  -- «grunnlaget er ikke kontrollert ennå», og ville tilbudt revieweren en
  -- handling databasen kommer til å avvise.
  --
  -- Samme smale fangst og samme begrunnelse som under: bare gatens egen
  -- avvisningskode blir til `blocked`, alt annet propagerer.
  begin
    perform knowledge.assert_claim_revision_ready_for_approval(p_claim_revision_id);
    v_readiness := jsonb_build_object('status', 'passes');
  exception
    when restrict_violation then
      get stacked diagnostics
        v_state = returned_sqlstate,
        v_message = message_text,
        v_hint = pg_exception_hint;
      v_readiness := jsonb_build_object(
        'status', 'blocked',
        'sqlstate', v_state,
        'message', v_message,
        'hint', v_hint
      );
  end;

  -- Publiseringsgaten leses av gaten selv. Den stopper på det første vilkåret
  -- som svikter, så svaret navngir én blokkering om gangen.
  --
  -- Bare `restrict_violation` fanges, og det er hele poenget (migrasjon 005p):
  -- det er koden gaten avviser med på hvert eneste av sine vilkår. Enhver annen
  -- feil — en regresjon i gaten, et manglende objekt, en rettighetsfeil — er en
  -- teknisk feil og propagerer, slik at hele kallet feiler og klienten viser det
  -- som en feil. En teknisk feil som ble gjengitt som «publiseringen er
  -- blokkert», ville skjult seg som en innholdsmangel på nøyaktig den flaten som
  -- skal være fasit for om innholdet er klart.
  begin
    perform knowledge.assert_claim_revision_publishable(p_claim_revision_id);
    v_gate := jsonb_build_object('status', 'passes');
  exception
    when restrict_violation then
      get stacked diagnostics
        v_state = returned_sqlstate,
        v_message = message_text,
        v_hint = pg_exception_hint;
      v_gate := jsonb_build_object(
        'status', 'blocked',
        'sqlstate', v_state,
        'message', v_message,
        'hint', v_hint
      );
  end;

  return jsonb_build_object(
    'reviewer_actor_id', v_reviewer_actor_id,
    'revision', v_dossier
      || workflow.claim_review_history(p_claim_revision_id)
      || jsonb_build_object(
           'is_published_revision', (
             select coalesce(cl.current_published_revision_id = p_claim_revision_id, false)
             from knowledge.claim_revisions r
             join knowledge.claims cl on cl.id = r.claim_id
             where r.id = p_claim_revision_id
           ),
           'publication_gate', v_gate,
           'approval_readiness', v_readiness
         )
  );
end;
$$;

-- --------------------------------------------------------------------------
-- 5.6 Den publiserte lesemodellen — withdrawn_evidence_count
--
-- Kolonnene, typene og rekkefølgen er ordrett som i migrasjon 007a; det eneste
-- som er endret, er hvilken tilbaketrekkingsbeslutning som telles som den
-- gjeldende. Uten rettingen kunne et evidensfunn Antidep faktisk har underkjent,
-- stått som gyldig evidens under en publisert påstand.
-- --------------------------------------------------------------------------
create or replace view api.published_claims
  with (security_invoker = true) as
select
  c.id                        as claim_id,
  r.id                        as claim_revision_id,
  r.revision_number           as revision_number,
  c.knowledge_type::text      as knowledge_type,

  c.subject_drug_id           as drug_id,
  d.canonical_name            as drug_name,
  c.topic_concept_id          as topic_concept_id,
  t.canonical_label           as topic_label,

  r.statement                 as statement,
  r.scope                     as scope,

  r.population_id             as population_id,
  p.canonical_label           as population_label,
  r.timeframe_min             as timeframe_min,
  r.timeframe_max             as timeframe_max,
  r.comparator_kind::text     as comparator_kind,
  r.comparator_drug_id        as comparator_drug_id,
  cd.canonical_name           as comparator_drug_name,

  r.direction::text           as direction,
  r.magnitude_measure::text   as magnitude_measure,
  r.magnitude_value           as magnitude_value,
  r.magnitude_unit::text      as magnitude_unit,

  r.qualifiers                as qualifiers,
  r.uncertainty_summary       as uncertainty_summary,

  ea.framework::text          as certainty_framework,
  ea.certainty_level::text    as certainty_level,
  ea.rationale                as certainty_rationale,
  ea.evidence_gap             as evidence_gap,
  ea.assessed_at              as last_assessed_at,

  (
    -- Antall lenkede evidensfunn hvis gjeldende ekstraksjonsbeslutning er
    -- tilbaketrekking. Samme avledning som publiseringsgaten G6 bruker. Uten
    -- dette ville en klient som bare viser påstandssammendraget ikke hatt noe
    -- signal om at grunnlaget er underkjent etter publisering.
    select count(*)
    from knowledge.claim_evidence_links l
    where l.claim_revision_id = r.id
      and (
        select rd.decision
        from workflow.review_decisions rd
        where rd.evidence_item_id = l.evidence_item_id
          and rd.review_type = 'extraction_withdrawal'
        order by rd.registration_ordinal desc
        limit 1
      ) = 'extraction_withdrawn'
  )                           as withdrawn_evidence_count,

  r.content_hash              as content_hash,
  r.created_at                as revision_created_at,

  (
    select max(pe.published_at)
    from knowledge.publication_events pe
    where pe.claim_id = c.id
      and pe.revision_id = r.id
  )                           as published_at,

  (
    select max(pe.approval_decided_at)
    from knowledge.publication_events pe
    where pe.claim_id = c.id
      and pe.revision_id = r.id
  )                           as last_reviewed_at
from knowledge.claims c
join knowledge.claim_revisions r
  on r.id = c.current_published_revision_id
join catalog.drugs d
  on d.id = c.subject_drug_id
join catalog.clinical_concepts t
  on t.id = c.topic_concept_id
left join catalog.populations p
  on p.id = r.population_id
left join catalog.drugs cd
  on cd.id = r.comparator_drug_id
left join knowledge.evidence_assessments ea
  on ea.claim_revision_id = r.id
where c.retired_at is null;

-- --------------------------------------------------------------------------
-- 5.7 Den publiserte lesemodellen — extraction_withdrawn på hvert funn
--
-- Samme retting, på detaljflaten under påstanden. De to skal aldri kunne svare
-- forskjellig på «er dette funnet trukket tilbake?».
-- --------------------------------------------------------------------------
create or replace view api.published_claim_evidence
  with (security_invoker = true) as
select
  c.id                                as claim_id,
  r.id                                as claim_revision_id,
  l.id                                as claim_evidence_link_id,

  l.relationship_type::text           as relationship_type,
  l.directness::text                  as directness,
  l.relevance_note                    as relevance_note,

  e.id                                as evidence_item_id,
  e.design_code::text                 as study_design,

  e.population_id                     as population_id,
  ep.canonical_label                  as population_label,
  e.population_detail                 as population_detail,
  e.population_availability::text     as population_availability,
  e.sample_size                       as sample_size,
  e.sample_size_availability::text    as sample_size_availability,

  e.intervention_drug_id              as intervention_drug_id,
  ed.canonical_name                   as intervention_drug_name,
  e.intervention_detail               as intervention_detail,
  e.comparator_kind::text             as comparator_kind,
  e.comparator_drug_id                as comparator_drug_id,
  ecd.canonical_name                  as comparator_drug_name,
  e.comparator_detail                 as comparator_detail,

  e.outcome_concept_id                as outcome_concept_id,
  eo.canonical_label                  as outcome_label,
  e.outcome_detail                    as outcome_detail,
  e.timepoint_min                     as timepoint_min,
  e.timepoint_max                     as timepoint_max,
  e.timepoint_availability::text      as timepoint_availability,

  e.reported_direction::text          as reported_direction,
  e.effect_measure::text              as effect_measure,
  e.estimate                          as estimate,
  e.estimate_unit::text               as estimate_unit,
  e.estimate_availability::text       as estimate_availability,
  e.ci_lower                          as ci_lower,
  e.ci_upper                          as ci_upper,
  e.ci_level_percent                  as ci_level_percent,
  e.confidence_interval_availability::text
                                      as confidence_interval_availability,

  e.limitations_text                  as limitations_text,
  e.source_locator                    as source_locator,

  -- Gjeldende ekstraksjonstilstand. Avledet på nøyaktig samme måte som
  -- publiseringsgaten G6 avleder den — siste beslutning av typen
  -- extraction_withdrawal — slik at lesemodellen og gaten ikke kan svare
  -- forskjellig på «er dette funnet trukket tilbake?».
  coalesce(ew.decision = 'extraction_withdrawn', false)
                                      as extraction_withdrawn,
  case when ew.decision = 'extraction_withdrawn' then ew.decided_at end
                                      as extraction_withdrawn_at,
  case when ew.decision = 'extraction_withdrawn' then ew.rationale end
                                      as extraction_withdrawal_rationale,

  -- Kildeversjonen funnet ble ekstrahert fra, når den er registrert.
  e.source_version_id                 as source_version_id,
  sv.retrieved_at                     as source_version_retrieved_at,
  sv.retrieved_from                   as source_version_retrieved_from,
  sv.external_version                 as source_version_external_version,
  sv.content_hash                     as source_version_content_hash,

  s.id                                as source_id,
  s.source_type::text                 as source_type,
  s.title                             as source_title,
  s.authors_or_issuer                 as source_authors_or_issuer,
  s.publisher_or_journal              as source_publisher_or_journal,
  s.publication_date                  as source_publication_date,
  s.publication_date_precision::text  as source_publication_date_precision,
  s.source_status::text               as source_status,
  s.status_note                       as source_status_note,
  -- Aggregater, ikke joins og ikke skalarer. knowledge.source_identifiers er unik
  -- på (identifier_system, identifier_value), ikke på (source_id,
  -- identifier_system), så en kilde kan ha flere DOI-er — parallellpublisering
  -- gir det. Med join ville ett evidensfunn blitt til to rader og sett ut som to
  -- uavhengige funn; med «velg den laveste» ville de øvrige gyldige
  -- identifikatorene forsvunnet, og en vilkårlig kanonisering blitt en offentlig
  -- kontrakt. Ingen av identifikatorene er definert som primær, så alle følger
  -- med, sortert.
  (
    select array_agg(i.identifier_value order by i.identifier_value)
    from knowledge.source_identifiers i
    where i.source_id = s.id and i.identifier_system = 'doi'
  )                                   as source_dois,
  (
    select array_agg(i.identifier_value order by i.identifier_value)
    from knowledge.source_identifiers i
    where i.source_id = s.id and i.identifier_system = 'pmid'
  )                                   as source_pmids
from knowledge.claims c
join knowledge.claim_revisions r
  on r.id = c.current_published_revision_id
join knowledge.claim_evidence_links l
  on l.claim_revision_id = r.id
join knowledge.evidence_items e
  on e.id = l.evidence_item_id
join knowledge.sources s
  on s.id = e.source_id
join catalog.drugs ed
  on ed.id = e.intervention_drug_id
join catalog.clinical_concepts eo
  on eo.id = e.outcome_concept_id
left join catalog.populations ep
  on ep.id = e.population_id
left join catalog.drugs ecd
  on ecd.id = e.comparator_drug_id
left join knowledge.source_versions sv
  on sv.id = e.source_version_id
left join lateral (
  select rd.decision, rd.decided_at, rd.rationale
  from workflow.review_decisions rd
  where rd.evidence_item_id = e.id
    and rd.review_type = 'extraction_withdrawal'
  order by rd.registration_ordinal desc
  limit 1
) ew on true
where c.retired_at is null;

-- ----------------------------------------------------------------------------
-- 6. Kommentarene som navngir rekkefølgen
--
-- Kommentarene er kontrakten neste leser møter. En som fortsatt sa «decided_at
-- desc» ville vært en oppfordring til å skrive den rekkefølgen inn igjen.
-- ----------------------------------------------------------------------------
comment on function knowledge.assert_claim_revision_ready_for_approval(uuid) is
  'Forutsetningene som skal holde før et menneske tar stilling til publisering: publiseringsgatens G1 til G10. Uendret fra migrasjon 005å bortsett fra ett uttrykk: G6 avgjør hvilken tilbaketrekkingsbeslutning som er den gjeldende for hvert lenket evidensfunn med registration_ordinal, databasens egen registreringsrekkefølge (migrasjon 006i), og ikke med decided_at — som er transaksjonens starttidspunkt og derfor kan la en tilbaketrekking skrevet sist bære det eldste tidsstempelet. G5b uttrykker dekningsregelen gjennom workflow.covered_check_fields(uuid), slik at reviewerflaten kan vise nøyaktig den dekningen gaten krever uten en andre formulering av den. G5c er speilbildet av G9c: den gjeldende ekstraksjonskontrollen for hvert lenket evidensfunn må være registrert av en aktør som hadde mandat til å gjøre den (workflow.evidence_verifier_has_mandate(uuid, uuid, timestamptz)) — den samme funksjonen triggeren på workflow.evidence_verifications håndhever ved innsetting, slik at gaten og triggeren ikke kan komme i utakt. Funksjonen leses to steder og er skrevet ett sted: knowledge.assert_claim_revision_publishable(uuid) kaller den før sine egne G11, G12 og G13, og api.register_publication_approval(uuid, text, text, text) kaller den før den registrerer en approved-beslutning, slik at en godkjenning aldri kan gis til et ukontrollert utkast og siden bli stående når kontrollene kommer (ANTIDEP_CONSTITUTION.md §13, KNOWLEDGE_MODEL.md §20). Avviser med restrict_violation på hvert vilkår, og med invalid_parameter_value når revisjonen ikke finnes. SECURITY INVOKER med tomt search_path: den kalles fra DEFINER-kontekster og skal ikke utvide DEFINER-flaten (DATABASE_ARCHITECTURE.md §50).';

comment on function knowledge.assert_claim_revision_publishable(uuid) is
  'Publiseringsgaten. Uendret utenfra: samme vilkår i samme rekkefølge, med samme SQLSTATE, setning og hint på hver avvisning. G1 til G10 ligger i knowledge.assert_claim_revision_ready_for_approval(uuid), som gaten kaller først, slik at api.register_publication_approval(uuid, text, text, text) kan kreve nøyaktig de samme forutsetningene før den registrerer en approved-beslutning uten at logikken finnes to steder (migrasjon 006e). G11 krever at en publication_approval finnes, G12 at den gjeldende beslutningen er approved, og G13 at evidenssettets avtrykk er det samme nå som da beslutningen ble lagret (KNOWLEDGE_MODEL.md §19.2). Hvilken beslutning som er den gjeldende, avgjøres av registration_ordinal — databasens egen registreringsrekkefølge, tildelt på innsiden av radlåsen på revisjonen (migrasjon 006i) — og ikke av decided_at: now() er transaksjonens starttidspunkt, og en avvisning skrevet sist kunne ellers båret det eldste tidsstempelet og forsvunnet bak en godkjenning som ble skrevet før den. Det er G12 issue #64 navngir, og retningen er alvorlig: det er et menneskes nei som ville forsvunnet. decided_at leses fortsatt der spørsmålet er *når* beslutningen ble tatt, som i rollekontrollen på tabellen. De tre leser workflow.review_decisions; forutsetningene leser workflow.evidence_verifications, workflow.claim_verifications og knowledge.evidence_assessments.';

comment on function knowledge.set_publication_approval_decided_at() is
  'Gir databasen eierskap til godkjenningstidspunktet en publisering hviler på, og fryser det på hendelsen. Speiler publiseringsgaten G11/G12: den gjeldende beslutningen er den som ble registrert sist, og bare approved teller. «Sist» leses av registration_ordinal og ikke av decided_at, av nøyaktig samme grunn som i gaten (migrasjon 006i); verdien som kopieres, er fortsatt decided_at, fordi den er svaret på når beslutningen ble tatt. SECURITY DEFINER fordi reviewbeslutningene ligger bak RLS med default deny; funksjonen leser bare og skriver bare til raden som settes inn.';

comment on function workflow.claim_review_history(uuid) is
  'Beslutningene som allerede er registrert om én påstandsrevisjon: hver claim-verifikasjon med sine sju kontrollpunkter og sine kontrollrader per evidenslenke, hver publiseringsgodkjenning med sin begrunnelse og sitt evidenssettavtrykk, og evidensvurderingen med GRADE-domenene (DATABASE_ARCHITECTURE.md §30, §31, ANTIDEP_CONSTITUTION.md §6, §12). Ingenting filtreres bort: en tidligere avvisning som senere er omgjort, står fortsatt der, fordi både beslutningen og omgjøringen skal bevares. current_claim_verification_id og current_review_decision_id peker på den raden publiseringsgaten leser som den gjeldende, hentet med nøyaktig den samme rekkefølgen som gaten — registration_ordinal desc for begge, fra migrasjon 005å og 006i — slik at flaten og gaten ikke kan bli uenige. evidence_assessment er NULL når ingen vurdering er registrert — ikke når grunnlaget er vurdert som svakt; «ingen vurderbar evidens» er en registrert verdi (§6, §17). sort_key er en intern sorteringsnøkkel og ikke en opplysning om objektet; den er den samme rekkefølgen, tekstlig utfylt slik at den sorterer likt. SECURITY DEFINER fordi workflow og knowledge har RLS med default deny; EXECUTE er revokert fra PUBLIC og gitt til ingen klientrolle.';

comment on column api.published_claims.withdrawn_evidence_count is
  'Antall av påstandens evidenslenker der ekstraksjonen er trukket tilbake etter publisering. Normalt 0: publiseringsgaten (G6) nekter å publisere en revisjon som hviler på en tilbaketrukket ekstraksjon, men beslutningen er append-only og kan komme etterpå, uten å flytte publiseringspekeren. Hvilken beslutning som er den gjeldende, avgjøres av registration_ordinal, den samme registreringsrekkefølgen gaten leser (migrasjon 006i), slik at lesemodellen og gaten ikke kan svare forskjellig. Et tall over 0 betyr at Antidep har underkjent deler av grunnlaget under en påstand som fortsatt står publisert, og en klient skal ikke presentere påstanden som uberørt. Detaljene ligger i api.published_claim_evidence.';

comment on column api.published_claim_evidence.extraction_withdrawn is
  'Om Antidep har trukket tilbake denne ekstraksjonen. Aldri NULL: false betyr at ingen tilbaketrekking er registrert, eller at en tidligere tilbaketrekking er opphevet av en senere beslutning. «Senere» avgjøres av registration_ordinal, den samme registreringsrekkefølgen publiseringsgatens G6 leser (migrasjon 006i), og ikke av decided_at — som er transaksjonens starttidspunkt og derfor kunne latt en tilbaketrekking skrevet sist forsvinne bak en opphevelse skrevet før den. true betyr at funnet er underkjent og ikke lenger står som gyldig evidens, selv om påstanden over det fortsatt er publisert — beslutningen er append-only og kan komme etter publiseringen. En klient skal ikke presentere et slikt funn som normalt gjeldende (ANTIDEP_CONSTITUTION.md §14).';
