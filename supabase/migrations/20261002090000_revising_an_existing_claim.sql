-- ============================================================================
-- Migrasjon 012d — revisjonen av en påstand som allerede finnes
--
-- Dette er det siste stedet kjeden med vilje stopper før den er tom for
-- arbeid. Kommer det et nytt evidensfunn om et virkestoff og et endepunkt som
-- allerede har en påstand, blir funnet kontrollert og står klart — men *hva*
-- påstanden skal si i lys av det, er en redaksjonell avgjørelse og ikke en
-- transport (docs/ROADMAP.md, docs/EVIDENCE_PIPELINE.md).
--
-- Fram til nå var den grensen et `return null` inne i
-- `workflow.chain_task_for_verified_extraction(uuid)`. Kjeden stoppet riktig,
-- og den stoppet stille: ingen rad sa at det fantes ny kunnskap som ventet på
-- et menneske, ingen flate viste det, og ingen kunne avgjøre noe.
--
-- Denne migrasjonen gjør tilstanden eksplisitt og gir den en vei ut.
--
-- ----------------------------------------------------------------------------
-- 1. Tilstanden er en rad, ikke fraværet av en jobb
--
-- `workflow.claim_revision_reviews` har én rad per påstand som har ny evidens
-- den ikke hviler på. Raden er varig: den overlever en sideoppfriskning, en
-- omstart og en ny sesjon, og den bærer sin egen ugjennomsiktige referanse slik
-- at en flate kan peke på den uten at en intern id står på skjermen.
--
-- Raden er idempotent på påstanden. Kommer det fem nye funn om det samme
-- virkestoffet og endepunktet, er det fortsatt én avgjørelse å ta, og det blir
-- fortsatt én rad. Det som endrer seg, er *grunnlaget* — og det føres som en
-- ny linje i sporet framfor som en ny oppgave.
--
-- ----------------------------------------------------------------------------
-- 2. Hva «ny evidens» er, og hvorfor den er avledet
--
-- Ny evidens er de brukbare evidensfunnene om påstandens virkestoff og
-- endepunkt som ingen revisjon av påstanden hviler på. «Brukbar» leses med
-- `workflow.evidence_usable_problem(uuid[], text)` — den samme funksjonen
-- skriveveien leser — slik at den redaksjonelle oppgaven ikke kan vise fram et
-- funn en syntese uansett ikke kunne bygget på.
--
-- Mengden er avledet og ikke lagret. En kopi ville drevet fra sannheten i det
-- et funn ble trukket tilbake eller fikk et åpent avvik, og flaten ville bedt
-- en redaktør ta stilling til noe som ikke lenger fantes.
--
-- Raden er derimot ikke avledet, og det er hele poenget: den sier at Antidep
-- *har lagt merke til* dette, når det skjedde, og hva som eventuelt ble
-- besluttet. Det er opplysninger ingen avledning kan svare på.
--
-- ----------------------------------------------------------------------------
-- 3. Beslutningen er bundet til det grunnlaget redaktøren faktisk så
--
-- Flaten får et avtrykk av hele det brukbare evidensgrunnlaget — ikke bare av
-- det nye — og sender det uendret tilbake med beslutningen. Databasen regner
-- avtrykket ut på nytt under subjektlåsen og avviser en beslutning som gjelder
-- et annet grunnlag enn det som ligger der nå. Det er den samme formen
-- sluttkontrollen har mot kandidatens avtrykk (ANTIDEP_CONSTITUTION.md regel 5):
-- en attestasjon av noe den som attesterte aldri ble vist, er ingen attestasjon.
--
-- Avvisningen er ikke en feil, og flaten skriver sin egen setning om den: hent
-- fersk tilstand, og ta stilling til det som faktisk finnes.
--
-- ----------------------------------------------------------------------------
-- 4. Når revisjon er besluttet, går resten av seg selv
--
-- Beslutningen bygger ikke noe nytt. Den legger inn nøyaktig den
-- `claim_synthesis`-oppgaven kjeden selv ville lagt inn — samme manifest, samme
-- jobbnøkkel, samme forhåndskontroll av grunnlaget, samme
-- `workflow.chain_enqueue_job(...)` — med ett felt til: `claim_id`. Det feltet
-- har vært en del av oppgavekontrakten siden migrasjon 010c
-- (`workflow.agent_task(workflow.pipeline_jobs)` bærer det, og
-- `knowledge.record_agent_claim_synthesis(...)` leser det), og det er det som
-- gjør svaret til en *ny revisjon av den påstanden* framfor til en ny påstand.
--
-- Derfra er det ingenting nytt: den registrerte påstandsrevisjonen legger
-- kildestøttekontrollen i køen, den beståtte kontrollen legger evidensvurderingen
-- i køen, og den registrerte vurderingen forsegler kandidaten. Ingen parallell
-- syntese- eller kontrollarkitektur, ingen ny skrivevei, ingen kontrollport
-- svekket. Den nye revisjonen er en ny rad; alle tidligere revisjoner,
-- kandidater og publiseringer står uendret (ANTIDEP_CONSTITUTION.md regel 6).
--
-- ----------------------------------------------------------------------------
-- 5. Hvorfor «sett til side» finnes, og hvorfor det ikke er et valg for
--    fleksibilitetens skyld
--
-- Uten den avgjørelsen ville en oppgave der redaktøren konkluderer med at den
-- nye evidensen ikke endrer påstanden, blitt stående for alltid. Den ville
-- ligget i den åpne arbeidsoversikten som planlagt arbeid ingen kommer til å
-- gjøre, og enhver senere vurdering av hvor mye som gjenstår, ville vært usann
-- (ANTIDEP_CONSTITUTION.md regel 4).
--
-- «Sett til side» er derfor en faglig konklusjon og ikke en utsettelse: den
-- krever en begrunnelse, den navngir hvem som tok den, og den er bundet til det
-- samme evidensavtrykket som en besluttet revisjon. Kommer det *ny* evidens
-- etterpå, er grunnlaget et annet, og oppgaven åpner seg igjen av seg selv.
--
-- ----------------------------------------------------------------------------
-- 6. En teknisk svikt blir aldri en menneskeoppgave
--
-- En besluttet revisjon peker på den synteseoppgaven den la inn. Oppgaven kan
-- stoppe teknisk — og da er den et teknisk problem under `automatic_task` og
-- stoppet arbeid i den åpne oversikten, akkurat som alt annet stoppet arbeid.
-- Den redaksjonelle oppgaven åpner seg *ikke* igjen av det: redaktøren har
-- allerede avgjort det som var vedkommendes å avgjøre, og å be om den samme
-- avgjørelsen en gang til ville gjort en driftsfeil til klinisk arbeid.
--
-- Den åpner seg igjen bare når den besluttede revisjonen faktisk ble skrevet
-- *og* grunnlaget siden er blitt et annet.
--
-- Styrende dokumenter: AGENTS.md, docs/ANTIDEP_CONSTITUTION.md (regel 1, 4, 5,
-- 6, 7), docs/EVIDENCE_PIPELINE.md, docs/DATABASE_ARCHITECTURE.md,
-- docs/ROADMAP.md.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Vokabularene
-- ----------------------------------------------------------------------------
create type workflow.claim_revision_review_state as enum (
  'open', 'revision_ordered', 'set_aside');

