-- Migrasjon 005e — legitimasjonens livssyklus og autentiseringen som er
-- rettighetsgrensen mellom agentledd.
--
-- Dette er den viktigste filen i endringen. Den prøver det som skal være sant
-- for at «en agent skal ikke kunne verifisere sitt eget arbeid» er en regel og
-- ikke en promptkonvensjon: at en identitet bare slipper gjennom for sin egen
-- rolle, at legitimasjonen aldri finnes i klartekst i basen, at en rotasjon
-- ugyldiggjør den forrige, og at en tilbakekalt identitet eller en tilbaketrukket
-- aktør ikke kan gjøre noe som helst.
--
-- Alle avvisningene skal være identiske. En feilmelding som skilte «ukjent
-- identitet» fra «feil hemmelighet», ville gjort flaten til et oppslagsverk over
-- hvilke identiteter som finnes.
--
-- SQLSTATE 42501 = insufficient_privilege, P0002 = no_data_found,
-- 23001 = restrict_violation.
begin;

create extension if not exists pgtap with schema extensions;

select plan(27);

-- ===========================================================================
-- Del 1 — Utgangstilstanden: identiteten er registrert og inert
-- ===========================================================================
select is(
  (select secret_version from provenance.agent_identities
   where identity_key = 'agent-identity:extraction-verification-01'),
  0,
  'identiteten har ingen utstedt legitimasjon etter migrasjonene'
);

-- ===========================================================================
-- Del 2 — Utstedelsen
-- ===========================================================================
create temporary table cred(label text primary key, secret text);

insert into cred
select 'first', provenance.issue_agent_identity_credential(
  'agent-identity:extraction-verification-01', 'human:peder-holman'
);

select matches(
  (select secret from cred where label = 'first'),
  '^[0-9a-f]{64}$',
  'utstedelsen returnerer en hemmelighet på 256 bits, i heksadesimal form'
);

-- Klartekstverdien skal ikke finnes i raden. Assertionen sammenligner den
-- faktiske hemmeligheten mot den faktiske kolonnen, framfor å stole på at
-- kolonnenavnet betyr det det heter.
select ok(
  (select ai.secret_hash from provenance.agent_identities ai
   where ai.identity_key = 'agent-identity:extraction-verification-01')
  not like ('%' || (select secret from cred where label = 'first') || '%'),
  'hemmeligheten finnes ikke i klartekst i raden'
);

select results_eq(
  $$
    select ai.secret_version,
           ai.secret_hash = provenance.agent_secret_hash(
             ai.identity_key, (select secret from cred where label = 'first')),
           ai.secret_issued_at is not null,
           issuer.actor_key,
           ai.secret_issued_by_actor_type::text
    from provenance.agent_identities ai
    join provenance.actors issuer on issuer.id = ai.secret_issued_by_actor_id
    where ai.identity_key = 'agent-identity:extraction-verification-01'
  $$,
  $$values (1, true, true, 'human:peder-holman', 'human')$$,
  'raden bærer versjonstall, hash av den utstedte hemmeligheten og den menneskelige utstederen'
);

-- Hashen er bundet til identitetsnøkkelen. Uten bindingen ville en lekket hash
-- kunnet spilles av mot en annen identitet.
select isnt(
  provenance.agent_secret_hash('agent-identity:en-annen', 'samme-hemmelighet'),
  provenance.agent_secret_hash('agent-identity:extraction-verification-01', 'samme-hemmelighet'),
  'samme hemmelighet gir forskjellig hash under forskjellige identiteter'
);

-- ===========================================================================
-- Del 3 — Autentiseringen, og rollen som rettighetsgrense
-- ===========================================================================
select is(
  provenance.authenticate_agent_identity(
    'agent-identity:extraction-verification-01',
    (select secret from cred where label = 'first'),
    'extraction_verification'::provenance.agent_role
  ),
  (select id from provenance.agent_identities
   where identity_key = 'agent-identity:extraction-verification-01'),
  'riktig nøkkel, riktig hemmelighet og riktig rolle gir identitetens id'
);

