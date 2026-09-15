-- Migrasjon 007b — kallerens egen autorisasjonslesevei.
--
-- MVP_IMPLEMENTATION_PLAN.md §29 sitt «manuell adminflyt» kan ikke begynne før
-- en klient kan svare på «hvem er jeg, og hva har jeg lov til?». Migrasjon 007b
-- åpner nøyaktig de radene som svarer på det, og ingenting mer. Denne filen
-- kontrollerer hvert lag for seg, etter samme oppskrift som
-- 290_api_read_model_access_test.sql:
--
--   lag 1  schema-USAGE mangler, så tabellene kan ikke navngis
--   lag 2  RLS slipper bare gjennom kallerens egne rader
--   lag 3  kolonnegranten avgjør hva av raden som kan leses
--   lag 4  viewene i api, som bare authenticated har SELECT på
--
-- Rekkefølgen på delene er ikke tilfeldig. Testene av lag 1 må kjøre før
-- selvtestene gir authenticated midlertidig usage, og kolonnegranten må prøves
-- før det tabellvide grantet legges på — et tabellvidt SELECT dekker hver
-- kolonne, så et grant lagt på for tidlig ville gjort kolonnetesten stille sann.
--
-- Den viktigste negative testen er at kallerne ikke ser hverandre.
-- workflow.user_roles er autorisasjonskilden (DATABASE_ARCHITECTURE.md §46), og
-- en klientrolle som kunne lese andres rader ville kunne kartlegge hvem som har
-- faglige rettigheter.
--
-- SQLSTATE 42501 = insufficient_privilege, 23514 = check_violation,
-- 23P01 = exclusion_violation.
begin;
\ir fixtures/active_clinical_fixture.inc

create extension if not exists pgtap with schema extensions;

select plan(35);

-- ===========================================================================
-- Del 1 — Kontrakten: hva migrasjonen faktisk åpnet
--
-- Det uttømmende inventaret over grants og policyer i workflow og provenance
-- står i 210_workflow_access_test.sql, som eier den kontrakten. Her prøves det
-- denne migrasjonen selv hevder: viewene er bare lesbare, og bare for
-- authenticated, og de tilbakeholdte kolonnene er tilbakeholdt.
-- ===========================================================================

-- anon er bevisst utelatt. En uinnlogget kaller har verken aktør eller roller,
-- og skal få avslag framfor et tomt svar — et tomt svar betyr allerede noe helt
-- annet her («ingen aktør knyttet til kontoen», «ingen rettighet nå»).
select is_empty(
  $$
    select t.view_name, r.role_name, p.privilege
    from (values ('api.my_actor'), ('api.my_roles')) as t(view_name)
    cross join (values ('anon'), ('authenticated'), ('service_role'), ('public'))
           as r(role_name)
    cross join (values ('select'), ('insert'), ('update'), ('delete'), ('truncate'),
                       ('references'), ('trigger')) as p(privilege)
    where has_table_privilege(r.role_name, t.view_name, p.privilege)
      and not (p.privilege = 'select' and r.role_name = 'authenticated')
  $$,
  'de to viewene gir bare SELECT, og bare til authenticated'
);

select is_empty(
  $$
    select t.table_name, t.column_name, r.role_name
    from (values ('provenance.actors', 'description'),
                 ('provenance.actors', 'retirement_note'),
                 ('provenance.actors', 'actor_type'),
                 ('provenance.actors', 'agent_role'),
                 ('provenance.actors', 'created_at'),
                 ('provenance.actors', 'updated_at'),
                 ('workflow.user_roles', 'id'),
                 ('workflow.user_roles', 'grant_reason'),
                 ('workflow.user_roles', 'granted_by_actor_id'),
                 ('workflow.user_roles', 'ended_by_actor_id'),
                 ('workflow.user_roles', 'end_reason'),
                 ('workflow.user_roles', 'created_at'),
                 ('workflow.user_roles', 'updated_at'))
           as t(table_name, column_name)
    cross join (values ('anon'), ('authenticated'), ('service_role'), ('public'))
           as r(role_name)
    where has_column_privilege(r.role_name, t.table_name, t.column_name, 'select')
  $$,
  'begrunnelsene, aktørpekerne og aktørens beskrivelse er ikke lesbare for noen klientrolle'
);

