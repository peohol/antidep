-- ============================================================================
-- Migrasjon 006g — redaktørkontoen får `publisher`-rollen, altså retten til å
--                  utføre selve publiseringen
--
-- Utvider medlemskapsmodellen fra migrasjon 005 på samme måte som 005b og 005c,
-- står utenfor den planlagte rekken i MVP_IMPLEMENTATION_PLAN.md §18-§27 og får
-- derfor en bokstav i publiseringsrekken. Nummeret 009 er fortsatt reservert for
-- DrugProduct- og importfundamentet (§26).
--
-- ----------------------------------------------------------------------------
-- Hvorfor denne migrasjonen finnes
--
-- §74.36 kjørte hele kjeden mot de reelle radene i produksjon. Alle tretten
-- vilkårene i publiseringsgaten passerte, og det som stoppet publiseringen var
-- ikke en gate, men en rettighet:
--
--   42501: Brukeren har ikke gyldig publisher-rolle for dette innholdsområdet.
--
-- Kontoen har `editor` (005c) og `reviewer` (005b). Ingen migrasjon tildeler
-- `publisher`, og knowledge.publish_claim_revision(uuid, uuid, text) krever den
-- gjennom knowledge.assert_publisher_authorized(uuid, uuid). Uten denne
-- migrasjonen kan ingen påstand publiseres i noe miljø, uansett hvor komplett
-- det faglige grunnlaget er.
--
-- Det var aldri en feil i migrasjon 006. Kontrollen skal være der, og den skal
-- avvise; det som manglet var tildelingen på den andre siden. Denne migrasjonen
-- skriver den, og gjør ingenting annet.
--
-- ----------------------------------------------------------------------------
-- Hva `publisher` er, og hva den ikke er
--
-- Rollen er retten til å *utføre* publiseringen: å flytte publiseringspekeren og
-- registrere hendelsen, når alt annet allerede holder. Den er ikke retten til å
-- avgjøre om innholdet er godt nok — det er `reviewer`, og den beslutningen er
-- en egen rad i workflow.review_decisions som publiseringsgatens G11 og G12
-- krever hver for seg. MVP_IMPLEMENTATION_PLAN.md §16 lister de to som
-- forskjellige roller, og migrasjon 006 sier det i sin egen feilmelding:
-- «reviewer-rollen gir ikke publiseringsrett: å godkjenne og å publisere er to
-- forskjellige handlinger».
--
-- Det skillet blir ikke svakere av at samme person har begge rollene. To
-- rettigheter er fortsatt to rader, to handlinger er fortsatt to kall, og to
-- beslutninger er fortsatt to objekter i basen. Det som *er* svakt — at
-- forfatter, godkjenner og publisher er samme menneske — er registrert gjeld fra
-- før (CONTENT_GOVERNANCE.md §5, MVP_IMPLEMENTATION_PLAN.md §74.7), og
-- tildelingen her gjør den gjelden større, ikke mindre. Derfor står den
-- eksplisitt i `grant_reason`, der en revisor finner den, framfor i en kommentar
-- som forsvinner.
--
-- ----------------------------------------------------------------------------
-- Hva rollen ikke kan utrette alene
--
-- Ingenting. `publisher` åpner ikke én eneste gate: alle tretten vilkårene i
-- knowledge.assert_claim_revision_publishable(uuid) kjøres på nytt inne i
-- publiseringstransaksjonen, etter at rettigheten er kontrollert. En publisher
-- uten kontrollert ekstraksjon, uten kontrollert påstand, uten evidensvurdering
-- eller uten en gjeldende godkjenning fra en kvalifisert reviewer får nøyaktig
-- den samme avvisningen som før. Rollen flytter altså ikke terskelen for hva som
-- kan publiseres; den avgjør bare hvem som kan trykke på knappen når terskelen
-- allerede er passert.
--
-- ----------------------------------------------------------------------------
-- Formen er den samme som 005b og 005c, og det er med hensikt
--
-- Migrasjonen er miljøavhengig av samme grunn som de to andre: `user_id` er en
-- fremmednøkkel til `auth.users`, og kontoen finnes bare i det hostede
-- prosjektet. Logikken ligger derfor i én navngitt, idempotent funksjon som
-- testene kan kjøre nøyaktig — ikke som løse setninger i denne filen, som ville
-- vært en andre kopi som kan drive fra originalen. Funksjonen tar ingen
-- parametere: konto, aktørnøkkel og rolle er konstanter i kroppen, slik at den
-- bare kan gjøre denne ene tildelingen. En parameterisert utgave ville vært en
-- generell «gi hvem som helst publisher»-funksjon, altså en
-- rettighetseskalering med et vennlig navn.
--
-- En avsluttet tildeling gjeninnføres aldri: en tilbakekalling som en rutinemessig
-- migrasjonskjøring omgjør, er ingen tilbakekalling (DATABASE_ARCHITECTURE.md §46).
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §12, §13, §14
--   docs/CONTENT_GOVERNANCE.md §5, §8, §11, §12
--   docs/DATABASE_ARCHITECTURE.md §38, §46, §47
--   docs/MVP_IMPLEMENTATION_PLAN.md §15, §16, §49, §74.6, §74.7, §74.36
-- ============================================================================