revoke usage on type workflow.claim_revision_review_state from public;

comment on type workflow.claim_revision_review_state is
  'Hvor en redaksjonell revisjonsvurdering står: open (ny evidens venter på en avgjørelse), revision_ordered (en redaktør har besluttet at påstanden skal revideres, og synteseoppgaven ligger i køen) eller set_aside (en redaktør har konkludert med at den nye evidensen ikke endrer påstanden). De tre er uttømmende, og de to siste er avgjørelser med et menneske bak — ikke fravær av arbeid.';

create type workflow.claim_revision_review_transition as enum (
  'opened', 'widened', 'reopened', 'revision_ordered', 'set_aside');

revoke usage on type workflow.claim_revision_review_transition from public;

comment on type workflow.claim_revision_review_transition is
  'Overgangen ett spor beskriver: opened (Antidep la merke til ny evidens om en påstand som finnes), widened (enda et funn kom til mens oppgaven sto åpen), reopened (grunnlaget er blitt et annet siden forrige avgjørelse), revision_ordered og set_aside (en redaktør avgjorde). Skillet mellom opened og widened er grunnen til at sporet finnes: uten det kunne ingen svare på om oppgaven har vokst siden den ble sett.';

-- ----------------------------------------------------------------------------
-- 2. Avtrykket av en mengde evidensfunn
--
-- Samme lengdeprefiksede kanonisering og versjonerte prefiks som
-- `knowledge.claim_evidence_set_digest(uuid)`: «lengde:verdi», og «~» skiller
-- en tom mengde fra en manglende verdi. Sorteringen gjør avtrykket uavhengig av
-- rekkefølgen kalleren samlet id-ene i.
--
-- Egen funksjon og ikke den som finnes, fordi den finnes tar en
-- *påstandsrevisjon* og leser lenkene under den. Her er mengden ikke lenket til
-- noe ennå — den er nettopp det som ikke har blitt en revisjon.
-- ----------------------------------------------------------------------------
create function workflow.evidence_set_digest(p_evidence_item_ids uuid[])
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  select 'sha256-v1:' || encode(
    sha256(convert_to(
      coalesce(
        (select string_agg('|' || length(x.id::text)::text || ':' || x.id::text,
                           '' order by x.id::text)
         from unnest(coalesce(p_evidence_item_ids, array[]::uuid[])) as x(id)),
        '|~:'
      ),
      'UTF8'
    )),
    'hex'
  );
$$;

comment on function workflow.evidence_set_digest(uuid[]) is
  'Fingeravtrykk av en mengde evidensfunn, uavhengig av rekkefølgen den ble samlet i. Brukes til å binde en redaksjonell beslutning til nøyaktig det evidensgrunnlaget redaktøren tok stilling til, slik at en beslutning tatt på et foreldet grunnlag kan avvises framfor å bli gjennomført på noe annet. Samme kanonisering som knowledge.claim_evidence_set_digest(uuid); en tom mengde har sitt eget avtrykk og kan ikke forveksles med en manglende verdi.';

revoke execute on function workflow.evidence_set_digest(uuid[]) from public;

-- ----------------------------------------------------------------------------
-- 3. Grunnlaget: hva som finnes, og hva påstanden allerede hviler på
-- ----------------------------------------------------------------------------
create function workflow.claim_subject_evidence(
  p_subject_drug_id uuid,
  p_topic_concept_id uuid
)
  returns uuid[]
  language sql
  stable
  set search_path = ''
as $$
  select coalesce(array_agg(e.id order by e.id), array[]::uuid[])
  from knowledge.evidence_items e
  where e.intervention_drug_id = p_subject_drug_id
    and e.outcome_concept_id = p_topic_concept_id
    and workflow.evidence_usable_problem(array[e.id], 'x') is null;
$$;

comment on function workflow.claim_subject_evidence(uuid, uuid) is
  'Hele det brukbare evidensgrunnlaget om ett virkestoff og ett endepunkt, i den rekkefølgen en synteseoppgave bærer det. Brukbarheten leses med workflow.evidence_usable_problem(uuid[], text) — den samme funksjonen skriveveien leser — slik at grunnlaget en redaktør får se, er nøyaktig det en syntese ville kunne bygge på. Ett sted framfor to: kjedeovergangen og den redaksjonelle beslutningen skal aldri kunne bygge hvert sitt sett.';

revoke execute on function workflow.claim_subject_evidence(uuid, uuid) from public;

create function workflow.claim_revision_new_evidence(p_claim_id uuid)
  returns uuid[]
  language sql
  stable
  set search_path = ''
as $$
  select coalesce(array_agg(wanted.id order by wanted.id), array[]::uuid[])
  from knowledge.claims c
  cross join lateral unnest(
    workflow.claim_subject_evidence(c.subject_drug_id, c.topic_concept_id)) as wanted(id)
  where c.id = p_claim_id
    and not exists (
      select 1
      from knowledge.claim_evidence_links l
      join knowledge.claim_revisions r on r.id = l.claim_revision_id
      where r.claim_id = c.id and l.evidence_item_id = wanted.id
    );
$$;

comment on function workflow.claim_revision_new_evidence(uuid) is
  'De brukbare evidensfunnene om påstandens virkestoff og endepunkt som ingen revisjon av påstanden hviler på — altså den nye kunnskapen en redaktør skal ta stilling til. Avledet og ikke lagret: en kopi ville drevet fra sannheten i det et funn ble trukket tilbake eller fikk et åpent avvik, og flaten ville bedt om en avgjørelse om noe som ikke lenger fantes.';

revoke execute on function workflow.claim_revision_new_evidence(uuid) from public;

-- ----------------------------------------------------------------------------
-- 4. Hvilken påstand en revisjon vil gjelde
--
-- To atomiske påstander om det samme virkestoffet og det samme endepunktet er
-- normalt og riktig (docs/EVIDENCE_PIPELINE.md), men en synteseoppgave om det
-- paret er *én* oppgave: jobbnøkkelens subjekt er virkestoffet og endepunktet.
-- Revisjonen må derfor gjelde nøyaktig én påstand, og valget kan ikke være
-- vilkårlig fra gang til gang.
--
-- Den eldste ikke-tilbaketrukne evidenssyntesen for paret er den påstanden.
-- Eldst og ikke nyest, fordi den da ikke flytter seg når en ny påstand om det
-- samme paret kommer til: en oppgave som pekte på en annen påstand i går enn i
-- dag, ville vært en annen oppgave uten at noe sa fra.
--
-- Finnes ingen slik påstand — alle er trukket tilbake, eller de er av en annen
-- kunnskapstype — finnes det ingen revisjon å be om, og ingen oppgave lages.
-- Kjeden stopper som før, og det er riktig: en tilbaketrukket påstand skal ikke
-- få nye revisjoner (knowledge.record_agent_claim_synthesis).
-- ----------------------------------------------------------------------------
create function workflow.claim_awaiting_revision(
  p_subject_drug_id uuid,
  p_topic_concept_id uuid
)
  returns uuid
  language sql
  stable
  set search_path = ''