-- ===========================================================================
-- Del 2 — Lag 1: schema-USAGE mangler fortsatt
--
-- throws_like og ikke throws_ok: begge lagene gir 42501, og en test som bare
-- krevde koden ville passert også om den feilet på tabellprivilegiet i stedet.
-- Mønsteret navngir schemaet, altså nøyaktig det laget som skal stoppe kallet.
-- ===========================================================================
set local role authenticated;
select throws_like(
  'select 1 from workflow.user_roles',
  '%schema workflow%',
  'medlemskapstabellen kan ikke navngis: authenticated mangler usage på workflow'
);
select throws_like(
  'select 1 from provenance.actors',
  '%schema provenance%',
  'aktørregisteret kan ikke navngis: authenticated mangler usage på provenance'
);
reset role;

-- ===========================================================================
-- Del 3 — Lag 4: anon har ingenting
-- ===========================================================================
set local role anon;
select throws_like(
  'select 1 from api.my_actor',
  '%my_actor%',
  'anon nektes api.my_actor, og feilen navngir viewet og ikke et lag under det'
);
select throws_like(
  'select 1 from api.my_roles',
  '%my_roles%',
  'anon nektes api.my_roles'
);
reset role;

-- ===========================================================================
-- Del 4 — Fiksturen
--
-- Fem brukerkontoer, valgt for å spenne ut svarene viewene kan gi:
--
--   A  aktør, fire tildelinger — én gyldig uavgrenset, én gyldig avgrenset med
--      planlagt utløp, én som først begynner å gjelde senere, én avsluttet
--   B  aktør som er trukket tilbake, én gyldig tildeling
--   C  brukerkonto uten aktørrad og uten tildelinger
--   D  tildeling som trer i kraft *mens transaksjonen løper*
--   E  tildeling som utløper mens transaksjonen løper
--
-- D og E finnes bare for å skille statement_timestamp() fra now(); se del 6.
-- ===========================================================================
insert into auth.users (id, email) values
  ('f3600000-0000-4000-8000-00000000000a', 'kaller-a-360@test.invalid'),
  ('f3600000-0000-4000-8000-00000000000b', 'kaller-b-360@test.invalid'),
  ('f3600000-0000-4000-8000-00000000000c', 'kaller-c-360@test.invalid'),
  ('f3600000-0000-4000-8000-00000000000d', 'kaller-d-360@test.invalid'),
  ('f3600000-0000-4000-8000-00000000000e', 'kaller-e-360@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id,
   retired_at, retirement_note)
values
  ('ac360000-0000-4000-8000-00000000000a', 'human', 'human:kaller-360-a',
   'Kaller A', 'Menneskelig aktør for tilgangstestene i 360.',
   'f3600000-0000-4000-8000-00000000000a', null, null),
  ('ac360000-0000-4000-8000-00000000000b', 'human', 'human:kaller-360-b',
   'Kaller B', 'Tilbaketrukket menneskelig aktør for tilgangstestene i 360.',
   'f3600000-0000-4000-8000-00000000000b',
   now() - interval '30 days', 'Trukket tilbake for testene i 360.');

-- Fiksturtabellen leses av assertionene under, som kjører som klientrolle.
create temporary table fixture (name text primary key, id uuid not null) on commit drop;
grant select on fixture to anon, authenticated;
insert into fixture (name, id)
select 'topic', id from catalog.clinical_concepts where canonical_label = 'vektendring';

-- Tildelingene. granted_by_actor_id og ended_by_actor_id peker på A, som er den
-- eneste aktøren i fiksturen som ikke er trukket tilbake; hvem som tildelte er
-- uten betydning for det denne filen prøver, og er uansett ikke eksponert.
insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, valid_to,
   granted_by_actor_id, grant_reason, ended_by_actor_id, end_reason)
