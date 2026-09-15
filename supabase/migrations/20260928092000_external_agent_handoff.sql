-- ============================================================================
-- Migrasjon 010c — ekstern agent-handoff som en førstegangs støttet arbeidsform
--
-- Antidep har hele tiden hatt én arbeidsform for det semantiske arbeidet: en
-- aktør utenfor Antidep leser en bunden forespørsel og legger svaret sitt i en
-- fil, og Antidep kontrollerer filen og registrerer resultatet. Den formen har
-- vært beskrevet som en midlertidighet i påvente av en «live semantisk
-- modellruntime» med leverandørnøkler.
--
-- Eieren har besluttet noe annet: ingen betalt modell-API skal tas i bruk. Det
-- semantiske arbeidet skal gjøres av KI-agenter eieren allerede har tilgang til
-- — i praksis vanlig ChatGPT i et nettleservindu — og handoff-en er derfor ikke
-- en nødløsning. Den er produktet.
--
-- Denne migrasjonen gjør den til én felles, versjonert kontrakt som gjelder for
-- flere agentroller, og som kan betjenes fra Antidep-flaten av et menneske som
-- verken har repoet, en terminal eller en modellnøkkel.
--
-- ----------------------------------------------------------------------------
-- 1. Oppgaven er databasens, og avtrykket er oppgavens identitet
--
-- `api.agent_task_payload(...)` bygger hele oppgaven av rader som allerede
-- finnes, og beregner `request_digest` av nøyaktig de opplysningene som binder
-- svaret: rollen, oppgavenøkkelen, promptmalversjonen, outputschemaversjonen,
-- inndataens versjon — kildeversjonens fingeravtrykk, evidenssettets avtrykk,
-- revisjonens innholdshash — og de tidligere agentkjøringene rollen hviler på.
--
-- Avtrykket regnes ut på nytt ved import, av de samme radene. Endres grunnlaget
-- i mellomtiden, får oppgaven et annet avtrykk, og et svar avgitt på den gamle
-- kan ikke importeres. Det er riktig utfall, ikke et hinder: alternativet er et
-- svar lest ut av ett grunnlag, registrert mot et annet
-- (ANTIDEP_CONSTITUTION.md regel 2, 4).
--
-- Verken filnavn eller katalogplassering betyr noe. Det gjør de heller ikke i
-- den filbaserte kjøremappa; her finnes de ikke i det hele tatt.
--
-- ----------------------------------------------------------------------------
-- 2. Svaret er data, og det får aldri skrive selv
--
-- `api.import_agent_answer(...)` tar imot svarfilen ordrett. Den kontrollerer
-- bindingen, henter verdiene ut av svaret selv — kalleren kan ikke bytte dem ut
-- underveis — og skriver gjennom nøyaktig de samme interne skriveveiene som
-- agentkjørerne bruker, med de samme constraintene, de samme gatene og det
-- samme auditsporet. Et eksternt modellsvar har ingen databaselegitimasjon og
-- ingen egen skrivevei.
--
-- Den ordrette kontrollen av hvert kildeutdrag ligger der den alltid har ligget:
-- i Antideps egen deterministiske kode før registreringen, og deretter i den
-- uavhengige ekstraksjonskontrollen, som er en egen rolle med en egen identitet
-- og en egen kjøring. Den er ikke duplisert her — en andre implementasjon av
-- den samme normaliseringen ville kunnet svare noe annet på den samme kilden,
-- og to kontroller som er uenige er verre enn én.
--
-- ----------------------------------------------------------------------------
-- 3. Modellen tildeles på forhånd, og kan aldri gjøre to jobber
--
-- Hvilken ekstern KI-agent en rolle handler som, avgjøres av den redaktøren som
-- faktisk har tilgangen — før oppgaven hentes ut, med hvem og hvorfor. Svaret
-- bekrefter identiteten sin, men etablerer den ikke: en erklæring som fikk
-- registrere seg selv, ville etablert premisset som autoriserte den, og en
-- oppgitt identitet kunnet gå klar av regelen om at to ledd ikke deler modell.
--
-- Tildelingen står i oppgavens binding og dermed i request_digest. Byttes
-- modellen, får hver utestående oppgave et nytt avtrykk, og et svar avgitt under
-- den gamle tildelingen kan ikke komme tilbake og registrere den gamle modellen
-- på nytt.
--
-- Separasjonen er strukturell: exclusion-regelen på registeret gjør at ingen to
-- roller kan dele modellidentitet. Forsøker eieren å la den samme
-- ChatGPT-modellen både lage innholdet og vurdere det, blir tildelingen avvist
-- med en setning som sier hva som må gjøres — velge en annen tjeneste — framfor
-- at kjeden later som om kontrollen var uavhengig, og avvisningen kommer FØR
-- arbeidet gjøres framfor etter (ANTIDEP_CONSTITUTION.md regel 3, 4).
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md regel 1-7
--   docs/DATABASE_ARCHITECTURE.md §33, §43, §48, §50
--   docs/EVIDENCE_PIPELINE.md
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Kontrakten
--
-- Versjonene står her fordi databasen eier oppgaven og avtrykket. De samme
-- verdiene står i src/agents/agent-task.ts, som er den siden som *skriver*
-- oppgavefilen — den samme kontrakten sett fra hver sin side av databasegrensen,
-- som tekstuttrekksoppskriften og modelltildelingene allerede er, og pinnet av
-- en prøve på begge sider.
--
-- En rolle uten kontrakt kan ikke ta imot et eksternt agentsvar. Fraværet er
-- tilsiktet: de uavhengige kontrolleddene er Antideps egen deterministiske kode,
-- og en ekstern modell som fikk utføre dem, ville gjort kontrollen til nok en
-- modellvurdering.
-- ----------------------------------------------------------------------------
create function workflow.agent_handoff_task_version()
  returns text language sql immutable set search_path = ''
as $$ select 'antidep/agent-task@1'::text $$;

create function workflow.agent_handoff_answer_version()
  returns text language sql immutable set search_path = ''
as $$ select 'antidep/agent-answer@1'::text $$;

comment on function workflow.agent_handoff_task_version() is
  'Versjonen av oppgaveformen den eksterne agent-handoffen bruker. Én versjon for alle roller: kontrakten er felles, og det rollespesifikke ligger i promptmalen og outputschemaet.';
comment on function workflow.agent_handoff_answer_version() is
  'Versjonen av svarformen den eksterne agent-handoffen tar imot. Et svar med en annen versjon avvises framfor å bli lest med standardverdier.';

revoke execute on function workflow.agent_handoff_task_version() from public;
revoke execute on function workflow.agent_handoff_answer_version() from public;

create function workflow.agent_task_contract(p_agent_role provenance.agent_role)
  returns jsonb
  language sql
  immutable
  set search_path = ''
as $$
  select case p_agent_role
    when 'evidence_extraction' then jsonb_build_object(
      'prompt_template_version', 'evidence-extraction/handoff-drafting/1',
      'output_schema_version', 'antidep/extraction-draft@1'
    )
    when 'claim_synthesis' then jsonb_build_object(
      'prompt_template_version', 'claim-synthesis/handoff-drafting/1',
      'output_schema_version', 'antidep/claim-synthesis-draft@1'
    )
    when 'evidence_assessment' then jsonb_build_object(
      'prompt_template_version', 'evidence-assessment/handoff-drafting/1',
      'output_schema_version', 'antidep/evidence-assessment-draft@1'
    )
    else null
  end;
$$;

comment on function workflow.agent_task_contract(provenance.agent_role) is
  'Promptmalversjonen og outputschemaversjonen rollen er bundet til i den eksterne agent-handoffen, eller NULL for en rolle som ikke kan ta imot et eksternt agentsvar. Begge verdiene inngår i request_digest, slik at et svar avgitt under en eldre mal eller et eldre skjema ikke kan importeres på en oppgave bygget under en nyere. Verdiene er de samme som i src/agents/agent-task.ts, og pinnes av en prøve på begge sider av databasegrensen.';

revoke execute on function workflow.agent_task_contract(provenance.agent_role) from public;

-- ----------------------------------------------------------------------------
-- 2. Den semantiske modellidentiteten er en attestert avgjørelse
--
-- Hvilken KI-tjeneste som utfører et agentledd, avgjøres av redaktøren som
-- faktisk har tilgangen — før oppgaven hentes ut, og utenfor svaret. Et svar kan
-- bekrefte identiteten sin, men det kan ikke etablere premisset som autoriserer
-- det selv: en erklæring som fikk registrere seg selv, ville gjort separasjonen
-- mellom leddene til noe modellen påsto om seg selv, og en oppgitt identitet
-- ville kunnet gå klar av regelen om at to ledd ikke deler modell
-- (ANTIDEP_CONSTITUTION.md regel 3).
--
-- Tildelingen inngår i oppgavens binding og dermed i request_digest. Byttes
-- modellen, får hver utestående oppgave et nytt avtrykk, og et svar avgitt under
-- den gamle tildelingen kan ikke komme tilbake og registrere den gamle modellen
-- på nytt.
-- ----------------------------------------------------------------------------

-- Identiteten lest med de samme reglene overalt.
--
-- Tildelingen og importen leser den samme formen, og ville ellers kunnet bli
-- uenige om hva «samme modell» betyr — nettopp den uenigheten separasjonen ikke
-- tåler. Kanoniseringen av en versjon tjenesten ikke oppgir, er regelen som gjør
-- to ukjente versjoner av den samme modellen til én identitet.
create function provenance.canonical_model_identity(
  p_provider text,
  p_model text,
  p_model_version text,
  p_model_version_disclosure text
)
  returns jsonb
  language plpgsql
  immutable
  set search_path = ''
as $$
declare
  v_provider text := nullif(btrim(coalesce(p_provider, '')), '');
  v_model text := nullif(btrim(coalesce(p_model, '')), '');
  v_version text := nullif(btrim(coalesce(p_model_version, '')), '');
  v_disclosure text := coalesce(
    nullif(btrim(coalesce(p_model_version_disclosure, '')), ''), 'exact');
begin
  if v_provider is null or v_model is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Modellidentiteten mangler leverandør eller modellnavn.',
      hint = 'Skriv tjenesten og det modellnavnet tjenesten selv viser. Antidep finner ikke på et navn på vegne av en leverandør.';
  end if;
  if v_disclosure not in ('exact', 'not_exposed') then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('model_version_disclosure er %L, som ikke er exact eller not_exposed.', v_disclosure);
  end if;

  if v_disclosure = 'not_exposed' then
    -- En oppgitt versjon under not_exposed er en selvmotsigelse, og den skal
    -- ikke forsvinne stille: proveniensen ville da sagt «ikke eksponert» mens
    -- svaret faktisk oppga en versjon, og ingen ville fått vite at den ble
    -- forkastet (ANTIDEP_CONSTITUTION.md regel 4).
    if v_version is not null and v_version <> provenance.unexposed_model_version() then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format(
          'model_version_disclosure er not_exposed, men model_version er oppgitt som %L.', v_version),
        hint = 'Oppgir tjenesten faktisk en eksakt versjon, sett model_version_disclosure = exact. Gjør den ikke det, la model_version stå tom.';
    end if;
    -- Den kanoniske verdien, og ikke den frie teksten noen måtte ha skrevet. To
    -- ukjente versjoner av den samme modellen skal være den samme identiteten;
    -- ellers ville separasjonsregelen sluttet å virke.
    v_version := provenance.unexposed_model_version();
  elsif v_version is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'model_version_disclosure er exact, men ingen model_version er oppgitt.',
      hint = 'Oppgir tjenesten ingen versjon, skal model_version_disclosure være not_exposed. En oppdiktet versjon ville sett like troverdig ut som en sann (ANTIDEP_CONSTITUTION.md regel 4).';
  elsif v_version = provenance.unexposed_model_version() then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('model_version er %L, som er den kanoniske verdien for en versjon tjenesten ikke oppgir.', v_version),
      hint = 'Sett model_version_disclosure = not_exposed og la model_version stå tom.';
  end if;

  return jsonb_build_object(
    'provider', v_provider,
    'model', v_model,
    'model_version', v_version,
    'model_version_disclosure', v_disclosure
  );
end;
$$;

comment on function provenance.canonical_model_identity(text, text, text, text) is
  'Modellidentiteten lest og kanonisert med de samme reglene overalt: leverandør og modellnavn må finnes, eksponeringsgraden må være exact eller not_exposed, en exact-identitet må ha en versjon, og en versjon tjenesten ikke oppgir, får den kanoniske verdien provenance.unexposed_model_version() framfor en fri tekst. Kanoniseringen er selve separasjonsregelen: to ukjente versjoner av den samme modellen skal være den samme identiteten, ellers ville regelen om at to agentledd ikke deler modell, sluttet å virke (ANTIDEP_CONSTITUTION.md regel 3, 4). Tildelingen og importen leser den samme formen gjennom denne funksjonen og kan derfor ikke bli uenige om hva samme modell betyr.';

revoke execute on function provenance.canonical_model_identity(text, text, text, text) from public;

-- Kontrollen ved import: svaret må komme fra den tildelte modellen.
--
-- Registrerer ingenting. En rolle uten tildeling er ikke et tomrom svaret kan
-- fylle — det er en oppgave som ikke skulle vært hentet ut, og importen sier det
-- framfor å la svaret bestemme.
create function provenance.require_semantic_model_assignment(
  p_agent_role provenance.agent_role,
  p_identity jsonb
)
  returns provenance.role_model_assignments
  language plpgsql
  stable
  set search_path = ''
as $$
declare
  v_current provenance.role_model_assignments;
begin
  v_current := provenance.current_semantic_model(p_agent_role);

  if v_current.id is null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Ingen KI-tjeneste er tildelt agentleddet %L, og et svar kan ikke registreres.',
        p_agent_role
      ),
      hint = 'Hvilken modell et ledd handler som, er en avgjørelse den som har tilgangen tar på forhånd — ikke noe svaret bestemmer om seg selv. Velg tjenesten for leddet med api.assign_agent_role_model(...) og hent oppgaven på nytt (ANTIDEP_CONSTITUTION.md regel 3).';
  end if;

  if v_current.provider is distinct from (p_identity ->> 'provider')
     or v_current.model is distinct from (p_identity ->> 'model')
     or v_current.model_version is distinct from (p_identity ->> 'model_version') then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format(
        'Agentleddet %L er tildelt %s/%s (%s), men svaret kom fra %s/%s (%s).',
        p_agent_role, v_current.provider, v_current.model, v_current.model_version,
        p_identity ->> 'provider', p_identity ->> 'model', p_identity ->> 'model_version'
      ),
      hint = 'Oppgaven ble bygget for den tildelte modellen, og avtrykket dekker tildelingen. Utfør oppgaven med den modellen leddet er tildelt, eller bytt tildeling med api.release_agent_role_model(...) og api.assign_agent_role_model(...) og hent oppgaven på nytt — byttet er en synlig hendelse med hvem og hvorfor.';
  end if;

  return v_current;
end;
$$;

comment on function provenance.require_semantic_model_assignment(provenance.agent_role, jsonb) is
  'Krever at et eksternt agentsvar kommer fra den modellen agentleddet er tildelt, og registrerer ingenting (ANTIDEP_CONSTITUTION.md regel 3). Skiller seg fra en tildeling som registrerte seg selv ved første svar: der ville svaret etablert sitt eget premiss, og en oppgitt identitet kunnet gå klar av regelen om at to ledd ikke deler modell. En rolle uten tildeling avvises her, og meldingen sier hva som må gjøres.';

revoke execute on function provenance.require_semantic_model_assignment(provenance.agent_role, jsonb) from public;