-- Kjernen i separasjonen: identiteten har verifikatorrollen og ingen annen, og
-- kan derfor ikke autentisere seg for et ekstraksjonssteg — selv med korrekt
-- legitimasjon. Det er dette som gjør at et agentledd ikke kan utføre et annet
-- agentledds operasjon (ANTIDEP_CONSTITUTION.md §10, §11).
select throws_ok(
  $$
    select provenance.authenticate_agent_identity(
      'agent-identity:extraction-verification-01',
      (select secret from cred where label = 'first'),
      'evidence_extraction'::provenance.agent_role)
  $$,
  '42501', 'Agentidentiteten kunne ikke autentiseres for denne operasjonen.',
  'gyldig legitimasjon gir ingen tilgang til et annet agentledds rolle'
);
select throws_ok(
  $$
    select provenance.authenticate_agent_identity(
      'agent-identity:extraction-verification-01',
      (select secret from cred where label = 'first'),
      'citation_support_verification'::provenance.agent_role)
  $$,
  '42501', 'Agentidentiteten kunne ikke autentiseres for denne operasjonen.',
  'ekstraksjonsverifikatoren er ikke også claim-verifikator'
);

select throws_ok(
  $$
    select provenance.authenticate_agent_identity(
      'agent-identity:extraction-verification-01', 'feil-hemmelighet',
      'extraction_verification'::provenance.agent_role)
  $$,
  '42501', 'Agentidentiteten kunne ikke autentiseres for denne operasjonen.',
  'feil hemmelighet avvises'
);
select throws_ok(
  $$
    select provenance.authenticate_agent_identity(
      'agent-identity:finnes-ikke',
      (select secret from cred where label = 'first'),
      'extraction_verification'::provenance.agent_role)
  $$,
  '42501', 'Agentidentiteten kunne ikke autentiseres for denne operasjonen.',
  'en ukjent identitet avvises med nøyaktig samme melding som feil hemmelighet'
);

-- ===========================================================================
-- Del 4 — Rotasjon
-- ===========================================================================
insert into cred
select 'second', provenance.issue_agent_identity_credential(
  'agent-identity:extraction-verification-01', 'human:peder-holman'
);

select isnt(
  (select secret from cred where label = 'second'),
  (select secret from cred where label = 'first'),
  'en rotasjon gir en ny hemmelighet'
);
select is(
  (select secret_version from provenance.agent_identities
   where identity_key = 'agent-identity:extraction-verification-01'),
  2,
  'rotasjonen øker versjonstallet, slik at byttet er synlig i raden'
);
select throws_ok(
  $$
    select provenance.authenticate_agent_identity(
      'agent-identity:extraction-verification-01',
      (select secret from cred where label = 'first'),
      'extraction_verification'::provenance.agent_role)
  $$,
  '42501', 'Agentidentiteten kunne ikke autentiseres for denne operasjonen.',
  'den forrige hemmeligheten slutter å virke i det den er rotert'
);
select lives_ok(
  $$
    select provenance.authenticate_agent_identity(
      'agent-identity:extraction-verification-01',
      (select secret from cred where label = 'second'),
      'extraction_verification'::provenance.agent_role)
  $$,
  'den nye hemmeligheten virker'
);