as $$
  select c.id
  from knowledge.claims c
  where c.subject_drug_id = p_subject_drug_id
    and c.topic_concept_id = p_topic_concept_id
    and c.knowledge_type = 'evidence_synthesis'
    and c.retired_at is null
  order by c.created_at, c.id
  limit 1;
$$;

comment on function workflow.claim_awaiting_revision(uuid, uuid) is
  'Påstanden en revisjon av dette virkestoffet og dette endepunktet vil gjelde: den eldste ikke-tilbaketrukne evidenssyntesen for paret. Eldst og ikke nyest, slik at valget ikke flytter seg når en ny påstand om det samme paret kommer til. NULL når ingen slik påstand finnes — da er det ingen revisjon å be om, og kjeden stopper som før.';

revoke execute on function workflow.claim_awaiting_revision(uuid, uuid) from public;

-- ----------------------------------------------------------------------------
-- 5. Tilstanden
-- ----------------------------------------------------------------------------
create table workflow.claim_revision_reviews (
  id uuid primary key default gen_random_uuid(),

  -- Håndtaket flaten bruker, og ikke radens id: en redaktør skal kunne åpne
  -- oppgaven uten at en intern verdi står i adressefeltet.
  reference text not null default workflow.new_public_reference(),

  -- Påstanden som har ny evidens den ikke hviler på. Unik: fem nye funn om det
  -- samme er fortsatt én avgjørelse å ta.
  claim_id uuid not null
    references knowledge.claims (id) on update restrict on delete restrict,

  state workflow.claim_revision_review_state not null default 'open',

  -- Avtrykket av hele det brukbare evidensgrunnlaget slik det var da tilstanden
  -- sist ble skrevet. Står også på en avgjort rad, fordi «har grunnlaget endret
  -- seg siden sist?» er spørsmålet som avgjør om oppgaven skal åpne seg igjen.
  pending_evidence_digest text not null,

  -- Avtrykket redaktøren faktisk tok stilling til. NULL mens oppgaven er åpen.
  decided_evidence_digest text,
  decided_at timestamptz,
  decided_by_actor_id uuid
    references provenance.actors (id) on update restrict on delete restrict,
  decision_note text,

  -- Synteseoppgaven beslutningen la inn. Bindingen er det som gjør at en
  -- besluttet revisjon kan skilles fra en som aldri ble bygget.
  pipeline_job_id uuid
    references workflow.pipeline_jobs (id) on update restrict on delete restrict,

  opened_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint claim_revision_reviews_claim_key unique (claim_id),
  constraint claim_revision_reviews_reference_key unique (reference),
  constraint claim_revision_reviews_pending_digest_shape_check
    check (pending_evidence_digest ~ '^sha256-v1:[0-9a-f]{64}$'),
  constraint claim_revision_reviews_decided_digest_shape_check
    check (decided_evidence_digest is null
           or decided_evidence_digest ~ '^sha256-v1:[0-9a-f]{64}$'),
  constraint claim_revision_reviews_note_shape_check
    check (decision_note is null
           or (decision_note = btrim(decision_note)
               and length(decision_note) between 1 and 2000)),

  -- Hva som skal være satt følger av tilstanden, og regelen er uttømmende over
  -- vokabularet. Uten else-grenen ville en ny tilstandsverdi gitt NULL, og en
  -- NULL passerer en CHECK — regelen ville stilltiende sluttet å gjelde for
  -- nettopp den tilstanden som er ny.
  constraint claim_revision_reviews_state_shape_check
    check (
      case state
        when 'open' then
          decided_evidence_digest is null and decided_at is null
          and decided_by_actor_id is null and decision_note is null
          and pipeline_job_id is null
        when 'revision_ordered' then
          decided_evidence_digest is not null and decided_at is not null
          and decided_by_actor_id is not null and pipeline_job_id is not null
        when 'set_aside' then
          decided_evidence_digest is not null and decided_at is not null
          and decided_by_actor_id is not null and decision_note is not null
          and pipeline_job_id is null
        else false
      end
    )
);

comment on table workflow.claim_revision_reviews is
  'Ny evidens om en påstand som allerede finnes, og den redaksjonelle avgjørelsen om hva som skal skje med den (docs/ROADMAP.md). Én rad per påstand: flere nye funn om det samme virkestoffet og endepunktet er fortsatt én avgjørelse å ta, ikke flere menneskeoppgaver. Raden er varig og eksplisitt framfor avledet av at en jobb mangler — «Antidep har lagt merke til dette, og det venter på et menneske» er en tilstand, og fravær er ingen tilstand (ANTIDEP_CONSTITUTION.md regel 4). Selve evidensgrunnlaget er derimot avledet av workflow.claim_revision_new_evidence(uuid), slik at et funn som trekkes tilbake, forsvinner fra oppgaven av seg selv. Tilstanden endres; overgangene bevares i workflow.claim_revision_review_events.';
comment on column workflow.claim_revision_reviews.reference is
  'Det ugjennomsiktige håndtaket redaktørflaten peker på oppgaven med. En egen tilfeldig verdi og ikke radens id, slik at ingen intern identifikator står på skjermen eller i en adresse (AGENTS.md).';
comment on column workflow.claim_revision_reviews.pending_evidence_digest is
  'Avtrykket av hele det brukbare evidensgrunnlaget for påstandens virkestoff og endepunkt, slik det var da raden sist ble skrevet. Dekker hele grunnlaget og ikke bare det nye, fordi det er hele grunnlaget synteseoppgaven bygges av: en beslutning bundet til bare det nye ville ikke fanget at et gammelt funn i mellomtiden ble trukket tilbake.';
comment on column workflow.claim_revision_reviews.decided_evidence_digest is
  'Avtrykket redaktøren faktisk tok stilling til. Oppgaven åpner seg igjen bare når grunnlaget er blitt et annet enn dette — så en avgjørelse gjelder det den gjaldt, og ikke noe som kom etterpå.';
comment on column workflow.claim_revision_reviews.pipeline_job_id is
  'Synteseoppgaven en besluttet revisjon la inn. Peker på nøyaktig det arbeidet beslutningen utløste, slik at «ble revisjonen faktisk bygget?» kan besvares uten å gjette. Står bare i tilstanden revision_ordered.';