-- Tildelingen, tatt av den som har tilgangen.
create function api.assign_agent_role_model(
  p_agent_role text,
  p_provider text,
  p_model text,
  p_model_version text default null,
  p_model_version_disclosure text default 'not_exposed',
  p_reason text default null,
  p_replaces_reason text default null
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_role provenance.agent_role;
  v_identity jsonb;
  v_current provenance.role_model_assignments;
  v_holder text;
  v_valid_from timestamptz;
  v_replaced boolean := false;
  v_assignment provenance.role_model_assignments;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  begin
    v_role := p_agent_role::provenance.agent_role;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke en kjent agentrolle.', p_agent_role);
  end;

  if workflow.agent_task_contract(v_role) is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format(
        'Rollen %L utføres av Antideps egen deterministiske kode, og har ingen ekstern KI-modell å tildele.',
        p_agent_role),
      hint = 'De uavhengige kontrolleddene er Antideps egen kode. En ekstern modell som fikk utføre dem, ville gjort kontrollen til nok en modellvurdering (ANTIDEP_CONSTITUTION.md regel 3).';
  end if;

  v_identity := provenance.canonical_model_identity(
    p_provider, p_model, p_model_version, p_model_version_disclosure);

  v_current := provenance.current_semantic_model(v_role);
  if v_current.id is not null then
    if v_current.provider = (v_identity ->> 'provider')
       and v_current.model = (v_identity ->> 'model')
       and v_current.model_version = (v_identity ->> 'model_version') then
      return jsonb_build_object(
        'agent_role', p_agent_role,
        'assigned', false,
        'already_assigned', true,
        'replaced', false,
        'model', v_identity
      );
    end if;
    -- Byttet er lovlig, men det er en endring av kjedens mest sikkerhetskritiske
    -- innstilling, og det krever derfor en begrunnelse. Uten den ville et bytte
    -- vært en endring uten ansvar — og avslutningen og den nye tildelingen skjer
    -- i den samme transaksjonen, slik at leddet aldri står uten en modell fordi
    -- den nye viste seg å tilhøre et annet ledd.
    if nullif(btrim(coalesce(p_replaces_reason, '')), '') is null then
      raise exception using
        errcode = 'restrict_violation',
        message = format(
          'Agentleddet %L er allerede tildelt %s/%s (%s).',
          p_agent_role, v_current.provider, v_current.model, v_current.model_version),
        hint = 'En tildeling skrives aldri om. Skal leddet bytte tjeneste, oppgi hvorfor: da avsluttes den gjeldende tildelingen med hvem og hvorfor, og den nye registreres i samme transaksjon. Utestående oppgaver får et nytt avtrykk, slik at et svar avgitt under den gamle tildelingen ikke kan registreres på den nye.';
    end if;

    update provenance.role_model_assignments
    set valid_to = statement_timestamp(),
        closed_by_actor_id = v_actor_id,
        close_reason = btrim(p_replaces_reason)
    where id = v_current.id;
    v_replaced := true;
  end if;

  -- Perioden begynner der den forrige sluttet, og aldri før.
  --
  -- Standardverdien for valid_from er now(), altså transaksjonens starttid. En
  -- avslutning og en ny tildeling i den samme transaksjonen ville derfor fått
  -- overlappende perioder, og exclusion-regelen ville avvist en tildeling som er
  -- helt legitim. Perioden regnes derfor av den siste avslutningen som finnes —
  -- både for dette leddet og for denne modellidentiteten.
  select greatest(
           statement_timestamp(),
           coalesce(max(a.valid_to), statement_timestamp()))
    into v_valid_from
  from provenance.role_model_assignments a
  where (a.agent_role = v_role and a.capacity = 'semantic')
     or (a.provider = (v_identity ->> 'provider')
         and a.model = (v_identity ->> 'model')
         and a.model_version = (v_identity ->> 'model_version'));

  begin
    insert into provenance.role_model_assignments (
      agent_role, capacity, provider, model, model_version, model_version_disclosure,
      valid_from, registered_by_actor_id, reason
    )
    values (
      v_role, 'semantic',
      v_identity ->> 'provider', v_identity ->> 'model', v_identity ->> 'model_version',
      (v_identity ->> 'model_version_disclosure')::provenance.model_version_disclosure,
      coalesce(v_valid_from, statement_timestamp()),
      v_actor_id,
      coalesce(
        nullif(btrim(coalesce(p_reason, '')), ''),
        'Valgt av en redaktør med mandat, som den KI-tjenesten dette agentleddet skal utføres av.')
    )
    returning * into v_assignment;
  exception
    when exclusion_violation then
      -- Hvilken av de to reglene som svarte, avgjør hva som må gjøres. En
      -- melding som gjettet, ville sendt eieren etter feil årsak.
      select string_agg(distinct a.agent_role::text, ', ' order by a.agent_role::text)
        into v_holder
      from provenance.role_model_assignments a
      where a.provider = (v_identity ->> 'provider')
        and a.model = (v_identity ->> 'model')
        and a.model_version = (v_identity ->> 'model_version')
        and a.agent_role <> v_role
        and (a.valid_to is null or a.valid_to > statement_timestamp());

      if v_holder is not null then
        raise exception using
          errcode = 'restrict_violation',
          message = format(
            'Modellen %s/%s (%s) er allerede tildelt agentleddet %s, og kan ikke også gjøre arbeidet i %s.',
            v_identity ->> 'provider', v_identity ->> 'model', v_identity ->> 'model_version',
            v_holder, p_agent_role),
          hint = 'Generator, kildestøttekontroll og evidensvurdering skal være reelt separate (ANTIDEP_CONSTITUTION.md regel 3). Velg en annen KI-tjeneste du allerede har tilgang til for dette leddet. Finnes ingen, skal kjeden stoppe her framfor å registrere en vurdering som ikke er uavhengig.';
      end if;

      raise exception using
        errcode = 'restrict_violation',
        message = format(
          'Agentleddet %L har en gjeldende modelltildeling i den perioden den nye ville dekket.',
          p_agent_role),
        hint = 'Avslutt den gjeldende tildelingen med api.release_agent_role_model(text, text) før en ny registreres. Én gyldig tildeling per ledd om gangen er regelen som gjør «hvilken modell handler dette leddet som» til et spørsmål med ett svar.';
  end;

  return jsonb_build_object(
    'agent_role', p_agent_role,
    'assigned', true,
    'already_assigned', false,
    'replaced', v_replaced,
    'model', v_identity
  );
end;
$$;

comment on function api.assign_agent_role_model(text, text, text, text, text, text, text) is
  'Velger hvilken ekstern KI-tjeneste et semantisk agentledd skal utføres av (ANTIDEP_CONSTITUTION.md regel 3). Tildelingen er en attestert avgjørelse tatt av en redaktør med mandat, FØR oppgaven hentes ut, og den inngår i oppgavens binding og dermed i request_digest. Registrerer aldri en modell på grunnlag av et agentsvar: en identitet som fikk registrere seg selv, ville etablert sitt eget premiss, og en oppgitt identitet kunnet gå klar av regelen om at to ledd ikke deler modell. Skriver aldri om en gjeldende tildeling: et bytte krever en begrunnelse, og avslutter da den gjeldende med hvem og hvorfor og registrerer den nye i den samme transaksjonen, slik at leddet aldri står uten modell fordi den nye viste seg å tilhøre et annet ledd. Et forsøk på å gi to ledd den samme modellen avvises av exclusion-regelen på registeret, med en setning som navngir leddet som allerede har den. Krever editor-mandat. SECURITY DEFINER fordi provenance har RLS med default deny; kalleren valideres på funksjonens eget kall.';

revoke execute on function api.assign_agent_role_model(text, text, text, text, text, text, text) from public;
grant execute on function api.assign_agent_role_model(text, text, text, text, text, text, text) to authenticated;

-- Avslutningen, slik at en feilregistrert modell ikke blir en blindvei.
--
-- Avslutter, og skriver aldri om: tildelingen som gjaldt, blir stående med sin
-- periode, og auditsporet får sin egen rad fra triggeren på tabellen. En ny
-- modell tildeles av api.assign_agent_role_model(...).
create function api.release_agent_role_model(p_agent_role text, p_reason text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_role provenance.agent_role;
  v_current provenance.role_model_assignments;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  begin
    v_role := p_agent_role::provenance.agent_role;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke en kjent agentrolle.', p_agent_role);
  end;

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En avslutning krever en begrunnelse.',
      hint = 'At en rolle slutter å handle som en modell, er øyeblikket separasjonen mellom to ledd kan endre seg. En endring uten grunn ville vært en endring uten ansvar.';
  end if;

  v_current := provenance.current_semantic_model(v_role);
  if v_current.id is null then
    return jsonb_build_object('agent_role', p_agent_role, 'released', false);
  end if;

  update provenance.role_model_assignments
  set valid_to = statement_timestamp(),
      closed_by_actor_id = v_actor_id,
      close_reason = btrim(p_reason)
  where id = v_current.id;

  return jsonb_build_object(
    'agent_role', p_agent_role,
    'released', true,
    'provider', v_current.provider,
    'model', v_current.model,
    'model_version', v_current.model_version
  );
end;
$$;

comment on function api.release_agent_role_model(text, text) is
  'Avslutter den gjeldende semantiske modelltildelingen for en agentrolle, slik at en ny kan tildeles med api.assign_agent_role_model(text, text, text, text, text, text, text) (ANTIDEP_CONSTITUTION.md regel 3, 7). Skal leddet bytte tjeneste framfor å slutte å ha en, gjør den funksjonen begge delene i én transaksjon. Finnes for at en feiltildelt modell ikke skal bli en blindvei som krever en migrasjon. Skriver aldri om: tildelingen som gjaldt, blir stående med sin periode, og triggeren på tabellen skriver auditraden over avslutningen med hvem og hvorfor. Utestående oppgaver får et nytt avtrykk av byttet, slik at et svar avgitt under den gamle tildelingen ikke kan registreres etterpå. Krever editor-mandat og en begrunnelse. SECURITY DEFINER fordi provenance har RLS med default deny; kalleren valideres på funksjonens eget kall.';

revoke execute on function api.release_agent_role_model(text, text) from public;
grant execute on function api.release_agent_role_model(text, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 3. Importsporet
--
-- Én rad per jobb som har tatt imot et svar. Unikheten på jobben er regelen mot
-- doble kliniske artefakter: en gjentatt import av det samme svaret svarer med
-- det som allerede ble registrert, og et *annet* svar på en jobb som allerede
-- er besvart, avvises. Uten den ville en dobbel innsending gitt to
-- evidensfunn, to revisjoner eller to vurderinger av det samme arbeidet.
-- ----------------------------------------------------------------------------
create table workflow.agent_handoff_imports (
  id uuid primary key default gen_random_uuid(),

  pipeline_job_id uuid not null unique
    references workflow.pipeline_jobs (id) on update restrict on delete restrict,
  agent_role provenance.agent_role not null,

  request_digest text not null,
  answer_digest text not null,

  agent_run_id uuid not null unique
    references provenance.agent_runs (id) on update restrict on delete restrict,
  imported_by_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,
  answered_at timestamptz,
  outcome jsonb not null,

  created_at timestamptz not null default now(),

  constraint agent_handoff_imports_request_digest_format_check
    check (request_digest ~ '^sha256:[0-9a-f]{64}$'),
  constraint agent_handoff_imports_answer_digest_format_check
    check (answer_digest ~ '^sha256:[0-9a-f]{64}$'),
  constraint agent_handoff_imports_outcome_shape_check
    check (jsonb_typeof(outcome) = 'object' and outcome <> '{}'::jsonb)
);

comment on table workflow.agent_handoff_imports is
  'Ett importert eksternt agentsvar per pipelinejobb (ANTIDEP_CONSTITUTION.md regel 4, 7). Unikheten på jobben er regelen mot doble kliniske artefakter: det samme svaret sendt inn igjen svarer med det som allerede ble registrert, og et annet svar på en jobb som allerede er besvart, avvises. answer_digest er fingeravtrykket av svarfilen ordrett, slik at «det samme svaret» er et faktum framfor en vurdering. Sporet er append-only.';
comment on column workflow.agent_handoff_imports.request_digest is
  'Avtrykket av oppgaven svaret ble avgitt på, slik databasen regnet det ut av sitt eget grunnlag ved importen. Endres grunnlaget senere, får oppgaven et annet avtrykk — og raden her sier hvilket som faktisk gjaldt.';
comment on column workflow.agent_handoff_imports.imported_by_actor_id is
  'Mennesket som importerte svaret. Selve arbeidet er gjort av en ekstern KI-agent, og den står på kjøringen (provenance.agent_runs.semantic_*); dette er hvem som førte det inn i Antidep.';

alter table workflow.agent_handoff_imports enable row level security;

create index agent_handoff_imports_role_idx
  on workflow.agent_handoff_imports (agent_role, created_at desc);

create trigger agent_handoff_imports_set_created_at
  before insert on workflow.agent_handoff_imports
  for each row execute function catalog.set_created_at();

create trigger agent_handoff_imports_are_append_only
  before update or delete on workflow.agent_handoff_imports
  for each row execute function knowledge.reject_append_only_mutation(
    'En import sier hvilket eksternt agentsvar som faktisk ble registrert mot hvilken oppgave. Et nytt svar er en ny jobb.'
  );

-- ----------------------------------------------------------------------------
-- 3b. Én implementasjon, to autentiseringsveier
--
-- Registreringen av en syntese og av en evidensvurdering har hittil ligget inne
-- i api-funksjonen, sammen med autentiseringen av agentlegitimasjonen. Den
-- eksterne handoffen har ingen agentlegitimasjon å autentisere: den autoriseres
-- av mandatet til mennesket som importerer, og kjøringen åpnes av databasen
-- selv.
--
-- Selve skrivingen er den samme, og skal være det. Kroppen flyttes derfor ut i
-- en intern funksjon som tar den åpne kjøringen og aktøren som parametre, og
-- api-funksjonen blir det den egentlig er: autentisering, og så det samme
-- arbeidet. En kopi ville vært et andre sted å endre en regel, og den ene som
-- ble glemt, ville sluppet gjennom noe den andre stoppet.
--
-- Funksjonene under er ordrett den samme koden som før, med autentiseringen
-- byttet ut med aktøren kalleren allerede har fastslått.
-- ----------------------------------------------------------------------------
create function knowledge.record_agent_claim_synthesis(
  p_agent_run_id uuid,
  p_actor_id uuid,
  p_topic_concept_id uuid,
  p_subject_drug_id uuid,
  p_statement text,
  p_scope text,
  p_comparator_kind text,
  p_uncertainty_summary text,
  p_evidence_links jsonb,
  p_claim_id uuid default null,
  p_population_id uuid default null,
  p_timeframe_min text default null,
  p_timeframe_max text default null,
  p_comparator_drug_id uuid default null,
  p_direction text default null,
  p_magnitude_measure text default null,
  p_magnitude_value numeric default null,
  p_magnitude_unit text default null,
  p_qualifiers text default null
)
  returns jsonb
  language plpgsql
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_claim_id uuid;
  v_claim_topic uuid;
  v_claim_drug uuid;
  v_claim_type knowledge.knowledge_type;
  v_claim_retired timestamptz;
  v_revision_number integer;
  v_supersedes uuid;
  v_revision_id uuid;
  v_evidence_item_ids uuid[];
  v_link_ids jsonb;
begin
  v_actor_id := p_actor_id;

  -- Formen på evidenslenkene, før noe skrives. En tom eller feilformet liste
  -- skal si hva som mangler, ikke feile på en fremmednøkkel lenger nede.
  if p_evidence_links is null
     or jsonb_typeof(p_evidence_links) <> 'array'
     or jsonb_array_length(p_evidence_links) = 0 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'p_evidence_links må være en ikke-tom JSON-liste med evidenslenker.',
      hint = 'Hver lenke er et objekt med evidence_item_id, relationship_type, directness og relevance_note. Både relasjonstypen og begrunnelsen er påkrevd: en kilde som bare omhandler samme tema, skal ikke kunne telle som støtte (ANTIDEP_CONSTITUTION.md §4).';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_evidence_links) as link(value)
    where jsonb_typeof(link.value) <> 'object'
       or nullif(btrim(coalesce(link.value ->> 'evidence_item_id', '')), '') is null
       or nullif(btrim(coalesce(link.value ->> 'relationship_type', '')), '') is null
       or nullif(btrim(coalesce(link.value ->> 'directness', '')), '') is null
       or nullif(btrim(coalesce(link.value ->> 'relevance_note', '')), '') is null
  ) then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Hver evidenslenke må ha evidence_item_id, relationship_type, directness og relevance_note.',
      hint = 'Begrunnelsen er alltid påkrevd: den sier hvorfor nettopp dette funnet har nettopp denne relasjonen til nettopp denne formuleringen (KNOWLEDGE_MODEL.md §12).';
  end if;

  select array_agg(distinct (link.value ->> 'evidence_item_id')::uuid)
    into v_evidence_item_ids
  from jsonb_array_elements(p_evidence_links) as link(value);

  if cardinality(v_evidence_item_ids) <> jsonb_array_length(p_evidence_links) then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Det samme evidensfunnet er oppført flere ganger i evidenslenkene.',
      hint = 'Ett funn kan ha nøyaktig én relasjon til én revisjon (claim_evidence_links_revision_item_key). To oppføringer ville fått ett funn til å se ut som flere uavhengige, og en senere vurdering til å hvile på en oppblåst evidensmengde.';
  end if;

  -- Kontrollnivået, før påstanden lages. Se migrasjon 005aj, avsnitt 1.
  perform workflow.assert_evidence_usable_for_synthesis(v_evidence_item_ids);

  -- Identiteten: enten en ny påstand, eller en ny revisjon av en som finnes.
  --
  -- Den gjenbrukes ikke automatisk på (tema, virkestoff): to atomiske påstander
  -- om samme virkestoff og samme endepunkt er normalt og riktig
  -- (EVIDENCE_PIPELINE.md §28), og et automatisk oppslag ville slått dem sammen
  -- til revisjoner av hverandre. Kalleren sier hva den mener.
  if p_claim_id is null then
    insert into knowledge.claims (
      knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id
    )
    values (
      'evidence_synthesis'::knowledge.knowledge_type,
      p_topic_concept_id,
      p_subject_drug_id,
      v_actor_id
    )
    returning id into v_claim_id;

    v_revision_number := 1;
    v_supersedes := null;
  else
    select c.id, c.topic_concept_id, c.subject_drug_id, c.knowledge_type, c.retired_at
      into v_claim_id, v_claim_topic, v_claim_drug, v_claim_type, v_claim_retired
    from knowledge.claims c
    where c.id = p_claim_id
    for update;

    if v_claim_id is null then
      raise exception using
        errcode = 'no_data_found',
        message = format('Påstanden %L finnes ikke.', p_claim_id),
        hint = 'La p_claim_id stå tom for å opprette en ny påstandsidentitet, eller oppgi id-en til en som finnes.';
    end if;

    if v_claim_retired is not null then
      raise exception using
        errcode = 'restrict_violation',
        message = format('Påstanden %L er trukket tilbake og kan ikke få nye revisjoner.', p_claim_id),
        hint = 'En tilbaketrukket påstand er tatt ut av bruk. Opprett en ny påstand dersom temaet fortsatt skal dekkes; historikken til den gamle bevares (DATABASE_ARCHITECTURE.md §36).';
    end if;

    -- Identiteten er uforanderlig (knowledge.freeze_claim_identity). En kaller
    -- som oppgir et annet tema eller virkestoff enn påstanden har, mener en
    -- annen påstand, og skal få vite det her framfor å få en revisjon som sier
    -- noe annet enn identiteten den henger på.
    if v_claim_topic is distinct from p_topic_concept_id
       or v_claim_drug is distinct from p_subject_drug_id
       or v_claim_type <> 'evidence_synthesis' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format(
          'Påstanden %L gjelder et annet tema, virkestoff eller kunnskapstype enn det som er oppgitt.',
          p_claim_id
        ),
        hint = 'Kunnskapstype, tema og virkestoff er påstandens identitet og kan ikke endres (ANTIDEP_CONSTITUTION.md §7). Et endret tema eller virkestoff er en ny påstand.';
    end if;

    select max(r.revision_number) + 1,
           (array_agg(r.id order by r.revision_number desc))[1]
      into v_revision_number, v_supersedes
    from knowledge.claim_revisions r
    where r.claim_id = v_claim_id;

    -- En påstand uten revisjoner er en tilstand skriveveien her aldri lager,
    -- men den kan finnes: identiteten og revisjonen er to rader.
    v_revision_number := coalesce(v_revision_number, 1);
  end if;

  insert into knowledge.claim_revisions (
    claim_id, revision_number, knowledge_type, subject_drug_id, supersedes_revision_id,
    statement, scope, population_id, timeframe_min, timeframe_max,
    comparator_kind, comparator_drug_id, direction,
    magnitude_measure, magnitude_value, magnitude_unit,
    qualifiers, uncertainty_summary,
    created_by_actor_id, agent_run_id
  )
  values (
    v_claim_id,
    v_revision_number,
    'evidence_synthesis'::knowledge.knowledge_type,
    p_subject_drug_id,
    v_supersedes,
    p_statement,
    p_scope,
    p_population_id,
    p_timeframe_min::interval,
    p_timeframe_max::interval,
    p_comparator_kind::knowledge.comparator_kind,
    p_comparator_drug_id,
    p_direction::knowledge.claim_direction,
    p_magnitude_measure::knowledge.effect_measure,
    p_magnitude_value,
    p_magnitude_unit::knowledge.estimate_unit,
    p_qualifiers,
    p_uncertainty_summary,
    v_actor_id,
    -- agent_run_role er en generert konstant på raden (migrasjon 004a) og
    -- oppgis ikke her: rollen skal ikke kunne settes av en kaller.
    p_agent_run_id
  )
  returning id into v_revision_id;

  with inserted as (
    insert into knowledge.claim_evidence_links (
      claim_revision_id, evidence_item_id, relationship_type, directness,
      relevance_note, created_by_actor_id
    )
    select
      v_revision_id,
      (link.value ->> 'evidence_item_id')::uuid,
      (link.value ->> 'relationship_type')::knowledge.claim_evidence_relationship,
      (link.value ->> 'directness')::knowledge.evidence_directness,
      btrim(link.value ->> 'relevance_note'),
      v_actor_id
    from jsonb_array_elements(p_evidence_links) as link(value)
    returning id, evidence_item_id
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object('claim_evidence_link_id', i.id, 'evidence_item_id', i.evidence_item_id)
      order by i.id::text
    ),
    '[]'::jsonb
  )
    into v_link_ids
  from inserted i;

  return jsonb_build_object(
    'claim_id', v_claim_id,
    'claim_revision_id', v_revision_id,
    'revision_number', v_revision_number,
    'supersedes_revision_id', v_supersedes,
    'evidence_links', v_link_ids,
    -- Avtrykket av det evidenssettet revisjonen hviler på. Kjøringen fører det i
    -- proveniensen sin; claim-verifikasjonen må gjelde nøyaktig det
    -- (publiseringsgatens G9b), og evidensvurderingen som kommer etter den, må
    -- oppgi det samme avtrykket som sett (api.register_evidence_assessment).
    'evidence_set_digest', knowledge.claim_evidence_set_digest(v_revision_id)
  );
