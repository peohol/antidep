-- Migrasjon 005c — begge grenene av tildelingen som åpner skriveveien, og
-- rollegrensen den ikke flytter.
--
-- Migrasjon 007c åpnet `api.create_source(...)` bak en kontroll på
-- `role_code = 'editor'`, men ingen migrasjon tildelte den rollen til noen
-- (GitHub-issue 36, MVP_IMPLEMENTATION_PLAN.md §74.24). 370_source_creation_test.sql
-- beviser at kontrollen virker — den tildeler rollen selv, i sin egen
-- transaksjon — og kunne derfor ikke fange at ingen består den. Denne filen
-- dekker den andre siden: at tildelingen faktisk skrives der kontoen finnes, og
-- at den ikke gir noe annet enn den ene retten.
--
-- Som 350_editor_authorization_test.sql kjører den BEGGE grenene av den
-- miljøavhengige funksjonen (MVP_IMPLEMENTATION_PLAN.md §74.18, «vei a»):
--
--   negativ   kontoen mangler, som i enhver fersk stack: ingenting skrives
--   positiv   kontoen opprettes inne i transaksjonen som rulles tilbake, og
--             hele produksjonsveien kjøres — 005b sin kobling først, så
--             tildelingen, så det den faktisk åpner
--
-- Rekkefølgen speiler produksjon med hensikt: i det hostede prosjektet kjørte
-- migrasjon 005b først og knyttet aktørraden til kontoen. Denne funksjonen
-- setter ikke den koblingen selv, og en test som lot den slippe å forholde seg
-- til den, ville prøvd en annen kode enn den som kjører.
--
-- Ingen assertion her kontrollerer at ingen klientrolle kan kjøre funksjonen:
-- 210_workflow_access_test.sql er allerede uttømmende over `workflow` og
-- `provenance`, og en kopi her ville vært to påstander som kan drive fra
-- hverandre.
--
-- SQLSTATE 42501 = insufficient_privilege, P0002 = no_data_found,
-- 23001 = restrict_violation.
begin;
\ir fixtures/active_clinical_fixture.inc

create extension if not exists pgtap with schema extensions;

select plan(36);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_function(
  'workflow', 'ensure_editor_role_grant',
  'workflow.ensure_editor_role_grant() finnes'
);

-- ===========================================================================
-- Del 2 — Den negative grenen: kontoen finnes ikke
--
-- Tilstanden i CI og i enhver lokal stack. Kallet er ikke en no-op som går
-- stille: statusen kommer tilbake til kalleren, og funksjonen gir i tillegg en
-- notice, slik at raden ikke kan utebli i stillhet under `supabase db push`.
-- ===========================================================================
select is(
  workflow.ensure_editor_role_grant(),
  'account_missing',
  'uten brukerkontoen i auth.users rapporterer funksjonen at kontoen mangler'
);
select is(
  (select count(*) from workflow.user_roles),
  0::bigint,
  'den negative grenen tildeler ingen rolle'
);
-- Koblingen mellom aktør og konto er migrasjon 005b sin. Denne funksjonen skal
-- ikke sette den, heller ikke som en hjelpsom bivirkning: to steder som skriver
-- samme kobling er to påstander som kan drive fra hverandre.
select is_empty(
  $$select actor_key from provenance.actors where auth_user_id is not null$$,
  'den negative grenen knytter ingen aktør til en brukerkonto'
);

-- ===========================================================================
-- Del 3 — Forutsetningene, prøvd framfor antatt
-- ===========================================================================

-- Aktørraden kommer fra migrasjon 005a og skal alltid finnes. Mangler den, er
-- migrasjonskjeden brutt, og det skal feile høyt framfor å bli en stille no-op
-- som ser ut som «kontoen manglet». throws_ok ruller tilbake endringen sammen
-- med feilen.
--
-- Aktørraden kan ikke lenger slettes: migrasjon 005f registrerte den første
-- agentidentiteten, og både identiteten og auditraden den la igjen, peker på
-- redaktøren med RESTRICT. Proben endrer derfor aktørnøkkelen framfor å slette
-- raden, slik at oppslaget funksjonen gjør ikke finner noe. Samme framgangsmåte
-- som i 350_editor_authorization_test.sql, og av samme grunn.
select throws_ok(
  $$
    do $probe$
    begin
      alter table provenance.actors disable trigger actors_freeze_identity;
      update provenance.actors
      set actor_key = 'human:ikke-registrert'
      where actor_key = 'human:peder-holman';
      alter table provenance.actors enable trigger actors_freeze_identity;
      perform workflow.ensure_editor_role_grant();
    end
    $probe$
  $$,
  'P0002',
  'Aktøren ''human:peder-holman'' finnes ikke; migrasjon 005a har ikke kjørt.',
  'uten aktørraden fra 005a feiler tildelingen høyt framfor å utebli stille'
);

