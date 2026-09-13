-- Migrasjon 005, 005a og 005b — seedomfang for aktører, og hva som bevisst ikke
-- er seedet.
--
-- MVP_IMPLEMENTATION_PLAN.md §29 og ANTIDEP_CONSTITUTION.md §11 og §12:
-- migrasjonene registrerer aktørene som faktisk produserte de eksisterende
-- radene, og den navngitte kvalifiserte redaktøren §12 krever — og ingenting
-- mer. Verifikasjoner og reviewbeslutninger er utførte handlinger, og ingen
-- slik handling har funnet sted; en seedet «verified» eller en seedet
-- godkjenning ville vært nøyaktig den fiktive kontrollen og den fiktive
-- godkjenningen konstitusjonen forbyr.
--
-- Testen er derfor like mye en test av hva som ikke finnes som av hva som
-- finnes. Den skal justeres av den migrasjonen som faktisk utfører en kontroll
-- eller registrerer en reell godkjenning, ikke omgås. Migrasjon 005a er første
-- gang det har skjedd: den registrerte redaktøren som aktør, og assertionene om
-- aktørregisteret er justert til å påstå den nye sannheten framfor å bli myket
-- opp.
--
-- Den viktigste nye assertionen er negativ. En navngitt redaktør i basen kan
-- lett leses som at godkjenningsveien nå står åpen, og derfor holder det ikke å
-- telle at reviewbeslutningstabellen fortsatt er tom: testen forsøker faktisk å
-- registrere en godkjenning i redaktørens navn og krever at databasen avviser
-- den.
--
-- Migrasjon 005b endrer ikke tilstanden her, og det er hele poenget med den.
-- Den knytter redaktørens aktørrad til brukerkontoen og tildeler
-- reviewer-rollen, men bare i miljøer der kontoen faktisk finnes i auth.users
-- (MVP_IMPLEMENTATION_PLAN.md §74.18, «vei a»). En fersk stack — lokalt og i CI
-- — har den ikke. Assertionene under er derfor den negative grenen av 005b, og
-- de sier hva som skjer når den grenen kjører: ingenting skrives.
--
-- Det de IKKE sier, er at 005b har kjørt. En påstand om at noe ikke finnes,
-- ville vært like sann om migrasjonen aldri hadde kjørt.
-- 350_editor_authorization_test.sql binder derfor begge grenene til selve
-- funksjonen ved å kalle den: den negative med krav om at kallet ikke skriver
-- noe, og den positive ved å opprette kontoen inne i en transaksjon som rulles
-- tilbake.
begin;

create extension if not exists pgtap with schema extensions;

select plan(22);

-- ---------------------------------------------------------------------------
-- Aktørene som faktisk produserte de eksisterende radene, og redaktøren
-- ---------------------------------------------------------------------------
--
-- display_name er med i assertionen fordi det er selve poenget med migrasjon
-- 005a: ANTIDEP_CONSTITUTION.md §12 krever en *navngitt* kvalifisert redaktør,
-- og navnet er det feltet som bærer navngivingen. Uten det ville testen
-- godtatt en anonym menneskelig aktør.
select results_eq(
  $$
    select actor_key, actor_type::text, agent_role::text, display_name
    from provenance.actors
    order by actor_key
  $$,
  $$values ('agent:citation-support-verification', 'agent', 'citation_support_verification', 'Antidep claim-verifikator'),
           ('agent:claim-synthesis', 'agent', 'claim_synthesis', 'Antidep synteseagent'),
           ('agent:evidence-extraction', 'agent', 'evidence_extraction', 'Antidep ekstraksjonsagent'),
           ('agent:extraction-verification', 'agent', 'extraction_verification', 'Antidep ekstraksjonsverifikator'),
           ('human:peder-holman', 'human', null, 'Peder Holman')$$,
  'aktørregisteret inneholder de fire KI-rollene fra migrasjon 003, 004, 005f og 005i, og den navngitte redaktøren fra 005a'
);

