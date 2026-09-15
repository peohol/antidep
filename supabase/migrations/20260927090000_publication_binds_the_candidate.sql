-- ============================================================================
-- Migrasjon 009e — publiseringen gjelder kandidaten, ikke bare revisjonen
--
-- Migrasjon 009d laget kandidaten: et forseglet innhold med et avtrykk beregnet
-- av innholdet selv, og en navngitt fagpersons sluttkontroll strukturelt bundet
-- til nøyaktig det avtrykket. Den publiserte ingenting, og sa det selv.
--
-- Publiseringslaget under er eldre enn kandidaten. knowledge.publication_events
-- og de tre kontrollerte operasjonene har fantes siden migrasjon 006, og de
-- kjenner bare påstandsrevisjonen. En hendelse kunne derfor si «revisjon R er
-- publisert» uten å si hvilket innhold det var — og en revisjon er ikke et
-- innhold: den samme revisjonen bygger til forskjellige kandidater etter hvert
-- som kontroller, vurderinger og forankringer kommer til. Uten kandidaten på
-- hendelsen ville «hva sa Antidep på dato X?» vært besvart av en gjenoppbygging
-- fra dagens rader, altså av noe annet enn det som faktisk ble godkjent.
--
-- Denne migrasjonen lukker det gapet. Den bygger ikke et nytt publiseringslag:
-- den fullfører det som står der.
--
-- ----------------------------------------------------------------------------
-- 1. Hendelsen navngir kandidaten, avtrykket og sluttkontrollen
--
-- `knowledge.publication_events` får `candidate_id`, `candidate_digest`,
-- `final_control_id` og `final_control_decision`, og speilene er låst av
-- sammensatte fremmednøkler:
--
--   (candidate_id, candidate_digest)   -> knowledge.candidates (id, candidate_digest)
--   (candidate_id, revision_id)        -> knowledge.candidates (id, claim_revision_id)
--   (final_control_id, candidate_id,
--    candidate_digest, final_control_decision)
--                                      -> workflow.candidate_final_controls
--                                         (id, candidate_id, candidate_digest, decision)
--
-- Sammen med `final_control_decision = 'approved'` betyr de at en
-- publiseringshendelse strukturelt ikke kan finnes uten at den navngir ett
-- forseglet innhold, at innholdet hører til den revisjonen som ble publisert, og
-- at en navngitt fagperson godkjente nøyaktig det avtrykket. Ikke ved en feil,
-- og ikke gjennom en framtidig skrivevei som glemte kontrollen. En `rejected`
-- eller `changes_requested` kan ikke bære en publisering, fordi fremmednøkkelen
-- da ikke har noen rad å peke på.
--
-- `previous_candidate_id` og `previous_candidate_digest` er den samme bindingen
-- på venstre side av overgangen: en tilbaketrekking sier hvilket innhold som ble
-- tatt ut av visning, ikke bare hvilken revisjon.
--
-- ----------------------------------------------------------------------------
-- 2. Pekeren på påstanden peker på innholdet
--
-- `knowledge.claims.current_published_candidate_id` står ved siden av
-- `current_published_revision_id`, låst til den av en sammensatt fremmednøkkel
-- og til hverandre av en pairing-CHECK. Klinikerflaten leser det publiserte
-- innholdet av kandidaten pekeren navngir, og det innholdet er raden selv —
-- ikke en gjenoppbygging. To gjeldende sannheter kan derfor ikke oppstå: det er
-- én peker, den er låst til kandidatens egen revisjon, og den flyttes bare inne
-- i den transaksjonen som skriver hendelsen.
--
-- ----------------------------------------------------------------------------
-- 3. Gaten spør etter det som faktisk finnes
--
-- Publiseringsgatens G11 til G13 het tidligere «det finnes en
-- publication_approval», «den gjeldende beslutningen er approved» og
-- «evidenssettet er det samme som da beslutningen ble lagret». De tre leste
-- `workflow.review_decisions`, altså prototypens felt-for-felt-mikroreview.
-- Antidep 2 har ingen slik review: skriveveien er stengt for klientrollene siden
-- resetten, og det et menneske faktisk vurderer, er kandidaten.
--
-- G11 til G13 er derfor formulert på nytt mot det som er:
--
--   G11  revisjonen har en *gjeldende* kandidat — en forseglet rad hvis avtrykk
--        fortsatt er avtrykket av innholdet slik det bygger nå,
--   G12  den gjeldende sluttkontrollen på den kandidaten er `approved`,
--   G13  er ikke lenger et eget vilkår: kravet om at grunnlaget ikke er endret
--        etter godkjenningen, *er* G11. Avtrykket dekker hele innholdet, og et
--        endret grunnlag gir et annet avtrykk.
--
-- G1 til G10 er uendret og leses fortsatt fra
-- knowledge.assert_claim_revision_ready_for_approval(uuid). Gaten er den samme
-- funksjonen, med det samme navnet og den samme feilklassen; det som er byttet
-- ut er hvilket objekt den spør om.
--
-- ----------------------------------------------------------------------------
-- 4. «Den gjeldende sluttkontrollen» må være et faktum, ikke en klokkeavlesning
--
-- `workflow.candidate_final_controls` får `registration_ordinal` av samme grunn
-- som `workflow.review_decisions` fikk det i migrasjon 006i: `decided_at` er
-- transaksjonens starttidspunkt, så to samtidige registreringer kan begynne i én
-- rekkefølge og skrive i den motsatte. Uten et registreringsnummer kunne et
-- menneskes `rejected`, skrevet sist, gjemt seg bak en `approved` som ble skrevet
-- før det — og publiseringen ville hvilt på den godkjenningen.
--
-- Nummeret tildeles av en sekvens på innsiden av radlåsen på kandidaten.
--
-- ----------------------------------------------------------------------------
-- 5. Låsene
--
-- Publisering, tilbaketrekking og rollback tar låsene i den faste rekkefølgen
-- påstand -> revisjon -> kandidat. Kandidatlåsen er ny og er ikke pynt:
-- sluttkontrollens egen skrivevei tar `for update` på nettopp den raden, så en
-- ny sluttkontroll kan ikke commite i vinduet mellom gaten og hendelsen. Uten
-- den kunne en `rejected` blitt registrert mellom «G12 holder» og innsettingen,
-- og publiseringen ville vært en publisering av noe som i mellomtiden var avvist.
--
-- Ingen kodevei tar de tre låsene i motsatt rekkefølge: sluttkontrollen tar bare
-- kandidatlåsen, og de tre publiseringsoperasjonene tar alle påstanden først.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md regel 3, 4, 5, 6, 7
--   docs/CONTENT_GOVERNANCE.md, docs/DATABASE_ARCHITECTURE.md
--   docs/EVIDENCE_PIPELINE.md, docs/KNOWLEDGE_MODEL.md
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Registreringsrekkefølgen på sluttkontrollen
-- ----------------------------------------------------------------------------
create sequence workflow.candidate_final_control_registration_seq
  as bigint start 1 increment 1 minvalue 1 no maxvalue cache 1;

revoke all on sequence workflow.candidate_final_control_registration_seq from public;

comment on sequence workflow.candidate_final_control_registration_seq is
  'Kilden til registreringsnummeret på workflow.candidate_final_controls. cache 1 er en del av garantien: en bufret sekvens deler ut blokker per økt, og to økter kunne da fått numre i motsatt rekkefølge av skrivingene. Hull i rekken er uten betydning; en tilbakerullet transaksjon har ikke skrevet noen rad.';

alter table workflow.candidate_final_controls add column registration_ordinal bigint;

alter sequence workflow.candidate_final_control_registration_seq
  owned by workflow.candidate_final_controls.registration_ordinal;

-- Rekkefølgen eksisterende rader faktisk ble skrevet i, finnes ikke lenger.
-- (decided_at, created_at, id) er den beste tilnærmingen, og er riktig for alt
-- som er skrevet sekvensielt — som alt som finnes nå, er. Append-only-triggeren
-- slås av for backfillen og på igjen etterpå; alternativet ville vært å myke opp
-- regelen, og den skal ikke mykes opp.
alter table workflow.candidate_final_controls
  disable trigger candidate_final_controls_are_append_only;

with ordered as (
  select id, row_number() over (order by decided_at, created_at, id) as n
  from workflow.candidate_final_controls
)
update workflow.candidate_final_controls fc
set registration_ordinal = ordered.n
from ordered
where ordered.id = fc.id;

alter table workflow.candidate_final_controls
  enable trigger candidate_final_controls_are_append_only;

select setval(
  'workflow.candidate_final_control_registration_seq',
  coalesce((select max(registration_ordinal) from workflow.candidate_final_controls), 0) + 1,
  false
);