values
  -- Gyldig nå, uavgrenset, uten sluttdato.
  ('f3600000-0000-4000-8000-00000000000a', 'reviewer', null,
   now() - interval '1 year', null,
   'ac360000-0000-4000-8000-00000000000a', 'Gyldig uavgrenset tildeling for 360.',
   null, null),
  -- Gyldig nå, men med en planlagt utløpsdato satt allerede ved tildeling.
  -- Dette er tilfellet «valid_to is null» svarer feil på.
  ('f3600000-0000-4000-8000-00000000000a', 'editor',
   (select id from fixture where name = 'topic'),
   now() - interval '1 year', now() + interval '1 year',
   'ac360000-0000-4000-8000-00000000000a', 'Avgrenset tildeling med planlagt utløp, for 360.',
   'ac360000-0000-4000-8000-00000000000a', 'Planlagt utløp satt ved tildeling.'),
  -- Begynner å gjelde senere. En rettighet før den er gitt.
  ('f3600000-0000-4000-8000-00000000000a', 'publisher', null,
   now() + interval '1 day', null,
   'ac360000-0000-4000-8000-00000000000a', 'Tildeling som først begynner å gjelde senere, for 360.',
   null, null),
  -- Avsluttet. En tilbakekalt rettighet skal ikke kunne leses som gjeldende.
  ('f3600000-0000-4000-8000-00000000000a', 'admin', null,
   now() - interval '2 years', now() - interval '1 year',
   'ac360000-0000-4000-8000-00000000000a', 'Avsluttet tildeling for 360.',
   'ac360000-0000-4000-8000-00000000000a', 'Tilbakekalt for testene i 360.'),
  -- B sin egen tildeling. A skal aldri se den.
  ('f3600000-0000-4000-8000-00000000000b', 'reviewer', null,
   now() - interval '1 year', null,
   'ac360000-0000-4000-8000-00000000000a', 'Gyldig tildeling for kaller B, for 360.',
   null, null);

-- ---------------------------------------------------------------------------
-- Kallerens eget svar
--
-- Rollesettet sammenlignes som tekst framfor som tidsstempler: verdiene er
-- relative til transaksjonens starttidspunkt og lar seg ikke skrive som
-- literaler, mens det påstanden gjelder — hvilke tildelinger som er med, om de
-- er avgrenset, og om de har en sluttdato — er nøyaktig det som står her.
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims',
                  '{"sub":"f3600000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;

select bag_eq(
  $$select actor_key, display_name, retired_at is null from api.my_actor$$,
  $$values ('human:kaller-360-a', 'Kaller A', true)$$,
  'api.my_actor gir kallerens egen aktørrad, og bare den'
);

select bag_eq(
  $$
    select role_code || ':' || coalesce(scope_type, 'uavgrenset')
        || ':' || (valid_to is null)::text
        || ':' || (valid_from <= statement_timestamp())::text
    from api.my_roles
  $$,
  $$
    values ('reviewer:uavgrenset:true:true'),
           ('editor:clinical_concept:false:true')
  $$,
  'api.my_roles gir bare tildelingene som gjelder nå: den framtidige og den avsluttede er ikke med'
);

-- scope_id peker faktisk på begrepet tildelingen er avgrenset til. Uten dette
-- ville set-testen over vært like sann med en scope_id som pekte hvor som helst.
select is(
  (select scope_id from api.my_roles where role_code = 'editor'),
  (select id from fixture where name = 'topic'),
  'den avgrensede tildelingen bærer det kliniske begrepet den er avgrenset til'
);

-- Og motsatt vei: en uavgrenset tildeling har begge kolonnene NULL sammen.
-- scope_type er generert av scope_id nettopp for at de to ikke skal kunne komme
-- i utakt, og «uten avgrensning» skal ikke kunne se ut som «ukjent avgrensning».
select is_empty(
  $$
    select role_code from api.my_roles
    where (scope_id is null) <> (scope_type is null)
  $$,
  'scope_id og scope_type er NULL sammen eller utfylt sammen'
);

reset role;

select set_config('request.jwt.claims',
                  '{"sub":"f3600000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;

-- En tilbaketrukket aktør skjules ikke. Å utelate raden ville gjort «aktøren er
-- tatt ut av bruk» umulig å skille fra «ingen aktør er knyttet til kontoen», og
-- en klient ville da vist rettigheter kalleren ikke får brukt.
select bag_eq(
  $$select actor_key, retired_at is not null from api.my_actor$$,
  $$values ('human:kaller-360-b', true)$$,
  'en tilbaketrukket aktør er synlig for seg selv, med tilbaketrekkingen merket'
);

select bag_eq(
  $$select role_code from api.my_roles$$,
  $$values ('reviewer')$$,
  'kaller B ser bare sin egen tildeling; ingen av kaller A sine fire er med'
);

reset role;

-- ---------------------------------------------------------------------------
-- En brukerkonto uten aktørrad
--
-- Tomt api.my_actor betyr «ingen aktør er knyttet til kontoen», og det er en
-- reell tilstand: en menneskelig aktør kan registreres før brukerkontoen finnes,
-- og en brukerkonto kan finnes uten at noen har registrert en aktør for den.
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims',
                  '{"sub":"f3600000-0000-4000-8000-00000000000c"}', true);
