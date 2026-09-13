-- Migrasjon 005b — begge grenene av den miljøavhengige autorisasjonen.
--
-- MVP_IMPLEMENTATION_PLAN.md §74.18 valgte «vei a»: koblingen mellom
-- redaktørens aktørrad og brukerkontoen gjøres betinget av at kontoen finnes,
-- fordi en rad i auth.users er miljøspesifikk tilstand og ikke schema. Prisen
-- for det valget er at migrasjonen gjør forskjellige ting i forskjellige
-- miljøer, og at CI ellers aldri ville kjørt den grenen som faktisk kjører i
-- produksjon.
--
-- Denne filen betaler prisen. Den kjører BEGGE grenene av
-- workflow.ensure_named_editor_authorization():
--
--   negativ   kontoen mangler, som i enhver fersk stack: funksjonen skriver
--             ingenting og sier fra
--   positiv   kontoen opprettes inne i transaksjonen som rulles tilbake, slik
--             testene allerede gjør for alt annet, og hele produksjonsveien
--             kjøres — kobling, rolletildeling, auditrad og virkningen på
--             kvalifikasjonskontrollen
--
-- 220_provenance_seed_test.sql påstår at den migrerte tilstanden er uendret.
-- Det er en påstand om tilstanden, ikke om koden: den ville vært like sann om
-- migrasjonen aldri hadde kjørt. Assertion 1-3 her binder den negative grenen
-- til funksjonen ved å kalle den og kreve at kallet ikke skriver noe.
begin;

create extension if not exists pgtap with schema extensions;

select plan(27);

-- ---------------------------------------------------------------------------
-- Den negative grenen: kontoen finnes ikke
-- ---------------------------------------------------------------------------
--
-- Dette er tilstanden i CI og i enhver lokal stack. Kallet er ikke en no-op som
-- går stille: statusen kommer tilbake til kalleren, og funksjonen gir i tillegg
-- en notice, slik at raden ikke kan utebli i stillhet under `supabase db push`.
select is(
  workflow.ensure_named_editor_authorization(),
  'account_missing',
  'uten brukerkontoen i auth.users rapporterer funksjonen at kontoen mangler'
);
select is_empty(
  $$select actor_key from provenance.actors where auth_user_id is not null$$,
  'den negative grenen knytter ingen aktør til en brukerkonto'
);
select is(
  (select count(*) from workflow.user_roles),
  0::bigint,
  'den negative grenen tildeler ingen rolle'
);

-- Aktørraden er en forutsetning og ikke noe funksjonen kan klare seg uten.
-- Mangler den, er migrasjonskjeden brutt, og det skal feile høyt framfor å bli
-- en stille no-op som ser ut som «kontoen manglet». throws_ok ruller tilbake
-- slettingen sammen med feilen.
-- Aktørraden kan ikke lenger slettes: migrasjon 005f registrerte den første
-- agentidentiteten, og både identiteten og auditraden den la igjen, peker på
-- redaktøren med RESTRICT. Det er nettopp meningen — et menneskes attribusjon
-- skal ikke kunne forsvinne under en maskin som handler i hens navn, og en
-- auditrad skal ikke kunne miste aktøren sin.
--
-- Proben stiller derfor den samme tilstanden på en måte som ikke rører noe av
-- det: aktørnøkkelen endres, slik at oppslaget funksjonen gjør ikke finner noe.
-- Det krever at aktøridentitetsvernet slås av, og det er skrevet ut framfor å
-- skjules — throws_ok ruller hele transaksjonen tilbake etterpå.
select throws_ok(
  $$
    do $probe$
    begin
      alter table provenance.actors disable trigger actors_freeze_identity;
      update provenance.actors
      set actor_key = 'human:ikke-registrert'
      where actor_key = 'human:peder-holman';
      alter table provenance.actors enable trigger actors_freeze_identity;
      perform workflow.ensure_named_editor_authorization();
    end
    $probe$
  $$,
  'P0002',
  'Aktøren ''human:peder-holman'' finnes ikke; migrasjon 005a har ikke kjørt.',
  'uten aktørraden fra 005a feiler autorisasjonen høyt framfor å utebli stille'
);