alter table workflow.candidate_final_controls
  alter column registration_ordinal set not null,
  add constraint candidate_final_controls_registration_ordinal_key
    unique (registration_ordinal);

comment on column workflow.candidate_final_controls.registration_ordinal is
  'Rekkefølgen sluttkontrollen ble registrert i, tildelt av databasen fra en sekvens etter at radlåsen på kandidaten er tatt. Fasiten for «senere» og «gjeldende»: publiseringsgatens G12 leser den. decided_at kan ikke brukes til det, fordi now() er transaksjonens starttidspunkt — to samtidige registreringer kan starte i én rekkefølge og skrive i den motsatte, og et menneskes avvisning ville da kunnet gjemme seg bak en godkjenning som ble skrevet før den. Ikke en parameter: triggeren overskriver enhver oppgitt verdi.';

create function workflow.set_candidate_final_control_registration_ordinal()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  -- Låsen først, nummeret etterpå, og låsen holdes ut transaksjonen. Rekkefølgen
  -- er hele poenget: tildeles nummeret før låsen, kan to registreringer få dem i
  -- motsatt rekkefølge av skrivingene. Den samme låsen er det publiseringen
  -- venter på, slik at en ny sluttkontroll ikke kan commite mellom gaten og
  -- publiseringshendelsen.
  perform 1
  from knowledge.candidates c
  where c.id = new.candidate_id
  for update;

  new.registration_ordinal :=
    nextval('workflow.candidate_final_control_registration_seq');

  return new;
end;
$$;

comment on function workflow.set_candidate_final_control_registration_ordinal() is
  'Tildeler registreringsnummeret på workflow.candidate_final_controls, på innsiden av radlåsen på kandidaten. SECURITY DEFINER fordi knowledge har RLS med default deny og triggeren må kunne ta låsen uansett hvem som skriver; den leser ingenting ut og skriver bare til raden som settes inn.';

revoke execute on function workflow.set_candidate_final_control_registration_ordinal() from public;

-- Navnet er valgt slik at triggeren fyrer etter
-- candidate_final_controls_set_created_at; rekkefølgen er alfabetisk, og de to
-- er uavhengige av hverandre.
create trigger candidate_final_controls_set_registration_ordinal
  before insert on workflow.candidate_final_controls
  for each row execute function workflow.set_candidate_final_control_registration_ordinal();

create index candidate_final_controls_candidate_ordinal_idx
  on workflow.candidate_final_controls (candidate_id, registration_ordinal desc);

-- ----------------------------------------------------------------------------
-- 2. Den gjeldende sluttkontrollen, og den gjeldende kandidaten
--
-- Begge er avledet og begge leses av gaten, av lesemodellen og av
-- publiseringsoperasjonene. De står som funksjoner og ikke som gjentatte
-- underspørringer, fordi to formuleringer av «gjeldende» før eller siden svarer
-- forskjellig — og da ville flaten kunnet vise noe annet enn gaten avgjør.
-- ----------------------------------------------------------------------------
create function workflow.current_candidate_final_control(p_candidate_id uuid)
  returns workflow.candidate_final_controls
  language sql
  stable
  set search_path = ''
as $$
  select fc.*
  from workflow.candidate_final_controls fc
  where fc.candidate_id = p_candidate_id
  order by fc.registration_ordinal desc
  limit 1;
$$;

comment on function workflow.current_candidate_final_control(uuid) is
  'Den gjeldende sluttkontrollen for én kandidat: raden med det høyeste registreringsnummeret, altså den som faktisk ble skrevet sist. En omgjøring er en ny rad, og den nye gjelder foran den gamle (ANTIDEP_CONSTITUTION.md regel 5). Rekkefølgen leses av registreringsnummeret og aldri av decided_at, fordi klokka er transaksjonens starttidspunkt.';

revoke execute on function workflow.current_candidate_final_control(uuid) from public;

create function knowledge.current_candidate(p_claim_revision_id uuid)
  returns knowledge.candidates
  language sql
  stable
  set search_path = ''
as $$
  select c.*
  from knowledge.candidates c
  where c.claim_revision_id = p_claim_revision_id
    and c.candidate_digest = knowledge.source_version_content_hash(
          knowledge.candidate_content(p_claim_revision_id)::text)
  limit 1;
$$;

comment on function knowledge.current_candidate(uuid) is
  'Den kandidaten som er gjeldende for én påstandsrevisjon nå: den forseglede raden hvis avtrykk fortsatt er avtrykket av innholdet slik det bygger i dette øyeblikket. Ingen rad betyr at grunnlaget er endret siden forseglingen, eller at ingen kandidat er bygget — og da er svaret å bygge en ny og sluttkontrollere den, ikke å publisere den gamle. Entydig per konstruksjon: knowledge.candidate_content(uuid) er deterministisk, og candidates_revision_digest_key gir høyst én rad per (revisjon, avtrykk).';

revoke execute on function knowledge.current_candidate(uuid) from public;

create function knowledge.publication_head_event(p_claim_id uuid)
  returns knowledge.publication_events
  language sql
  stable
  set search_path = ''
as $$
  select e.*
  from knowledge.publication_events e
  where e.claim_id = p_claim_id
    and not exists (
      select 1
      from knowledge.publication_events successor
      where successor.previous_event_id = e.id
    )
  limit 1;
$$;

comment on function knowledge.publication_head_event(uuid) is
  'Den siste hendelsen i publiseringskjeden for én påstand: den ingen annen hendelse peker tilbake på. Entydig fordi publication_events_no_forked_history_key forbyr to hendelser med samme forgjenger; oppslaget er bare stabilt under radlåsen på påstanden, og publiseringsoperasjonene tar den før de leser.';

revoke execute on function knowledge.publication_head_event(uuid) from public;

-- ----------------------------------------------------------------------------
-- 3. Nøklene bindingen trenger
-- ----------------------------------------------------------------------------
alter table knowledge.candidates
  add constraint candidates_id_claim_revision_key unique (id, claim_revision_id);

comment on constraint candidates_id_claim_revision_key on knowledge.candidates is
  'Venstresiden i fremmednøkkelen som binder en publiseringshendelse og publiseringspekeren til den revisjonen kandidatens innhold faktisk gjelder. Uten den kunne en hendelse sagt at revisjon R er publisert, og samtidig navngitt innholdet til en annen revisjon.';

alter table workflow.candidate_final_controls
  add constraint candidate_final_controls_binding_key
    unique (id, candidate_id, candidate_digest, decision);

comment on constraint candidate_final_controls_binding_key on workflow.candidate_final_controls is
  'Venstresiden i fremmednøkkelen som binder en publiseringshendelse til sluttkontrollen den hviler på — kandidaten, avtrykket og beslutningen i samme nøkkel. Sammen med publication_events_final_control_approves_check gjør den det strukturelt umulig at en rejected eller changes_requested bærer en publisering.';

-- ----------------------------------------------------------------------------
-- 4. Hendelsen
-- ----------------------------------------------------------------------------
alter table knowledge.publication_events
  add column candidate_id uuid,
  add column candidate_digest text,
  add column final_control_id uuid,
  add column final_control_decision workflow.final_control_decision,
  add column previous_candidate_id uuid,
  add column previous_candidate_digest text;

alter table knowledge.publication_events
  -- De fire beskriver én binding og er derfor enten alle satt eller ingen.
  add constraint publication_events_candidate_pairing_check
    check (num_nonnulls(candidate_id, candidate_digest,
                        final_control_id, final_control_decision) in (0, 4)),
  add constraint publication_events_previous_candidate_pairing_check
    check (num_nonnulls(previous_candidate_id, previous_candidate_digest) in (0, 2)),

  -- Hver hendelse som etterlater noe publisert, navngir innholdet. Og hver
  -- hendelse som hadde noe publisert før seg, navngir det innholdet også.
  -- En publisering uten kandidat ville vært en publisering av «en revisjon»,
  -- altså av noe som ikke er et innhold.
  add constraint publication_events_candidate_required_check
    check ((revision_id is null) = (candidate_id is null)),
  add constraint publication_events_previous_candidate_required_check
    check ((previous_revision_id is null) = (previous_candidate_id is null)),

  -- ANTIDEP_CONSTITUTION.md regel 5: bare nøyaktig godkjent kandidat kan
  -- publiseres. Her er «godkjent» en verdi databasen kan kontrollere, ikke en
  -- egenskap noen husker.
  add constraint publication_events_final_control_approves_check
    check (final_control_decision is null or final_control_decision = 'approved'),

  add constraint publication_events_candidate_fkey
    foreign key (candidate_id, candidate_digest)
    references knowledge.candidates (id, candidate_digest)
    on update restrict on delete restrict,
  add constraint publication_events_candidate_revision_fkey
    foreign key (candidate_id, revision_id)
    references knowledge.candidates (id, claim_revision_id)
    on update restrict on delete restrict,
  add constraint publication_events_previous_candidate_fkey
    foreign key (previous_candidate_id, previous_candidate_digest)
    references knowledge.candidates (id, candidate_digest)
    on update restrict on delete restrict,
  add constraint publication_events_previous_candidate_revision_fkey
    foreign key (previous_candidate_id, previous_revision_id)
    references knowledge.candidates (id, claim_revision_id)
    on update restrict on delete restrict,
  add constraint publication_events_final_control_fkey
    foreign key (final_control_id, candidate_id, candidate_digest, final_control_decision)
    references workflow.candidate_final_controls (id, candidate_id, candidate_digest, decision)
    on update restrict on delete restrict;