alter table workflow.claim_revision_reviews enable row level security;

create index claim_revision_reviews_open_idx
  on workflow.claim_revision_reviews (opened_at)
  where state = 'open';

create trigger claim_revision_reviews_set_row_timestamps
  before insert or update on workflow.claim_revision_reviews
  for each row execute function catalog.set_row_timestamps();

create table workflow.claim_revision_review_events (
  id uuid primary key default gen_random_uuid(),

  claim_revision_review_id uuid not null
    references workflow.claim_revision_reviews (id) on update restrict on delete restrict,
  transition workflow.claim_revision_review_transition not null,

  -- Grunnlaget slik det var i det overgangen skjedde, og hvor mange nye funn
  -- som da ventet. Tallet er ikke utledbart i ettertid: settet endrer seg.
  evidence_digest text not null,
  new_evidence_count integer not null,

  -- Redaktøren, når overgangen var en avgjørelse. NULL når det var Antidep som
  -- la merke til noe: de to er forskjellige ting, og en oppdiktet aktør på en
  -- automatisk overgang ville vært en attribusjon uten et menneske bak.
  actor_id uuid
    references provenance.actors (id) on update restrict on delete restrict,
  note text,

  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now(),

  constraint claim_revision_review_events_count_check check (new_evidence_count >= 0),
  constraint claim_revision_review_events_digest_shape_check
    check (evidence_digest ~ '^sha256-v1:[0-9a-f]{64}$'),
  constraint claim_revision_review_events_note_shape_check
    check (note is null or (note = btrim(note) and length(note) between 1 and 2000)),
  -- En avgjørelse har alltid et menneske bak seg, og en automatisk observasjon
  -- har det aldri.
  constraint claim_revision_review_events_actor_shape_check
    check (
      case transition
        when 'revision_ordered' then actor_id is not null
        when 'set_aside' then actor_id is not null and note is not null
        else actor_id is null
      end
    )
);

comment on table workflow.claim_revision_review_events is
  'Append-only spor over hver overgang på en redaksjonell revisjonsvurdering. Oppgaven selv er tilstand og endres; det som skjedde, er historikk og overskrives ikke. Uten sporet ville «når la Antidep merke til dette, hvor mye har kommet til siden, og hva ble besluttet på hvilket grunnlag» vært ubesvarlig så snart raden hadde fått en ny tilstand (ANTIDEP_CONSTITUTION.md regel 7).';

alter table workflow.claim_revision_review_events enable row level security;

create index claim_revision_review_events_review_idx
  on workflow.claim_revision_review_events (claim_revision_review_id, occurred_at);

-- Tabellen har ingen updated_at, fordi en rad aldri endres. Da må created_at
-- settes av databasen også når kalleren oppgir den: en default gjelder bare når
-- kolonnen utelates, og et spor som kunne dateres fritt, ville ikke vært et spor.
create trigger claim_revision_review_events_set_created_at
  before insert on workflow.claim_revision_review_events
  for each row execute function catalog.set_created_at();

create trigger claim_revision_review_events_are_append_only
  before update or delete on workflow.claim_revision_review_events
  for each row execute function knowledge.reject_append_only_mutation(
    'Et spor sier hva som faktisk skjedde med den redaksjonelle oppgaven. En ny overgang er en ny rad.'
  );

create function workflow.record_claim_revision_review_event(
  p_review_id uuid,
  p_transition workflow.claim_revision_review_transition,
  p_evidence_digest text,
  p_new_evidence_count integer,
  p_actor_id uuid,
  p_note text
)
  returns uuid
  language sql
  set search_path = ''
as $$
  insert into workflow.claim_revision_review_events (
    claim_revision_review_id, transition, evidence_digest, new_evidence_count, actor_id, note
  )
  values (
    p_review_id, p_transition, p_evidence_digest, p_new_evidence_count, p_actor_id,
    nullif(btrim(coalesce(p_note, '')), '')
  )
  returning id;
$$;

comment on function workflow.record_claim_revision_review_event(uuid, workflow.claim_revision_review_transition, text, integer, uuid, text) is
  'Skriver én rad i sporet over en revisjonsvurderings overganger. Ett sted framfor fire, slik at ingen skrivevei kan endre oppgaven uten å etterlate sporet. Kalles fra innsiden av en funksjon som allerede har fastslått opphavet, og er derfor ikke SECURITY DEFINER.';

revoke execute on function workflow.record_claim_revision_review_event(uuid, workflow.claim_revision_review_transition, text, integer, uuid, text) from public;

-- ----------------------------------------------------------------------------
-- 6. Synteseoppgavens manifest, bygget ett sted
--
-- Kjedeovergangen og den redaksjonelle beslutningen bygger nøyaktig det samme
-- manifestet. To formuleringer ville før eller siden gitt to forskjellige
-- jobbnøkler for det samme arbeidet — og da ville «ett subjekt, én oppgave»
-- vært en påstand framfor en invariant.
--
-- Den ene forskjellen er `claim_id`, som bare en revisjon har. Feltet er en del
-- av oppgavekontrakten fra før: `workflow.agent_task(workflow.pipeline_jobs)`
-- bærer det inn i bindingen og inndataen, og
-- `knowledge.record_agent_claim_synthesis(...)` leser det når svaret kommer
-- tilbake. Det er derfor ingen ny skrivevei her — bare et felt som endelig får
-- en avsender.
-- ----------------------------------------------------------------------------
create function workflow.claim_synthesis_manifest(
  p_subject_drug_id uuid,
  p_topic_concept_id uuid,
  p_claim_id uuid
)
  returns jsonb
  language plpgsql
  stable
  set search_path = ''
as $$
declare
  v_evidence_ids uuid[];
  v_population_ids uuid[];
  v_manifest jsonb;
begin
  v_evidence_ids := workflow.claim_subject_evidence(p_subject_drug_id, p_topic_concept_id);
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

  return v_manifest;
end;
$$;

comment on function workflow.claim_synthesis_manifest(uuid, uuid, uuid) is
  'Inndatamanifestet for én synteseoppgave: hele det brukbare evidensgrunnlaget om virkestoffet og endepunktet, populasjonene det er avgrenset til, og — når oppgaven er en revisjon — påstanden revisjonen skal gjelde. Ett sted framfor to, slik at kjedeovergangen og den redaksjonelle beslutningen ikke kan bygge hvert sitt sett og dermed hver sin jobbnøkkel for det samme arbeidet. NULL når det ikke finnes brukbart grunnlag i det hele tatt.';

revoke execute on function workflow.claim_synthesis_manifest(uuid, uuid, uuid) from public;