-- Og aktøren kan ikke autoriseres for en annen konto enn den §74.18 navngir.
-- Uten denne grenen ville en aktør som allerede peker et annet sted fått
-- rollen tildelt til en konto som ikke er bundet til den — altså en rettighet
-- uten den attribusjonen den hviler på.
select throws_ok(
  $$
    do $probe$
    begin
      insert into auth.users (id, email)
      values ('cccccccc-0000-0000-0000-000000000009', 'feil-konto-350@test.invalid');
      update provenance.actors
      set auth_user_id = 'cccccccc-0000-0000-0000-000000000009'
      where actor_key = 'human:peder-holman';
      perform workflow.ensure_named_editor_authorization();
    end
    $probe$
  $$,
  '23001',
  'Aktøren ''human:peder-holman'' er allerede knyttet til brukerkontoen ''cccccccc-0000-0000-0000-000000000009'' og kan ikke autoriseres for en annen.',
  'en aktør som allerede peker på en annen brukerkonto blir ikke autorisert for denne'
);

-- ---------------------------------------------------------------------------
-- Den positive grenen: kontoen finnes
-- ---------------------------------------------------------------------------
--
-- Bare id og email settes. Det eneste denne testen trenger av kontoen, er at
-- fremmednøkkelen fra workflow.user_roles har noe å peke på; resten av
-- auth.users eies av autentiseringslaget og skal ikke etterlignes her. Samme
-- form som 250_publication_gate_test.sql.
insert into auth.users (id, email)
values ('a703ede9-3f58-4de9-8c85-73936d58df1f', 'redaktor-350@test.invalid');

select is(
  workflow.ensure_named_editor_authorization(),
  'authorized',
  'med brukerkontoen på plass utfører funksjonen autorisasjonen'
);

select results_eq(
  $$
    select actor_key, auth_user_id::text
    from provenance.actors
    where auth_user_id is not null
  $$,
  $$values ('human:peder-holman', 'a703ede9-3f58-4de9-8c85-73936d58df1f')$$,
  'nøyaktig én aktør er knyttet til en brukerkonto, og det er den navngitte redaktøren'
);

-- Hele tildelingen i én assertion, felt for felt. scope_id NULL betyr «uten
-- avgrensning» og valid_to NULL betyr «løpende»; begge er valg og ikke
-- utelatelser, så begge påstås.
select results_eq(
  $$
    select ur.user_id::text, ur.role_code::text,
           ur.scope_id is null, ur.valid_to is null, g.actor_key
    from workflow.user_roles ur
    join provenance.actors g on g.id = ur.granted_by_actor_id
  $$,
  $$values ('a703ede9-3f58-4de9-8c85-73936d58df1f', 'reviewer',
            true, true, 'human:peder-holman')$$,
  'det finnes nøyaktig én rolletildeling: en løpende reviewer-rolle uten avgrensning, tildelt av redaktørens egen aktør'
);

-- Selvtildelingen er ikke forbudt av noen CHECK (MVP_IMPLEMENTATION_PLAN.md
-- §74.17 punkt 3), så begrunnelsen i raden er hele sikringen. Assertionen
-- krever at ordet står FØRST og ikke bare et sted i teksten: et treff hvor som
-- helst i feltet ville også slått ut på en benektelse av det.
select ok(
  (select grant_reason from workflow.user_roles) like 'Selvtildeling%',
  'tildelingsraden navngir selvtildelingen i sin egen begrunnelse'
);

-- Tildelingen skriver sin egen auditrad, uten at migrasjonen setter noe: den
-- kommer fra user_roles_record_grant_audit_event i migrasjon 008.
select results_eq(
  $$
    select e.operation::text, e.object_schema, e.object_table, a.actor_key,
           e.new_revision_or_snapshot->>'role_code'
    from audit.events e
    join provenance.actors a on a.id = e.actor_id
    order by e.occurred_at, e.operation::text
  $$,
  -- De fire første radene kommer fra migrasjon 005f, 005i, 005w og 005ak og er
  -- migrert tilstand, ikke noe denne testen gjør. De står med i assertionen
  -- framfor å filtreres bort: listen er uttømmende, så en uventet auditrad slår
  -- fortsatt ut. Rekkefølgen mellom dem er ikke sortert på her — de er
  -- identiske, så resultatet er det samme uansett hvilken som kom først.
  $$values ('agent_identity_registered', 'provenance', 'agent_identities', 'human:peder-holman', null),
           ('agent_identity_registered', 'provenance', 'agent_identities', 'human:peder-holman', null),
           ('agent_identity_registered', 'provenance', 'agent_identities', 'human:peder-holman', null),
           ('agent_identity_registered', 'provenance', 'agent_identities', 'human:peder-holman', null),
           ('role_granted', 'workflow', 'user_roles', 'human:peder-holman', 'reviewer')$$,
  'tildelingen legger igjen én auditrad, attribuert til aktøren som tildelte rollen'
);