comment on column knowledge.publication_events.candidate_id is
  'Det forseglede innholdet som er publisert etter hendelsen, eller NULL når ingenting er publisert etter den. Publisering gjelder en kandidat og ikke bare en revisjon: den samme revisjonen bygger til forskjellige kandidater etter hvert som kontroller og vurderinger kommer til, og en hendelse uten kandidat ville ikke sagt hvilket innhold Antidep faktisk viste.';
comment on column knowledge.publication_events.candidate_digest is
  'Speil av kandidatens eget avtrykk, låst til kandidaten av publication_events_candidate_fkey. Ikke en kopi for lesbarhetens skyld: det er venstresiden i bindingen mot sluttkontrollen, og dermed selve lenken mellom det publiserte og det godkjente.';
comment on column knowledge.publication_events.final_control_id is
  'Sluttkontrollen publiseringen hviler på. Den sammensatte fremmednøkkelen binder den til nøyaktig den kandidaten og det avtrykket hendelsen publiserer, slik at en godkjenning av ett innhold ikke kan bære publiseringen av et annet (ANTIDEP_CONSTITUTION.md regel 5).';
comment on column knowledge.publication_events.final_control_decision is
  'Speil av sluttkontrollens beslutning, låst av fremmednøkkelen og begrenset til approved av en CHECK. Gjør det strukturelt umulig at en rejected eller changes_requested står bak en publisert påstand.';
comment on column knowledge.publication_events.previous_candidate_id is
  'Det forseglede innholdet som var publisert før hendelsen, eller NULL når ingenting var publisert. Gjør en tilbaketrekking til et utsagn om et innhold og ikke bare om en revisjon: historikken skal kunne si hva som faktisk ble tatt ut av visning.';
comment on column knowledge.publication_events.previous_candidate_digest is
  'Speil av det forrige innholdets avtrykk, med samme formål og samme låsing som candidate_digest.';

create index publication_events_candidate_id_idx
  on knowledge.publication_events (candidate_id);
create index publication_events_final_control_id_idx
  on knowledge.publication_events (final_control_id);

-- ----------------------------------------------------------------------------
-- 5. Godkjenningstidspunktet på hendelsen er sluttkontrollens eget
--
-- knowledge.set_publication_approval_decided_at() speilet fram til nå den
-- gjeldende publication_approval-beslutningen i workflow.review_decisions. Den
-- beslutningen finnes ikke i Antidep 2. Triggeren leser derfor sluttkontrollen
-- hendelsen allerede er bundet til — ikke et nytt oppslag som kunne pekt et
-- annet sted enn fremmednøkkelen gjør.
-- ----------------------------------------------------------------------------
create or replace function knowledge.set_publication_approval_decided_at()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_decided_at timestamptz;
begin
  if new.final_control_id is null then
    new.approval_decided_at := null;
    return new;
  end if;

  select fc.decided_at into v_decided_at
  from workflow.candidate_final_controls fc
  where fc.id = new.final_control_id;

  new.approval_decided_at := v_decided_at;

  return new;
end;
$$;

comment on function knowledge.set_publication_approval_decided_at() is
  'Gir databasen eierskap til godkjenningstidspunktet en publisering hviler på, og fryser det på hendelsen. Leser sluttkontrollen hendelsen allerede er bundet til av publication_events_final_control_fkey — altså nøyaktig den navngitte fagpersonens beslutning om nøyaktig det publiserte innholdet — framfor å slå opp på nytt og kunne svare noe annet enn fremmednøkkelen sier. En hendelse uten sluttkontroll er en tilbaketrekking, og da er det ingen godkjenningsdato å bære. SECURITY DEFINER fordi workflow har RLS med default deny; funksjonen leser bare og skriver bare til raden som settes inn.';

-- ----------------------------------------------------------------------------
-- 6. Pekeren på påstanden
-- ----------------------------------------------------------------------------
alter table knowledge.claims add column current_published_candidate_id uuid;

alter table knowledge.claims
  add constraint claims_published_candidate_pairing_check
    check ((current_published_candidate_id is null)
           = (current_published_revision_id is null)),
  add constraint claims_current_published_candidate_fkey
    foreign key (current_published_candidate_id, current_published_revision_id)
    references knowledge.candidates (id, claim_revision_id)
    on update restrict on delete restrict;

comment on column knowledge.claims.current_published_candidate_id is
  'Det forseglede innholdet som er publisert nå, eller NULL når ingenting er publisert. Klinikerflaten leser det publiserte innholdet av denne raden, og innholdet *er* raden — ikke en gjenoppbygging fra dagens tilstand, som ville kunnet vise noe annet enn det som ble godkjent. Pairing-CHECK-en og den sammensatte fremmednøkkelen gjør at pekeren og revisjonspekeren ikke kan si hver sin ting: to gjeldende sannheter kan ikke oppstå.';

create index claims_current_published_candidate_id_idx
  on knowledge.claims (current_published_candidate_id);

-- ----------------------------------------------------------------------------
-- 7. Gaten: G11 og G12 spør etter kandidaten
--
-- Uendret utenfra på alt annet: samme navn, samme signatur, samme feilklasse, og
-- G1 til G10 leses fortsatt av
-- knowledge.assert_claim_revision_ready_for_approval(uuid).
-- ----------------------------------------------------------------------------
create or replace function knowledge.assert_claim_revision_publishable(p_claim_revision_id uuid)
  returns void
  language plpgsql
  set search_path = ''
as $$
declare
  v_candidate knowledge.candidates;
  v_control workflow.candidate_final_controls;
begin
  -- G1 til G10: alt som skal holde før et menneske i det hele tatt kan ta
  -- stilling til innholdet.
  perform knowledge.assert_claim_revision_ready_for_approval(p_claim_revision_id);

  -- G11: det finnes en gjeldende kandidat.
  --
  -- «Gjeldende» er ikke «sist bygget»: det er den kandidaten hvis avtrykk
  -- fortsatt er avtrykket av innholdet slik det bygger nå. Er grunnlaget endret
  -- etter forseglingen, finnes det ingen slik rad — og det er nettopp det gamle
  -- G13 handlet om, uttrykt på hele innholdet framfor bare på evidenssettet.
  v_candidate := knowledge.current_candidate(p_claim_revision_id);

  if v_candidate.id is null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Revisjon %L har ingen gjeldende kandidat og kan ikke publiseres.',
        p_claim_revision_id
      ),
      hint = 'Publisering gjelder et forseglet innhold, ikke en revisjon. Bygg kandidaten med api.build_candidate(uuid) og få den sluttkontrollert. Finnes det en kandidat fra før, er grunnlaget endret siden den ble forseglet: da bygger innholdet til et annet avtrykk, og den gamle godkjenningen dekker ikke det som ville blitt publisert (ANTIDEP_CONSTITUTION.md regel 5).';
  end if;

  -- G12: den gjeldende sluttkontrollen godkjenner nøyaktig den kandidaten.
  v_control := workflow.current_candidate_final_control(v_candidate.id);

  if v_control.id is null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Kandidaten %L er ikke sluttkontrollert og kan ikke publiseres.',
        v_candidate.id
      ),
      hint = 'KI kan foreslå, men mennesker har det faglige ansvaret (ANTIDEP_CONSTITUTION.md regel 5). Registrer en sluttkontroll fra en navngitt fagperson med mandat, i den samme visningen klinikeren får: api.record_candidate_final_control(uuid, text, text, text).';
  end if;

  if v_control.decision <> 'approved' then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Den gjeldende sluttkontrollen for kandidaten %L er %s, ikke approved.',
        v_candidate.id, v_control.decision
      ),
      hint = 'En senere beslutning gjelder foran en tidligere, og rekkefølgen leses av registreringsnummeret og ikke av klokka. Rett innholdet slik fagpersonen ba om, bygg en ny kandidat og be om ny sluttkontroll. Både godkjenningen og omgjøringen bevares.';
  end if;
end;
$$;