-- ----------------------------------------------------------------------------
-- 7. Å legge merke til at ny evidens venter
--
-- Kalles av kjedeovergangen, i den samme transaksjonen som registrerte den
-- beståtte ekstraksjonskontrollen, og av rekonsilieringen som tar igjen det en
-- teknisk svikt etterlot. To veier inn, én funksjon: en andre formulering ville
-- kunnet åpne en oppgave den første ikke ville åpnet.
--
-- Låsen på subjektet tas her og ikke av kalleren. Den er den samme rådgivende
-- transaksjonslåsen kjedeovergangene tar, og den er re-entrant, så en kaller
-- som allerede holder den, betaler ingenting. Uten den kunne to samtidige
-- kontroller av forskjellige funn på det samme subjektet begge lest «ingen
-- rad» og begge forsøkt å opprette den — og taperen ville feilet på
-- unikhetskravet midt i en registrering som ellers lyktes.
-- ----------------------------------------------------------------------------
create function workflow.notice_claim_revision_need(
  p_subject_drug_id uuid,
  p_topic_concept_id uuid
)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_claim_id uuid;
  v_review workflow.claim_revision_reviews;
  v_new_ids uuid[];
  v_digest text;
  v_job_state workflow.pipeline_job_state;
begin
  v_claim_id := workflow.claim_awaiting_revision(p_subject_drug_id, p_topic_concept_id);
  if v_claim_id is null then
    return null;
  end if;

  perform workflow.lock_chain_subject(
    'claim_synthesis'::provenance.agent_role,
    format('%s+%s', p_subject_drug_id, p_topic_concept_id));

  v_new_ids := workflow.claim_revision_new_evidence(v_claim_id);
  if v_new_ids is null or cardinality(v_new_ids) = 0 then
    return null;
  end if;

  v_digest := workflow.evidence_set_digest(
    workflow.claim_subject_evidence(p_subject_drug_id, p_topic_concept_id));

  select r.* into v_review
  from workflow.claim_revision_reviews r
  where r.claim_id = v_claim_id
  for update;

  if not found then
    insert into workflow.claim_revision_reviews (claim_id, pending_evidence_digest)
    values (v_claim_id, v_digest)
    returning * into v_review;

    perform workflow.record_claim_revision_review_event(
      v_review.id, 'opened'::workflow.claim_revision_review_transition,
      v_digest, cardinality(v_new_ids), null, null);
    return v_review.id;
  end if;

  if v_review.state = 'open' then
    -- Enda et funn på en oppgave som alt står åpen. Fortsatt én avgjørelse å
    -- ta, og derfor fortsatt én rad: det som endrer seg, er grunnlaget. Svaret
    -- er NULL, fordi ingen oppgave ble åpnet — den sto åpen fra før.
    if v_review.pending_evidence_digest is distinct from v_digest then
      update workflow.claim_revision_reviews r
      set pending_evidence_digest = v_digest
      where r.id = v_review.id;

      perform workflow.record_claim_revision_review_event(
        v_review.id, 'widened'::workflow.claim_revision_review_transition,
        v_digest, cardinality(v_new_ids), null, null);
    end if;
    return null;
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
  if v_review.state = 'revision_ordered' then
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
      decided_evidence_digest = null,
      decided_at = null,
      decided_by_actor_id = null,
      decision_note = null,
      pipeline_job_id = null,
      opened_at = now()
  where r.id = v_review.id;

  perform workflow.record_claim_revision_review_event(
    v_review.id, 'reopened'::workflow.claim_revision_review_transition,
    v_digest, cardinality(v_new_ids), null, null);
  return v_review.id;
end;
$$;

comment on function workflow.notice_claim_revision_need(uuid, uuid) is
  'Gjør det eksplisitt at ny evidens om et virkestoff og et endepunkt venter på en redaksjonell avgjørelse om en påstand som allerede finnes. Idempotent på påstanden: flere nye funn gir én oppgave, og et grunnlag som ikke har endret seg, skriver ingenting. Tar selv subjektlåsen kjedeovergangene tar, slik at to samtidige kontroller ikke kan forsøke å opprette den samme raden. Åpner en avgjort oppgave igjen bare når grunnlaget er blitt et annet enn det redaktøren tok stilling til — og for en besluttet revisjon bare når synteseoppgaven faktisk lyktes, slik at en teknisk svikt aldri blir en ny menneskeoppgave. Svarer med id-en til den oppgaven som faktisk ble *åpnet* — opprettet eller gjenåpnet — og NULL ellers, også når en oppgave som alt sto åpen, bare vokste: en teller over åpnede oppgaver skal telle avgjørelser som venter, ikke rader som finnes.';

revoke execute on function workflow.notice_claim_revision_need(uuid, uuid) from public;

-- ----------------------------------------------------------------------------
-- 8. Kjedeovergangen bruker den, og bygger manifestet ett sted
--
-- Kroppen er den fra migrasjon 012b, med to endringer og ingen lempinger:
--
--   * der den før returnerte stille fordi paret allerede hadde en påstand,
--     registrerer den nå at ny evidens venter på en redaksjonell avgjørelse, og
--   * manifestet bygges av workflow.claim_synthesis_manifest(uuid, uuid, uuid)
--     framfor av en spørring som bare finnes her.
--
-- Porten er uendret: kjeden synteserer fortsatt ikke om igjen en påstand som
-- finnes. Det eneste nye er at den sier fra.
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

  -- En påstand som allerede finnes for det samme temaet og virkestoffet, er
  -- ikke automatikkens å skrive om. Å revidere en påstand i lys av ny evidens
  -- er en redaksjonell avgjørelse om hva påstanden skal si — og den
  -- avgjørelsen skal være synlig og mulig å ta, framfor å være et stille
  -- stopp (migrasjon 012d).
  if exists (
    select 1
    from knowledge.claims c
    where c.topic_concept_id = v_item.outcome_concept_id
      and c.subject_drug_id = v_item.intervention_drug_id
  ) then
    perform workflow.notice_claim_revision_need(
      v_item.intervention_drug_id, v_item.outcome_concept_id);
    return null;
  end if;

  -- Låsen først, og deretter spørsmålet. Uten den rekkefølgen kan to samtidige
  -- kontroller av forskjellige funn på det samme subjektet begge lese «ingen
  -- oppgave» og legge inn hver sin, fordi evidenssettet — og dermed nøkkelen —
  -- blir forskjellig.
  v_subject := format('%s+%s', v_item.intervention_drug_id, v_item.outcome_concept_id);
  perform workflow.lock_chain_subject('claim_synthesis'::provenance.agent_role, v_subject);

  if workflow.agent_task_subject_queued('claim_synthesis'::provenance.agent_role, v_subject) then
    return null;
  end if;

  -- Hele grunnlaget som er brukbart nå, og ikke bare funnet som utløste
  -- overgangen: en syntese som utelot et funn som motsier påstanden, ville
  -- hvilt på et annet grunnlag enn det som finnes (ANTIDEP_CONSTITUTION.md
  -- regel 4). Settet leses én gang, og jobben lages bare én gang, så manifestet
  -- er stabilt.
  v_manifest := workflow.claim_synthesis_manifest(
    v_item.intervention_drug_id, v_item.outcome_concept_id, null);

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