-- ---------------------------------------------------------------------------
-- Idempotens
-- ---------------------------------------------------------------------------
--
-- Vei a betyr at koblingen kan bli stående ugjort i et miljø der kontoen kommer
-- senere, og at funksjonen da skal kunne kalles på nytt. Et andre kall må
-- verken feile på exclusion constraint-en eller legge igjen en rolletildeling
-- til.
select is(
  workflow.ensure_named_editor_authorization(),
  'already_authorized',
  'et nytt kall etter en fullført autorisasjon rapporterer at den allerede er gjort'
);
select is(
  (select count(*) from workflow.user_roles),
  1::bigint,
  'et nytt kall legger ikke igjen en rolletildeling til'
);

-- ---------------------------------------------------------------------------
-- Virkningen: kvalifikasjonskravet er innfridd, publiseringsgaten er det ikke
-- ---------------------------------------------------------------------------
--
-- 220 krever at en faglig beslutning i redaktørens navn avvises med
-- insufficient_privilege så lenge kontoen mangler. Her er speilbildet, og det
-- er prøvd framfor talt: den samme handlingen går gjennom når autorisasjonen er
-- på plass.
--
-- Beslutningen er bevisst `changes_requested` og ikke `approved`. Det som
-- kontrolleres er kvalifikasjonskravet, og det leser verken beslutningstypen
-- eller utfallet. En «approved» ville derimot vært en registrert faglig
-- godkjenning uten at noen har gjennomgått noe — nøyaktig den fiktive
-- godkjenningen ANTIDEP_CONSTITUTION.md §12 forbyr, og transaksjonen som ruller
-- tilbake gjør den ikke mindre fiktiv mens den står.
select lives_ok(
  $$
    insert into workflow.review_decisions
      (claim_revision_id, claim_revision_creator_actor_id,
       review_type, decision, rationale,
       reviewer_actor_id, reviewer_actor_type, decided_at)
    select r.id, r.created_by_actor_id,
           'publication_approval', 'changes_requested',
           'Testprobe for kvalifikasjonskravet. Ingen faglig gjennomgang har funnet sted.',
           a.id, 'human', now()
    from knowledge.claim_revisions r
    cross join provenance.actors a
    where a.actor_key = 'human:peder-holman'
    order by r.id
    limit 1
  $$,
  'med brukerkonto og gyldig reviewer-rolle avviser kvalifikasjonskontrollen ikke lenger en beslutning i redaktørens navn'
);

-- Men autorisasjonen åpner ikke publiseringsgaten. De tre andre tingene Milepæl
-- B mangler (§74.4) er urørt, og gaten skal fortsatt stoppe på den første av
-- dem — ekstraksjonsverifikasjonen — og ikke på reviewer.
select throws_like(
  $$
    select knowledge.assert_claim_revision_publishable(
      (select id from knowledge.claim_revisions order by id limit 1))
  $$,
  '%uten registrert ekstraksjonsverifikasjon%',
  'rolletildelingen åpner ikke publiseringsgaten; den stopper fortsatt på den manglende ekstraksjonsverifikasjonen'
);

-- ---------------------------------------------------------------------------
-- De fire lovlige tilstandene en eksisterende rolletildeling kan stå i
-- ---------------------------------------------------------------------------
--
-- workflow.user_roles er en gyldighetsmodell og ikke et flagg: tildelingen har
-- et halvåpent intervall [valid_from, valid_to), og valid_to kan være satt
-- allerede ved tildeling som en planlagt utløpsdato. «Løpende» og «gyldig nå»
-- er derfor to forskjellige spørsmål.
--
-- Funksjonen skiller mellom alle fire tilstandene, og bare én av dem skriver
-- noe. Hver av de tre andre prøves her framfor å bli påstått.