-- Kontoen opprettes her, og blir stående resten av filen. Bare id og email
-- settes: det eneste testen trenger av kontoen, er at fremmednøkkelen fra
-- workflow.user_roles har noe å peke på. Resten av auth.users eies av
-- autentiseringslaget og skal ikke etterlignes her.
insert into auth.users (id, email)
values ('a703ede9-3f58-4de9-8c85-73936d58df1f', 'redaktor-380@test.invalid');

-- Kontoen finnes nå, men aktøren peker ikke på den ennå. En tildeling her ville
-- vært en rettighet uten den attribusjonen den hviler på:
-- knowledge.assert_editor_authorized() slår opp aktøren på auth_user_id, og
-- ville avvist kalleren uansett — bare med en annen feilmelding.
select throws_ok(
  $$select workflow.ensure_editor_role_grant()$$,
  '23001',
  'Aktøren ''human:peder-holman'' er ikke knyttet til brukerkontoen ''a703ede9-3f58-4de9-8c85-73936d58df1f'', og kan ikke tildeles editor-rollen for den.',
  'uten koblingen fra 005b tildeles ingen editor-rolle til en konto uten aktør'
);
select is(
  (select count(*) from workflow.user_roles),
  0::bigint,
  'den avviste tildelingen etterlot ingen rad'
);

-- ===========================================================================
-- Del 4 — Den positive grenen, i produksjonens egen rekkefølge
-- ===========================================================================

-- Migrasjon 005b først, slik den kjørte i det hostede prosjektet: den knytter
-- aktørraden til kontoen og tildeler reviewer-rollen. Statusen påstås framfor å
-- ignoreres, slik at en endring i 005b ikke kan gjøre resten av filen til en
-- test av noe annet enn den tror.
select is(
  workflow.ensure_named_editor_authorization(),
  'authorized',
  'migrasjon 005b knytter kontoen og tildeler reviewer-rollen først, som i produksjon'
);

select is(
  workflow.ensure_editor_role_grant(),
  'authorized',
  'med konto og kobling på plass skrives editor-tildelingen'
);

-- Hele tilstanden i én assertion, felt for felt, og med begge rollene. En ren
-- telling ville passert også om reviewer-tildelingen var blitt skrevet om eller
-- byttet ut: de to rollene er forskjellige rettigheter, og den ene skal ikke
-- kunne bli den andre.
select results_eq(
  $$
    select ur.role_code::text, ur.user_id::text,
           ur.scope_id is null, ur.valid_to is null, g.actor_key
    from workflow.user_roles ur
    join provenance.actors g on g.id = ur.granted_by_actor_id
    order by ur.role_code::text
  $$,
  $$values ('editor', 'a703ede9-3f58-4de9-8c85-73936d58df1f', true, true, 'human:peder-holman'),
           ('reviewer', 'a703ede9-3f58-4de9-8c85-73936d58df1f', true, true, 'human:peder-holman')$$,
  'begge tildelingene står side om side: en løpende, uavgrenset editor og den uendrede reviewer fra 005b'
);

-- Selvtildelingen er ikke forbudt av noen CHECK, så begrunnelsen i raden er hele
-- sikringen. Ordet skal stå FØRST og ikke bare et sted i teksten: et treff hvor
-- som helst i feltet ville også slått ut på en benektelse av det.
select ok(
  (select grant_reason from workflow.user_roles where role_code = 'editor')
    like 'Selvtildeling%',
  'editor-tildelingen navngir selvtildelingen i sin egen begrunnelse'
);