comment on function knowledge.assert_claim_revision_publishable(uuid) is
  'Publiseringsgaten. G1 til G10 er uendret og leses av knowledge.assert_claim_revision_ready_for_approval(uuid). G11 krever at revisjonen har en *gjeldende* kandidat — et forseglet innhold hvis avtrykk fortsatt er avtrykket av innholdet slik det bygger nå — og G12 at den gjeldende sluttkontrollen på nøyaktig den kandidaten er approved. Det gamle G13, «evidensgrunnlaget er det samme som godkjenningen ble gitt for», er ikke borte: det er G11, uttrykt på hele det forseglede innholdet framfor bare på evidenssettet, fordi avtrykket dekker alt sammen. Kan bare avvise, og returnerer ingen data.';

-- ----------------------------------------------------------------------------
-- 8. Sluttkontrollens skrivevei tar den låsen publiseringen venter på
--
-- Uendret utenfra. Forskjellen er `for update` framfor `for share`: nummeret
-- tildeles under nettopp den låsen, og to samtidige sluttkontroller på samme
-- kandidat ville ellers begge holdt en delt lås og begge bedt om en eksklusiv —
-- altså en oppgradering som ender i vranglås framfor i en kø.
-- ----------------------------------------------------------------------------
create or replace function api.record_candidate_final_control(
  p_candidate_id uuid,
  p_seen_candidate_digest text,
  p_decision text,
  p_rationale text
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_candidate knowledge.candidates;
  v_topic_concept_id uuid;
  v_reviewer_actor_id uuid;
  v_decision workflow.final_control_decision;
  v_current_digest text;
  v_control_id uuid;
begin
  begin
    v_decision := p_decision::workflow.final_control_decision;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke et kjent utfall av en sluttkontroll.', p_decision),
        hint = 'Gyldige utfall er approved, rejected og changes_requested.';
  end;

  -- Låsen tas før kontrollen av avtrykket, slik at en kandidat ikke kan få en
  -- ny sluttkontroll skrevet under oss mellom lesningen og skrivingen. `for
  -- update` og ikke `for share`: det er den samme låsen registreringsnummeret
  -- tildeles under, og den samme låsen publiseringen venter på.
  select c.* into v_candidate
  from knowledge.candidates c
  where c.id = p_candidate_id
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = format('Kandidaten %L finnes ikke.', p_candidate_id);
  end if;

  select cl.topic_concept_id into v_topic_concept_id
  from knowledge.claim_revisions r
  join knowledge.claims cl on cl.id = r.claim_id
  where r.id = v_candidate.claim_revision_id;

  v_reviewer_actor_id := workflow.assert_reviewer_authorized(v_topic_concept_id);

  if p_seen_candidate_digest is distinct from v_candidate.candidate_digest then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Sluttkontrollen viser til et annet kandidatavtrykk enn kandidatens eget.',
      hint = 'Avtrykket skal kopieres uendret fra den kandidaten som faktisk ble lest. En godkjenning avgitt mot ett innhold og registrert mot et annet, ville vært en attestasjon uten dekning (ANTIDEP_CONSTITUTION.md regel 5).';
  end if;

  v_current_digest := knowledge.source_version_content_hash(
    knowledge.candidate_content(v_candidate.claim_revision_id)::text
  );
  if v_current_digest is distinct from v_candidate.candidate_digest then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Grunnlaget kandidaten ble forseglet av, er endret siden den ble bygget.',
      hint = format(
        'Kandidaten bærer %s, mens innholdet nå bygger til %s. Bygg kandidaten på nytt med api.build_candidate(uuid) og sluttkontroller den nye; en godkjenning av et innhold som ikke lenger er det som ligger der, er ikke en godkjenning av noe (ANTIDEP_CONSTITUTION.md regel 5).',
        v_candidate.candidate_digest, v_current_digest
      );
  end if;

  insert into workflow.candidate_final_controls (
    candidate_id, candidate_digest, decision, rationale,
    reviewer_actor_id, reviewer_actor_type
  )
  values (
    v_candidate.id, v_candidate.candidate_digest, v_decision, btrim(coalesce(p_rationale, '')),
    v_reviewer_actor_id, 'human'
  )
  returning id into v_control_id;

  return jsonb_build_object(
    'candidate_final_control_id', v_control_id,
    'candidate_id', v_candidate.id,
    'candidate_digest', v_candidate.candidate_digest,
    'decision', v_decision::text,
    -- Sagt eksplisitt, fordi det er den ene misforståelsen som ville vært
    -- alvorlig: en godkjenning er ikke en publisering. Publiseringen er en egen
    -- handling, med et annet mandat, i api.publish_candidate(uuid, text, text).
    'published', false
  );
end;
$$;

comment on function api.record_candidate_final_control(uuid, text, text, text) is
  'Registrerer en navngitt fagpersons sluttkontroll av nøyaktig ett forseglet kandidatinnhold (ANTIDEP_CONSTITUTION.md regel 5, DATABASE_ARCHITECTURE.md §43). Krever gyldig reviewer-rolle for påstandens kliniske begrep (workflow.assert_reviewer_authorized(uuid)), og binder beslutningen til kandidaten i to lag: avtrykket kalleren oppgir må være kandidatens eget, og innholdet må fortsatt bygge til nøyaktig det samme avtrykket. Radlåsen på kandidaten tas først og er den samme låsen registreringsnummeret tildeles under og publiseringen venter på, slik at en sluttkontroll ikke kan commite mellom publiseringsgaten og publiseringshendelsen. Publiserer ingenting: svaret sier published: false, og publiseringen er en egen handling med et annet mandat. Append-only — en omgjøring er en ny rad, og den nye gjelder foran den gamle. SECURITY DEFINER med tomt search_path fordi knowledge, workflow og provenance har RLS med default deny (§50).';

-- ----------------------------------------------------------------------------
-- 9. De tre kontrollerte operasjonene
--
-- Uendret signatur, uendret navn, uendret feilklasse. Det som er nytt er at hver
-- av dem nå skriver hvilket innhold handlingen gjaldt, og at publiseringen og
-- rollbacken henter kandidaten selv framfor å ta imot den: en kandidat kalleren
-- oppga, ville vært en påstand fra den som skriver om noe databasen selv kan
-- avgjøre entydig (ANTIDEP_CONSTITUTION.md regel 5, 7).
-- ----------------------------------------------------------------------------
create or replace function knowledge.publish_claim_revision(
  p_claim_revision_id uuid,
  p_publisher_actor_id uuid,
  p_reason text
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_claim_id uuid;
  v_topic_concept_id uuid;
  v_revision_number integer;
  v_current_revision_id uuid;
  v_current_revision_number integer;
  v_current_candidate_id uuid;
  v_current_candidate_digest text;
  v_previous_event_id uuid;
  v_candidate knowledge.candidates;
  v_control workflow.candidate_final_controls;
  v_action knowledge.publication_action;
  v_event_id uuid;
begin
  select r.claim_id, r.revision_number
    into v_claim_id, v_revision_number
  from knowledge.claim_revisions r
  where r.id = p_claim_revision_id;

  if not found then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Påstandsrevisjon %L finnes ikke.', p_claim_revision_id),
      hint = 'Publisering peker på en eksakt revisjon, ikke på påstandsidentiteten (KNOWLEDGE_MODEL.md §19.3).';
  end if;

  -- Låsene, i den faste rekkefølgen påstand -> revisjon -> kandidat.
  select c.topic_concept_id, c.current_published_revision_id, c.current_published_candidate_id
    into v_topic_concept_id, v_current_revision_id, v_current_candidate_id
  from knowledge.claims c
  where c.id = v_claim_id
  for update;

  perform 1 from knowledge.claim_revisions r where r.id = p_claim_revision_id for update;

  perform knowledge.assert_publisher_authorized(p_publisher_actor_id, v_topic_concept_id);

  -- Kandidaten hentes og låses *før* gaten. Låsen er den samme som
  -- sluttkontrollens skrivevei tar, så en ny sluttkontroll kan ikke commite i
  -- vinduet mellom G12 og innsettingen av hendelsen.
  v_candidate := knowledge.current_candidate(p_claim_revision_id);
  if v_candidate.id is not null then
    perform 1 from knowledge.candidates c where c.id = v_candidate.id for share;
    -- Lest på nytt under låsen: den første lesningen var utenfor den.
    v_candidate := knowledge.current_candidate(p_claim_revision_id);
  end if;

  perform knowledge.assert_claim_revision_publishable(p_claim_revision_id);

  v_control := workflow.current_candidate_final_control(v_candidate.id);

  if v_current_revision_id is null then
    v_action := 'publish';
  elsif v_current_revision_id = p_claim_revision_id then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Revisjon %L er allerede den publiserte.', p_claim_revision_id),
      hint = 'Publiseringshistorikken skal registrere reelle tilstandsendringer. En publisering som ikke endrer noe er ikke en hendelse.';
  else
    select r.revision_number into v_current_revision_number
    from knowledge.claim_revisions r
    where r.id = v_current_revision_id;

    if v_revision_number < v_current_revision_number then
      raise exception using
        errcode = 'restrict_violation',
        message = format(
          'Revisjon %L er eldre enn den publiserte revisjonen og kan ikke erstatte den.',
          p_claim_revision_id
        ),
        hint = 'Å gå tilbake til en tidligere revisjon er en rollback, ikke en erstatning, og skal registreres som det (DATABASE_ARCHITECTURE.md §40). Bruk knowledge.rollback_claim_publication().';
    end if;

    v_action := 'replace';
  end if;

  select c.candidate_digest into v_current_candidate_digest
  from knowledge.candidates c
  where c.id = v_current_candidate_id;

  v_previous_event_id := (knowledge.publication_head_event(v_claim_id)).id;

  update knowledge.claims
  set current_published_revision_id = p_claim_revision_id,
      current_published_candidate_id = v_candidate.id
  where id = v_claim_id;

  insert into knowledge.publication_events (
    claim_id, action, revision_id, revision_number,
    previous_revision_id, previous_revision_number, previous_event_id,
    candidate_id, candidate_digest, final_control_id, final_control_decision,
    previous_candidate_id, previous_candidate_digest,
    published_by_actor_id, published_by_actor_type, reason, published_at
  )
  select
    v_claim_id, v_action, p_claim_revision_id, v_revision_number,
    v_current_revision_id, v_current_revision_number, v_previous_event_id,
    v_candidate.id, v_candidate.candidate_digest, v_control.id, v_control.decision,
    v_current_candidate_id, v_current_candidate_digest,
    p_publisher_actor_id, a.actor_type, p_reason, now()
  from provenance.actors a
  where a.id = p_publisher_actor_id
  returning id into v_event_id;

  return v_event_id;
end;
$$;

comment on function knowledge.publish_claim_revision(uuid, uuid, text) is
  'Den kontrollerte publiseringsoperasjonen (DATABASE_ARCHITECTURE.md §38): validerer caller og publisher-rolle, henter og låser den gjeldende kandidaten, kjører publiseringsgaten, flytter begge publiseringspekerne og registrerer hendelsen med kandidaten, avtrykket og sluttkontrollen — alt i én transaksjon. Kandidaten er ikke en parameter: den er entydig utledbar av revisjonen, og en kandidat kalleren oppga ville vært en påstand fra den som skriver om noe databasen selv kan avgjøre. Låsene tas i rekkefølgen påstand, revisjon, kandidat, og kandidatlåsen er den samme sluttkontrollens skrivevei tar, slik at ingen ny sluttkontroll kan commite mellom gaten og hendelsen. Registrerer publish når ingenting var publisert og replace ellers. SECURITY DEFINER fordi rollemodellen og kandidatene ligger bak RLS med default deny; tomt search_path, og funksjonen er ikke kjørbar for PUBLIC (§50).';

create or replace function knowledge.withdraw_claim_publication(
  p_claim_id uuid,
  p_publisher_actor_id uuid,
  p_reason text
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_topic_concept_id uuid;
  v_current_revision_id uuid;
  v_current_revision_number integer;
  v_current_candidate_id uuid;
  v_current_candidate_digest text;
  v_previous_event_id uuid;
  v_event_id uuid;
begin
  select c.topic_concept_id, c.current_published_revision_id, c.current_published_candidate_id
    into v_topic_concept_id, v_current_revision_id, v_current_candidate_id
  from knowledge.claims c
  where c.id = p_claim_id
  for update;

  if not found then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Påstand %L finnes ikke.', p_claim_id),
      hint = 'Kontroller påstands-ID-en.';
  end if;

  if v_current_revision_id is null then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Påstand %L har ingen publisert revisjon å trekke tilbake.', p_claim_id),
      hint = 'Publiseringshistorikken skal registrere reelle tilstandsendringer. En avpublisering av noe som ikke er publisert er ikke en hendelse.';
  end if;

  perform 1 from knowledge.claim_revisions r where r.id = v_current_revision_id for update;

  perform knowledge.assert_publisher_authorized(p_publisher_actor_id, v_topic_concept_id);

  select r.revision_number into v_current_revision_number
  from knowledge.claim_revisions r
  where r.id = v_current_revision_id;

  select c.candidate_digest into v_current_candidate_digest
  from knowledge.candidates c
  where c.id = v_current_candidate_id;

  v_previous_event_id := (knowledge.publication_head_event(p_claim_id)).id;

  update knowledge.claims
  set current_published_revision_id = null,
      current_published_candidate_id = null
  where id = p_claim_id;

  insert into knowledge.publication_events (
    claim_id, action, revision_id, revision_number,
    previous_revision_id, previous_revision_number, previous_event_id,
    previous_candidate_id, previous_candidate_digest,
    published_by_actor_id, published_by_actor_type, reason, published_at
  )
  select
    p_claim_id, 'withdraw', null, null,
    v_current_revision_id, v_current_revision_number, v_previous_event_id,
    v_current_candidate_id, v_current_candidate_digest,
    p_publisher_actor_id, a.actor_type, p_reason, now()
  from provenance.actors a
  where a.id = p_publisher_actor_id
  returning id into v_event_id;

  return v_event_id;
end;
$$;

comment on function knowledge.withdraw_claim_publication(uuid, uuid, text) is
  'Tilbaketrekking: fjerner begge publiseringspekerne og registrerer hendelsen i én transaksjon. Kjører bevisst ikke publiseringsgaten — å ta innhold ut av visning skal aldri kunne blokkeres av at grunnlaget er blitt utilstrekkelig; det er nettopp da handlingen trengs. Sletter ingenting: hendelsen navngir både revisjonen og det forseglede innholdet som var publisert, slik at historikken fortsatt kan svare på hva Antidep sa og hva som ble trukket tilbake (DATABASE_ARCHITECTURE.md §36, §40). Krever publisher-mandat og en begrunnelse, som alle hendelsene.';

create or replace function knowledge.rollback_claim_publication(
  p_claim_id uuid,
  p_target_revision_id uuid,
  p_publisher_actor_id uuid,
  p_reason text
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_topic_concept_id uuid;
  v_current_revision_id uuid;
  v_current_revision_number integer;
  v_current_candidate_id uuid;
  v_current_candidate_digest text;
  v_target_claim_id uuid;
  v_target_revision_number integer;
  v_previous_event_id uuid;
  v_candidate knowledge.candidates;
  v_control workflow.candidate_final_controls;
  v_event_id uuid;
begin
  select c.topic_concept_id, c.current_published_revision_id, c.current_published_candidate_id
    into v_topic_concept_id, v_current_revision_id, v_current_candidate_id
  from knowledge.claims c
  where c.id = p_claim_id
  for update;

  if not found then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Påstand %L finnes ikke.', p_claim_id),
      hint = 'Kontroller påstands-ID-en.';
  end if;

  if v_current_revision_id is null then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Påstand %L har ingen publisert revisjon å rulle tilbake fra.', p_claim_id),
      hint = 'En rollback flytter pekeren fra den gjeldende revisjonen tilbake til en tidligere publisert. Er ingenting publisert, er handlingen en publisering.';
  end if;

  select r.claim_id, r.revision_number
    into v_target_claim_id, v_target_revision_number
  from knowledge.claim_revisions r
  where r.id = p_target_revision_id;

  if not found or v_target_claim_id <> p_claim_id then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format(
        'Revisjon %L finnes ikke eller tilhører en annen påstand enn %L.',
        p_target_revision_id, p_claim_id
      ),
      hint = 'Publiseringspekeren kan bare peke på en revisjon av den samme påstanden (DATABASE_ARCHITECTURE.md §58).';
  end if;

  perform 1 from knowledge.claim_revisions r where r.id = p_target_revision_id for update;

  if p_target_revision_id = v_current_revision_id then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Revisjon %L er allerede den publiserte.', p_target_revision_id),
      hint = 'Publiseringshistorikken skal registrere reelle tilstandsendringer.';
  end if;

  select r.revision_number into v_current_revision_number
  from knowledge.claim_revisions r
  where r.id = v_current_revision_id;

  if v_target_revision_number > v_current_revision_number then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Revisjon %L er nyere enn den publiserte revisjonen og er derfor ikke en rollback.',
        p_target_revision_id
      ),
      hint = 'Å gå framover til en nyere revisjon er en erstatning. Bruk knowledge.publish_claim_revision().';
  end if;

  -- Målet må ha vært publisert før. Uten det kravet ville «rollback» vært en
  -- vilkårlig flytting bakover til noe Antidep aldri har sagt.
  if not exists (
    select 1
    from knowledge.publication_events e
    where e.revision_id = p_target_revision_id
  ) then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Revisjon %L har aldri vært publisert og kan derfor ikke rulles tilbake til.',
        p_target_revision_id
      ),
      hint = 'En rollback flytter pekeren tilbake til en tidligere publisert revisjon (DATABASE_ARCHITECTURE.md §40). Skal en revisjon som aldri har vært publisert tas i bruk, er det en publisering.';
  end if;

  perform knowledge.assert_publisher_authorized(p_publisher_actor_id, v_topic_concept_id);

  v_candidate := knowledge.current_candidate(p_target_revision_id);
  if v_candidate.id is not null then
    perform 1 from knowledge.candidates c where c.id = v_candidate.id for share;
    v_candidate := knowledge.current_candidate(p_target_revision_id);
  end if;

  -- Gaten kjøres på nytt på målrevisjonen. Det er ikke overflødig: en revisjon
  -- som var publiserbar i fjor kan ha fått et senere avvist verifikasjonsfunn,
  -- en tilbaketrukket kilde eller en omgjort sluttkontroll. Å rulle tilbake til
  -- den ville da vært å publisere noe som ikke lenger holder.
  perform knowledge.assert_claim_revision_publishable(p_target_revision_id);

  -- Målets gjeldende kandidat må være den som faktisk har vært publisert. Uten
  -- dette kravet kunne en rollback tatt i bruk et innhold som aldri har vært
  -- vist — gaten ville sluppet det gjennom, fordi det er godkjent, men
  -- «tilbake» ville da betydd «til noe nytt».
  if not exists (
    select 1
    from knowledge.publication_events e
    where e.candidate_id = v_candidate.id
  ) then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Det gjeldende innholdet for revisjon %L har aldri vært publisert, og en rollback kan ikke ta det i bruk.',
        p_target_revision_id
      ),
      hint = 'Grunnlaget under revisjonen er endret siden den var publisert, så den gjeldende kandidaten er et annet innhold enn det som faktisk ble vist. Et innhold som aldri har vært publisert, tas i bruk ved en publisering — ikke ved en rollback (DATABASE_ARCHITECTURE.md §40).';
  end if;

  v_control := workflow.current_candidate_final_control(v_candidate.id);

  select c.candidate_digest into v_current_candidate_digest
  from knowledge.candidates c
  where c.id = v_current_candidate_id;

  v_previous_event_id := (knowledge.publication_head_event(p_claim_id)).id;

  update knowledge.claims
  set current_published_revision_id = p_target_revision_id,
      current_published_candidate_id = v_candidate.id
  where id = p_claim_id;

  insert into knowledge.publication_events (
    claim_id, action, revision_id, revision_number,
    previous_revision_id, previous_revision_number, previous_event_id,
    candidate_id, candidate_digest, final_control_id, final_control_decision,
    previous_candidate_id, previous_candidate_digest,
    published_by_actor_id, published_by_actor_type, reason, published_at
  )
  select
    p_claim_id, 'rollback', p_target_revision_id, v_target_revision_number,
    v_current_revision_id, v_current_revision_number, v_previous_event_id,
    v_candidate.id, v_candidate.candidate_digest, v_control.id, v_control.decision,
    v_current_candidate_id, v_current_candidate_digest,
    p_publisher_actor_id, a.actor_type, p_reason, now()
  from provenance.actors a
  where a.id = p_publisher_actor_id
  returning id into v_event_id;

  return v_event_id;
end;
$$;

comment on function knowledge.rollback_claim_publication(uuid, uuid, uuid, text) is
  'Rollback (DATABASE_ARCHITECTURE.md §40): flytter begge publiseringspekerne tilbake til en tidligere publisert revisjon og registrerer det som en ny hendelse. Sletter aldri den publiseringen den korrigerer. Tre krav om målet, og alle tre håndheves her: revisjonen må faktisk ha vært publisert, hele publiseringsgaten må holde på nytt — en revisjon som var publiserbar tidligere kan ha fått et senere avvik eller en omgjort sluttkontroll — og målets *gjeldende* kandidat må være et innhold som faktisk har vært publisert. Det siste er forskjellen mellom å gå tilbake og å ta i bruk noe nytt: er grunnlaget endret siden revisjonen var publisert, bygger innholdet til et annet avtrykk, og det avtrykket har aldri vært vist.';

-- ----------------------------------------------------------------------------
-- 10. Sluttkontrollen hendelsen navngir, må være den gjeldende
--
-- Fremmednøkkelen over binder hendelsen til en sluttkontroll som gjelder
-- nøyaktig den kandidaten og det avtrykket, og CHECK-en krever at den er
-- `approved`. Til sammen gjør de det umulig å publisere på en avvisning — men
-- ikke på en *utdatert* godkjenning: en kandidat kan ha en godkjenning fra i går
-- og en avvisning fra i dag, og en fremmednøkkel kan bare kreve at raden finnes,
-- ikke at den er den siste.
--
-- Publiseringsgatens G12 leser den gjeldende, så den kontrollerte veien er
-- allerede riktig. Denne triggeren gjør regelen til tabellens egen, slik at også
-- en framtidig skrivevei — eller en vedlikeholdsoperasjon — får den samme
-- avvisningen. Det er en av tverradsinvariantene DATABASE_ARCHITECTURE.md §60
-- navngir som legitim triggerbruk: en CHECK kan ikke lese en annen tabell.
-- ----------------------------------------------------------------------------
create function knowledge.assert_publication_cites_current_final_control()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
declare
  v_current workflow.candidate_final_controls;
begin
  if new.final_control_id is null then
    return new;
  end if;

  v_current := workflow.current_candidate_final_control(new.candidate_id);

  if v_current.id is distinct from new.final_control_id then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Publiseringshendelsen viser til sluttkontrollen %L, men den gjeldende for kandidaten %L er %L.',
        new.final_control_id, new.candidate_id, v_current.id
      ),
      hint = 'En senere sluttkontroll gjelder foran en tidligere, og rekkefølgen leses av registreringsnummeret. En publisering kan ikke hvile på en godkjenning som er gjort om etterpå (ANTIDEP_CONSTITUTION.md regel 5).';
  end if;

  return new;