-- ===========================================================================
-- Del 5 — Utstedelsen er en menneskelig handling
-- ===========================================================================
select throws_ok(
  $$
    select provenance.issue_agent_identity_credential(
      'agent-identity:finnes-ikke', 'human:peder-holman')
  $$,
  'P0002', 'Agentidentiteten ''agent-identity:finnes-ikke'' finnes ikke.',
  'legitimasjon kan ikke utstedes til en identitet som ikke er registrert'
);
select throws_ok(
  $$
    select provenance.issue_agent_identity_credential(
      'agent-identity:extraction-verification-01', 'agent:evidence-extraction')
  $$,
  '23001', '''agent:evidence-extraction'' er ikke en registrert menneskelig aktør.',
  'en agent kan ikke utstede legitimasjon til en agent'
);

-- ===========================================================================
-- Del 6 — En tilbaketrukket aktør kan ikke handle
--
-- Tilbaketrekking er en statusendring og ikke en sletting: historikken består,
-- og aktøren kan tas i bruk igjen. Begge veier prøves, slik at en test som
-- passerte fordi ingenting virket, ikke kan se ut som en bestått kontroll.
-- ===========================================================================
update provenance.actors
set retired_at = now(), retirement_note = 'Prøve i 420.'
where actor_key = 'agent:extraction-verification';

select throws_ok(
  $$
    select provenance.authenticate_agent_identity(
      'agent-identity:extraction-verification-01',
      (select secret from cred where label = 'second'),
      'extraction_verification'::provenance.agent_role)
  $$,
  '42501', 'Agentidentiteten kunne ikke autentiseres for denne operasjonen.',
  'en identitet hvis aktør er trukket tilbake, kan ikke autentisere seg'
);
select throws_ok(
  $$
    select provenance.issue_agent_identity_credential(
      'agent-identity:extraction-verification-01', 'human:peder-holman')
  $$,
  '23001',
  'Aktøren bak agentidentiteten ''agent-identity:extraction-verification-01'' er trukket tilbake.',
  'en tilbaketrukket aktør får ingen ny legitimasjon'
);

-- Samme regel, men på den privilegerte veien utenom funksjonen. Uten den ville
-- en direkte rotasjon lyktes, og legitimasjonen ville blitt gyldig i det
-- aktøren tas i bruk igjen — uten at noen hadde utstedt noe etter
-- reaktiveringen.
select throws_ok(
  $$
    update provenance.agent_identities ai
    set secret_hash = 'sha256-v1:' || repeat('c', 64),
        secret_version = ai.secret_version + 1,
        secret_issued_at = now()
    where ai.identity_key = 'agent-identity:extraction-verification-01'
  $$,
  '23001', null,
  'legitimasjonen kan ikke roteres direkte mens agentaktøren er trukket tilbake'
);

update provenance.actors
set retired_at = null, retirement_note = null
where actor_key = 'agent:extraction-verification';

select lives_ok(
  $$
    select provenance.authenticate_agent_identity(
      'agent-identity:extraction-verification-01',
      (select secret from cred where label = 'second'),
      'extraction_verification'::provenance.agent_role)
  $$,
  'aktøren kan tas i bruk igjen, og identiteten virker da som før'
);

-- Reaktiveringen åpner den veien som var stengt, og den skal åpnes av en ny
-- utstedelse etterpå — ikke av en rotasjon som ble utført mens aktøren var ute
-- av bruk.
select lives_ok(
  $$
    select provenance.issue_agent_identity_credential(
      'agent-identity:extraction-verification-01', 'human:peder-holman')
  $$,
  'etter reaktivering kan legitimasjonen utstedes på nytt'
);

-- Også utstederen må kunne utføre handlinger. Regelen ligger på tabellen
-- (provenance.assert_agent_identity_actors_active()), og funksjonen gir i
-- tillegg en setning som sier hva som er galt.
update provenance.actors
set retired_at = now(), retirement_note = 'Prøve i 420.'
where actor_key = 'human:peder-holman';

select throws_ok(
  $$
    select provenance.issue_agent_identity_credential(
      'agent-identity:extraction-verification-01', 'human:peder-holman')
  $$,
  '23001',
  'Aktøren ''human:peder-holman'' er trukket tilbake og kan ikke utstede legitimasjon.',
  'en tilbaketrukket utsteder kan ikke gi en maskin ny legitimasjon'
);

-- Rotasjonen er handlingen, ikke bytte av utsteder. Samme menneske har allerede
-- utstedt to ganger over; når det mennesket trekkes tilbake, skal en tredje
-- rotasjon i vedkommendes navn avvises selv om utsteder-ID-en står stille — det
-- er tilstandsendringen og ikke kolonnen som attribuerer handlingen. Dette er
-- den direkte, privilegerte veien utenom funksjonen, og den er nettopp det
-- tabellvernet finnes for.
select throws_ok(
  $$
    update provenance.agent_identities ai
    set secret_hash = 'sha256-v1:' || repeat('b', 64),
        secret_version = ai.secret_version + 1,
        secret_issued_at = now()
    where ai.identity_key = 'agent-identity:extraction-verification-01'
  $$,
  '23001', null,
  'en rotasjon med uendret utsteder avvises når den utstederen er trukket tilbake'
);

update provenance.actors
set retired_at = null, retirement_note = null
where actor_key = 'human:peder-holman';


-- ===========================================================================
-- Del 7 — Tilbakekalling er endelig
-- ===========================================================================
update provenance.agent_identities ai
set valid_to = now(),
    revoked_by_actor_id = (select id from provenance.actors where actor_key = 'human:peder-holman'),
    revoked_by_actor_type = 'human',
    revocation_reason = 'Prøve i 420: legitimasjonen antas kompromittert.'
where ai.identity_key = 'agent-identity:extraction-verification-01';

select throws_ok(
  $$
    select provenance.authenticate_agent_identity(
      'agent-identity:extraction-verification-01',
      (select secret from cred where label = 'second'),
      'extraction_verification'::provenance.agent_role)
  $$,
  '42501', 'Agentidentiteten kunne ikke autentiseres for denne operasjonen.',
  'en tilbakekalt identitet kan ikke autentisere seg, selv med gyldig legitimasjon'
);
select throws_ok(
  $$
    select provenance.issue_agent_identity_credential(
      'agent-identity:extraction-verification-01', 'human:peder-holman')
  $$,
  '23001', 'Agentidentiteten ''agent-identity:extraction-verification-01'' er trukket tilbake.',
  'en tilbakekalt identitet kan ikke få ny legitimasjon'
);
-- En tilbakekalling som en senere skriving kunne omgjøre, ville ikke vært en
-- tilbakekalling (DATABASE_ARCHITECTURE.md §46).
select throws_ok(
  $$
    update provenance.agent_identities
    set valid_to = null, revoked_by_actor_id = null,
        revoked_by_actor_type = null, revocation_reason = null
    where identity_key = 'agent-identity:extraction-verification-01'
  $$,
  '23001', null,
  'en tilbakekalt identitet kan ikke gjenåpnes'
);

-- ===========================================================================
-- Del 8 — Auditsporet
--
-- Hver endring i hva maskinen har lov til, står i loggen, attribuert til
-- mennesket som gjorde den. Hashen står ikke der.
-- ===========================================================================
select results_eq(
  $$
    select e.operation::text, a.actor_key,
           e.new_revision_or_snapshot ? 'secret_hash'
    from audit.events e
    join provenance.actors a on a.id = e.actor_id
    -- Bare identiteten denne testen arbeider med: migrasjon 005i registrerte
    -- en identitet til, og den har sin egen registreringsrad som ikke hører til
    -- det sporet som prøves her.
    where e.object_table = 'agent_identities'
      and e.object_id = (
        select id from provenance.agent_identities
        where identity_key = 'agent-identity:extraction-verification-01'
      )
    order by e.occurred_at, e.operation::text
  $$,
  $$values ('agent_identity_registered', 'human:peder-holman', false),
           ('agent_identity_credential_issued', 'human:peder-holman', false),
           ('agent_identity_credential_issued', 'human:peder-holman', false),
           ('agent_identity_credential_issued', 'human:peder-holman', false),
           ('agent_identity_revoked', 'human:peder-holman', false)$$,
  'registrering, alle tre utstedelsene og tilbakekallingen står i auditloggen, uten legitimasjonshashen'
);

select finish();

rollback;