set local role authenticated;

select is_empty(
  $$select actor_key from api.my_actor$$,
  'en brukerkonto uten aktørrad får et tomt api.my_actor'
);
select is_empty(
  $$select role_code from api.my_roles$$,
  'en brukerkonto uten tildelinger får et tomt api.my_roles'
);

reset role;

-- ---------------------------------------------------------------------------
-- Ingen JWT: NULL = NULL er ukjent, ikke sant
--
-- De seedede KI-aktørene har auth_user_id NULL. Var predikatet skrevet slik at
-- NULL matchet NULL, ville en innlogget kaller uten subjekt fått hele
-- aktørregisteret. Kontrollen teller ikke bare rader, men krever at aktørene
-- faktisk finnes å lekke — ellers ville den vært stille sann.
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims', '', true);

select isnt_empty(
  $$select actor_key from provenance.actors where auth_user_id is null$$,
  'det finnes aktører uten brukerkonto som en NULL-matchende policy ville lekket'
);

set local role authenticated;
select is_empty(
  $$select actor_key from api.my_actor$$,
  'en innlogget kaller uten subjekt i tokenet ser ingen aktør, og ikke aktørene uten konto'
);
select is_empty(
  $$select role_code from api.my_roles$$,
  'en innlogget kaller uten subjekt i tokenet ser ingen rolletildeling'
);
reset role;

-- ===========================================================================
-- Del 5 — Gyldighet måles på setningen, ikke på transaksjonen
--
-- MVP_IMPLEMENTATION_PLAN.md §74.6: tid som *avgjør* noe måles med
-- statement_timestamp(); now() er transaksjonens starttidspunkt. Forskjellen er
-- ikke akademisk her — med now() ville en tilbakekalling ikke virket for en
-- transaksjon som allerede var i gang, og en tildeling som trådte i kraft
-- underveis ville blitt lest som «gjelder ikke ennå».
--
-- Vinduet gjøres deterministisk med pg_sleep framfor å hvile på at to setninger
-- tilfeldigvis får ulikt tidsstempel: begge grensene legges 250 ms etter
-- transaksjonsstart, og spørringene skjer minst ett sekund etter.
-- ===========================================================================
insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, valid_to,
   granted_by_actor_id, grant_reason, ended_by_actor_id, end_reason)
values
  -- Trer i kraft mens transaksjonen løper. now() ville sagt «ikke ennå».
  ('f3600000-0000-4000-8000-00000000000d', 'reviewer', null,
   now() + interval '250 milliseconds', null,
   'ac360000-0000-4000-8000-00000000000a', 'Tildeling som trer i kraft underveis, for 360.',
   null, null),
  -- Utløper mens transaksjonen løper. now() ville sagt «gjelder fortsatt».
  ('f3600000-0000-4000-8000-00000000000e', 'reviewer', null,
   now() - interval '1 day', now() + interval '250 milliseconds',
   'ac360000-0000-4000-8000-00000000000a', 'Tildeling som utløper underveis, for 360.',
   'ac360000-0000-4000-8000-00000000000a', 'Planlagt utløp under transaksjonen.');

select pg_sleep(1);

select set_config('request.jwt.claims',
                  '{"sub":"f3600000-0000-4000-8000-00000000000d"}', true);
set local role authenticated;
select bag_eq(
  $$select role_code from api.my_roles$$,
  $$values ('reviewer')$$,
  'en tildeling som trådte i kraft mens transaksjonen løp, gjelder nå'
);
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"f3600000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;
select is_empty(
  $$select role_code from api.my_roles$$,
  'en tildeling som utløp mens transaksjonen løp, gjelder ikke lenger'
);
reset role;