-- 1. Gyldig nå, men tidsavgrenset. Tildelingen fra assertionene over avsluttes
--    med en utløpsdato som ligger fram i tid — det er en normal tildeling og
--    ikke en tilbakekalling.
--
--    Dette er regresjonstesten. Et predikat skrevet som «valid_to is null»
--    leser denne raden som «ingen tildeling», forsøker å skrive en ny med
--    intervallet [nå, ∞), og user_roles_no_overlapping_grant_excl avviser den:
--    kallet feiler i stedet for å svare. En `supabase db push` ville stoppet.
update workflow.user_roles
set valid_to = now() + interval '30 days',
    ended_by_actor_id = granted_by_actor_id,
    end_reason = 'Planlagt utløpsdato satt i testen; tildelingen gjelder fortsatt.';

select is(
  workflow.ensure_named_editor_authorization(),
  'already_authorized',
  'en tidsavgrenset tildeling som gjelder nå leses som gyldig, ikke som fraværende'
);
select is(
  (select count(*) from workflow.user_roles),
  1::bigint,
  'ingen overlappende tildeling forsøkes ved siden av den tidsavgrensede'
);

-- 2. Avsluttet tildeling. Den skal ikke gjeninnføres.
--
--    DATABASE_ARCHITECTURE.md §46 krever at en rettighet kan tilbakekalles
--    umiddelbart, og en tilbakekalling som en rutinemessig migrasjonskjøring
--    omgjør, er ingen tilbakekalling. workflow.freeze_role_grant() sier det
--    samme om modellen: en gjeninnføring er en ny tildeling med sin egen
--    begrunnelse — og en slik begrunnelse kan ikke dikte seg selv opp.
--
--    Slettingen her er teststillas. Intervallet på en avsluttet tildeling kan
--    ikke skrives om etterpå (freeze_role_grant), så tilstanden må settes opp
--    fra bunnen. Alt rulles tilbake.
delete from workflow.user_roles;
insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, valid_to,
   granted_by_actor_id, grant_reason, ended_by_actor_id, end_reason)
select 'a703ede9-3f58-4de9-8c85-73936d58df1f', 'reviewer', null,
       now() - interval '2 years', now() - interval '1 year',
       a.id, 'Opprinnelig tildeling i testen.',
       a.id, 'Tilbakekalt i testen.'
from provenance.actors a
where a.actor_key = 'human:peder-holman';

select is(
  workflow.ensure_named_editor_authorization(),
  'role_ended',
  'en avsluttet tildeling rapporteres som avsluttet, ikke som fraværende'
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
  $$values ('reviewer', true, true, 'Tilbakekalt i testen.')$$,
  'tilbakekallingen står urørt, og ingen ny tildeling er skrevet ved siden av den'
);

-- 3. Tildeling som først begynner å gjelde senere. Ingen rettighet finnes nå,
--    men en ny tildeling ville overlappet den framtidige og blitt avvist.
delete from workflow.user_roles;
insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
select 'a703ede9-3f58-4de9-8c85-73936d58df1f', 'reviewer', null,
       now() + interval '7 days', a.id, 'Planlagt tildeling i testen.'
from provenance.actors a
where a.actor_key = 'human:peder-holman';

select is(
  workflow.ensure_named_editor_authorization(),
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
--    måten en autorisasjonskontroll kan ta feil, og rekkefølgen mellom de tre
--    spørsmålene er derfor skrevet ut i funksjonen framfor å falle ut av
--    rekkefølgen på tre uavhengige kontroller.
delete from workflow.user_roles;
insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, valid_to,
   granted_by_actor_id, grant_reason, ended_by_actor_id, end_reason)
select 'a703ede9-3f58-4de9-8c85-73936d58df1f', 'reviewer', null,
       now() - interval '2 years', now() - interval '1 year',
       a.id, 'Opprinnelig tildeling i testen.',
       a.id, 'Tilbakekalt i testen.'