-- ---------------------------------------------------------------------------
-- De tekniske agentidentitetene (migrasjon 005f, 005i, 005w og 005ak)
--
-- Fire påstander som hver for seg er det migrasjonene faktisk lover, og som
-- hver for seg ville vært en sikkerhetsendring om de sluttet å holde. Listen er
-- uttømmende: en identitet ingen har bestemt seg for, kan ikke gli inn
-- ubemerket.
-- ---------------------------------------------------------------------------
select results_eq(
  $$
    select ai.identity_key,
           verifier.actor_key,
           ai.agent_role::text,
           registrar.actor_key,
           ai.registered_by_actor_type::text,
           ai.secret_hash is null,
           ai.secret_version,
           ai.valid_to is null
    from provenance.agent_identities ai
    join provenance.actors verifier on verifier.id = ai.actor_id
    join provenance.actors registrar on registrar.id = ai.registered_by_actor_id
    order by ai.identity_key
  $$,
  $$values ('agent-identity:citation-support-verification-01', 'agent:citation-support-verification',
            'citation_support_verification', 'human:peder-holman', 'human', true, 0, true),
           ('agent-identity:claim-synthesis-01', 'agent:claim-synthesis',
            'claim_synthesis', 'human:peder-holman', 'human', true, 0, true),
           ('agent-identity:evidence-extraction-01', 'agent:evidence-extraction',
            'evidence_extraction', 'human:peder-holman', 'human', true, 0, true),
           ('agent-identity:extraction-verification-01', 'agent:extraction-verification',
            'extraction_verification', 'human:peder-holman', 'human', true, 0, true)$$,
  'identitetsregisteret inneholder nøyaktig de to verifikatorene, ekstraksjonsagenten og synteseagenten, alle registrert av den navngitte redaktøren og alle uten utstedt legitimasjon'
);

-- Identiteten er inert etter migrasjonen, og det skal den være til legitimasjonen
-- utstedes i det miljøet kjøreren leser den fra (migrasjon 005f). En identitet
-- som kunne autentisere seg rett etter en migrasjon, ville betydd at en
-- hemmelighet lå i repoet.
select throws_ok(
  $$select provenance.authenticate_agent_identity(
      'agent-identity:extraction-verification-01', 'hva som helst',
      'extraction_verification'::provenance.agent_role)$$,
  '42501', 'Agentidentiteten kunne ikke autentiseres for denne operasjonen.',
  'en identitet uten utstedt legitimasjon kan ikke autentisere seg'
);
select throws_ok(
  $$select provenance.authenticate_agent_identity(
      'agent-identity:citation-support-verification-01', 'hva som helst',
      'citation_support_verification'::provenance.agent_role)$$,
  '42501', 'Agentidentiteten kunne ikke autentiseres for denne operasjonen.',
  'det samme gjelder claim-verifikatoren fra migrasjon 005i'
);

-- Ingen agentkjøring er registrert. En kjøring i migrert tilstand ville betydd
-- at en KI-operasjon var utført uten at noen ba om den.
select is(
  (select count(*) from provenance.agent_runs), 0::bigint,
  'ingen agentkjøring er registrert i migrert tilstand'
);
-- Lengdegulvet er ikke pynt. Databasens CHECK krever bare 1-2000 tegn, så en
-- beskrivelse på ett tegn passerer den — og passerte også den tidligere
-- assertionen her, som bare utelukket tom og NULL. Migrasjon 005 sier hvorfor
-- kolonnen finnes: «en aktørrad uten beskrivelse ville gjort attribusjonen til
-- en etikett i stedet for en forklaring». En etikett er nettopp det en svært
-- kort beskrivelse er, så assertionen påstår det den sier den påstår.
select is_empty(
  $$
    select actor_key from provenance.actors
    where description is null or length(description) < 80
  $$,
  'alle aktørene forklarer konkret hva de er, ikke bare med en etikett'
);
select results_eq(
  $$select actor_key from provenance.actors where actor_type = 'human'$$,
  $$values ('human:peder-holman')$$,
  'det finnes nøyaktig én menneskelig aktør, og det er den navngitte redaktøren'
);
select is_empty(
  $$select actor_key from provenance.actors where retired_at is not null$$,
  'ingen aktør er trukket tilbake'
);

-- ---------------------------------------------------------------------------
-- Redaktøren er registrert, men ikke autorisert
-- ---------------------------------------------------------------------------
--
-- provenance.actors.auth_user_id er nullbar med vilje: en menneskelig aktør kan
-- registreres før brukerkontoen finnes, og koblingen kan settes én gang senere
-- (provenance.freeze_actor_identity(), testet i 200). Migrasjon 005a bruker
-- nettopp den formen, fordi kontoen er en reell Supabase-konto som ikke kan
-- opprettes fra en migrasjon.
--
-- Migrasjon 005b setter koblingen — men bare der kontoen finnes. Her gjør den
-- det ikke, og aktøren står fortsatt uten konto.
select is_empty(
  $$select actor_key from provenance.actors where auth_user_id is not null$$,
  'ingen aktør er knyttet til en brukerkonto; brukerkontoen finnes ikke i dette miljøet, så 005b knyttet ingen'
);