create function workflow.ensure_publisher_role_grant()
  returns text
  language plpgsql
  -- SECURITY INVOKER (standard): funksjonen skal ikke kunne gi mer enn kalleren
  -- allerede har. Tomt search_path og schemakvalifiserte navn likevel, etter
  -- samme mønster som 005b og 005c (DATABASE_ARCHITECTURE.md §50).
  set search_path = ''
as $$
declare
  -- Samme konto og samme aktørnøkkel som migrasjon 005b og 005c. Konstanter i
  -- kroppen, ikke parametere: funksjonen kan bare gjøre denne ene tildelingen,
  -- aldri en vilkårlig. At raden finnes, er `auth.users`-oppslaget under som
  -- avgjør — ikke denne konstanten.
  c_account_id constant uuid := 'a703ede9-3f58-4de9-8c85-73936d58df1f';
  c_actor_key constant text := 'human:peder-holman';
  v_actor_id uuid;
  v_linked_account_id uuid;
  -- Ett oppslag, tre svar. Å stille de tre spørsmålene hver for seg ville gjort
  -- rekkefølgen mellom dem til et implisitt valg; her er presedensen skrevet ut.
  v_valid_now boolean;
  v_starts_later boolean;
  v_any_grant boolean;
begin
  select a.id, a.auth_user_id into v_actor_id, v_linked_account_id
  from provenance.actors a
  where a.actor_key = c_actor_key;

  -- Aktørraden kommer fra migrasjon 005a og skal alltid finnes. Mangler den, er
  -- migrasjonskjeden brutt, og det skal feile høyt framfor å bli en stille no-op
  -- som ser ut som «kontoen manglet».
  if v_actor_id is null then
    raise exception using
      errcode = 'no_data_found',
      message = format('Aktøren %L finnes ikke; migrasjon 005a har ikke kjørt.', c_actor_key),
      hint = 'Rolletildelingen forutsetter at den navngitte kvalifiserte redaktøren er registrert som aktør.';
  end if;

  if not exists (select 1 from auth.users u where u.id = c_account_id) then
    raise notice
      'Brukerkontoen % finnes ikke i auth.users. Publisher-rollen er ikke tildelt, og api.publish_claim_revision() er derfor fortsatt stengt i dette miljøet. Dette er forventet i en lokal stack og i CI; kall workflow.ensure_publisher_role_grant() på nytt i miljøet der kontoen finnes.',
      c_account_id;
    return 'account_missing';
  end if;

  -- Kontoen finnes, men aktøren peker ikke på den. Da ville tildelingen vært en
  -- rettighet uten den attribusjonen den hviler på:
  -- knowledge.assert_publisher_authorized(uuid, uuid) krever at den innloggede
  -- brukeren *er* den aktøren publiseringen attribueres til, og ville avvist
  -- kalleren uansett. Koblingen er 005b sin, og settes der — ikke her, hvor en
  -- andre kopi av den logikken ville kunnet drive fra originalen.
  if v_linked_account_id is distinct from c_account_id then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Aktøren %L er ikke knyttet til brukerkontoen %L, og kan ikke tildeles publisher-rollen for den.',
        c_actor_key, c_account_id
      ),
      hint = 'Koblingen settes av workflow.ensure_named_editor_authorization() (migrasjon 005b). Kall den først i dette miljøet. Peker aktøren på en annen konto, er den frosset av provenance.freeze_actor_identity(), og en annen person er en annen aktør med sin egen rad.';
  end if;

  select
    count(*) filter (
      where ur.valid_from <= statement_timestamp()
        and (ur.valid_to is null or ur.valid_to > statement_timestamp())
    ) > 0,
    count(*) filter (where ur.valid_from > statement_timestamp()) > 0,
    count(*) > 0
  into v_valid_now, v_starts_later, v_any_grant
  from workflow.user_roles ur
  where ur.user_id = c_account_id
    and ur.role_code = 'publisher'
    and ur.scope_id is null;

  -- Presedensen er skrevet ut framfor å falle ut av rekkefølgen på tre
  -- uavhengige if-er. En avsluttet tildeling ved siden av en løpende betyr at
  -- rettigheten gjelder; det motsatte svaret ville vært feil på den farligste
  -- måten en autorisasjonskontroll kan ta feil.
  if v_valid_now then
    return 'already_authorized';
  end if;

  if v_starts_later then
    raise notice
      'Kontoen % har en publisher-tildeling som først begynner å gjelde senere. Ingen ny tildeling er skrevet: en tildeling nå ville overlappet den, og databasen ville avvist den (user_roles_no_overlapping_grant_excl).',
      c_account_id;
    return 'role_not_yet_valid';
  end if;

  if v_any_grant then
    raise notice
      'Kontoen % har hatt en publisher-tildeling som er avsluttet. Ingen ny er skrevet: en tilbakekalling som en migrasjonskjøring omgjør, er ingen tilbakekalling (DATABASE_ARCHITECTURE.md §46). En gjeninnføring er en ny tildeling med sin egen begrunnelse, og den avgjørelsen hører til et menneske.',
      c_account_id;
    return 'role_ended';
  end if;

  insert into workflow.user_roles
    (user_id, role_code, scope_id, granted_by_actor_id, grant_reason)
  values (
    c_account_id,
    'publisher',
    -- NULL betyr «uten avgrensning», ikke «ukjent avgrensning». Antidep har ett
    -- innholdsområde og én redaktør; en avgrensning til ett klinisk begrep ville
    -- vært en presisjon vi ikke har dekning for.
    null,
    v_actor_id,
    'Selvtildeling, og den er en tredje rettighet med sin egen terskel. publisher gir rett til å utføre selve publiseringen — å flytte publiseringspekeren og registrere hendelsen — og ingenting mer. Den avgjør ikke om innholdet er godt nok: den vurderingen er reviewer-rollens, den er en egen rad i workflow.review_decisions, og publiseringsgatens G11 og G12 krever den uavhengig av hvem som publiserer (MVP_IMPLEMENTATION_PLAN.md §16). Rollen åpner heller ingen gate: alle vilkårene kjøres på nytt inne i publiseringstransaksjonen, etter at rettigheten er kontrollert. Tildelingen hviler på prosjekteierrollen; alternativet ville gjort en KI-aktør til opphavet til et menneskes publiseringsrett (ANTIDEP_CONSTITUTION.md §10, §12). At forfatter, godkjenner og publisher nå er samme menneske, er registrert gjeld (CONTENT_GOVERNANCE.md §5, MVP_IMPLEMENTATION_PLAN.md §74.7) og skal revurderes så snart Antidep har mer enn én kvalifisert person.'
  );

  return 'authorized';