comment on function workflow.chain_task_for_verified_extraction(uuid) is
  'Legger synteseoppgaven i køen når ekstraksjonskontrollen av ett evidensfunn er bestått. Grunnlaget er hele settet av brukbare funn på det samme virkestoffet og endepunktet, bygget av workflow.claim_synthesis_manifest(uuid, uuid, uuid) — den samme funksjonen den redaksjonelle beslutningen bruker — og ikke bare funnet som utløste overgangen. Gjør ingenting når den gjeldende kontrollen ikke bekrefter, eller når leddet allerede har en oppgave om det samme subjektet. Har temaet og virkestoffet allerede en påstand, synteseres den ikke om igjen: da registreres i stedet at ny evidens venter på en redaksjonell avgjørelse (workflow.notice_claim_revision_need(uuid, uuid)). Svarer med jobbens id, eller NULL.';

-- ----------------------------------------------------------------------------
-- 9. Det redaktøren ser
--
-- Bare det den faglige avgjørelsen trenger: hva påstanden sier i dag, hvilket
-- virkestoff og endepunkt den gjelder, om den er publisert, hvor sikker
-- evidensen ble vurdert til å være — og hva slags ny forskning som er kommet
-- til siden.
--
-- Ingen uuid, ingen jobbnøkkel, ingen agentrolle, ingen modell, ingen
-- rpc-navn, ingen avtrykk av noe annet enn det ene flaten sender uendret
-- tilbake. Artikkelen navngis med bibliografien sin, fordi det er nettopp det
-- en redaktør kjenner den igjen på.
--
-- `evidence_basis` er det ene som ikke er til å se på: det er avtrykket flaten
-- sender med beslutningen, slik at databasen kan avvise en beslutning tatt på
-- et foreldet grunnlag. Samme form som sluttkontrollens `candidate_digest`, og
-- av samme grunn — og den vises like lite.
-- ----------------------------------------------------------------------------
create function workflow.claim_revision_task(
  p_review workflow.claim_revision_reviews,
  p_with_evidence boolean
)
  returns jsonb
  language plpgsql
  stable
  set search_path = ''
as $$
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

  select r.* into v_revision
  from knowledge.claim_revisions r
  where r.claim_id = v_claim.id
  order by r.revision_number desc
  limit 1;

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
    'new_evidence_count', cardinality(v_new_ids),
    'noticed_at', p_review.opened_at,
    -- Avtrykket flaten sender uendret tilbake. Regnes av hele det brukbare
    -- grunnlaget her og nå, og ikke av den lagrede verdien: den som åpner
    -- siden, skal ta stilling til det som faktisk finnes.
    'evidence_basis', workflow.evidence_set_digest(
      workflow.claim_subject_evidence(v_claim.subject_drug_id, v_claim.topic_concept_id)));

  if not p_with_evidence then
    return v_task;
  end if;

  return v_task || jsonb_build_object('new_evidence', coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'article_title', s.title,
        'article_authors', s.authors_or_issuer,
        'published_year', case when s.publication_date is null then null
                               else extract(year from s.publication_date)::integer end,
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
      order by s.title, e.id::text)
    from knowledge.evidence_items e
    join knowledge.sources s on s.id = e.source_id
    where e.id = any (v_new_ids)), '[]'::jsonb));
end;
$$;

comment on function workflow.claim_revision_task(workflow.claim_revision_reviews, boolean) is
  'Én redaksjonell revisjonsoppgave, slik en redaktør trenger den: hva påstanden sier i dag, virkestoffet og endepunktet den gjelder, om den er publisert, hvor sikker evidensen ble vurdert til å være, og — når hele oppgaven åpnes — hva slags ny forskning som er kommet til. Artiklene navngis med bibliografien sin, som er det en redaktør kjenner dem igjen på. Ingen uuid, ingen jobbnøkkel, ingen agentrolle og ingen modell forlater databasen her. evidence_basis er avtrykket flaten sender uendret tilbake med beslutningen, og det regnes av grunnlaget her og nå framfor av den lagrede verdien: den som åpner siden, skal ta stilling til det som faktisk finnes.';

revoke execute on function workflow.claim_revision_task(workflow.claim_revision_reviews, boolean) from public;

create function api.claim_revision_queue()
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_rows jsonb;
begin
  perform knowledge.assert_editor_authorized();

  select coalesce(jsonb_agg(task order by task ->> 'noticed_at'), '[]'::jsonb)
    into v_rows
  from (
    select workflow.claim_revision_task(r, false) as task
    from workflow.claim_revision_reviews r
    where r.state = 'open'
    order by r.opened_at
    limit 200
  ) q
  where q.task is not null;

  return v_rows;
end;
$$;

comment on function api.claim_revision_queue() is
  'Påstandene som har fått ny evidens, og som venter på at en redaktør avgjør om teksten skal revideres. Ett kall, uten et eneste teknisk felt: påstanden i klartekst, virkestoffet og endepunktet den gjelder, og hvor mange nye funn som er kommet til. Krever editor-mandat, fordi det å avgjøre hva en påstand skal si i lys av ny kunnskap er en redaksjonell avgjørelse (ANTIDEP_CONSTITUTION.md regel 1). SECURITY DEFINER fordi knowledge, workflow og catalog har RLS med default deny.';

revoke execute on function api.claim_revision_queue() from public;
grant execute on function api.claim_revision_queue() to authenticated;