from provenance.actors a
where a.actor_key = 'human:peder-holman';
insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
select 'a703ede9-3f58-4de9-8c85-73936d58df1f', 'reviewer', null,
       now() - interval '1 hour', a.id, 'Gjeninnført tildeling i testen.'
from provenance.actors a
where a.actor_key = 'human:peder-holman';

select is(
  workflow.ensure_named_editor_authorization(),
  'already_authorized',
  'en løpende tildeling ved siden av en avsluttet gir gyldig, ikke avsluttet'
);
select is(
  (select count(*) from workflow.user_roles),
  2::bigint,
  'presedensen skriver ingenting; begge de eksisterende tildelingene står'
);

-- 5. Gyldighet måles på setningen, ikke på transaksjonen.
--
--    MVP_IMPLEMENTATION_PLAN.md §74.6: tid som *avgjør* noe måles med
--    statement_timestamp(); now() er transaksjonens starttidspunkt. Predikatet
--    her avgjør om en rettighet gjelder, så forskjellen er ikke akademisk: en
--    tildeling som trådte i kraft mens transaksjonen løp, ville med now() blitt
--    lest som «gjelder ikke ennå» så lenge transaksjonen varte.
--
--    Vinduet gjøres deterministisk med pg_sleep framfor å hvile på at to
--    setninger tilfeldigvis får ulikt tidsstempel: tildelingen begynner å
--    gjelde 50 ms etter transaksjonsstart, og kallet skjer minst 200 ms etter.
delete from workflow.user_roles;
insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
select 'a703ede9-3f58-4de9-8c85-73936d58df1f', 'reviewer', null,
       now() + interval '50 milliseconds', a.id,
       'Tildeling som trer i kraft mens transaksjonen løper.'
from provenance.actors a
where a.actor_key = 'human:peder-holman';

select pg_sleep(0.2);

select is(
  workflow.ensure_named_editor_authorization(),
  'already_authorized',
  'en tildeling som trådte i kraft mens transaksjonen løp, leses som gyldig nå'
);

-- 6. En *avgrenset* reviewer-tildeling er en annen og smalere rettighet.
--
--    Den skal verken telle som den uavgrensede eller blokkere den.
--    user_roles_no_overlapping_grant_excl nøkler på
--    coalesce(scope_id, ...), så de to kolliderer ikke — og nettopp derfor må
--    oppslaget i funksjonen bruke samme nøkkel. Uten `scope_id is null` der
--    ville en avgrenset tildeling gjort at redaktøren stille satt igjen med en
--    smalere rettighet enn den migrasjonen skal gi.
delete from workflow.user_roles;
insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
select 'a703ede9-3f58-4de9-8c85-73936d58df1f', 'reviewer', cc.id,
       now() - interval '1 hour', a.id,
       'Avgrenset tildeling i testen.'
from provenance.actors a, catalog.clinical_concepts cc
where a.actor_key = 'human:peder-holman'
  and cc.canonical_label = 'vektendring';

select is(
  workflow.ensure_named_editor_authorization(),
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

-- 7. En annen applikasjonsrolle er ikke en reviewer-rolle.
--
--    DATABASE_ARCHITECTURE.md §45: admin, editor og publisher gir ikke faglig
--    godkjenningsrett. Talte oppslaget dem med, ville funksjonen lest en
--    editor-tildeling som «allerede autorisert» og aldri skrevet
--    reviewer-rollen — redaktøren ville stått igjen uten godkjenningsrett, og
--    ingenting ville sagt fra.
delete from workflow.user_roles;
insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
select 'a703ede9-3f58-4de9-8c85-73936d58df1f', 'editor', null,
       now() - interval '1 hour', a.id, 'Editor-tildeling i testen.'
from provenance.actors a
where a.actor_key = 'human:peder-holman';

select is(
  workflow.ensure_named_editor_authorization(),
  'authorized',
  'en editor-tildeling teller ikke som en reviewer-tildeling; reviewer skrives'
);
select results_eq(
  $$
    select ur.role_code::text, ur.grant_reason like 'Selvtildeling%'
    from workflow.user_roles ur
    order by 1
  $$,
  $$values ('editor', false), ('reviewer', true)$$,
  'editor-tildelingen står urørt ved siden av den nye reviewer-tildelingen'
);

select * from finish();

rollback;