-- Og dette er konsekvensen, prøvd framfor påstått: uten brukerkonto avviser
-- workflow.enforce_reviewer_qualification() en godkjenning i redaktørens navn.
--
-- Assertionen kan ikke bli stille sann. Slår oppslaget på actor_key feil, gir
-- select-en null rader, insert-en lykkes med å sette inn ingenting, og
-- throws_ok feiler fordi ingen exception ble kastet. Både feilkoden og selve
-- meldingen kontrolleres, slik at en feil på et tidligere lag — en NOT NULL,
-- en CHECK eller en fremmednøkkel — ikke kan telle som riktig avvisning.
select throws_ok(
  $$
    insert into workflow.review_decisions
      (claim_revision_id, claim_revision_creator_actor_id,
       review_type, decision, rationale,
       reviewer_actor_id, reviewer_actor_type, decided_at)
    select r.id, r.created_by_actor_id,
           'publication_approval', 'approved',
           'Forsøk på godkjenning fra en redaktør uten brukerkonto.',
           a.id, 'human', now()
    from knowledge.claim_revisions r
    cross join provenance.actors a
    where a.actor_key = 'human:peder-holman'
    order by r.id
    limit 1
  $$,
  '42501',
  'Reviewaktøren er ikke knyttet til en brukerkonto og kan ikke registrere en faglig beslutning.',
  'den registrerte redaktøren kan ikke godkjenne noe ennå; aktørraden alene åpner ikke publiseringsgaten'
);

-- ---------------------------------------------------------------------------
-- Hva som bevisst ikke er seedet (ANTIDEP_CONSTITUTION.md §11, §12)
-- ---------------------------------------------------------------------------
select is(
  (select count(*) from workflow.user_roles),
  0::bigint,
  'ingen rolletildeling finnes; workflow.user_roles.user_id krever en brukerkonto, og 005b fant ingen å tildele rollen til'
);
select is(
  (select count(*) from workflow.evidence_verifications),
  0::bigint,
  'ingen ekstraksjonsverifikasjon er seedet; ingen separat kontroll er utført'
);
select is(
  (select count(*) from workflow.claim_verifications),
  0::bigint,
  'ingen claim-verifikasjon er seedet; ingen separat kontroll er utført'
);
select is(
  (select count(*) from workflow.claim_verification_citations),
  0::bigint,
  'ingen kontrollrad er seedet; det finnes ingen kontroll å registrere kontrollerte lenker for'
);
select is(
  (select count(*) from workflow.review_decisions),
  0::bigint,
  'ingen reviewbeslutning er seedet; en seedet godkjenning ville vært den fiktive godkjenningen ANTIDEP_CONSTITUTION.md §12 forbyr'
);

-- Følgen av at ingenting er godkjent: ingenting er publisert heller.
--
-- Migrasjon 006 opprettet publiseringsgaten, og den endrer ikke dette bildet.
-- Den kan ikke: publisering av en evidenssyntese krever en godkjenning fra en
-- navngitt kvalifisert redaktør, og selv om redaktøren nå er navngitt, mangler
-- både brukerkonto, rolletildeling, verifikasjon og beslutning. Gaten leverer
-- et bevis på at den nekter, ikke en publisert påstand, og disse tre
-- assertionene er det maskinelle uttrykket for det. De skal justeres av
-- migrasjonen som registrerer en reell godkjenning og en reell publisering,
-- ikke omgås.
select is(
  (select count(*) from knowledge.claims where current_published_revision_id is not null),
  0::bigint,
  'ingen påstand er publisert; ingen godkjenning finnes å publisere på'
);
select is(
  (select count(*) from knowledge.publication_events),
  0::bigint,
  'ingen publiseringshendelse er seedet; en seedet publisering ville hvilt på en godkjenning som ikke finnes'
);
-- Kontroll av at de to assertionene over ikke passerer av feil grunn: det finnes
-- faktisk revisjoner som kunne vært publisert dersom gaten hadde vært åpen.
select is(
  (select count(*) from knowledge.claim_revisions),
  2::bigint,
  'de to påstandsrevisjonene finnes fortsatt; det er gaten som stopper dem, ikke fravær av innhold'
);