create function api.claim_revision_for_decision(p_reference text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_review workflow.claim_revision_reviews;
  v_task jsonb;
begin
  perform knowledge.assert_editor_authorized();

  select r.* into v_review
  from workflow.claim_revision_reviews r
  where r.reference = p_reference and r.state = 'open';

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Det finnes ingen åpen revisjonsvurdering med denne referansen.',
      hint = 'Oppgaven kan være avgjort av noen andre, eller den nye evidensen kan ha blitt trukket tilbake. Hent listen på nytt.';
  end if;

  v_task := workflow.claim_revision_task(v_review, true);
  if v_task is null then
    raise exception using
      errcode = 'no_data_found',
      message = 'Påstanden oppgaven gjelder, finnes ikke lenger.';
  end if;

  return v_task;
end;
$$;

comment on function api.claim_revision_for_decision(text) is
  'Hele den ene redaksjonelle revisjonsoppgaven: påstanden slik den står i dag, og en forståelig oppsummering av hver ny forskningsartikkel som er kommet til — studiedesign, populasjon, retning, effektmål og forbehold. Nok til å ta den faglige avgjørelsen, og ikke noe mer. Slås opp på det ugjennomsiktige håndtaket, slik at en redaktør kan åpne oppgaven uten å kjenne én eneste teknisk identifikator (AGENTS.md). Krever editor-mandat. SECURITY DEFINER fordi knowledge, workflow og catalog har RLS med default deny.';

revoke execute on function api.claim_revision_for_decision(text) from public;
grant execute on function api.claim_revision_for_decision(text) to authenticated;

-- ----------------------------------------------------------------------------
-- 10. Avgjørelsen
--
-- To utfall, og ikke et tredje. `revise` bygger synteseoppgaven med hele det
-- gjeldende evidensgrunnlaget; `set_aside` er den faglige konklusjonen om at
-- den nye evidensen ikke endrer påstanden, og krever en begrunnelse.
--
-- Rekkefølgen på låsene er den samme som i
-- `workflow.notice_claim_revision_need(uuid, uuid)`: subjektlåsen først, radlåsen
-- etterpå. To veier som tok dem i hver sin rekkefølge, ville kunnet vente på
-- hverandre.
--
-- Fail-closed på tre punkter, og alle tre er samtidighet og ikke skjemakontroll:
--
--   * Grunnlaget må være nøyaktig det redaktøren så. Er det blitt et annet
--     mens beslutningen sto på skjermen, avvises den, og flaten ber om fersk
--     tilstand. En beslutning gjennomført på et annet grunnlag enn det som ble
--     lest, ville vært en attestasjon av noe ingen så.
--   * Oppgaven må fortsatt være åpen. Er den avgjort av noen andre, svarer
--     veien idempotent når det var den samme avgjørelsen på det samme
--     grunnlaget, og avviser ellers.
--   * Subjektet må ikke allerede ha en synteseoppgave underveis. To
--     semantisk like revisjoner av det samme faglige subjektet er nøyaktig det
--     kjeden ikke skal kunne produsere.
-- ----------------------------------------------------------------------------
create function api.record_claim_revision_decision(
  p_reference text,
  p_decision text,
  p_seen_evidence_basis text,
  p_note text default null
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
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
    workflow.claim_subject_evidence(v_claim.subject_drug_id, v_claim.topic_concept_id));

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
    v_claim.subject_drug_id, v_claim.topic_concept_id, v_claim.id);

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
$$;

comment on function api.record_claim_revision_decision(text, text, text, text) is
  'Den redaksjonelle avgjørelsen om ny evidens på en påstand som allerede finnes: enten skal påstanden revideres med det oppdaterte grunnlaget, eller så er konklusjonen at den nye evidensen ikke endrer den — og da med en begrunnelse. En besluttet revisjon legger inn nøyaktig den claim_synthesis-oppgaven kjeden selv ville lagt inn, gjennom workflow.chain_enqueue_job(provenance.agent_role, text, jsonb, uuid, uuid, boolean, text), med hele det gjeldende brukbare evidensgrunnlaget og med påstanden revisjonen skal gjelde; derfra går kildestøttekontroll, evidensvurdering og kandidatbygging av seg selv som før. Beslutningen er bundet til nøyaktig det evidensgrunnlaget redaktøren tok stilling til: er grunnlaget blitt et annet, avvises den, og flaten ber om fersk tilstand (ANTIDEP_CONSTITUTION.md regel 5). Idempotent for den samme avgjørelsen på det samme grunnlaget, og avviser en andre synteseoppgave om det samme faglige subjektet. Krever editor-mandat for endepunktet påstanden hører under. SECURITY DEFINER fordi knowledge, workflow og provenance har RLS med default deny.';