-- Og begrunnelsen er editor-rollens egen. Terskelen for å selvtildele retten til
-- å registrere forslag er en annen enn terskelen for å selvtildele faglig
-- godkjenningsrett (ANTIDEP_CONSTITUTION.md §12), og en tildeling som arver en
-- begrunnelse, er en tildeling ingen har tatt stilling til.
select isnt(
  (select grant_reason from workflow.user_roles where role_code = 'editor'),
  (select grant_reason from workflow.user_roles where role_code = 'reviewer'),
  'editor-tildelingen har sin egen begrunnelse og arver ikke reviewer-tildelingens'
);
select ok(
  (select grant_reason from workflow.user_roles where role_code = 'editor')
    like '%godkjenningsrett%'
  and (select grant_reason from workflow.user_roles where role_code = 'editor')
    like '%publiseringsrett%',
  'begrunnelsen navngir eksplisitt de to rettighetene editor-rollen ikke gir'
);

-- Tildelingen skriver sin egen auditrad, uten at migrasjonen setter noe: den
-- kommer fra user_roles_record_grant_audit_event i migrasjon 008.
select results_eq(
  $$
    select e.object_schema, e.object_table, a.actor_key,
           e.old_revision_or_snapshot,
           e.new_revision_or_snapshot->>'scope_id'
    from audit.events e
    join provenance.actors a on a.id = e.actor_id
    where e.operation = 'role_granted'
      and e.new_revision_or_snapshot->>'role_code' = 'editor'
  $$,
  $$values ('workflow', 'user_roles', 'human:peder-holman', null::jsonb, null::text)$$,
  'editor-tildelingen legger igjen én auditrad, attribuert til aktøren som tildelte rollen'
);

-- ===========================================================================
-- Del 5 — Konsekvensen: skriveveien er faktisk åpen (issue 36)
--
-- Dette er hele hensikten med migrasjonen. Alt annet i filen kan være sant
-- samtidig som redaktøren fortsatt møter «Brukeren har ikke gyldig
-- editor-rolle» på /sources/new, så kjeden prøves gjennom den faktiske
-- klientrollen og den faktiske RPC-en framfor gjennom kontrollfunksjonen alene.
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"a703ede9-3f58-4de9-8c85-73936d58df1f"}', true);
set local role authenticated;
select lives_ok(
  $$
    select api.create_source(
      p_source_type := 'journal_article',
      p_title := 'Kilde opprettet av redaktøren i 380',
      p_authors_or_issuer := 'Peder Holman'
    )
  $$,
  'redaktøren kan opprette en kilde gjennom api.create_source() etter tildelingen'
);
reset role;

-- Innholdet kontrolleres som eieren: authenticated har ikke usage på knowledge
-- og skal ikke ha det (samme begrunnelse som del 5 i 370).
select is(
  (select s.created_by_actor_id from knowledge.sources s
    where s.title = 'Kilde opprettet av redaktøren i 380'),
  (select a.id from provenance.actors a where a.actor_key = 'human:peder-holman'),
  'kilden er attribuert til redaktørens egen aktør, ikke til en KI-aktør'
);
select results_eq(
  $$
    select e.object_schema, e.object_table,
           e.new_revision_or_snapshot->>'title'
    from audit.events e
    where e.operation = 'source_created'
  $$,
  $$values ('knowledge', 'sources', 'Kilde opprettet av redaktøren i 380')$$,
  'opprettelsen la igjen nøyaktig én auditrad for kildelaget'
);

-- ===========================================================================
-- Del 6 — Idempotens
--
-- Vei a betyr at tildelingen kan bli stående ugjort i et miljø der kontoen
-- kommer senere, og at funksjonen da skal kunne kalles på nytt. Et andre kall må
-- verken feile på exclusion constraint-en eller legge igjen en tildeling til.
-- ===========================================================================
select is(
  workflow.ensure_editor_role_grant(),
  'already_authorized',
  'et nytt kall etter en fullført tildeling rapporterer at den allerede er gjort'
);
select results_eq(
  $$select ur.role_code::text from workflow.user_roles ur order by 1$$,
  $$values ('editor'), ('reviewer')$$,
  'et nytt kall legger ikke igjen en tildeling til, og rører ikke reviewer-tildelingen'
);