end;
$$;

comment on function workflow.ensure_publisher_role_grant() is
  'Idempotent tildeling av `publisher`-rollen til den navngitte kvalifiserte redaktørens brukerkonto, altså retten til å utføre selve publiseringen (MVP_IMPLEMENTATION_PLAN.md §16). Åpner knowledge.publish_claim_revision(uuid, uuid, text) og api.publish_claim_revision(uuid, text), som krever en gyldig publisher-tildeling gjennom knowledge.assert_publisher_authorized(uuid, uuid). Gir ikke faglig godkjenningsrett: å godkjenne og å publisere er to forskjellige handlinger med hver sin rolle og hver sin rad, og publiseringsgatens G11 og G12 krever godkjenningen uavhengig av hvem som publiserer. Åpner ingen gate: alle vilkårene kjøres på nytt inne i publiseringstransaksjonen. Forutsetter at aktørraden er knyttet til kontoen av workflow.ensure_named_editor_authorization() (migrasjon 005b) og setter ikke koblingen selv. Returnerer account_missing (ingen rad i auth.users), authorized (tildelingen ble skrevet), already_authorized (en tildeling er gyldig nå), role_not_yet_valid (en tildeling begynner å gjelde senere) eller role_ended (en tildeling er avsluttet). Bare authorized skriver noe. Gyldighet måles med statement_timestamp() fordi predikatet avgjør noe (§74.6). En avsluttet tildeling gjeninnføres aldri (DATABASE_ARCHITECTURE.md §46). Konto, aktørnøkkel og rolle er konstanter i kroppen: funksjonen kan bare gjøre denne ene tildelingen, aldri en vilkårlig.';

revoke execute on function workflow.ensure_publisher_role_grant() from public;

-- Selve utførelsen. `select` framfor `do`, slik at statusen står i utdataene fra
-- `supabase db push` og `supabase db reset` ved siden av en eventuell notice.
select workflow.ensure_publisher_role_grant();