revoke execute on function api.record_claim_revision_decision(text, text, text, text) from public;
grant execute on function api.record_claim_revision_decision(text, text, text, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 11. Den åpne arbeidsoversikten lærer den nye tilstanden å kjenne
--
-- En påstand som venter på en redaksjonell avgjørelse, er *planlagt* arbeid.
-- Den er ikke en teknisk feil, og den skal ikke se ut som en: ingenting er i
-- stykker, kjeden har gjort ferdig sitt, og det som gjenstår, er en faglig
-- avgjørelse et menneske skal ta (ANTIDEP_CONSTITUTION.md regel 4).
--
-- `waiting_for_full_text` blir samtidig til `waiting_for`, med et lukket
-- vokabular. To boolske felter som utelukker hverandre, ville vært to
-- formuleringer av det samme spørsmålet — og det tredje som en gang kommer,
-- ville blitt et tredje felt. Her er svaret ett felt med ett ord i:
-- `full_text` når artikkelen mangler, `editorial_decision` når en redaktør må
-- avgjøre noe, og NULL når det ikke venter på noe utenfor kjeden.
-- ----------------------------------------------------------------------------
create or replace function api.public_work_board()
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_rows jsonb;
begin
  select coalesce(jsonb_agg(row_to_json(q)::jsonb order by q.updated_at desc), '[]'::jsonb)
    into v_rows
  from (
    -- Artiklene Antidep mangler. En åpen forespørsel uten fil er planlagt
    -- arbeid som venter på fullteksten; er filen levert, arbeider Antidep med
    -- den. Ingen av delene er en teknisk feil.
    select
      workflow.work_board_reference(r.id) as reference,
      'full_text' as activity,
      -- Tre utfall, og de betyr tre forskjellige ting for den som leser:
      -- Antidep venter på artikkelen, Antidep arbeider med den, eller Antidep
      -- står fast på noe teknisk. Bare det første er å vente på et menneske.
      case
        when i.id is null then 'planned'
        when i.state = 'blocked' then 'failed'
        else 'in_progress'
      end as status,
      case when i.id is null then 'full_text' end as waiting_for,
      (select coalesce(array_agg(d.canonical_name order by d.canonical_name), array[]::text[])
       from catalog.drugs d where d.id = any (r.drug_ids)) as subjects,
      greatest(r.requested_at, coalesce(i.submitted_at, r.requested_at)) as updated_at
    from (
      -- Bundet, som historikken under. Oversikten er offentlig og krever ingen
      -- innlogging, så den skal ikke kunne bli et vilkårlig stort arbeid å be
      -- om. Grensen ligger langt over reell mengde, og den eldste ventingen
      -- står først, fordi det er den som har stått lengst.
      select * from workflow.full_text_requests
      where state = 'open'
      order by requested_at
      limit 200
    ) r
    left join workflow.full_text_intake i
      on i.full_text_request_id = r.id
     and i.state in ('received', 'processing', 'blocked')

    union all

    -- Påstandene som har fått ny evidens, og som venter på at en redaktør
    -- avgjør om teksten skal revideres. Planlagt, redaksjonelt arbeid — aldri
    -- stoppet arbeid, og aldri et teknisk problem.
    select
      workflow.work_board_reference(rv.id),
      'claim_revision',
      'planned',
      'editorial_decision',
      (select coalesce(array_agg(d.canonical_name), array[]::text[])
       from catalog.drugs d where d.id = c.subject_drug_id),
      greatest(rv.opened_at, rv.updated_at)
    from (
      select * from workflow.claim_revision_reviews
      where state = 'open'
      order by opened_at
      limit 200
    ) rv
    join knowledge.claims c on c.id = rv.claim_id

    union all

    -- Alt annet arbeid, uavhengig av om det utføres av en ekstern KI-agent
    -- eller av Antideps egne kjørere. Hvem som gjør det, er ikke en opplysning
    -- den åpne oversikten bærer.
    select
      workflow.work_board_reference(j.id),
      case j.agent_role
        when 'evidence_extraction' then 'findings'
        when 'extraction_verification' then 'findings_check'
        when 'claim_synthesis' then 'claim'
        when 'citation_support_verification' then 'claim_check'
        when 'evidence_assessment' then 'assessment'
        else 'other'
      end,
      case j.state
        when 'succeeded' then 'done'
        when 'failed' then 'failed'
        when 'leased' then
          case when j.lease_expires_at > statement_timestamp() then 'in_progress' else 'planned' end
        else 'planned'
      end,
      null::text,
      workflow.work_board_drugs(j.input_manifest),
      coalesce(j.completed_at, j.updated_at, j.enqueued_at)
    from (
      select * from workflow.pipeline_jobs
      where state <> 'succeeded'
      order by enqueued_at
      limit 200
    ) j

    union all

    -- Historikken. Begrenset, fordi en oversikt er en oversikt: den som vil
    -- lese hva Antidep faktisk sier, leser det publiserte innholdet.
    select
      workflow.work_board_reference(j.id),
      case j.agent_role
        when 'evidence_extraction' then 'findings'
        when 'extraction_verification' then 'findings_check'
        when 'claim_synthesis' then 'claim'
        when 'citation_support_verification' then 'claim_check'
        when 'evidence_assessment' then 'assessment'
        else 'other'
      end,
      'done',
      null::text,
      workflow.work_board_drugs(j.input_manifest),
      j.completed_at
    from (
      select * from workflow.pipeline_jobs
      where state = 'succeeded'
      order by completed_at desc
      limit 50
    ) j
  ) q;

  return v_rows;
end;
$$;

comment on function api.public_work_board() is
  'Hva Antidep arbeider med, i klinikerens språk og uten en eneste intern verdi (issue #99). Svarer med et lukket produktvokabular: hva slags arbeid det er, om det er planlagt, pågår, har feilet eller er fullført, hva det eventuelt venter på — at artikkelen mangler, eller at en redaktør må avgjøre om ny kunnskap skal inn i en påstand som finnes — hvilke virkestoff det gjelder, og når det sist skjedde noe. Ingen agentrolle, ingen modell, ingen kjører, ingen jobbnøkkel, ingen påstandstekst, ingen artikkeltittel, ingen uuid og ingen feiltekst forlater databasen her — at en oppgave har feilet er en opplysning, og hvorfor den feilet er en teknisk detalj som blir liggende. En påstand som venter på en redaksjonell avgjørelse, er planlagt arbeid og aldri stoppet arbeid: ingenting er i stykker. Tilstanden er databasens egen og ikke en flates: den overlever en sideoppfriskning og en ny sesjon. Lesbar uten innlogging, og det er hele poenget.';
-- ----------------------------------------------------------------------------
-- 12. Rekonsilieringen tar også igjen den redaksjonelle oppgaven
--
-- De fem kjedeleddene har siden migrasjon 012b hatt hver sin feiing, fordi en
-- overgang som svikter teknisk, ellers ville etterlatt et hull ingen fant
-- igjen. Det sjette leddet trenger det like mye, og av en grunn som er verre:
-- her er det ikke en jobb som mangler, men *synligheten* av at det finnes ny
-- kunnskap. En tapt overgang ville betydd at en redaktør aldri fikk vite det.
--
-- Leddet feies derfor på samme måte, fra sin egen markør, med sin egen lampe,
-- og med de samme tre feilklassene som går stille fordi de betyr «grunnlaget er
-- ikke klart» og ikke «noe er i stykker».
-- ----------------------------------------------------------------------------
create or replace function api.resume_chain_transitions(p_identity_key text, p_secret text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
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
    utestaaende as (
      select c.id as claim_id,
             c.subject_drug_id as drug_id,
             c.topic_concept_id as topic_id,
             format('%s+%s', c.subject_drug_id, c.topic_concept_id) as sort_key
      from knowledge.claims c
      join knowledge.evidence_items e
        on e.intervention_drug_id = c.subject_drug_id
       and e.outcome_concept_id = c.topic_concept_id
      join gjeldende g on g.evidence_item_id = e.id and g.outcome = 'verified'
      where c.id = workflow.claim_awaiting_revision(c.subject_drug_id, c.topic_concept_id)
        and not exists (
          select 1
          from knowledge.claim_evidence_links l
          join knowledge.claim_revisions r on r.id = l.claim_revision_id
          where r.claim_id = c.id and l.evidence_item_id = e.id)
      group by c.id, c.subject_drug_id, c.topic_concept_id
    )
    select u.claim_id as id, u.drug_id, u.topic_id, u.sort_key
    from utestaaende u
    where u.sort_key > v_position
    order by u.sort_key
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
    begin
      if workflow.notice_claim_revision_need(v_row.drug_id, v_row.topic_id) is not null then
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
$$;

comment on function api.resume_chain_transitions(text, text) is
  'Tar igjen de automatiske kjedeovergangene en teknisk svikt etterlot, og rekonsilierer samtidig det tekniske bildet. Leser hva databasens egen tilstand tilsier og legger inn nøyaktig det triggerne ville lagt inn — de samme funksjonene, de samme portene, den samme idempotensen — og tar ikke imot ett eneste felt fra kalleren. Den erstatter ingen tilstandsovergang: overgangen har allerede skjedd, og dette er lesningen av hva som mangler i forhold til den. Seks ledd rekonsilieres, hvert for seg og fra sin egen markør, slik at en kostnadsgrense per passering ikke blir til sult: fem som legger arbeid i køen, og ett som gjør synlig at ny evidens venter på en redaksjonell avgjørelse om en påstand som allerede finnes — der er det ikke en jobb som kan gå tapt, men vissheten om at kunnskapen finnes. Leddets tekniske problem lukkes bare når en hel feiing — ikke en enkelt passering — kom gjennom leddet uten en eneste teknisk svikt. Krever en identitet i et av de to deterministiske kontrolleddene, fordi det er den kjøringen som uansett går med jevne mellomrom. Svarer med hvor mange jobber som ble lagt inn, hvor mange kandidater som ble forseglet, og hvor mange redaksjonelle oppgaver som ble åpnet. SECURITY DEFINER fordi knowledge, workflow og provenance har RLS med default deny; EXECUTE går til anon og authenticated av samme grunn som for de øvrige agentveiene.';