-- ===========================================================================
-- Del 7 — Rollegrensen, prøvd fra begge sider
--
-- reviewer-tildelingen fjernes her, slik at editor står alene. Da er hver
-- assertion under en påstand om nøyaktig editor-rollen og ikke om summen av de
-- to. Slettingen er teststillas; alt rulles tilbake.
-- ===========================================================================
delete from workflow.user_roles where role_code = 'reviewer';

-- editor gir ingen faglig godkjenningsrett. Beslutningen er bevisst
-- `changes_requested` og ikke `approved`: en registrert godkjenning uten at noen
-- har gjennomgått noe, er den fiktive godkjenningen ANTIDEP_CONSTITUTION.md §12
-- forbyr, og en transaksjon som rulles tilbake gjør den ikke mindre fiktiv mens
-- den står.
select throws_ok(
  $$
    insert into workflow.review_decisions
      (claim_revision_id, claim_revision_creator_actor_id,
       review_type, decision, rationale,
       reviewer_actor_id, reviewer_actor_type, decided_at)
    select r.id, r.created_by_actor_id,
           'publication_approval', 'changes_requested',
           'Testprobe for rollegrensen. Ingen faglig gjennomgang har funnet sted.',
           a.id, 'human', now()
    from knowledge.claim_revisions r
    cross join provenance.actors a
    where a.actor_key = 'human:peder-holman'
    order by r.id
    limit 1
  $$,
  '42501',
  'Reviewaktøren hadde ikke gyldig reviewer-rolle for dette innholdsområdet på beslutningstidspunktet.',
  'editor-rollen gir ingen faglig godkjenningsrett; å registrere og å godkjenne er forskjellige handlinger'
);

-- editor gir ingen publiseringsrett.
select throws_ok(
  $$
    select knowledge.assert_publisher_authorized(
      (select a.id from provenance.actors a where a.actor_key = 'human:peder-holman'),
      (select cl.topic_concept_id from knowledge.claims cl order by cl.id limit 1)
    )
  $$,
  '42501',
  'Brukeren har ikke gyldig publisher-rolle for dette innholdsområdet.',
  'editor-rollen gir ingen publiseringsrett; å registrere og å publisere er forskjellige handlinger'
);

-- Og tildelingen åpner ikke publiseringsgaten. De tre tingene Milepæl B mangler
-- (§74.4) er urørt, og gaten skal fortsatt stoppe på den første av dem.
select throws_like(
  $$
    select knowledge.assert_claim_revision_publishable(
      (select id from knowledge.claim_revisions order by id limit 1))
  $$,
  '%uten registrert ekstraksjonsverifikasjon%',
  'editor-tildelingen åpner ikke publiseringsgaten; den stopper fortsatt på den manglende ekstraksjonsverifikasjonen'
);

-- Motstykket: skriveveien henger på editor alene og ikke på summen av rollene.
-- Uten denne ville de tre avvisningene over vært forenlige med at reviewer var
-- det som faktisk åpnet /sources/new.
set local role authenticated;
select lives_ok(
  $$select api.create_source('clinical_guideline', 'Kilde uten reviewer-rolle i 380', 'Peder Holman')$$,
  'skriveveien virker med editor alene; reviewer-rollen er ikke en forutsetning for den'
);
reset role;

-- ===========================================================================
-- Del 8 — De fire lovlige tilstandene en eksisterende tildeling kan stå i
--
-- workflow.user_roles er en gyldighetsmodell og ikke et flagg: intervallet er
-- halvåpent [valid_from, valid_to), og valid_to kan være satt allerede ved
-- tildeling som en planlagt utløpsdato. «Løpende» og «gyldig nå» er derfor to
-- forskjellige spørsmål. Funksjonen skiller mellom alle fire tilstandene, og
-- bare én av dem skriver noe.
-- ===========================================================================

-- 1. Gyldig nå, men tidsavgrenset. Regresjonstesten: et predikat skrevet som
--    «valid_to is null» leser denne raden som «ingen tildeling», forsøker å
--    skrive en ny med intervallet [nå, ∞), og
--    user_roles_no_overlapping_grant_excl avviser den. En `supabase db push`
--    ville stoppet.
update workflow.user_roles
set valid_to = now() + interval '30 days',
    ended_by_actor_id = granted_by_actor_id,
    end_reason = 'Planlagt utløpsdato satt i testen; tildelingen gjelder fortsatt.';