end;
$$;

create or replace function api.register_claim_synthesis(
  p_identity_key text,
  p_secret text,
  p_agent_run_id uuid,
  p_topic_concept_id uuid,
  p_subject_drug_id uuid,
  p_statement text,
  p_scope text,
  p_comparator_kind text,
  p_uncertainty_summary text,
  p_evidence_links jsonb,
  p_claim_id uuid default null,
  p_population_id uuid default null,
  p_timeframe_min text default null,
  p_timeframe_max text default null,
  p_comparator_drug_id uuid default null,
  p_direction text default null,
  p_magnitude_measure text default null,
  p_magnitude_value numeric default null,
  p_magnitude_unit text default null,
  p_qualifiers text default null
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_identity_id uuid;
  v_actor_id uuid;
begin
  v_identity_id := provenance.authenticate_agent_identity(
    p_identity_key, p_secret, 'claim_synthesis'::provenance.agent_role
  );
  v_actor_id := provenance.assert_agent_run_open(p_agent_run_id, v_identity_id);

  return knowledge.record_agent_claim_synthesis(
    p_agent_run_id,
    v_actor_id,
    p_topic_concept_id,
    p_subject_drug_id,
    p_statement,
    p_scope,
    p_comparator_kind,
    p_uncertainty_summary,
    p_evidence_links,
    p_claim_id,
    p_population_id,
    p_timeframe_min,
    p_timeframe_max,
    p_comparator_drug_id,
    p_direction,
    p_magnitude_measure,
    p_magnitude_value,
    p_magnitude_unit,
    p_qualifiers
  );
end;
$$;

create function knowledge.record_evidence_assessment_row(
  p_agent_run_id uuid,
  p_actor_id uuid,
  p_claim_revision_id uuid,
  p_seen_evidence_set_digest text,
  p_framework text,
  p_certainty_level text,
  p_rationale text,
  p_risk_of_bias text default null,
  p_inconsistency text default null,
  p_indirectness text default null,
  p_imprecision text default null,
  p_publication_bias text default null,
  p_other_considerations text default null,
  p_evidence_gap text default null
)
  returns jsonb
  language plpgsql
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_claim_id uuid;
  v_knowledge_type knowledge.knowledge_type;
  v_retired_at timestamptz;
  v_evidence_item_ids uuid[];
  v_assessment_id uuid;
  v_assessed_at timestamptz;
begin
  v_actor_id := p_actor_id;

  select r.claim_id, r.knowledge_type, c.retired_at
    into v_claim_id, v_knowledge_type, v_retired_at
  from knowledge.claim_revisions r
  join knowledge.claims c on c.id = r.claim_id
  where r.id = p_claim_revision_id;

  if v_claim_id is null then
    raise exception using
      errcode = 'no_data_found',
      message = format('Påstandsrevisjon %L finnes ikke.', p_claim_revision_id),
      hint = 'Vurderingen gjelder en eksakt revisjon, ikke påstandsidentiteten (KNOWLEDGE_MODEL.md §19.3). Kontroller revisjons-ID-en.';
  end if;

  -- Samme avgrensning som synteseveien, og av samme grunn: en klinisk
  -- anbefaling skal ikke ha en KI-kjøring som opphav, og et deterministisk
  -- faktum skal ikke ha en GRADE-vurdering i det hele tatt
  -- (ANTIDEP_CONSTITUTION.md §12, §17, KNOWLEDGE_MODEL.md §13).
  if v_knowledge_type <> 'evidence_synthesis' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format(
        'Revisjon %L er av typen %s, og denne veien vurderer bare evidenssynteser.',
        p_claim_revision_id, v_knowledge_type
      ),
      hint = 'En klinisk anbefaling skal ikke ha en KI-kjøring som opphav, og et deterministisk faktum skal ikke ha en evidensvurdering. Trenger en annen kunnskapstype en vurdering, er det en egen skrivevei med sine egne vilkår.';
  end if;

  if v_retired_at is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Påstanden bak revisjon %L er trukket tilbake og skal ikke vurderes.',
        p_claim_revision_id
      ),
      hint = 'En tilbaketrukket påstand er tatt ut av bruk. Historikken bevares (DATABASE_ARCHITECTURE.md §36).';
  end if;

  -- Låsen på revisjonsraden tas her, og holdes ut transaksjonen. Den er både
  -- kontrollen av at kalleren vurderte det grunnlaget som faktisk ligger der, og
  -- serialiseringen mot en evidenslenke som commiter i vinduet mellom lesningen
  -- og innsettingen — den samme raden hver innsetting i
  -- knowledge.claim_evidence_links allerede låser (migrasjon 006f). Uten den
  -- ville vurderingen kunnet forsegle et sett den aldri så.
  perform workflow.assert_evidence_set_unchanged(p_claim_revision_id, p_seen_evidence_set_digest);

  select array_agg(distinct l.evidence_item_id)
    into v_evidence_item_ids
  from knowledge.claim_evidence_links l
  where l.claim_revision_id = p_claim_revision_id;

  if v_evidence_item_ids is null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Revisjon %L har ingen registrerte evidenslenker, og det finnes ikke noe grunnlag å vurdere.',
        p_claim_revision_id
      ),
      hint = 'Evidenslenkene registreres sammen med revisjonen av api.register_claim_synthesis(...). En vurdering uten et evidensgrunnlag ville vært en gradering av ingenting (ANTIDEP_CONSTITUTION.md §4).';
  end if;

  -- Kontrollnivået leses på nytt, på vurderingstidspunktet: et funn kan ha blitt
  -- trukket tilbake, eller fått et åpent avvik, etter at revisjonen ble laget.
  -- Samme funksjon som synteseveien bruker, slik at de to ikke kan bli uenige.
  perform workflow.assert_evidence_usable_for_synthesis(v_evidence_item_ids);

  -- Rekkefølgen: kildestøtteverifikasjonen kommer først. Se hodekommentaren.
  perform workflow.assert_claim_verified_before_assessment(p_claim_revision_id);

  -- Én vurdering per revisjon (evidence_assessments_claim_revision_key). En
  -- eksisterende vurdering skal ikke møtes av en naken unique-avvisning: den
  -- betyr at revisjonen allerede er gradert, og at en ny vurdering hører hjemme
  -- i en ny revisjon.
  if exists (
    select 1
    from knowledge.evidence_assessments a
    where a.claim_revision_id = p_claim_revision_id
  ) then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Revisjon %L har allerede en evidensvurdering.', p_claim_revision_id),
      hint = 'Vurderingen er append-only og forsegler evidenssettet til revisjonen. En endret vurdering av det samme grunnlaget er en ny revisjon, ikke en overskriving (ANTIDEP_CONSTITUTION.md §14).';
  end if;

  insert into knowledge.evidence_assessments (
    claim_revision_id, assessed_knowledge_type, framework, certainty_level,
    risk_of_bias, inconsistency, indirectness, imprecision, publication_bias,
    other_considerations, rationale, evidence_gap, assessed_at,
    created_by_actor_id, agent_run_id
  )
  values (
    p_claim_revision_id,
    v_knowledge_type,
    p_framework::knowledge.assessment_framework,
    p_certainty_level::knowledge.certainty_level,
    p_risk_of_bias::knowledge.grade_domain_rating,
    p_inconsistency::knowledge.grade_domain_rating,
    p_indirectness::knowledge.grade_domain_rating,
    p_imprecision::knowledge.grade_domain_rating,
    p_publication_bias::knowledge.grade_domain_rating,
    btrim(p_other_considerations),
    btrim(p_rationale),
    btrim(p_evidence_gap),
    -- Tidspunktet eies av databasen, som verified_at på kontrollene: en verdi
    -- kalleren kunne oppgitt, kunne datert en vurdering til noe annet enn da den
    -- faktisk ble gjort (DATABASE_ARCHITECTURE.md §7.3).
    now(),
    v_actor_id,
    -- agent_run_role er en generert konstant på raden (migrasjon 004b) og
    -- oppgis ikke her: rollen skal ikke kunne settes av en kaller.
    p_agent_run_id
  )
  returning id, assessed_at into v_assessment_id, v_assessed_at;

  return jsonb_build_object(
    'evidence_assessment_id', v_assessment_id,
    'claim_revision_id', p_claim_revision_id,
    'claim_id', v_claim_id,
    'certainty_level', p_certainty_level,
    'assessed_at', v_assessed_at,
    'evidence_set_digest', knowledge.claim_evidence_set_digest(p_claim_revision_id)
  );