-- ===========================================================================
-- Del 6 — Lag 3: kolonnegranten alene
--
-- Midlertidig usage på schemaene, og *ingen* tabellvidt grant: det som virker
-- her, virker på kolonnegranten fra migrasjon 007b og ingenting annet.
--
-- PostgreSQL svarer «permission denied for table user_roles» både når kolonnen
-- mangler grant og når hele tabellen gjør det. En negativ test alene kunne
-- derfor vært stille sann. Paret — den granta kolonnen leses, den tilbakeholdte
-- avvises, i samme kontekst — er det som fester kolonnegrensen.
-- ===========================================================================
grant usage on schema workflow, provenance to authenticated;

select set_config('request.jwt.claims',
                  '{"sub":"f3600000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;

select lives_ok(
  $$select role_code from workflow.user_roles$$,
  'en kolonne kolonnegranten dekker, er lesbar'
);
select throws_like(
  $$select grant_reason from workflow.user_roles$$,
  '%user_roles%',
  'begrunnelsen for tildelingen er ikke lesbar, selv med usage på schemaet'
);
select lives_ok(
  $$select actor_key from provenance.actors$$,
  'aktørnøkkelen er lesbar'
);
select throws_like(
  $$select description from provenance.actors$$,
  '%actors%',
  'aktørens beskrivelse er ikke lesbar, selv med usage på schemaet'
);

reset role;

-- ===========================================================================
-- Del 7 — Lag 2: RLS er radgrensen, også med et tabellvidt grant
--
-- Selvtest av lag 2: skulle en framtidig migrasjon ved et uhell gi
-- klientrollene et bredere privilegium, skal RLS fortsatt bare slippe gjennom
-- kallerens egne rader. Grantet finnes bare inne i denne transaksjonen.
-- ===========================================================================
grant select on workflow.user_roles to authenticated;
grant select on provenance.actors to authenticated;

-- Kontroll av selve selvtesten: det finnes mer å se enn kallerens egne rader.
-- Uten dette ville tallene under vært like sanne i en tom database.
select is(
  (select count(*) from workflow.user_roles), 7::bigint,
  'fiksturen har sju rolletildelinger totalt, sett fra eieren'
);

set local role authenticated;

select is(
  (select count(*) from workflow.user_roles), 4::bigint,
  'RLS gir kaller A nøyaktig sine egne fire tildelinger, også de som ikke gjelder nå'
);
select is(
  (select count(*) from provenance.actors), 1::bigint,
  'RLS gir kaller A nøyaktig sin egen aktørrad, av alle aktørene i registeret'
);

-- Skriveveien er uendret: policyene gjelder bare SELECT, og ingen grant åpner
-- for skriving. Den farligste skriveveien i hele schemaet er å gi seg selv en
-- rolle, så den prøves framfor å telles.
select throws_ok(
  $$
    insert into workflow.user_roles
      (user_id, role_code, granted_by_actor_id, grant_reason)
    values ('f3600000-0000-4000-8000-00000000000a', 'admin',
            'ac360000-0000-4000-8000-00000000000a', 'Selvtildelt rolle.')
  $$,
  '42501', null,
  'lesetilgangen til egne roller gir ingen vei til å gi seg selv en ny'
);
select throws_ok(
  $$update workflow.user_roles set valid_to = null, ended_by_actor_id = null, end_reason = null$$,
  '42501', null,
  'lesetilgangen gir ingen vei til å gjenåpne en avsluttet tildeling'
);

reset role;

-- ===========================================================================
-- Del 8 — Lag 4 alene: viewet filtrerer også når RLS slipper alt gjennom
--
-- Viewene gjentar eierskapspredikatet policyene allerede håndhever, etter samme
-- form som migrasjon 007: hvert lag skal være korrekt alene, slik at verken en
-- tapt policy eller en feilskrevet projeksjon er nok til å vise en annens rader.
--
-- Det dobbeltarbeidet er usynlig så lenge RLS holder — en mutasjon som fjerner
-- viewets eget predikat ville ellers overlevd hele filen, og dobbeltarbeidet
-- ville vært en påstand ingenting kontrollerte. En permissiv policy er OR-et
-- sammen med de andre, så en ekstra «using (true)» gjør RLS til en åpen dør og
-- lar viewets eget predikat stå alene. Begge policyene rulles tilbake med
-- transaksjonen.
-- ===========================================================================
create policy actors_probe_open_read on provenance.actors
  for select to authenticated using (true);
create policy user_roles_probe_open_read on workflow.user_roles
  for select to authenticated using (true);

-- Kontroll av selvtesten: døren er faktisk åpen. Uten dette ville de to
-- assertionene under vært like sanne om policyen ikke hadde virket.
set local role authenticated;
select isnt_empty(
  $$select actor_key from provenance.actors where auth_user_id is null$$,
  'den permissive probe-policyen slipper gjennom aktørene uten brukerkonto, som ellers aldri er lesbare for en klientrolle'
);
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"f3600000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;

select bag_eq(
  $$select actor_key from api.my_actor$$,
  $$values ('human:kaller-360-a')$$,
  'api.my_actor viser bare kallerens egen aktør selv når RLS slipper alle gjennom'
);
select is(
  (select count(*) from api.my_roles), 2::bigint,
  'api.my_roles viser bare kallerens egne gjeldende tildelinger selv når RLS slipper alle gjennom'
);

reset role;
drop policy user_roles_probe_open_read on workflow.user_roles;
drop policy actors_probe_open_read on provenance.actors;

-- ===========================================================================
-- Del 9 — Antakelsene viewene hviler på, prøvd framfor talt
--
-- Hver av de to utelatte kolonnene hviler på en databaseregel. En påstand om at
-- regelen finnes, sier ingenting om at den virker: begge prøves ved å forsøke
-- handlingen regelen skal stoppe.
-- ===========================================================================

-- api.my_actor projiserer ikke actor_type, fordi bare et menneske kan ha en
-- brukerkonto. Faller den regelen bort, er kolonnen ikke lenger uten
-- informasjon, og viewet skjuler at kalleren er en KI-aktør.
select throws_ok(
  $$
    insert into provenance.actors
      (actor_type, actor_key, display_name, description, agent_role, auth_user_id)
    values ('agent', 'agent:kaller-360', 'Agent med konto',
            'Forsøk på å knytte en KI-aktør til en brukerkonto.',
            'adversarial_review', 'f3600000-0000-4000-8000-00000000000c')
  $$,
  '23514', null,
  'en KI-aktør kan ikke knyttes til en brukerkonto, så aktørtypen i api.my_actor ville hatt én mulig verdi'
);

-- api.my_roles projiserer ikke tildelingens id, fordi (role_code, scope_id) er
-- entydig innenfor det settet viewet viser: to tildelinger som begge gjelder nå
-- ville overlappet i tid, og det er nettopp det exclusion constraint-en forbyr.
select throws_ok(
  $$
    insert into workflow.user_roles
      (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
    values ('f3600000-0000-4000-8000-00000000000a', 'reviewer', null,
            now() - interval '1 month',
            'ac360000-0000-4000-8000-00000000000a', 'Overlappende uavgrenset tildeling.')
  $$,
  '23P01', null,
  'to overlappende uavgrensede reviewer-tildelinger avvises, så role_code er entydig blant de uavgrensede'
);

-- Men avgrensningen er en del av nøkkelen, ikke en detalj ved siden av den: en
-- avgrenset tildeling av samme rolle er lovlig, og da er det scope_id som
-- skiller de to radene fra hverandre.
select lives_ok(
  $$
    insert into workflow.user_roles
      (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
    values ('f3600000-0000-4000-8000-00000000000a', 'reviewer',
            (select id from catalog.clinical_concepts where canonical_label = 'vektendring'),
            now() - interval '1 month',
            'ac360000-0000-4000-8000-00000000000a', 'Avgrenset reviewer-tildeling ved siden av den uavgrensede.')
  $$,
  'en avgrenset tildeling av samme rolle kolliderer ikke med den uavgrensede'
);

select set_config('request.jwt.claims',
                  '{"sub":"f3600000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;

select bag_eq(
  $$
    select role_code || ':' || coalesce(scope_type, 'uavgrenset') from api.my_roles
  $$,
  $$
    values ('reviewer:uavgrenset'),
           ('reviewer:clinical_concept'),
           ('editor:clinical_concept')
  $$,
  'de to reviewer-tildelingene står som hver sin rad, skilt av avgrensningen'
);

reset role;
select set_config('request.jwt.claims', '', true);

select finish();

rollback;