end;
$$;

comment on function knowledge.assert_publication_cites_current_final_control() is
  'Tverradsinvariant: en publiseringshendelse kan bare navngi den *gjeldende* sluttkontrollen for kandidaten sin. Fremmednøkkelen krever at raden finnes og at den er approved; denne krever at den ikke er gjort om etterpå. Uten den ville en kandidat med en godkjenning fra i går og en avvisning fra i dag fortsatt kunnet bære en publisering gjennom en skrivevei som ikke gikk via publiseringsgaten (DATABASE_ARCHITECTURE.md §60).';

revoke execute on function knowledge.assert_publication_cites_current_final_control() from public;

create trigger publication_events_cite_current_final_control
  before insert on knowledge.publication_events
  for each row execute function knowledge.assert_publication_cites_current_final_control();

-- ----------------------------------------------------------------------------
-- 11. Fjerningsveien for upubliserte påstandsartefakter kjenner kandidaten
--
-- knowledge.discard_unpublished_claim_artifacts(uuid[], text) er den ene,
-- sterkt guardede veien til å fjerne et upublisert agentartefakt. Den er eldre
-- enn kandidaten: den sletter revisjonene, men vet ikke at
-- knowledge.candidates peker på dem med RESTRICT. En revisjon som var forseglet,
-- kunne derfor ikke fjernes i det hele tatt — kallet feilet på en fremmednøkkel
-- framfor på en setning som sier hvorfor.
--
-- Veien er uendret i alt annet. Det som er nytt er tre ting, og de følger
-- funksjonens egen logikk:
--
--   * en kandidat som *er sluttkontrollert*, stopper fjerningen, av samme grunn
--     som en menneskelig kontroll og en reviewbeslutning gjør det: en faglig
--     beslutning med en ansvarlig bak skal ikke kunne forsvinne,
--   * en kandidat uten sluttkontroll er rent agentarbeid og fjernes med resten,
--     etter at øyeblikksbildet har tatt vare på avtrykket, og
--   * de to nye tabellene låses sammen med de øvrige, slik at kontrollen og
--     slettingen ser den samme tilstanden.
-- ----------------------------------------------------------------------------
create or replace function knowledge.discard_unpublished_claim_artifacts(
  p_claim_ids uuid[],
  p_reason text
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_id uuid;
  v_snapshots jsonb := '{}'::jsonb;
  v_removed jsonb := '[]'::jsonb;
  v_citations bigint := 0;
  v_verifications bigint := 0;
  v_assessments bigint := 0;
  v_links bigint := 0;
  v_candidates bigint := 0;
  v_revisions bigint := 0;
  v_claims bigint := 0;
begin
  -- Fjerningen er en redaksjonell handling med en ansvarlig, ikke en
  -- driftsoperasjon: auditraden skal navngi den som bestemte den.
  v_actor_id := knowledge.assert_editor_authorized();

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Fjerningen mangler en begrunnelse, og da kan den ikke registreres.',
      hint = 'Oppgi hvorfor påstandene fjernes. Begrunnelsen er det som gjør en hard sletting rapporterbar i ettertid (ANTIDEP_CONSTITUTION.md §14).';
  end if;

  if p_claim_ids is null or cardinality(p_claim_ids) = 0 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Ingen påstander er oppgitt.',
      hint = 'Veien tar en eksplisitt liste med id-er. Den kan ikke kalles med et predikat, og den kan ikke feie: hvilke rader som fjernes, skal være skrevet ned før kallet, ikke utledet av det.';
  end if;

  if cardinality(p_claim_ids) > 50 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('%s påstander er oppgitt, og grensen er 50.', cardinality(p_claim_ids)),
      hint = 'En reset er en navngitt liste noen har gått gjennom. Er listen lengre enn dette, er den ikke gjennomgått.';
  end if;

  if (select count(distinct x) from unnest(p_claim_ids) as x)
     <> cardinality(p_claim_ids) then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Listen inneholder samme påstand mer enn én gang.',
      hint = 'En dublett betyr at listen ikke er den gjennomgåtte listen. Rett den framfor å la kallet gjøre noe annet enn det som ble bestemt.';
  end if;

  -- ------------------------------------------------------------------------
  -- Låsen. Tas før kontrollene, slik at tilstanden de leser, er den samme
  -- tilstanden slettingen møter.
  --
  -- De to øverste er rettelsen i denne migrasjonen. Kontrollene leser
  -- `workflow.evidence_verifications` og `workflow.review_decisions` for
  -- evidensfunnene påstanden er lenket til — men begge tabellene peker på
  -- `knowledge.evidence_items`, som denne veien ikke rører. En innsetting der
  -- trengte derfor ikke røre noen av de seks låste tabellene, og kunne commite
  -- i vinduet mellom «vakten leste ingen» og slettingen. Da ville kallet
  -- returnert suksess samtidig som vilkåret det lover å feile lukket på, var
  -- sant. `on delete restrict` beskytter ikke her, i motsetning til i
  -- migrasjon 005af: der pekte de samme radene på funnet som ble slettet.
  --
  -- `workflow.evidence_verifications` står først, i samme posisjon som i
  -- 005af, slik at de to veiene ikke kan ta den samme låsen i motsatt
  -- rekkefølge. Resten er slettingens egen rekkefølge, slik at ingen lås må
  -- oppgraderes underveis.
  -- ------------------------------------------------------------------------
  lock table workflow.evidence_verifications in access exclusive mode;
  lock table workflow.review_decisions in access exclusive mode;
  lock table workflow.claim_verification_citations in access exclusive mode;
  lock table workflow.claim_verifications in access exclusive mode;
  lock table knowledge.evidence_assessments in access exclusive mode;
  lock table knowledge.claim_evidence_links in access exclusive mode;
  -- Kandidaten og sluttkontrollen er nye siden migrasjon 009d, og
  -- knowledge.candidates peker på knowledge.claim_revisions med RESTRICT: uten
  -- at de låses og fjernes her, ville slettingen feilet på en fremmednøkkel
  -- framfor på en setning som sier hvorfor. Låsen står før kontrollen av
  -- sluttkontrollen, av samme grunn som de to øverste.
  lock table workflow.candidate_final_controls in access exclusive mode;
  lock table knowledge.candidates in access exclusive mode;
  lock table knowledge.claim_revisions in access exclusive mode;
  lock table knowledge.claims in access exclusive mode;

  -- ------------------------------------------------------------------------
  -- Kontrollene. Alle kjøres før noe slettes, og én rad som feiler stopper
  -- hele kallet: en delvis reset ville etterlatt en tilstand ingen bestemte.
  -- ------------------------------------------------------------------------
  foreach v_id in array p_claim_ids loop
    if not exists (select 1 from knowledge.claims c where c.id = v_id) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('Påstanden %s finnes ikke.', v_id),
        hint = 'Listen er ikke den databasen har. Hent tilstanden på nytt framfor å fjerne noe annet enn det som ble gjennomgått.';
    end if;

    if exists (select 1 from knowledge.claims c
               where c.id = v_id and c.current_published_revision_id is not null) then
      raise exception using
        errcode = 'restrict_violation',
        message = format('Påstanden %s er publisert, og fjernes ikke.', v_id),
        hint = 'En publisert påstand er klinisk historikk. Den trekkes tilbake gjennom knowledge.withdraw_claim_publication(...), som etterlater et spor — den slettes ikke (ANTIDEP_CONSTITUTION.md §13).';
    end if;

    -- publication_events peker på påstanden selv, ikke på revisjonen, og har
    -- `on delete restrict` mot den: en slettning ville feilet uansett. Kontrollen
    -- står her for å feile med en setning som sier hvorfor, framfor med en
    -- fremmednøkkel.
    if exists (select 1 from knowledge.publication_events pe
               where pe.claim_id = v_id) then
      raise exception using
        errcode = 'restrict_violation',
        message = format('Påstanden %s har vært publisert, og fjernes ikke.', v_id),
        hint = 'En påstand som har vært publisert, har vært klinisk innhold noen kan ha lest. Historikken om det skal bestå (§13, §14).';
    end if;

    if exists (
      select 1
      from workflow.claim_verifications cv
      join knowledge.claim_revisions cr on cr.id = cv.claim_revision_id
      join provenance.actors a on a.id = cv.verifier_actor_id
      where cr.claim_id = v_id
        and a.actor_type = 'human'
    ) then
      raise exception using
        errcode = 'restrict_violation',
        message = format('Påstanden %s er menneskelig kontrollert, og fjernes ikke.', v_id),
        hint = 'En utført menneskelig kontroll er en faglig handling med en ansvarlig bak. Den skal ikke kunne forsvinne (ANTIDEP_CONSTITUTION.md §12, §14).';
    end if;

    if exists (
      select 1
      from workflow.evidence_verifications ev
      join knowledge.claim_evidence_links l on l.evidence_item_id = ev.evidence_item_id
      join knowledge.claim_revisions cr on cr.id = l.claim_revision_id
      join provenance.actors a on a.id = ev.verifier_actor_id
      where cr.claim_id = v_id
        and a.actor_type = 'human'
    ) then
      raise exception using
        errcode = 'restrict_violation',
        message = format('Et evidensfunn under påstanden %s er menneskelig kildekontrollert, og påstanden fjernes ikke.', v_id),
        hint = 'Kontrollen dokumenterer hva en kontrollør faktisk fant. Å fjerne påstanden ville tatt lenken kontrollen gjaldt, med seg (§12, §14).';
    end if;

    if exists (
      select 1
      from workflow.candidate_final_controls fc
      join knowledge.candidates ca on ca.id = fc.candidate_id
      join knowledge.claim_revisions cr on cr.id = ca.claim_revision_id
      where cr.claim_id = v_id
    ) then
      raise exception using
        errcode = 'restrict_violation',
        message = format('Påstanden %s er sluttkontrollert av en navngitt fagperson, og fjernes ikke.', v_id),
        hint = 'En sluttkontroll er en faglig beslutning om et konkret innhold, med en ansvarlig bak. Den skal ikke kunne forsvinne, og heller ikke det innholdet den gjaldt (ANTIDEP_CONSTITUTION.md regel 5, 6). En kandidat uten sluttkontroll er derimot rent agentarbeid, og fjernes med resten.';
    end if;

    if exists (
      select 1
      from workflow.review_decisions rd
      join knowledge.claim_evidence_links l on l.evidence_item_id = rd.evidence_item_id
      join knowledge.claim_revisions cr on cr.id = l.claim_revision_id
      where cr.claim_id = v_id
    ) then
      raise exception using
        errcode = 'restrict_violation',
        message = format('Et evidensfunn under påstanden %s har en registrert reviewbeslutning, og påstanden fjernes ikke.', v_id),
        hint = 'En beslutning er en utført faglig handling, og tabellen er append-only av samme grunn som kontrollene.';
    end if;

    -- Øyeblikksbildet tas før slettingen, og er hele kontrollgrunnlaget: det som
    -- fjernes, skal fortsatt kunne leses av den som spør hva som sto der.
    v_snapshots := v_snapshots || jsonb_build_object(
      v_id::text,
      jsonb_build_object(
        -- `id` er påkrevd av events_snapshot_identifies_object_check.
        'id', v_id,
        'claim', (select to_jsonb(c) from knowledge.claims c where c.id = v_id),
        'revisions', (
          select coalesce(jsonb_agg(to_jsonb(cr) order by cr.revision_number), '[]'::jsonb)
          from knowledge.claim_revisions cr where cr.claim_id = v_id
        ),
        'evidence_links', (
          select coalesce(jsonb_agg(to_jsonb(l) order by l.created_at), '[]'::jsonb)
          from knowledge.claim_evidence_links l
          join knowledge.claim_revisions cr on cr.id = l.claim_revision_id
          where cr.claim_id = v_id
        ),
        'evidence_assessments', (
          select coalesce(jsonb_agg(to_jsonb(ea) order by ea.created_at), '[]'::jsonb)
          from knowledge.evidence_assessments ea
          join knowledge.claim_revisions cr on cr.id = ea.claim_revision_id
          where cr.claim_id = v_id
        ),
        'claim_verifications', (
          select coalesce(jsonb_agg(to_jsonb(cv) order by cv.created_at), '[]'::jsonb)
          from workflow.claim_verifications cv
          join knowledge.claim_revisions cr on cr.id = cv.claim_revision_id
          where cr.claim_id = v_id
        ),
        'candidates', (
          -- Uten innholdet, av samme grunn som auditskriveren på
          -- knowledge.candidates utelater det: avtrykket identifiserer
          -- innholdet entydig, og en andre kopi ville doblet en
          -- tilgangsbegrenset tekst uten å legge til noe spor.
          select coalesce(jsonb_agg(to_jsonb(ca) - 'content' order by ca.built_at), '[]'::jsonb)
          from knowledge.candidates ca
          join knowledge.claim_revisions cr on cr.id = ca.claim_revision_id
          where cr.claim_id = v_id
        ),
        'claim_verification_citations', (
          select coalesce(jsonb_agg(to_jsonb(cc)), '[]'::jsonb)
          from workflow.claim_verification_citations cc
          join workflow.claim_verifications cv on cv.id = cc.claim_verification_id
          join knowledge.claim_revisions cr on cr.id = cv.claim_revision_id
          where cr.claim_id = v_id
        )
      )
    );
  end loop;

  -- ------------------------------------------------------------------------
  -- Slettingen. Append-only-vernet er fasiten for enhver annen skrivevei, og
  -- skrus av bare her, bare i denne transaksjonen, og slås på igjen også når
  -- noe går galt. Rekkefølgen er gitt av fremmednøklene, som alle er RESTRICT.
  -- ------------------------------------------------------------------------
  begin
    -- Samme grunn som i 005af: ALTER TABLE kan ikke kjøre på en tabell med
    -- utsatte triggerhendelser i kø. Modusen settes tilbake etterpå, også når
    -- noe går galt, slik at en lovlig registrering senere i den samme
    -- transaksjonen ikke blir kontrollert før forankringen sin er skrevet.
    set constraints all immediate;

    alter table workflow.claim_verification_citations disable trigger claim_verification_citations_reject_mutation;
    alter table workflow.claim_verifications disable trigger claim_verifications_reject_mutation;
    alter table knowledge.evidence_assessments disable trigger evidence_assessments_reject_mutation;
    alter table knowledge.claim_evidence_links disable trigger claim_evidence_links_reject_mutation;
    alter table knowledge.claim_revisions disable trigger claim_revisions_reject_mutation;
    alter table knowledge.candidates disable trigger candidates_are_append_only;

    delete from workflow.claim_verification_citations cc
    where cc.claim_verification_id in (
      select cv.id from workflow.claim_verifications cv
      join knowledge.claim_revisions cr on cr.id = cv.claim_revision_id
      where cr.claim_id = any(p_claim_ids)
    );
    get diagnostics v_citations = row_count;

    delete from workflow.claim_verifications cv
    where cv.claim_revision_id in (
      select cr.id from knowledge.claim_revisions cr where cr.claim_id = any(p_claim_ids)
    );
    get diagnostics v_verifications = row_count;

    delete from knowledge.evidence_assessments ea
    where ea.claim_revision_id in (
      select cr.id from knowledge.claim_revisions cr where cr.claim_id = any(p_claim_ids)
    );
    get diagnostics v_assessments = row_count;

    delete from knowledge.claim_evidence_links l
    where l.claim_revision_id in (
      select cr.id from knowledge.claim_revisions cr where cr.claim_id = any(p_claim_ids)
    );
    get diagnostics v_links = row_count;

    delete from knowledge.candidates ca
    where ca.claim_revision_id in (
      select cr.id from knowledge.claim_revisions cr where cr.claim_id = any(p_claim_ids)
    );
    get diagnostics v_candidates = row_count;

    delete from knowledge.claim_revisions cr where cr.claim_id = any(p_claim_ids);
    get diagnostics v_revisions = row_count;

    delete from knowledge.claims c where c.id = any(p_claim_ids);
    get diagnostics v_claims = row_count;

    -- Slettingene setter selv hendelser i kø: fremmednøklene mellom de seks
    -- tabellene er utsatte, og en slettet forelder legger igjen en RI-kontroll
    -- som skal kjøre ved commit. `ALTER TABLE` kan ikke kjøre med hendelser i
    -- kø, så køen tømmes her — kontrollene passerer, fordi begge sider av hver
    -- nøkkel er borte.
    set constraints all immediate;

    alter table knowledge.candidates enable trigger candidates_are_append_only;
    alter table knowledge.claim_revisions enable trigger claim_revisions_reject_mutation;
    alter table knowledge.claim_evidence_links enable trigger claim_evidence_links_reject_mutation;
    alter table knowledge.evidence_assessments enable trigger evidence_assessments_reject_mutation;
    alter table workflow.claim_verifications enable trigger claim_verifications_reject_mutation;
    alter table workflow.claim_verification_citations enable trigger claim_verification_citations_reject_mutation;
    set constraints all deferred;
  exception
    when others then
      alter table knowledge.candidates enable trigger candidates_are_append_only;
      alter table knowledge.claim_revisions enable trigger claim_revisions_reject_mutation;
      alter table knowledge.claim_evidence_links enable trigger claim_evidence_links_reject_mutation;
      alter table knowledge.evidence_assessments enable trigger evidence_assessments_reject_mutation;
      alter table workflow.claim_verifications enable trigger claim_verifications_reject_mutation;
      alter table workflow.claim_verification_citations enable trigger claim_verification_citations_reject_mutation;
      set constraints all deferred;
      raise;
  end;

  if v_claims <> cardinality(p_claim_ids) then
    -- Kan i praksis ikke skje: eksistensen er kontrollert over, og
    -- transaksjonen har holdt låsen siden før kontrollene.
    raise exception using
      errcode = 'restrict_violation',
      message = format('%s av %s påstander ble fjernet. Ingenting er lagret.',
                       v_claims, cardinality(p_claim_ids));
  end if;

  -- ------------------------------------------------------------------------
  -- Sporet. Én rad per fjernet påstand, med det som sto der.
  -- ------------------------------------------------------------------------
  foreach v_id in array p_claim_ids loop
    insert into audit.events
      (operation, object_id, actor_id, old_revision_or_snapshot, reason, occurred_at)
    values
      ('claim_artifact_discarded', v_id, v_actor_id,
       v_snapshots -> v_id::text, btrim(p_reason), now());
    v_removed := v_removed || to_jsonb(v_id::text);
  end loop;

  return jsonb_build_object(
    'discarded_claim_ids', v_removed,
    'deleted_candidates', v_candidates,
    'deleted_claim_revisions', v_revisions,
    'deleted_evidence_links', v_links,
    'deleted_evidence_assessments', v_assessments,
    'deleted_claim_verifications', v_verifications,
    'deleted_claim_verification_citations', v_citations,
    'discarded_by_actor_id', v_actor_id,
    'reason', btrim(p_reason)
  );
end;
$$;

comment on function knowledge.discard_unpublished_claim_artifacts(uuid[], text) is
  'Den ene, sterkt guardede veien til å fjerne et upublisert påstandsartefakt med revisjonene, lenkene, vurderingene, kontrollene og de forseglede kandidatene sine. Uendret fra migrasjon 005ai bortsett fra kandidatlaget: knowledge.candidates og workflow.candidate_final_controls låses sammen med de øvrige, en kandidat som er sluttkontrollert av en navngitt fagperson stopper fjerningen slik en menneskelig kontroll og en reviewbeslutning gjør det, og en kandidat uten sluttkontroll fjernes med resten etter at øyeblikksbildet har tatt vare på avtrykket. Uten det ville en forseglet revisjon ikke kunnet fjernes i det hele tatt: knowledge.candidates peker på knowledge.claim_revisions med RESTRICT, og kallet ville feilet på en fremmednøkkel framfor på en setning som sier hvorfor. Ikke en redaksjonell funksjon: EXECUTE er revokert fra PUBLIC og gitt til ingen klientrolle.';