end;
$$;

create or replace function api.register_evidence_assessment(
  p_identity_key text,
  p_secret text,
  p_agent_run_id uuid,
  p_claim_revision_id uuid,
  p_seen_evidence_set_digest text,
  p_framework text,
  p_certainty_level text,
  p_rationale text,
  p_risk_of_bias text default null,
  p_inconsistency text default null,
  p_indirectness text default null,
  p_imprecision text default null,
  p_publication_bias text default null,
  p_other_considerations text default null,
  p_evidence_gap text default null
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_identity_id uuid;
  v_actor_id uuid;
begin
  v_identity_id := provenance.authenticate_agent_identity(
    p_identity_key, p_secret, 'evidence_assessment'::provenance.agent_role
  );
  v_actor_id := provenance.assert_agent_run_open(p_agent_run_id, v_identity_id);

  return knowledge.record_evidence_assessment_row(
    p_agent_run_id,
    v_actor_id,
    p_claim_revision_id,
    p_seen_evidence_set_digest,
    p_framework,
    p_certainty_level,
    p_rationale,
    p_risk_of_bias,
    p_inconsistency,
    p_indirectness,
    p_imprecision,
    p_publication_bias,
    p_other_considerations,
    p_evidence_gap
  );
end;
$$;

comment on function knowledge.record_agent_claim_synthesis(uuid, uuid, uuid, uuid, text, text, text, text, jsonb, uuid, uuid, text, text, uuid, text, text, numeric, text, text) is
  'Registreringen av én påstandsrevisjon med sitt evidensgrunnlag, uten autentisering: kalleren har allerede fastslått hvem aktøren er og at kjøringen er åpen og tilhører den. Finnes fordi det er to autentiseringsveier inn i den samme skrivingen — agentkjøreren med legitimasjon (api.register_claim_synthesis) og den eksterne agent-handoffen med et menneskes mandat (api.import_agent_answer) — og de to skal håndheve nøyaktig de samme invariantene. Ingen regel er duplisert her; kroppen er den som alltid har ligget i api-funksjonen.';

comment on function knowledge.record_evidence_assessment_row(uuid, uuid, uuid, text, text, text, text, text, text, text, text, text, text, text) is
  'Registreringen av evidensvurderingen for én påstandsrevisjon, uten autentisering: kalleren har allerede fastslått hvem aktøren er og at kjøringen er åpen og tilhører den. Samme grunn som for synteseveien: to autentiseringsveier inn i den samme skrivingen, og én implementasjon å endre.';

revoke execute on function knowledge.record_agent_claim_synthesis(
  uuid, uuid, uuid, uuid, text, text, text, text, jsonb, uuid, uuid, text, text, uuid,
  text, text, numeric, text, text
) from public;

revoke execute on function knowledge.record_evidence_assessment_row(
  uuid, uuid, uuid, text, text, text, text, text, text, text, text, text, text, text
) from public;

-- ----------------------------------------------------------------------------
-- 3c. Hvilke pipelinejobber som er eksterne agentoppgaver
--
-- Utførelsesmåten er en strukturell egenskap ved raden, og ikke noe som utledes
-- av agentrollen eller av jobbnøkkelen. Uten den ville en helt vanlig
-- pipelinejobb i en semantisk rolle dukket opp på agentflaten — og en ekte
-- handoff-jobb kunnet blitt tatt av den automatiserte kjøreren. Rollen sier hva
-- arbeidet er; denne raden sier hvem som utfører det.
--
-- Raden skrives bare av api.enqueue_agent_task, og bare i det samme kallet som
-- oppretter jobben. Den er append-only av samme grunn som resten av sporet: en
-- utførelsesmåte som kunne flyttes i ettertid, ville ikke vært noen beskyttelse
-- i det hele tatt.
-- ----------------------------------------------------------------------------
create table workflow.agent_handoff_jobs (
  id uuid primary key default gen_random_uuid(),

  -- Én rad per jobb. Unikheten ligger i en egen constraint framfor i
  -- primærnøkkelen, slik at tabellen følger den samme radidentiteten som resten
  -- av skjemaet (030_conventions_test.sql).
  pipeline_job_id uuid not null
    references workflow.pipeline_jobs (id) on update restrict on delete restrict
    constraint agent_handoff_jobs_pipeline_job_key unique,
  registered_by_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,
  created_at timestamptz not null default now()
);

comment on table workflow.agent_handoff_jobs is
  'Én rad per pipelinejobb som er en ekstern agentoppgave, altså som utføres av et menneske med en KI-tjeneste framfor av en automatisert kjører (ANTIDEP_CONSTITUTION.md regel 3, 4, 7). Utførelsesmåten er en strukturell egenskap ved jobben og ikke noe som utledes av agentrollen eller av jobbnøkkelen: uten raden ville en vanlig pipelinejobb i en semantisk rolle dukket opp på agentflaten, og en ekte handoff-jobb kunnet blitt tatt av api.claim_pipeline_job(text, text, text, integer). Skrives bare av api.enqueue_agent_task(text, jsonb), i det samme kallet som oppretter jobben, og er append-only: en utførelsesmåte som kunne flyttes i ettertid, ville ikke vært noen beskyttelse.';
comment on column workflow.agent_handoff_jobs.registered_by_actor_id is
  'Redaktøren som la oppgaven inn som en ekstern agentoppgave. At arbeidet skal ut av Antidep er en avgjørelse, og en avgjørelse har en avsender.';

alter table workflow.agent_handoff_jobs enable row level security;

create trigger agent_handoff_jobs_set_created_at
  before insert on workflow.agent_handoff_jobs
  for each row execute function catalog.set_created_at();

create trigger agent_handoff_jobs_are_append_only
  before update or delete on workflow.agent_handoff_jobs
  for each row execute function knowledge.reject_append_only_mutation(
    'Utførelsesmåten til en pipelinejobb avgjøres når jobben legges inn. En måte som kunne flyttes i ettertid, ville ikke vært noen beskyttelse mot at det samme arbeidet ble gjort to ganger.'
  );

-- ----------------------------------------------------------------------------
-- 3d. Den gamle kjøreren tar ikke en ekstern agentoppgave
--
-- `api.claim_pipeline_job` valgte enhver ledig jobb i rollen legitimasjonen var
-- autentisert for. Etter at handoff-jobbene finnes som en egen form, ville den
-- dermed kunnet ta ut en jobb et menneske allerede hadde lastet ned og gitt til
-- en KI-tjeneste. Utvalget utelater dem nå eksplisitt.
--
-- Funksjonen gjenskapes her framfor å endres i migrasjon 009b: den er anvendt,
-- og en historisk migrasjon skrives ikke om.
-- ----------------------------------------------------------------------------
create or replace function api.claim_pipeline_job(
  p_identity_key text,
  p_secret text,
  p_agent_role text,
  p_lease_seconds integer default 900
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_role provenance.agent_role;
  v_identity_id uuid;
  v_job workflow.pipeline_jobs;
  v_from workflow.pipeline_job_state;
begin
  begin
    v_role := p_agent_role::provenance.agent_role;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke en kjent agentrolle.', p_agent_role),
        hint = 'Gyldige roller er de eksplisitte agentrollene i EVIDENCE_PIPELINE.md.';
  end;

  v_identity_id := provenance.authenticate_agent_identity(p_identity_key, p_secret, v_role);

  if p_lease_seconds is null or p_lease_seconds < 30 or p_lease_seconds > 86400 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Leietiden %s sekunder er utenfor 30–86400.', coalesce(p_lease_seconds::text, 'NULL')),
      hint = 'En leie som er for kort, utløper mens arbeidet pågår og lar to kjørere ta det samme oppdraget. En som er for lang, holder et oppdrag utilgjengelig lenge etter at kjøreren er borte.';
  end if;

  -- `skip locked` framfor å vente: to kjørere som spør samtidig, skal få hver
  -- sin jobb, ikke stå i kø bak hverandre. En utløpt leie regnes som ledig —
  -- det er nettopp den tilstanden som skal overleve at en prosess døde.
  select j.* into v_job
  from workflow.pipeline_jobs j
  where j.agent_role = v_role
    and (
      j.state = 'ready'
      or (j.state = 'leased' and j.lease_expires_at <= now())
    )
    and j.attempts < j.max_attempts
    -- En ekstern agentoppgave er ikke denne kjørerens arbeid. Uten dette kunne
    -- en automatisert kjører tatt ut en jobb et menneske allerede hadde lastet
    -- ned, og det samme arbeidet blitt gjort to ganger — i to modellidentiteter,
    -- med to utfall, og med ett av dem uten proveniens for hvem som ba om det
    -- (ANTIDEP_CONSTITUTION.md regel 4, 7).
    and not exists (
      select 1 from workflow.agent_handoff_jobs h where h.pipeline_job_id = j.id
    )
  order by j.enqueued_at, j.id
  for update skip locked
  limit 1;

  if not found then
    return jsonb_build_object('claimed', false);
  end if;

  v_from := v_job.state;

  update workflow.pipeline_jobs j
  set state = 'leased',
      attempts = j.attempts + 1,
      leased_by_agent_identity_id = v_identity_id,
      -- Ny nøkkel for hvert uttak. Den forrige slutter å gjelde i det samme
      -- øyeblikket, så et utfall fra en utløpt leie treffer ingenting.
      lease_token = gen_random_uuid(),
      lease_expires_at = now() + make_interval(secs => p_lease_seconds)
  where j.id = v_job.id
  returning * into v_job;

  perform workflow.record_pipeline_job_event(
    v_job.id, v_from, 'leased'::workflow.pipeline_job_state, v_job.attempts,
    null, v_identity_id,
    case when v_from = 'leased' then 'Forrige leie var utløpt.' else null end
  );

  return jsonb_build_object(
    'claimed', true,
    'pipeline_job_id', v_job.id,
    'job_key', v_job.job_key,
    'agent_role', v_job.agent_role::text,
    'input_manifest', v_job.input_manifest,
    'attempt', v_job.attempts,
    'max_attempts', v_job.max_attempts,
    'lease_token', v_job.lease_token,
    'lease_expires_at', v_job.lease_expires_at,
    'last_failure_reason', v_job.failure_reason
  );
end;
$$;

comment on function api.claim_pipeline_job(text, text, text, integer) is
  'Tar ut én jobb for rollen legitimasjonen er autentisert for, og gir den en leie med utløpstid (DATABASE_ARCHITECTURE.md §33, §43). Bruker FOR UPDATE SKIP LOCKED, slik at to kjørere som spør samtidig får hver sin jobb framfor å stå i kø. En jobb med utløpt leie regnes som ledig: en kjører som forsvant, skal ikke blokkere køen for alltid. attempts økes ved uttaket og ikke ved feilen, slik at en kjører som dør uten å melde fra, også telles — ellers ville nettopp den feilformen kunnet prøves i det uendelige. Fra migrasjon 010c utelates de eksterne agentoppgavene (workflow.agent_handoff_jobs) eksplisitt: de utføres av et menneske med en KI-tjeneste, og en automatisert kjører som tok en av dem, ville gjort det samme arbeidet en gang til under en annen modellidentitet. Svarer {claimed: false} når køen er tom; det er ikke en feil. EXECUTE går til anon fordi en agent ikke har brukerkonto — legitimasjonen og ikke Data API-rollen er kontrollen.';

-- ----------------------------------------------------------------------------
-- 4. Oppgaven, bygget av rader som allerede finnes
--
-- Tre små lesere først. De finnes for at en feilskrevet id i et inndatamanifest
-- skal bli en setning om hva som mangler, og ikke en cast-feil fra dypet av en
-- spørring.
-- ----------------------------------------------------------------------------
create function workflow.manifest_uuid(p_manifest jsonb, p_key text)
  returns uuid
  language sql
  immutable
  set search_path = ''
as $$
  select case
    when p_manifest ->> p_key ~
      '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    then (p_manifest ->> p_key)::uuid
  end;
$$;

create function workflow.manifest_uuids(p_manifest jsonb, p_key text)
  returns uuid[]
  language sql
  immutable
  set search_path = ''
as $$
  select case when jsonb_typeof(p_manifest -> p_key) <> 'array' then null
    else (
      select coalesce(array_agg(t.value::uuid order by t.value), array[]::uuid[])
      from jsonb_array_elements_text(p_manifest -> p_key) as t(value)
      where t.value ~
        '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    )
  end;
$$;

comment on function workflow.manifest_uuid(jsonb, text) is
  'Én id ut av et inndatamanifest, eller NULL når feltet mangler eller ikke er en uuid. Et cast rett på verdien ville gitt en SQLSTATE fra dypet av en spørring der kalleren trenger en setning om hva som mangler.';
comment on function workflow.manifest_uuids(jsonb, text) is
  'Id-listen ut av et inndatamanifest, sortert og uten verdier som ikke er uuid-er, eller NULL når feltet ikke er en liste. Kalleren sammenligner antallet med listens lengde: er de ulike, bar listen noe som ikke er en id.';

revoke execute on function workflow.manifest_uuid(jsonb, text) from public;
revoke execute on function workflow.manifest_uuids(jsonb, text) from public;

create function workflow.agent_task_digest(p_binding jsonb)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  select 'sha256:' || encode(sha256(convert_to(p_binding::text, 'UTF8')), 'hex');
$$;

comment on function workflow.agent_task_digest(jsonb) is
  'Avtrykket av oppgavens binding. jsonb sorterer nøklene og gjengir dem entydig, og bindingen inneholder bare tekst- og uuid-verdier, så den samme bindingen gir den samme strengen. Avtrykket regnes ut på nytt ved import av de samme radene: er grunnlaget endret, er avtrykket et annet, og et svar avgitt på den gamle oppgaven kan ikke importeres (ANTIDEP_CONSTITUTION.md regel 2, 4).';

revoke execute on function workflow.agent_task_digest(jsonb) from public;

-- Skriveveienes egne vilkår, lest som en setning framfor som et kast.
--
-- De to funksjonene under kaller nøyaktig de assertene registreringen kaller.
-- Alternativet — å skrive om vilkårene i en mildere forhåndskontroll — ville
-- gitt to regelsett som kunne bli uenige, og uenigheten ville kostet den som
-- utførte oppgaven en hel økt i en KI-tjeneste (ANTIDEP_CONSTITUTION.md regel 4).
create function workflow.evidence_usable_problem(p_evidence_item_ids uuid[], p_lead text)
  returns text
  language plpgsql
  stable
  set search_path = ''
as $$
begin
  perform workflow.assert_evidence_usable_for_synthesis(p_evidence_item_ids);
  return null;
exception
  -- Bare de feilklassene kontrollen faktisk reiser. Et `when others` ville
  -- gjort en programmeringsfeil eller en databasefeil til setningen «grunnlaget
  -- er ikke klart», og konstitusjonen skiller uttrykkelig en teknisk feil fra en
  -- manglende kontroll: en teknisk feil skal boble opp og bli synlig som det den
  -- er (ANTIDEP_CONSTITUTION.md regel 4).
  when restrict_violation or no_data_found or invalid_parameter_value then
    return format('%s: %s', p_lead, sqlerrm);
end;
$$;

comment on function workflow.evidence_usable_problem(uuid[], text) is
  'Kontrollnivået evidensen må ha nådd, lest som én setning framfor som et kast. Kaller workflow.assert_evidence_usable_for_synthesis(uuid[]) — den samme funksjonen skriveveiene kaller — slik at forhåndskontrollen i agentkøen ikke kan bli mildere enn den virkelige. Fanger bare de feilklassene kontrollen faktisk reiser: en teknisk feil skal boble opp framfor å bli presentert som «grunnlaget er ikke klart» (ANTIDEP_CONSTITUTION.md regel 4).';

revoke execute on function workflow.evidence_usable_problem(uuid[], text) from public;

create function workflow.claim_verified_problem(p_claim_revision_id uuid, p_lead text)
  returns text
  language plpgsql
  stable
  set search_path = ''
as $$
begin
  perform workflow.assert_claim_verified_before_assessment(p_claim_revision_id);
  return null;
exception
  -- Samme avgrensning som over, og av samme grunn.
  when restrict_violation or no_data_found or invalid_parameter_value then
    return format('%s: %s', p_lead, sqlerrm);
end;
$$;

comment on function workflow.claim_verified_problem(uuid, text) is
  'Kildestøttekontrollen en påstandsrevisjon må ha vært gjennom, lest som én setning framfor som et kast. Kaller workflow.assert_claim_verified_before_assessment(uuid) — den samme funksjonen skriveveien kaller — slik at forhåndskontrollen i agentkøen ikke kan bli mildere enn den virkelige. Fanger bare de feilklassene kontrollen faktisk reiser: en teknisk feil skal boble opp framfor å bli presentert som «kontrollen holder ikke» (ANTIDEP_CONSTITUTION.md regel 4).';

revoke execute on function workflow.claim_verified_problem(uuid, text) from public;


-- Hva som eventuelt hindrer at oppgaven kan bygges, sett fra grunnlaget.
--
-- Vilkårene er de samme fail-closed vilkårene skriveveiene leser når svaret
-- kommer tilbake, lest med de samme funksjonene framfor med en svakere kopi. En
-- forhåndskontroll som var mildere enn den virkelige, ville latt noen bruke en
-- hel økt i en KI-tjeneste på et svar importen uansett måtte avvise
-- (ANTIDEP_CONSTITUTION.md regel 4).
create function workflow.agent_task_input_problem(p_job workflow.pipeline_jobs)
  returns text
  language plpgsql
  stable
  set search_path = ''
as $$
declare
  v_manifest jsonb := p_job.input_manifest;
  v_source_version_id uuid;
  v_revision_id uuid;
  v_ids uuid[];
  v_count integer;
  v_knowledge_type knowledge.knowledge_type;
  v_retired_at timestamptz;
begin
  if p_job.agent_role = 'evidence_extraction' then
    v_source_version_id := workflow.manifest_uuid(v_manifest, 'source_version_id');
    if v_source_version_id is null then
      return 'Oppgaven sier ikke hvilken kildeversjon den gjelder.';
    end if;
    if not exists (select 1 from knowledge.source_versions sv where sv.id = v_source_version_id) then
      return 'Kildeversjonen oppgaven gjelder, finnes ikke.';
    end if;
    if knowledge.source_version_text(v_source_version_id) is null then
      return 'Kildeteksten er ikke lagret for denne kildeversjonen, så oppgaven kan ikke inneholde artikkelen. Last opp fullteksten på nytt gjennom fulltekstbiblioteket.';
    end if;

    v_ids := workflow.manifest_uuids(v_manifest, 'drug_ids');
    if v_ids is null or cardinality(v_ids) = 0 then
      return 'Oppgaven sier ikke hvilke virkestoff funnet kan gjelde.';
    end if;
    select count(*) into v_count from catalog.drugs d where d.id = any (v_ids);
    if v_count <> cardinality(v_ids) then
      return 'Ett av virkestoffene i oppgaven finnes ikke i katalogen.';
    end if;

    v_ids := workflow.manifest_uuids(v_manifest, 'outcome_concept_ids');
    if v_ids is null or cardinality(v_ids) = 0 then
      return 'Oppgaven sier ikke hvilke endepunkt funnet kan gjelde.';
    end if;
    select count(*) into v_count
    from catalog.clinical_concepts c
    where c.id = any (v_ids) and c.concept_type = 'outcome';
    if v_count <> cardinality(v_ids) then
      return 'Ett av endepunktene i oppgaven finnes ikke i katalogen.';
    end if;

    v_ids := coalesce(workflow.manifest_uuids(v_manifest, 'population_ids'), array[]::uuid[]);
    select count(*) into v_count from catalog.populations p where p.id = any (v_ids);
    if v_count <> cardinality(v_ids) then
      return 'En av populasjonene i oppgaven finnes ikke i katalogen.';
    end if;
    return null;
  end if;

  if p_job.agent_role = 'claim_synthesis' then
    if workflow.manifest_uuid(v_manifest, 'topic_concept_id') is null
       or workflow.manifest_uuid(v_manifest, 'subject_drug_id') is null then
      return 'Oppgaven sier ikke hvilket tema og virkestoff påstanden skal gjelde.';
    end if;
    -- Katalogverdiene må finnes, og ikke bare ha formen. Uten dette ville
    -- oppgaven blitt bygget av et tomt oppslag, og feilen kommet først når et
    -- ferdig svar ikke lot seg registrere.
    if not exists (
      select 1 from catalog.clinical_concepts c
      where c.id = workflow.manifest_uuid(v_manifest, 'topic_concept_id')
        and c.concept_type = 'outcome'
    ) then
      return 'Temaet oppgaven gjelder, finnes ikke som et endepunkt i katalogen.';
    end if;
    if not exists (
      select 1 from catalog.drugs d
      where d.id = workflow.manifest_uuid(v_manifest, 'subject_drug_id')
    ) then
      return 'Virkestoffet oppgaven gjelder, finnes ikke i katalogen.';
    end if;
    v_ids := workflow.manifest_uuids(v_manifest, 'evidence_item_ids');
    if v_ids is null or cardinality(v_ids) = 0 then
      return 'Oppgaven sier ikke hvilke evidensfunn syntesen skal bygge på.';
    end if;

    -- Kontrollnivået evidensen må ha nådd, lest med skriveveiens egen funksjon.
    -- Et funn uten bekreftet ekstraksjonskontroll — eller med et senere åpent
    -- avvik — kan ikke bære en påstand, og det er like sant før oppgaven hentes
    -- ut som etter at svaret er skrevet.
    return workflow.evidence_usable_problem(
      v_ids, 'Evidensgrunnlaget er ikke klart for en syntese ennå');
  end if;

  if p_job.agent_role = 'evidence_assessment' then
    v_revision_id := workflow.manifest_uuid(v_manifest, 'claim_revision_id');
    if v_revision_id is null then
      return 'Oppgaven sier ikke hvilken påstandsrevisjon den gjelder.';
    end if;

    select r.knowledge_type, c.retired_at into v_knowledge_type, v_retired_at
    from knowledge.claim_revisions r
    join knowledge.claims c on c.id = r.claim_id
    where r.id = v_revision_id;

    if not found then
      return 'Påstandsrevisjonen oppgaven gjelder, finnes ikke.';
    end if;
    if v_knowledge_type <> 'evidence_synthesis' then
      return 'Påstanden er ikke en evidenssyntese, og skal ikke graderes. En klinisk anbefaling og et deterministisk faktum har ingen evidensvurdering.';
    end if;
    if v_retired_at is not null then
      return 'Påstanden er trukket tilbake, og skal ikke vurderes.';
    end if;
    if exists (
      select 1 from knowledge.evidence_assessments a
      where a.claim_revision_id = v_revision_id
    ) then
      return 'Påstanden er allerede vurdert. En endret vurdering av det samme grunnlaget er en ny påstandsformulering, ikke en overskriving.';
    end if;
    if not exists (
      select 1 from workflow.claim_verifications v
      where v.claim_revision_id = v_revision_id
    ) then
      return 'Påstanden er ikke kildestøttekontrollert ennå. Evidensvurderingen kommer etter den kontrollen.';
    end if;

    select array_agg(distinct l.evidence_item_id) into v_ids
    from knowledge.claim_evidence_links l
    where l.claim_revision_id = v_revision_id;

    if v_ids is null then
      return 'Påstanden har ingen evidenslenker, og det finnes ikke noe grunnlag å vurdere.';
    end if;

    -- De samme to vilkårene skriveveien leser på vurderingstidspunktet, i den
    -- samme rekkefølgen: grunnlaget må fortsatt kunne bære påstanden, og
    -- kildestøttekontrollen må være gjeldende, bekreftet og gjort av noen med
    -- mandat — på nøyaktig det evidenssettet som ligger der nå.
    return coalesce(
      workflow.evidence_usable_problem(
        v_ids, 'Evidensgrunnlaget bak påstanden er ikke lenger brukbart'),
      workflow.claim_verified_problem(
        v_revision_id, 'Kildestøttekontrollen av påstanden holder ikke'));
  end if;

  return format('Rollen %s har ingen oppgaveform ennå.', p_job.agent_role);
end;
$$;

comment on function workflow.agent_task_input_problem(workflow.pipeline_jobs) is
  'Én setning om hva i grunnlaget som hindrer at oppgaven kan bygges, eller NULL. Vilkårene er de samme fail-closed vilkårene skriveveiene leser når svaret kommer tilbake, lest med de samme funksjonene framfor med en svakere kopi: en forhåndskontroll som var mildere enn den virkelige, ville latt noen bruke en hel økt i en KI-tjeneste på et svar importen uansett måtte avvise (ANTIDEP_CONSTITUTION.md regel 4). Sier ingenting om jobbens tilstand eller om modelltildelingen — det er workflow.agent_task_problem(workflow.pipeline_jobs) som legger dem til, og api.enqueue_agent_task(text, jsonb) som bare spør om grunnlaget.';

revoke execute on function workflow.agent_task_input_problem(workflow.pipeline_jobs) from public;


-- Hva som eventuelt hindrer at oppgaven kan besvares nå.
--
-- Returnerer én setning på norsk, eller NULL. Den står i køen ved siden av
-- oppgaven, fordi «venter på deg» og «kan ikke kjøres ennå» er to forskjellige
-- tilstander, og en flate som viste dem likt, ville bedt noen gjøre noe som
-- ikke går (ANTIDEP_CONSTITUTION.md regel 4).
--
-- Køen, uttaket og importen leser denne ene funksjonen. Uten den ene regelen
-- kunne flaten vist nedlasting og opplasting for en jobb importen uansett måtte
-- avvise — og det er nettopp den differansen som koster noen en hel økt.
create function workflow.agent_task_problem(p_job workflow.pipeline_jobs)
  returns text
  language plpgsql
  stable
  set search_path = ''
as $$
declare
  v_model provenance.role_model_assignments;
begin
  -- Utførelsesmåten først, og som en egenskap ved raden. Rollen sier hva
  -- arbeidet er, men ikke hvem som gjør det: en helt vanlig pipelinejobb i en
  -- semantisk rolle er den automatiserte kjørerens, og skal ikke vises på
  -- agentflaten som noe et menneske venter på å utføre.
  if not exists (
    select 1 from workflow.agent_handoff_jobs h where h.pipeline_job_id = p_job.id
  ) then
    return 'Denne jobben er ikke lagt inn som en ekstern agentoppgave, og utføres av Antideps egne kjørere.';
  end if;

  if workflow.agent_task_contract(p_job.agent_role) is null then
    return format(
      'Rollen %s utføres av Antideps egen deterministiske kode, og kan ikke settes ut til en ekstern KI-agent.',
      p_job.agent_role
    );
  end if;

  -- En jobb som allerede har et utfall, er historikk og ikke noe som venter.
  -- Handoffimporten er ett av utfallene; en fullført kjøring fra et automatisert
  -- ledd er et annet, og begge gjør jobben ferdig.
  if exists (
    select 1 from workflow.agent_handoff_imports i where i.pipeline_job_id = p_job.id
  ) then
    return 'Oppgaven har allerede tatt imot et svar. Skal arbeidet gjøres om igjen, er det en ny oppgave.';
  end if;
  if p_job.state = 'succeeded' then
    return 'Oppgaven er allerede fullført. Skal arbeidet gjøres om igjen, er det en ny oppgave.';
  end if;

  -- En oppbrukt oppgave kan ikke ta imot et svar, og skal derfor ikke kunne
  -- hentes ut heller.
  if p_job.attempts >= p_job.max_attempts then
    return 'Oppgaven har brukt opp forsøkene sine og blir stående. Arbeidet må legges inn som en ny oppgave for å kunne gjøres om igjen.';
  end if;

  -- En leie som fortsatt løper, tilhører den som tok den. Importen tar selv et
  -- uttak med sin egen nøkkel, og uten denne regelen ville den overtatt jobben
  -- fra en kjører som holder den — kollisjonen ville først blitt oppdaget da den
  -- andre kjøreren prøvde å melde utfallet med en nøkkel som ikke gjaldt lenger
  -- (ANTIDEP_CONSTITUTION.md regel 4, 7). En UTLØPT leie er derimot ledig: det
  -- er nettopp den tilstanden som skal overleve at en prosess døde.
  if p_job.state = 'leased'
     and p_job.lease_expires_at is not null
     and p_job.lease_expires_at > statement_timestamp() then
    return 'Oppgaven er tatt ut av en kjøring som fortsatt holder den. Den blir ledig igjen når uttaket er ferdig eller leien løper ut.';
  end if;

  -- Hvilken KI-tjeneste leddet utføres av, avgjøres før oppgaven hentes ut:
  -- tildelingen inngår i bindingen, og et svar kontrolleres mot den. En oppgave
  -- bygget uten en tildeling ville bedt om et svar ingen kunne si var uavhengig
  -- (ANTIDEP_CONSTITUTION.md regel 3).
  v_model := provenance.current_semantic_model(p_job.agent_role);
  if v_model.id is null then
    return 'Ingen KI-tjeneste er valgt for dette agentleddet ennå. Velg tjenesten først, slik at oppgaven bindes til den og svaret kan kontrolleres mot den.';
  end if;

  return workflow.agent_task_input_problem(p_job);
end;
$$;

comment on function workflow.agent_task_problem(workflow.pipeline_jobs) is
  'Én setning om hva som hindrer at oppgaven kan besvares nå, eller NULL. Køen (api.agent_work_queue()), uttaket (api.agent_task_payload(uuid)) og importen (api.import_agent_answer(uuid, jsonb)) leser denne ene funksjonen, slik at de tre ikke kan bli uenige om hvilke jobber som faktisk er utførbare handoff-oppgaver: en jobb som allerede har et utfall — et importert svar eller en fullført kjøring fra et automatisert ledd — er historikk og ikke noe som venter, og en flate som viste den med nedlasting og opplasting, ville bedt noen gjøre noe importen uansett måtte avvise. Legger jobbtilstanden, forsøkene og modelltildelingen til vilkårene i workflow.agent_task_input_problem(workflow.pipeline_jobs) (ANTIDEP_CONSTITUTION.md regel 3, 4).';

revoke execute on function workflow.agent_task_problem(workflow.pipeline_jobs) from public;


-- Hva oppgaven gjelder, i klartekst.
--
-- Egen funksjon fordi køen trenger den for hver rad, og hele oppgaven — som
-- inneholder artikkelen — er altfor dyr å bygge bare for å lese en overskrift.
create function workflow.agent_task_subject(p_job workflow.pipeline_jobs)
  returns jsonb
  language sql
  stable
  set search_path = ''
as $$
  select case p_job.agent_role
    when 'evidence_extraction' then (
      select jsonb_build_object('kind', 'kilde', 'label', s.title)
      from knowledge.source_versions sv
      join knowledge.sources s on s.id = sv.source_id
      where sv.id = workflow.manifest_uuid(p_job.input_manifest, 'source_version_id')
    )
    when 'claim_synthesis' then (
      select jsonb_build_object('kind', 'påstand',
               'label', format('%s — %s', d.canonical_name, c.canonical_label))
      from catalog.drugs d, catalog.clinical_concepts c
      where d.id = workflow.manifest_uuid(p_job.input_manifest, 'subject_drug_id')
        and c.id = workflow.manifest_uuid(p_job.input_manifest, 'topic_concept_id')
    )
    when 'evidence_assessment' then (
      select jsonb_build_object('kind', 'påstandsrevisjon', 'label', r.statement)
      from knowledge.claim_revisions r
      where r.id = workflow.manifest_uuid(p_job.input_manifest, 'claim_revision_id')
    )
  end;
$$;

comment on function workflow.agent_task_subject(workflow.pipeline_jobs) is
  'Hva oppgaven gjelder, i klartekst: kildens tittel, virkestoffet og temaet, eller påstandens formulering. Egen funksjon fordi køen trenger den for hver rad, og hele oppgaven — som inneholder artikkelen — er altfor dyr å bygge bare for å lese en overskrift.';

revoke execute on function workflow.agent_task_subject(workflow.pipeline_jobs) from public;

-- Selve oppgaven.
create function workflow.agent_task(p_job workflow.pipeline_jobs)
  returns jsonb
  language plpgsql
  stable
  set search_path = ''
as $$
declare
  v_manifest jsonb := p_job.input_manifest;
  v_contract jsonb := workflow.agent_task_contract(p_job.agent_role);
  v_binding jsonb;
  v_input jsonb;
  v_subject jsonb;
  v_ignored jsonb;
  v_prior jsonb := '[]'::jsonb;
  v_model provenance.role_model_assignments;
  v_source_version_id uuid;
  v_revision_id uuid;
  v_evidence_ids uuid[];
  v_drug_ids uuid[];
  v_outcome_ids uuid[];
  v_population_ids uuid[];
begin
  if p_job.agent_role = 'evidence_extraction' then
    v_source_version_id := workflow.manifest_uuid(v_manifest, 'source_version_id');
    v_drug_ids := workflow.manifest_uuids(v_manifest, 'drug_ids');
    v_outcome_ids := workflow.manifest_uuids(v_manifest, 'outcome_concept_ids');
    v_population_ids := coalesce(workflow.manifest_uuids(v_manifest, 'population_ids'), array[]::uuid[]);

    select jsonb_build_object(
             'source_id', sv.source_id,
             'source_version_id', sv.id,
             'content_hash', sv.content_hash,
             'representation', sv.representation::text,
             'document_sha256', sv.document_sha256,
             'drug_ids', to_jsonb(v_drug_ids),
             'outcome_concept_ids', to_jsonb(v_outcome_ids),
             'population_ids', to_jsonb(v_population_ids)
           ),
           jsonb_build_object(
             'source', jsonb_build_object(
               'source_id', s.id,
               'title', s.title,
               'authors_or_issuer', s.authors_or_issuer,
               'publisher_or_journal', s.publisher_or_journal,
               'publication_date', s.publication_date,
               'source_type', s.source_type::text
             ),
             'source_version', jsonb_build_object(
               'source_version_id', sv.id,
               'retrieved_from', sv.retrieved_from,
               'retrieved_at', sv.retrieved_at,
               'content_hash', sv.content_hash,
               'representation', sv.representation::text,
               'document_sha256', sv.document_sha256
             ),
             'representation_text', knowledge.source_version_text(sv.id),
             'drugs', (
               select coalesce(jsonb_agg(jsonb_build_object(
                        'drug_id', d.id, 'label', d.canonical_name) order by d.canonical_name), '[]'::jsonb)
               from catalog.drugs d where d.id = any (v_drug_ids)
             ),
             'outcomes', (
               select coalesce(jsonb_agg(jsonb_build_object(
                        'outcome_concept_id', c.id, 'label', c.canonical_label) order by c.canonical_label), '[]'::jsonb)
               from catalog.clinical_concepts c where c.id = any (v_outcome_ids)
             ),
             'populations', (
               select coalesce(jsonb_agg(jsonb_build_object(
                        'population_id', p.id, 'label', p.canonical_label) order by p.canonical_label), '[]'::jsonb)
               from catalog.populations p where p.id = any (v_population_ids)
             )
           ),
           null::jsonb
      into v_binding, v_input, v_ignored
    from knowledge.source_versions sv
    join knowledge.sources s on s.id = sv.source_id
    where sv.id = v_source_version_id;

  elsif p_job.agent_role = 'claim_synthesis' then
    v_evidence_ids := workflow.manifest_uuids(v_manifest, 'evidence_item_ids');

    select jsonb_build_object(
             'topic_concept_id', workflow.manifest_uuid(v_manifest, 'topic_concept_id'),
             'subject_drug_id', workflow.manifest_uuid(v_manifest, 'subject_drug_id'),
             'claim_id', workflow.manifest_uuid(v_manifest, 'claim_id'),
             'population_ids', to_jsonb(coalesce(
               workflow.manifest_uuids(v_manifest, 'population_ids'), array[]::uuid[])),
             'evidence', (
               select coalesce(jsonb_agg(
                 jsonb_build_object('evidence_item_id', e.id, 'content_hash', e.content_hash)
                 order by e.id::text), '[]'::jsonb)
               from knowledge.evidence_items e where e.id = any (v_evidence_ids)
             )
           ),
           jsonb_build_object(
             'topic', jsonb_build_object(
               'topic_concept_id', c.id, 'label', c.canonical_label),
             'subject_drug', jsonb_build_object(
               'drug_id', d.id, 'label', d.canonical_name),
             'claim_id', workflow.manifest_uuid(v_manifest, 'claim_id'),
             'populations', (
               select coalesce(jsonb_agg(jsonb_build_object(
                        'population_id', p.id, 'label', p.canonical_label) order by p.canonical_label), '[]'::jsonb)
               from catalog.populations p
               where p.id = any (coalesce(
                 workflow.manifest_uuids(v_manifest, 'population_ids'), array[]::uuid[]))
             ),
             'evidence', (
               select coalesce(jsonb_agg(workflow.evidence_extraction_dossier(e.id) order by e.id::text), '[]'::jsonb)
               from knowledge.evidence_items e where e.id = any (v_evidence_ids)
             )
           ),
           null::jsonb
      into v_binding, v_input, v_ignored
    from catalog.clinical_concepts c, catalog.drugs d
    where c.id = workflow.manifest_uuid(v_manifest, 'topic_concept_id')
      and d.id = workflow.manifest_uuid(v_manifest, 'subject_drug_id');

    select coalesce(jsonb_agg(
             jsonb_build_object('role', r.agent_role::text, 'agent_run_id', r.id)
             order by r.id::text), '[]'::jsonb)
      into v_prior
    from knowledge.evidence_items e
    join provenance.agent_runs r on r.id = e.agent_run_id
    where e.id = any (v_evidence_ids);

  else
    v_revision_id := workflow.manifest_uuid(v_manifest, 'claim_revision_id');

    select jsonb_build_object(
             'claim_revision_id', r.id,
             'revision_content_hash', r.content_hash,
             'evidence_set_digest', knowledge.claim_evidence_set_digest(r.id)
           ),
           jsonb_build_object(
             'dossier', workflow.claim_evidence_dossier(r.id),
             'seen_evidence_set_digest', knowledge.claim_evidence_set_digest(r.id)
           ),
           null::jsonb
      into v_binding, v_input, v_ignored
    from knowledge.claim_revisions r
    where r.id = v_revision_id;

    select coalesce(jsonb_agg(
             jsonb_build_object('role', x.role, 'agent_run_id', x.run_id)
             order by x.role, x.run_id::text), '[]'::jsonb)
      into v_prior
    from (
      select r.agent_role::text as role, r.id as run_id
      from knowledge.claim_revisions cr
      join provenance.agent_runs r on r.id = cr.agent_run_id
      where cr.id = v_revision_id
      union all
      select r.agent_role::text, r.id
      from workflow.claim_verifications v
      join provenance.agent_runs r on r.id = v.agent_run_id
      where v.claim_revision_id = v_revision_id
    ) x;
  end if;

  v_subject := workflow.agent_task_subject(p_job);
  v_model := provenance.current_semantic_model(p_job.agent_role);

  v_binding := jsonb_build_object(
    'task_version', workflow.agent_handoff_task_version(),
    'role', p_job.agent_role::text,
    'job_key', p_job.job_key,
    'pipeline_job_id', p_job.id,
    'prompt_template_version', v_contract ->> 'prompt_template_version',
    'output_schema_version', v_contract ->> 'output_schema_version',
    -- Tildelingen er en del av det som binder svaret. Byttes modellen, får hver
    -- utestående oppgave et nytt avtrykk, og et svar avgitt under den gamle
    -- tildelingen kan ikke komme tilbake og registrere den gamle modellen på
    -- nytt (ANTIDEP_CONSTITUTION.md regel 3). Tildelingens id står med, fordi to
    -- tildelinger av den samme modellen er to avgjørelser.
    'semantic_model', case when v_model.id is null then null else jsonb_build_object(
      'assignment_id', v_model.id,
      'provider', v_model.provider,
      'model', v_model.model,
      'model_version', v_model.model_version,
      'model_version_disclosure', v_model.model_version_disclosure::text
    ) end,
    'input', v_binding,
    'prior_runs', v_prior
  );

  return jsonb_build_object(
    'task_version', workflow.agent_handoff_task_version(),
    'answer_version', workflow.agent_handoff_answer_version(),
    'pipeline_job_id', p_job.id,
    'job_key', p_job.job_key,
    'role', p_job.agent_role::text,
    'prompt_template_version', v_contract ->> 'prompt_template_version',
    'output_schema_version', v_contract ->> 'output_schema_version',
    'request_digest', workflow.agent_task_digest(v_binding),
    'binding', v_binding,
    'subject', v_subject,
    'registered_model', case when v_model.id is null then null else jsonb_build_object(
      'provider', v_model.provider,
      'model', v_model.model,
      'model_version', v_model.model_version,
      'model_version_disclosure', v_model.model_version_disclosure::text
    ) end,
    'input', v_input
  );
end;
$$;

comment on function workflow.agent_task(workflow.pipeline_jobs) is
  'Hele agentoppgaven, bygget av rader som allerede finnes (ANTIDEP_CONSTITUTION.md regel 2, 4). binding er nøyaktig de opplysningene som binder svaret — rollen, oppgavenøkkelen, promptmalversjonen, outputschemaversjonen, den tildelte KI-modellen, inndataens versjon og de tidligere agentkjøringene rollen hviler på — og request_digest er avtrykket av den. Modelltildelingen står MED i bindingen fordi den er attestert på forhånd av en redaktør med mandat og ikke etableres av svaret: byttes modellen, får hver utestående oppgave et nytt avtrykk, og et svar avgitt under den gamle tildelingen kan ikke komme tilbake og registrere den gamle modellen på nytt (regel 3). input er innholdet agenten skal lese, inkludert hele den kontrollerte kildeteksten der rollen leser en kilde.';

revoke execute on function workflow.agent_task(workflow.pipeline_jobs) from public;

-- ----------------------------------------------------------------------------
-- 5. Flaten: køen, oppgaven og innleggingen
--
-- Alle tre krever editor-mandat. Oppgaven inneholder hele den kontrollerte
-- kildeteksten, og den skal ikke kunne leses av en innlogget kliniker: teksten
-- er beskyttet materiale, og den forlater databasen bare til den som faktisk
-- skal utføre agentarbeidet (ANTIDEP_CONSTITUTION.md regel 2, 7).
-- ----------------------------------------------------------------------------
create function api.agent_work_queue()
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_rows jsonb;
begin
  perform knowledge.assert_editor_authorized();

  select coalesce(jsonb_agg(row_to_json(q)::jsonb order by q.enqueued_at), '[]'::jsonb)
    into v_rows
  from (
    select
      j.id as pipeline_job_id,
      j.agent_role::text as agent_role,
      j.job_key,
      j.state::text as state,
      j.attempts,
      j.max_attempts,
      j.enqueued_at,
      j.failure_reason,
      workflow.agent_task_problem(j) as blocked_reason,
      coalesce(workflow.agent_task_subject(j) ->> 'label', j.job_key) as subject_label,
      case when m.id is null then null else jsonb_build_object(
        'provider', m.provider, 'model', m.model,
        'model_version', m.model_version,
        'model_version_disclosure', m.model_version_disclosure::text) end as registered_model
    from workflow.pipeline_jobs j
    -- Bare de jobbene som faktisk ER eksterne agentoppgaver. En innerjoin og
    -- ikke et rollefilter: utførelsesmåten er en egenskap ved raden.
    join workflow.agent_handoff_jobs h on h.pipeline_job_id = j.id
    -- Den samme tildelingen kontrollen leser, lest med den samme funksjonen.
    left join lateral provenance.current_semantic_model(j.agent_role) m on true
    where workflow.agent_task_contract(j.agent_role) is not null
      -- Køen er det som venter. En jobb med et registrert utfall er historikk,
      -- og en flate som lot den stå, ville vokst med noe ingen skal gjøre noe
      -- med (ANTIDEP_CONSTITUTION.md regel 4).
      and j.state <> 'succeeded'
      and not exists (
        select 1 from workflow.agent_handoff_imports i where i.pipeline_job_id = j.id
      )
  ) q;

  return v_rows;
end;
$$;

comment on function api.agent_work_queue() is
  'De eksterne agentoppgavene som fortsatt venter, slik en operativ flate trenger dem: rolle, hva oppgaven gjelder, tilstand, hvilken ekstern modell leddet er tildelt, og én setning om hva som eventuelt hindrer at den kan kjøres. Bare jobber som faktisk er lagt inn som eksterne agentoppgaver (workflow.agent_handoff_jobs) — utførelsesmåten er en egenskap ved raden og ikke noe som utledes av agentrollen — og bare de som ikke har et registrert utfall: en besvart eller fullført jobb er historikk, og en flate som lot den stå, ville vokst med noe ingen skal gjøre noe med. Inneholder ikke kildeteksten — den ligger i api.agent_task_payload(uuid), som hentes når oppgaven faktisk skal utføres. Krever editor-mandat. SECURITY DEFINER fordi workflow og provenance har RLS med default deny; kalleren valideres på funksjonens eget kall.';

revoke execute on function api.agent_work_queue() from public;
grant execute on function api.agent_work_queue() to authenticated;

create function api.agent_task_payload(p_pipeline_job_id uuid)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_job workflow.pipeline_jobs;
  v_problem text;
begin
  perform knowledge.assert_editor_authorized();

  select j.* into v_job from workflow.pipeline_jobs j where j.id = p_pipeline_job_id;
  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = format('Det finnes ingen agentoppgave med id %L.', p_pipeline_job_id);
  end if;

  v_problem := workflow.agent_task_problem(v_job);
  if v_problem is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = v_problem,
      hint = 'Oppgaven bygges av grunnlaget som faktisk ligger der. Mangler noe av det, skal oppgaven ikke hentes ut — et svar avgitt på et ufullstendig grunnlag ville ikke kunnet registreres (ANTIDEP_CONSTITUTION.md regel 4).';
  end if;

  return workflow.agent_task(v_job);
end;
$$;

comment on function api.agent_task_payload(uuid) is
  'Hele agentoppgaven for én pipelinejobb, inkludert den kontrollerte kildeteksten der rollen leser en kilde (ANTIDEP_CONSTITUTION.md regel 2). Krever editor-mandat: innholdet er beskyttet materiale, og det forlater databasen bare til den som faktisk skal utføre agentarbeidet. request_digest i svaret er oppgavens identitet og skal kopieres uendret inn i svarfilen; endres grunnlaget, får oppgaven et annet avtrykk, og det gamle svaret kan ikke importeres. Kan hentes så mange ganger man vil: den skriver ingenting, og den samme oppgaven gir det samme avtrykket.';

revoke execute on function api.agent_task_payload(uuid) from public;
grant execute on function api.agent_task_payload(uuid) to authenticated;

-- Innleggingen: nøkkelen utledes, framfor å velges.
create function api.enqueue_agent_task(p_agent_role text, p_input_manifest jsonb)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_role provenance.agent_role;
  v_subject text;
  v_job_key text;
  v_result jsonb;
  v_job workflow.pipeline_jobs;
  v_problem text;
begin
  begin
    v_role := p_agent_role::provenance.agent_role;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke en kjent agentrolle.', p_agent_role);
  end;

  if workflow.agent_task_contract(v_role) is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format(
        'Rollen %L kan ikke settes ut til en ekstern KI-agent.', p_agent_role),
      hint = 'De uavhengige kontrolleddene er Antideps egen deterministiske kode. En ekstern modell som fikk utføre dem, ville gjort kontrollen til nok en modellvurdering (ANTIDEP_CONSTITUTION.md regel 3).';
  end if;

  if p_input_manifest is null or jsonb_typeof(p_input_manifest) <> 'object' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Inndatamanifestet må være et JSON-objekt.';
  end if;

  v_subject := case v_role
    when 'evidence_extraction' then coalesce(p_input_manifest ->> 'source_version_id', '?')
    when 'claim_synthesis' then format('%s+%s',
      coalesce(p_input_manifest ->> 'subject_drug_id', '?'),
      coalesce(p_input_manifest ->> 'topic_concept_id', '?'))
    else coalesce(p_input_manifest ->> 'claim_revision_id', '?')
  end;

  -- Nøkkelen utledes av hva jobben handler om, med et kort avtrykk av hele
  -- manifestet bak. Subjektet gjør køen lesbar; avtrykket gjør to forskjellige
  -- avgrensninger av det samme subjektet til to jobber framfor til en kollisjon.
  v_job_key := format('agent-handoff:%s:%s', v_subject,
    left(encode(sha256(convert_to(p_input_manifest::text, 'UTF8')), 'hex'), 12));

  v_result := api.enqueue_pipeline_job(p_agent_role, v_job_key, p_input_manifest);

  select j.* into v_job
  from workflow.pipeline_jobs j
  where j.id = (v_result ->> 'pipeline_job_id')::uuid;

  -- Utførelsesmåten settes i det samme kallet som oppretter jobben, og aldri
  -- etterpå. Fikk vi tilbake en jobb som allerede fantes, må den ha vært en
  -- handoff-jobb fra før: en intern pipelinejobb som ble omdøpt til en ekstern
  -- oppgave i ettertid, ville kunnet stå midt i en kjøring.
  if (v_result ->> 'enqueued')::boolean then
    insert into workflow.agent_handoff_jobs (pipeline_job_id, registered_by_actor_id)
    values (v_job.id, v_job.enqueued_by_actor_id);
  elsif not exists (
    select 1 from workflow.agent_handoff_jobs h where h.pipeline_job_id = v_job.id
  ) then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Jobben %L finnes allerede for rollen %L som en intern pipelinejobb.', v_job_key, p_agent_role),
      hint = 'Utførelsesmåten avgjøres når jobben legges inn. En intern jobb som ble gjort om til en ekstern agentoppgave i ettertid, kunne stått midt i en kjøring — og det samme arbeidet ville blitt gjort to ganger.';
  end if;

  -- Bare grunnlaget. At ingen KI-tjeneste er valgt for leddet ennå, er ikke en
  -- grunn til å nekte å legge inn oppgaven — det er noe køen ber om, og valget
  -- hører hjemme der og ikke i en innlegging.
  v_problem := workflow.agent_task_input_problem(v_job);
  if v_problem is not null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = v_problem,
      hint = 'En oppgave som ikke kan bygges, skal ikke legges i køen: den ville stått der som noe som ventet på et menneske, uten å kunne utføres (ANTIDEP_CONSTITUTION.md regel 4).';
  end if;

  return v_result || jsonb_build_object('job_key', v_job_key);
end;
$$;

comment on function api.enqueue_agent_task(text, jsonb) is
  'Legger inn én ekstern agentoppgave og utleder jobbnøkkelen av hva oppgaven handler om — subjektet i klartekst, med et kort avtrykk av hele inndatamanifestet bak, slik at to forskjellige avgrensninger av det samme subjektet blir to jobber framfor en kollisjon. Kaller api.enqueue_pipeline_job(text, text, jsonb), som er idempotent på (rolle, nøkkel), og avviser en oppgave som ikke kan bygges av grunnlaget som faktisk ligger der. Krever editor-mandat gjennom det kallet.';

revoke execute on function api.enqueue_agent_task(text, jsonb) from public;
grant execute on function api.enqueue_agent_task(text, jsonb) to authenticated;

-- ----------------------------------------------------------------------------
-- 6. Importen
--
-- Svarfilen kommer inn ordrett. Funksjonen kontrollerer bindingen, henter
-- verdiene ut av svaret selv — kalleren kan ikke bytte dem ut underveis — og
-- skriver gjennom nøyaktig de samme interne skriveveiene agentkjørerne bruker.
--
-- Rekkefølgen er ikke tilfeldig. Autorisasjon, så bindingen, så
-- modellidentiteten, så arbeidet. Et svar som ikke hører til oppgaven, eller som
-- kommer fra en modell som ikke får gjøre denne rollen, skal avvises før noe
-- skrives — ikke etter.
-- ----------------------------------------------------------------------------
create function api.import_agent_answer(p_pipeline_job_id uuid, p_answer jsonb)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_job workflow.pipeline_jobs;
  v_problem text;
  v_task jsonb;
  v_binding jsonb;
  v_input jsonb;
  v_answer_digest text;
  v_existing workflow.agent_handoff_imports;
  v_identity jsonb;
  v_provider text;
  v_model text;
  v_model_version text;
  v_disclosure provenance.model_version_disclosure;
  v_answered_at timestamptz;
  v_result jsonb;
  v_unknown text;
  v_agent_identity provenance.agent_identities;
  v_agent_actor_id uuid;
  v_registration provenance.role_model_assignments;
  v_semantic provenance.role_model_assignments;
  v_lease uuid := gen_random_uuid();
  v_run_id uuid;
  v_outcome jsonb;
  v_extraction jsonb;
  v_claim jsonb;
  v_assessment jsonb;
  v_evidence_item_id uuid;
  v_ids uuid[];
  v_id uuid;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  select j.* into v_job
  from workflow.pipeline_jobs j
  where j.id = p_pipeline_job_id
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = format('Det finnes ingen agentoppgave med id %L.', p_pipeline_job_id);
  end if;

  -- ------------------------------------------------------------------
  -- Gjentakelsen først, før alt annet
  --
  -- Det samme svaret sendt inn igjen — et dobbeltklikk, en gjenopptatt
  -- økt — skal svare med det som allerede ble registrert, framfor å lage
  -- et nytt klinisk objekt. Et *annet* svar på en jobb som allerede er
  -- besvart, er ikke en gjentakelse, og avvises.
  -- ------------------------------------------------------------------
  v_answer_digest := 'sha256:' || encode(sha256(convert_to(p_answer::text, 'UTF8')), 'hex');

  select i.* into v_existing
  from workflow.agent_handoff_imports i
  where i.pipeline_job_id = p_pipeline_job_id;

  if found then
    if v_existing.answer_digest = v_answer_digest then
      return jsonb_build_object(
        'imported', false,
        'already_imported', true,
        'pipeline_job_id', p_pipeline_job_id,
        'agent_role', v_existing.agent_role::text,
        'agent_run_id', v_existing.agent_run_id,
        'outcome', v_existing.outcome
      );
    end if;
    raise exception using
      errcode = 'unique_violation',
      message = 'Denne agentoppgaven har allerede tatt imot et annet svar.',
      hint = 'Ett svar per oppgave. To svar ville gitt to kliniske objekter for det samme arbeidet, og ingen ville kunnet si hvilket som gjaldt (ANTIDEP_CONSTITUTION.md regel 4). Skal arbeidet gjøres om igjen, er det en ny oppgave.';
  end if;

  if v_job.state = 'succeeded' then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Agentoppgaven er allerede fullført.',
      hint = 'Jobben har et registrert utfall fra før. Skal arbeidet gjøres om igjen, er det en ny oppgave.';
  end if;
  if v_job.attempts >= v_job.max_attempts then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Agentoppgaven har brukt opp forsøkene sine og blir stående.',
      hint = 'En oppbrukt jobb skal ikke se ut som en jobb som fortsatt er underveis (ANTIDEP_CONSTITUTION.md regel 4). Legg inn oppgaven på nytt dersom den skal forsøkes igjen.';
  end if;

  v_problem := workflow.agent_task_problem(v_job);
  if v_problem is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = v_problem;
  end if;

  -- ------------------------------------------------------------------
  -- Formen på svaret, og bindingen
  -- ------------------------------------------------------------------
  if p_answer is null or jsonb_typeof(p_answer) <> 'object' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Svaret er ikke et JSON-objekt.';
  end if;

  select string_agg(quote_literal(k.value), ', ' order by k.value) into v_unknown
  from jsonb_object_keys(p_answer) as k(value)
  where k.value not in (
    'answer_version', 'task_version', 'role', 'job_key', 'request_digest',
    'output_schema_version', 'identity', 'answered_at', 'result'
  );
  if v_unknown is not null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Svaret har felter denne kontrakten ikke kjenner: %s.', v_unknown),
      hint = 'Ukjente felter avvises framfor å ignoreres: et felt med skrivefeil ville ellers sett ut som en utelatt opplysning, og et felt ingen leser, ville vært en påstand uten virkning.';
  end if;

  v_task := workflow.agent_task(v_job);
  v_binding := v_task -> 'binding';
  v_input := v_binding -> 'input';

  if p_answer ->> 'answer_version' is distinct from workflow.agent_handoff_answer_version() then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Svaret er skrevet mot %L, men Antidep leser %L.',
        p_answer ->> 'answer_version', workflow.agent_handoff_answer_version());
  end if;
  if p_answer ->> 'task_version' is distinct from workflow.agent_handoff_task_version() then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Svaret gjelder oppgaveformen %L, men denne oppgaven er %L.',
        p_answer ->> 'task_version', workflow.agent_handoff_task_version());
  end if;
  if p_answer ->> 'role' is distinct from v_job.agent_role::text then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Svaret er avgitt i rollen %L, mens oppgaven gjelder rollen %L.',
        p_answer ->> 'role', v_job.agent_role::text),
      hint = 'Rollen avgjør hva svaret får lov til å registrere. Et svar fra ett ledd skal ikke kunne lukkes inn i et annet.';
  end if;
  if p_answer ->> 'job_key' is distinct from v_job.job_key then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Svaret gjelder en annen agentoppgave enn den det importeres på.';
  end if;
  if p_answer ->> 'output_schema_version' is distinct from (v_task ->> 'output_schema_version') then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Svaret er skrevet mot svarformen %L, mens oppgaven krever %L.',
        p_answer ->> 'output_schema_version', v_task ->> 'output_schema_version');
  end if;
  if p_answer ->> 'request_digest' is distinct from (v_task ->> 'request_digest') then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format(
        'Svaret er avgitt på forespørselen %s, mens oppgaven nå er %s.',
        coalesce(p_answer ->> 'request_digest', '(mangler)'), v_task ->> 'request_digest'),
      hint = 'Avtrykket dekker rollen, oppgaven, promptmalen, svarformen og hele grunnlaget oppgaven ble bygget av. Er noe av det endret siden oppgaven ble hentet ut, gjelder ikke det gamle svaret lenger. Hent oppgaven på nytt og be om et nytt svar (ANTIDEP_CONSTITUTION.md regel 2, 4).';
  end if;

  v_result := p_answer -> 'result';
  if v_result is null or jsonb_typeof(v_result) <> 'object' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Svaret har ingen result som er et JSON-objekt.';
  end if;

  -- ------------------------------------------------------------------
  -- Hvem som svarte
  -- ------------------------------------------------------------------
  v_identity := p_answer -> 'identity';
  if v_identity is null or jsonb_typeof(v_identity) <> 'object' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Svaret sier ikke hvilken modell som utførte oppgaven.',
      hint = 'identity skal ha provider, model og model_version_disclosure — og model_version når tjenesten faktisk oppgir en versjon. Uten den kan ingen si om kontrollene i kjeden er uavhengige (ANTIDEP_CONSTITUTION.md regel 3).';
  end if;

  select string_agg(quote_literal(k.value), ', ' order by k.value) into v_unknown
  from jsonb_object_keys(v_identity) as k(value)
  where k.value not in ('provider', 'model', 'model_version', 'model_version_disclosure');
  if v_unknown is not null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('identity har felter denne kontrakten ikke kjenner: %s.', v_unknown);
  end if;

  -- Den samme lesningen tildelingen ble gjort med, slik at «samme modell» betyr
  -- det samme begge steder.
  v_identity := provenance.canonical_model_identity(
    v_identity ->> 'provider',
    v_identity ->> 'model',
    v_identity ->> 'model_version',
    v_identity ->> 'model_version_disclosure'
  );
  v_provider := v_identity ->> 'provider';
  v_model := v_identity ->> 'model';
  v_model_version := v_identity ->> 'model_version';
  v_disclosure := (v_identity ->> 'model_version_disclosure')::provenance.model_version_disclosure;

  -- Svaret bekrefter identiteten sin; det etablerer den ikke. Tildelingen er
  -- tatt på forhånd av en redaktør med mandat, den står i bindingen avtrykket er
  -- regnet av, og et svar fra en annen modell avvises her — før noe skrives. Et
  -- svar som fikk registrere sin egen identitet, ville etablert premisset som
  -- autoriserte det selv, og separasjonen mellom leddene ville hvilt på en
  -- erklæring modellen avga om seg selv (ANTIDEP_CONSTITUTION.md regel 3).
  v_semantic := provenance.require_semantic_model_assignment(v_job.agent_role, v_identity);

  if p_answer ->> 'answered_at' is not null then
    begin
      v_answered_at := (p_answer ->> 'answered_at')::timestamptz;
    exception
      when others then
        raise exception using
          errcode = 'invalid_parameter_value',
          message = format('answered_at er %L, som ikke er et tidspunkt.', p_answer ->> 'answered_at');
    end;

    -- Et svar kan ikke være avgitt i framtiden. Slakken finnes fordi agenten
    -- kjører på en annen maskin med en annen klokke, og et tidspunkt avrundet
    -- til nærmeste minutt ikke er en usann påstand; uten den ville en riktig
    -- import blitt stoppet av tre sekunder, og kontrollen blitt skrudd av
    -- framfor fulgt. Samme regel og samme slakk som i den filbaserte kjøringen.
    if v_answered_at > statement_timestamp() + interval '5 minutes'
       or v_answered_at < v_job.enqueued_at - interval '5 minutes' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format(
          'answered_at er %L, som ligger utenfor oppgaven: den ble lagt inn %L og importeres nå.',
          v_answered_at, v_job.enqueued_at
        ),
        hint = 'Tidspunktet registreres som da agenten svarte. Et svar avgitt før oppgaven fantes, eller inn i framtiden, er ikke en unøyaktighet — det er en usann proveniens (ANTIDEP_CONSTITUTION.md regel 4). La feltet stå tomt om du er usikker.';
    end if;
  end if;

  -- ------------------------------------------------------------------
  -- Uttaket og kjøringen
  --
  -- Importen gjør det en kjører ville gjort: tar ut jobben med en leie i
  -- rollens egen agentidentitet, åpner kjøringen for nettopp det uttaket, og
  -- melder utfallet. Da gjelder de samme bindingene og de samme reglene som
  -- for et automatisert ledd — inkludert at kjøringen ikke kan gjenbrukes på
  -- en annen jobb.
  -- ------------------------------------------------------------------
  select ai.* into v_agent_identity
  from provenance.agent_identities ai
  where ai.agent_role = v_job.agent_role
    and ai.valid_from <= statement_timestamp()
    and (ai.valid_to is null or ai.valid_to > statement_timestamp())
  order by ai.valid_from
  limit 1;

  if v_agent_identity.id is null then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Rollen %L har ingen gyldig agentidentitet å registrere kjøringen under.', v_job.agent_role);
  end if;
  v_agent_actor_id := v_agent_identity.actor_id;

  v_registration := provenance.current_role_model(v_job.agent_role);
  if v_registration.id is null then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Rollen %L har ingen gyldig modelltildeling for registreringsleddet.', v_job.agent_role);
  end if;

  update workflow.pipeline_jobs
  set state = 'leased',
      attempts = v_job.attempts + 1,
      leased_by_agent_identity_id = v_agent_identity.id,
      lease_expires_at = statement_timestamp() + interval '15 minutes',
      lease_token = v_lease,
      -- En jobb som sto som failed, bærer et fullføringstidspunkt. Uttaket er
      -- et nytt forsøk, og et forsøk som pågår, er ikke fullført.
      completed_at = null
  where id = v_job.id;

  perform workflow.record_pipeline_job_event(
    v_job.id, v_job.state, 'leased'::workflow.pipeline_job_state,
    v_job.attempts + 1, v_actor_id, null,
    'Uttak for import av et eksternt agentsvar.'
  );

  insert into provenance.agent_runs (
    agent_identity_id, actor_id, agent_role,
    provider, model, model_version, model_version_disclosure,
    semantic_provider, semantic_model, semantic_model_version,
    semantic_model_version_disclosure,
    prompt_template_version, pipeline_version,
    status, input_manifest, input_source_version_id
  )
  values (
    v_agent_identity.id, v_agent_actor_id, v_job.agent_role,
    v_registration.provider, v_registration.model, v_registration.model_version,
    v_registration.model_version_disclosure,
    v_provider, v_model, v_model_version, v_disclosure,
    v_task ->> 'prompt_template_version', 'antidep-evidence/1',
    'running',
    jsonb_build_object('handoff', jsonb_build_object(
      'task_version', v_task ->> 'task_version',
      'answer_version', v_task ->> 'answer_version',
      'request_digest', v_task ->> 'request_digest',
      'output_schema_version', v_task ->> 'output_schema_version',
      'answer_digest', v_answer_digest,
      'answered_at', v_answered_at,
      'imported_by_actor_id', v_actor_id,
      'binding', v_binding
    )),
    case when v_job.agent_role = 'evidence_extraction'
         then (v_input ->> 'source_version_id')::uuid end
  )
  returning id into v_run_id;

  insert into workflow.pipeline_job_runs (agent_run_id, pipeline_job_id, lease_token, attempt)
  values (v_run_id, v_job.id, v_lease, v_job.attempts + 1);

  -- ------------------------------------------------------------------
  -- Arbeidet, gjennom de samme skriveveiene som agentkjørerne bruker
  -- ------------------------------------------------------------------
  if v_job.agent_role = 'evidence_extraction' then
    v_extraction := v_result -> 'extraction';
    if v_extraction is null or jsonb_typeof(v_extraction) <> 'object' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret har ingen extraction som er et JSON-objekt.';
    end if;

    -- Katalogen er redaktørens avgrensning, og modellen velger innenfor den.
    -- En id utenfor oppgaven ville flyttet funnet til et annet virkestoff eller
    -- et naboendepunkt, og den ordrette kontrollen kontrollerer utdrag — ikke
    -- avgrensning.
    v_ids := workflow.manifest_uuids(v_input, 'drug_ids');
    v_id := workflow.manifest_uuid(v_extraction, 'intervention_drug_id');
    if v_id is null or not (v_id = any (v_ids)) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret oppgir et virkestoff som ikke står blant virkestoffene i oppgaven.';
    end if;
    v_id := workflow.manifest_uuid(v_extraction, 'comparator_drug_id');
    if v_extraction ->> 'comparator_drug_id' is not null and (v_id is null or not (v_id = any (v_ids))) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret oppgir et komparatorvirkestoff som ikke står blant virkestoffene i oppgaven.';
    end if;
    v_ids := workflow.manifest_uuids(v_input, 'outcome_concept_ids');
    v_id := workflow.manifest_uuid(v_extraction, 'outcome_concept_id');
    if v_id is null or not (v_id = any (v_ids)) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret oppgir et endepunkt som ikke står blant endepunktene i oppgaven.';
    end if;
    v_ids := coalesce(workflow.manifest_uuids(v_input, 'population_ids'), array[]::uuid[]);
    v_id := workflow.manifest_uuid(v_extraction, 'population_id');
    if v_extraction ->> 'population_id' is not null and (v_id is null or not (v_id = any (v_ids))) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret oppgir en populasjon som ikke står blant populasjonene i oppgaven.';
    end if;

    v_evidence_item_id := knowledge.record_evidence_item(
      (v_input ->> 'source_id')::uuid,
      v_extraction ->> 'design_code',
      v_extraction ->> 'population_availability',
      v_extraction ->> 'population_detail',
      v_extraction ->> 'sample_size_availability',
      (v_extraction ->> 'intervention_drug_id')::uuid,
      v_extraction ->> 'comparator_kind',
      (v_extraction ->> 'outcome_concept_id')::uuid,
      v_extraction ->> 'outcome_detail',
      v_extraction ->> 'timepoint_availability',
      v_extraction ->> 'reported_direction',
      v_extraction ->> 'estimate_availability',
      v_extraction ->> 'confidence_interval_availability',
      v_extraction ->> 'source_locator',
      (v_input ->> 'source_version_id')::uuid,
      workflow.manifest_uuid(v_extraction, 'population_id'),
      (v_extraction ->> 'sample_size')::integer,
      v_extraction ->> 'intervention_detail',
      workflow.manifest_uuid(v_extraction, 'comparator_drug_id'),
      v_extraction ->> 'comparator_detail',
      v_extraction ->> 'timepoint_min',
      v_extraction ->> 'timepoint_max',
      v_extraction ->> 'effect_measure',
      (v_extraction ->> 'estimate')::numeric,
      v_extraction ->> 'estimate_unit',
      (v_extraction ->> 'ci_lower')::numeric,
      (v_extraction ->> 'ci_upper')::numeric,
      (v_extraction ->> 'ci_level_percent')::numeric,
      v_extraction ->> 'limitations_text',
      v_extraction ->> 'source_quote',
      v_result -> 'field_groundings',
      'ai_assisted',
      v_agent_actor_id,
      v_run_id
    );

    perform workflow.assert_extraction_fully_grounded(v_evidence_item_id);
    v_outcome := jsonb_build_object('evidence_item_id', v_evidence_item_id);

  elsif v_job.agent_role = 'claim_synthesis' then
    v_claim := v_result -> 'claim';
    if v_claim is null or jsonb_typeof(v_claim) <> 'object' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret har ingen claim som er et JSON-objekt.';
    end if;

    -- Evidenssettet er oppgavens, ikke svarets. En lenke til et funn utenfor
    -- oppgaven ville gitt en påstand som hvilte på noe ingen hadde avgrenset.
    if exists (
      select 1
      from jsonb_array_elements(coalesce(v_result -> 'evidence_links', '[]'::jsonb)) as link(value)
      where workflow.manifest_uuid(link.value, 'evidence_item_id') is null
         or not (workflow.manifest_uuid(link.value, 'evidence_item_id') = any (
              select (e.value ->> 'evidence_item_id')::uuid
              from jsonb_array_elements(v_input -> 'evidence') as e(value)))
    ) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret lenker til et evidensfunn som ikke står i oppgaven.',
        hint = 'Hvilke funn en syntese kan bygge på, er en faglig avgrensning som ligger i oppgaven. En modell som fikk velge fritt, ville kunnet bygge påstanden på noe ingen hadde tatt stilling til.';
    end if;

    -- Og hele settet, ikke en delmengde av det. Et svar som utelot et funn som
    -- MOTSIER påstanden, ville gitt en syntese som hvilte på et annet grunnlag
    -- enn det redaktøren avgrenset — og uenigheten ville vært borte uten at noe
    -- i kjeden sa fra (ANTIDEP_CONSTITUTION.md regel 4).
    if exists (
      select 1
      from jsonb_array_elements(v_input -> 'evidence') as assigned(value)
      where not exists (
        select 1
        from jsonb_array_elements(coalesce(v_result -> 'evidence_links', '[]'::jsonb)) as link(value)
        where link.value ->> 'evidence_item_id' = assigned.value ->> 'evidence_item_id'
      )
    ) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret dekker ikke alle evidensfunnene oppgaven avgrenset.',
        hint = 'Hvert funn i oppgaven skal ha en relasjon til påstanden — også et funn som motsier den, som da føres som contradicts. Et utelatt funn ville gjort grunnlaget til et annet enn det som finnes.';
    end if;

    -- Populasjonen er redaktørens avgrensning, som katalogen i et
    -- ekstraksjonsoppdrag. En id kopiert ut av dossieret ville passert
    -- fremmednøkkelen og flyttet påstanden til en annen populasjon.
    v_ids := coalesce(workflow.manifest_uuids(v_input, 'population_ids'), array[]::uuid[]);
    v_id := workflow.manifest_uuid(v_claim, 'population_id');
    if v_claim ->> 'population_id' is not null and (v_id is null or not (v_id = any (v_ids))) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret oppgir en populasjon som ikke står blant populasjonene i oppgaven.';
    end if;

    v_outcome := knowledge.record_agent_claim_synthesis(
      v_run_id,
      v_agent_actor_id,
      (v_input ->> 'topic_concept_id')::uuid,
      (v_input ->> 'subject_drug_id')::uuid,
      v_claim ->> 'statement',
      v_claim ->> 'scope',
      v_claim ->> 'comparator_kind',
      v_claim ->> 'uncertainty_summary',
      v_result -> 'evidence_links',
      workflow.manifest_uuid(v_input, 'claim_id'),
      workflow.manifest_uuid(v_claim, 'population_id'),
      v_claim ->> 'timeframe_min',
      v_claim ->> 'timeframe_max',
      workflow.manifest_uuid(v_claim, 'comparator_drug_id'),
      v_claim ->> 'direction',
      v_claim ->> 'magnitude_measure',
      (v_claim ->> 'magnitude_value')::numeric,
      v_claim ->> 'magnitude_unit',
      v_claim ->> 'qualifiers'
    );

  else
    v_assessment := v_result -> 'assessment';
    if v_assessment is null or jsonb_typeof(v_assessment) <> 'object' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret har ingen assessment som er et JSON-objekt.';
    end if;

    v_outcome := knowledge.record_evidence_assessment_row(
      v_run_id,
      v_agent_actor_id,
      (v_input ->> 'claim_revision_id')::uuid,
      -- Avtrykket av evidenssettet er oppgavens eget, ikke svarets: oppgaven
      -- viste nøyaktig det settet, og request_digest dekker det allerede. En
      -- verdi fra svaret ville vært en påstand om hva agenten så.
      v_input ->> 'evidence_set_digest',
      v_assessment ->> 'framework',
      v_assessment ->> 'certainty_level',
      v_assessment ->> 'rationale',
      v_assessment ->> 'risk_of_bias',
      v_assessment ->> 'inconsistency',
      v_assessment ->> 'indirectness',
      v_assessment ->> 'imprecision',
      v_assessment ->> 'publication_bias',
      v_assessment ->> 'other_considerations',
      v_assessment ->> 'evidence_gap'
    );
  end if;

  -- ------------------------------------------------------------------
  -- Utfallet
  -- ------------------------------------------------------------------
  update provenance.agent_runs
  set status = 'succeeded', completed_at = now(), output_manifest = v_outcome
  where id = v_run_id;

  update workflow.pipeline_jobs
  set state = 'succeeded',
      agent_run_id = v_run_id,
      output_manifest = v_outcome,
      completed_at = now(),
      failure_reason = null
  where id = v_job.id;

  perform workflow.record_pipeline_job_event(
    v_job.id, 'leased'::workflow.pipeline_job_state, 'succeeded'::workflow.pipeline_job_state,
    v_job.attempts + 1, v_actor_id, null,
    'Eksternt agentsvar importert og registrert.'
  );

  insert into workflow.agent_handoff_imports (
    pipeline_job_id, agent_role, request_digest, answer_digest,
    agent_run_id, imported_by_actor_id, answered_at, outcome
  )
  values (
    v_job.id, v_job.agent_role, v_task ->> 'request_digest', v_answer_digest,
    v_run_id, v_actor_id, v_answered_at, v_outcome
  );

  return jsonb_build_object(
    'imported', true,
    'already_imported', false,
    'pipeline_job_id', v_job.id,
    'agent_role', v_job.agent_role::text,
    'agent_run_id', v_run_id,
    'request_digest', v_task ->> 'request_digest',
    'model', jsonb_build_object(
      'provider', v_provider, 'model', v_model,
      'model_version', v_model_version,
      'model_version_disclosure', v_disclosure::text),
    'outcome', v_outcome
  );