select is(
  workflow.ensure_editor_role_grant(),
  'already_authorized',
  'en tidsavgrenset tildeling som gjelder nå leses som gyldig, ikke som fraværende'
);
select is(
  (select count(*) from workflow.user_roles),
  1::bigint,
  'ingen overlappende tildeling forsøkes ved siden av den tidsavgrensede'
);

-- 2. Avsluttet tildeling. Den skal ikke gjeninnføres: en tilbakekalling som en
--    rutinemessig migrasjonskjøring omgjør, er ingen tilbakekalling
--    (DATABASE_ARCHITECTURE.md §46), og en gjeninnføring er en ny tildeling med
--    sin egen begrunnelse. Slettingen er teststillas — intervallet på en
--    avsluttet tildeling kan ikke skrives om etterpå (freeze_role_grant).
delete from workflow.user_roles;
insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, valid_to,
   granted_by_actor_id, grant_reason, ended_by_actor_id, end_reason)
select 'a703ede9-3f58-4de9-8c85-73936d58df1f', 'editor', null,
       now() - interval '2 years', now() - interval '1 year',
       a.id, 'Opprinnelig tildeling i testen.',
       a.id, 'Tilbakekalt i testen.'
from provenance.actors a
where a.actor_key = 'human:peder-holman';

select is(
  workflow.ensure_editor_role_grant(),
  'role_ended',
  'en avsluttet editor-tildeling rapporteres som avsluttet, ikke som fraværende'
);
-- Både at ingenting ble skrevet og at den avsluttede raden står urørt. En ren
-- telling ville passert også om raden var blitt skrevet om.
select results_eq(
  $$
    select ur.role_code::text,
           ur.valid_from < statement_timestamp(),
           ur.valid_to < statement_timestamp(),
           ur.end_reason
    from workflow.user_roles ur
  $$,
  $$values ('editor', true, true, 'Tilbakekalt i testen.')$$,
  'tilbakekallingen står urørt, og ingen ny tildeling er skrevet ved siden av den'
);

-- 3. Tildeling som først begynner å gjelde senere. Ingen rettighet finnes nå,
--    men en ny tildeling ville overlappet den framtidige og blitt avvist.
delete from workflow.user_roles;
insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
select 'a703ede9-3f58-4de9-8c85-73936d58df1f', 'editor', null,
       now() + interval '7 days', a.id, 'Planlagt tildeling i testen.'
from provenance.actors a
where a.actor_key = 'human:peder-holman';

select is(
  workflow.ensure_editor_role_grant(),
  'role_not_yet_valid',
  'en tildeling som begynner å gjelde senere leses ikke som en gyldig rettighet nå'
);
select is(
  (select count(*) from workflow.user_roles),
  1::bigint,
  'ingen overlappende tildeling forsøkes foran den framtidige'
);

-- 4. Presedens: en avsluttet tildeling ved siden av en løpende betyr at
--    rettigheten gjelder. Det motsatte svaret ville vært feil på den farligste
--    måten en autorisasjonskontroll kan ta feil.
delete from workflow.user_roles;
insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, valid_to,
   granted_by_actor_id, grant_reason, ended_by_actor_id, end_reason)
select 'a703ede9-3f58-4de9-8c85-73936d58df1f', 'editor', null,
       now() - interval '2 years', now() - interval '1 year',
       a.id, 'Opprinnelig tildeling i testen.',
       a.id, 'Tilbakekalt i testen.'
from provenance.actors a
where a.actor_key = 'human:peder-holman';
insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
select 'a703ede9-3f58-4de9-8c85-73936d58df1f', 'editor', null,
       now() - interval '1 hour', a.id, 'Gjeninnført tildeling i testen.'
from provenance.actors a
where a.actor_key = 'human:peder-holman';

select is(
  workflow.ensure_editor_role_grant(),
  'already_authorized',
  'en løpende tildeling ved siden av en avsluttet gir gyldig, ikke avsluttet'
);
select is(
  (select count(*) from workflow.user_roles),
  2::bigint,
  'presedensen skriver ingenting; begge de eksisterende tildelingene står'
);