-- ---------------------------------------------------------------------------
-- Attribusjonen av de eksisterende radene er sann og fullstendig
-- ---------------------------------------------------------------------------
select is_empty(
  $$
    select e.id::text
    from knowledge.evidence_items e
    join provenance.actors a on a.id = e.created_by_actor_id
    where a.actor_key <> 'agent:evidence-extraction'
  $$,
  'alle evidensfunn er attribuert til ekstraksjonsrollen som produserte dem i migrasjon 003'
);
-- Migrasjon 003a la created_by_actor_id til knowledge.sources i etterkant
-- (et hull migrasjon 005 etterlot, se migrasjonens hodekommentar) og
-- backfyller de to seedede radene med samme aktør: aktørens egen beskrivelse
-- sier allerede at den «Produserte kildene, kildeversjonene og evidensfunnene
-- i migrasjon 003».
select is_empty(
  $$
    select s.id::text
    from knowledge.sources s
    join provenance.actors a on a.id = s.created_by_actor_id
    where a.actor_key <> 'agent:evidence-extraction'
  $$,
  'alle kilder er attribuert til ekstraksjonsrollen som produserte dem i migrasjon 003'
);
select is_empty(
  $$
    select t.table_name || ':' || t.wrong_rows::text
    from (
      select 'knowledge.claims' as table_name, count(*) as wrong_rows
      from knowledge.claims c
      join provenance.actors a on a.id = c.created_by_actor_id
      where a.actor_key <> 'agent:claim-synthesis'
      union all
      select 'knowledge.claim_revisions', count(*)
      from knowledge.claim_revisions r
      join provenance.actors a on a.id = r.created_by_actor_id
      where a.actor_key <> 'agent:claim-synthesis'
      union all
      select 'knowledge.claim_evidence_links', count(*)
      from knowledge.claim_evidence_links l
      join provenance.actors a on a.id = l.created_by_actor_id
      where a.actor_key <> 'agent:claim-synthesis'
      union all
      select 'knowledge.evidence_assessments', count(*)
      from knowledge.evidence_assessments ea
      join provenance.actors a on a.id = ea.created_by_actor_id
      where a.actor_key <> 'agent:claim-synthesis'
    ) t
    where t.wrong_rows > 0
  $$,
  'påstandslaget er i sin helhet attribuert til synteserollen som produserte det i migrasjon 004'
);

-- Redaktøren har ikke forfattet noe, og det er en forutsetning og ikke en
-- tilfeldighet: workflow.review_decisions_separate_actor_check nekter en
-- godkjenning der godkjenner og forfatter er samme aktør
-- (ANTIDEP_CONSTITUTION.md §10, §12). Ville redaktøren senere stått som
-- opphavet til en revisjon, kunne vedkommende ikke godkjent den.
--
-- Assertionen er skrevet over aktørtypen og ikke over actor_key, slik at den
-- ikke kan bli stille sann av en feilstavet nøkkel. At det i det hele tatt
-- finnes en menneskelig aktør å treffe, er påstått lenger oppe i filen.
select is(
  (select count(*)
   from (
     select c.id from knowledge.claims c
       join provenance.actors a on a.id = c.created_by_actor_id
       where a.actor_type = 'human'
     union all
     select r.id from knowledge.claim_revisions r
       join provenance.actors a on a.id = r.created_by_actor_id
       where a.actor_type = 'human'
     union all
     select l.id from knowledge.claim_evidence_links l
       join provenance.actors a on a.id = l.created_by_actor_id
       where a.actor_type = 'human'
     union all
     select ea.id from knowledge.evidence_assessments ea
       join provenance.actors a on a.id = ea.created_by_actor_id
       where a.actor_type = 'human'
     union all
     select e.id from knowledge.evidence_items e
       join provenance.actors a on a.id = e.created_by_actor_id
       where a.actor_type = 'human'
     union all
     select s.id from knowledge.sources s
       join provenance.actors a on a.id = s.created_by_actor_id
       where a.actor_type = 'human'
   ) t),
  0::bigint,
  'ingen kunnskapsobjekt er attribuert til en menneskelig aktør; redaktøren er ikke forfatter av noe vedkommende senere skal kunne godkjenne'
);

select * from finish();

rollback;