end;
$$;

comment on function api.import_agent_answer(uuid, jsonb) is
  'Tar imot ett eksternt agentsvar på én agentoppgave og registrerer resultatet gjennom de samme interne skriveveiene agentkjørerne bruker (ANTIDEP_CONSTITUTION.md regel 3, 4, 7). Svaret er data: ukjente felter avvises, bindingen kontrolleres mot oppgaven slik databasen bygger den nå, og verdiene hentes ut av svaret selv — kalleren kan ikke bytte dem ut underveis. Et svar avgitt på en oppgave som siden har fått et annet grunnlag, har et annet request_digest og avvises. Modellidentiteten registreres på kjøringen og kontrolleres mot rollens registrerte semantiske modell; to roller kan strukturelt ikke dele modell, så det samme modellsvaret kan ikke både lage innholdet og kontrollere det. Importen er idempotent på jobben: det samme svaret sendt inn igjen svarer med det som allerede ble registrert, og et annet svar på en besvart jobb avvises — retries gir aldri doble kliniske artefakter. Den ordrette kontrollen av hvert kildeutdrag ligger der den alltid har ligget: i Antideps egen deterministiske kode før importen, og i den uavhengige ekstraksjonskontrollen etterpå. Krever editor-mandat. SECURITY DEFINER fordi knowledge, workflow og provenance har RLS med default deny; kalleren valideres på funksjonens eget kall (§50).';

revoke execute on function api.import_agent_answer(uuid, jsonb) from public;
grant execute on function api.import_agent_answer(uuid, jsonb) to authenticated;