-- 5. Gyldighet måles på setningen, ikke på transaksjonen
--    (MVP_IMPLEMENTATION_PLAN.md §74.6). now() er transaksjonens starttidspunkt,
--    og en tildeling som trådte i kraft mens transaksjonen løp, ville med now()
--    blitt lest som «gjelder ikke ennå» så lenge transaksjonen varte. Vinduet
--    gjøres deterministisk med pg_sleep framfor å hvile på at to setninger
--    tilfeldigvis får ulikt tidsstempel.
delete from workflow.user_roles;
insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
select 'a703ede9-3f58-4de9-8c85-73936d58df1f', 'editor', null,
       now() + interval '50 milliseconds', a.id,
       'Tildeling som trer i kraft mens transaksjonen løper.'
from provenance.actors a
where a.actor_key = 'human:peder-holman';

select pg_sleep(0.2);

select is(
  workflow.ensure_editor_role_grant(),
  'already_authorized',
  'en tildeling som trådte i kraft mens transaksjonen løp, leses som gyldig nå'
);

-- 6. En *avgrenset* editor-tildeling er en annen og smalere rettighet i
--    medlemskapsmodellen. user_roles_no_overlapping_grant_excl nøkler på
--    coalesce(scope_id, ...), så de to kolliderer ikke — og nettopp derfor må
--    oppslaget i funksjonen bruke samme nøkkel. Uten `scope_id is null` der
--    ville redaktøren stille sittet igjen med en smalere tildeling enn den
--    migrasjonen skal gi. At knowledge.assert_editor_authorized() godtar begge
--    (§74.24), gjør dem ikke til samme tildeling her.
delete from workflow.user_roles;
insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
select 'a703ede9-3f58-4de9-8c85-73936d58df1f', 'editor', cc.id,
       now() - interval '1 hour', a.id,
       'Avgrenset tildeling i testen.'
from provenance.actors a, catalog.clinical_concepts cc
where a.actor_key = 'human:peder-holman'
  and cc.canonical_label = 'vektendring';

select is(
  workflow.ensure_editor_role_grant(),
  'authorized',
  'en avgrenset tildeling teller ikke som den uavgrensede; den skrives'
);
select results_eq(
  $$
    select ur.scope_id is null, ur.grant_reason like 'Selvtildeling%'
    from workflow.user_roles ur
    order by 1
  $$,
  $$values (false, false), (true, true)$$,
  'begge tildelingene står side om side; den avgrensede er urørt, og den nye er den uavgrensede selvtildelingen'
);

-- ===========================================================================
-- Del 9 — De tre andre applikasjonsrollene teller ikke som editor
--
-- DATABASE_ARCHITECTURE.md §45: de fire rollene er forskjellige rettigheter.
-- Talte oppslaget dem med, ville funksjonen lest en reviewer-tildeling som
-- «allerede autorisert» og aldri skrevet editor-rollen — redaktøren ville stått
-- igjen uten rett til å registrere kilder, og ingenting ville sagt fra.
-- ===========================================================================
delete from workflow.user_roles;
insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
select 'a703ede9-3f58-4de9-8c85-73936d58df1f', r.role_code, null,
       now() - interval '1 hour', a.id,
       'Tildeling av ' || r.role_code || ' i testen.'
from provenance.actors a,
     (values ('reviewer'::workflow.app_role), ('publisher'), ('admin')) as r(role_code)
where a.actor_key = 'human:peder-holman';

select is(
  workflow.ensure_editor_role_grant(),
  'authorized',
  'verken reviewer, publisher eller admin teller som en editor-tildeling; editor skrives'
);
select results_eq(
  $$
    select ur.role_code::text, ur.grant_reason like 'Selvtildeling%'
    from workflow.user_roles ur
    order by 1
  $$,
  $$values ('admin', false), ('editor', true), ('publisher', false), ('reviewer', false)$$,
  'de tre andre tildelingene står urørt ved siden av den nye editor-tildelingen'
);

select set_config('request.jwt.claims', '', true);

select * from finish();

rollback;
