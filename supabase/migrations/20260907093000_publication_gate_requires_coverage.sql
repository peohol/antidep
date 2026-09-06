-- ============================================================================
-- Publiseringsgaten leser hva kontrollene faktisk dekket
--
-- G5 krevde at den siste ekstraksjonsverifikasjonen for hvert lenket
-- evidensfunn har `outcome = 'verified'`. Den leste aldri `checked_fields`.
--
-- Det holdt så lenge en verifikasjon var noe et menneske skrev om hele
-- ekstraksjonen. Med en deterministisk verifikator som *med vilje* bedømmer en
-- delmengde — den ser verken tidspunkt, retning, effektmål,
-- availability-semantikk eller forbehold — betyr `verified` noe smalere enn
-- gaten leste det som: «alt jeg kontrollerte, stemte». En rad registrert med
-- timepoint = 12 uker mot en kilde som sier 8, eller med
-- sample_size_availability = not_reported mot et utdrag som sier «N = 48»,
-- kunne dermed passere en gate som er ment å bety at ekstraksjonen er
-- kontrollert.
--
-- Feilen er ikke i verifikatoren: `checked_fields` sier presist hva den gikk
-- gjennom (DATABASE_ARCHITECTURE.md §29). Feilen er at gaten ikke leste det.
-- Denne migrasjonen lukker kontrakten: en delkontroll kan ikke alene
-- tilfredsstille en full publiseringsgate.
--
-- `workflow.required_check_fields(...)` utleder kravet fra raden selv framfor
-- fra en liste noen må vedlikeholde: et felt kreves kontrollert når raden
-- faktisk påstår noe om det. Et felt som ikke er rapportert, påstår ingenting,
-- og kreves derfor ikke — men *at* det er ført som ikke rapportert, er selv en
-- påstand, og den dekkes av `availability_semantics`, som alltid kreves.
--
-- Fremoverskrivende: ingen merget migrasjon er endret. Gatefunksjonen
-- gjenskapes i sin helhet med ett nytt vilkår (G5b) lagt inn etter G5.
-- ============================================================================

create function workflow.required_check_fields(p_evidence_item_id uuid)
  returns workflow.evidence_check_field[]
  language sql
  stable
  set search_path = ''
as $$
  select array_remove(
    array[
      -- Alltid: raden påstår disse uansett hvordan den er fylt ut.
      'raw_extraction',
      'source_locator',
      'intervention_arm',
      'outcome',
      'reported_direction',
      -- At de øvrige feltene er ført som rapportert eller ikke rapportert, er
      -- selv en påstand om kilden, og en av de enkleste å ta feil på uten at
      -- noe tall ser galt ut.
      'availability_semantics',
      case when e.effect_measure is not null then 'effect_measure' end,
      case when e.comparator_kind <> 'none' then 'comparator_arm' end,
      case when e.population_availability = 'reported_value' then 'population' end,
      case when e.sample_size_availability = 'reported_value' then 'sample_size' end,
      case when e.timepoint_availability = 'reported_value' then 'timepoint' end,
      case when e.estimate_availability = 'reported_value' then 'estimate' end,
      case
        when e.confidence_interval_availability = 'reported_value'
        then 'confidence_interval'
      end,
      case when e.limitations_text is not null then 'limitations' end
    ]::workflow.evidence_check_field[],
    null
  )
  from knowledge.evidence_items e
  where e.id = p_evidence_item_id;
$$;

comment on function workflow.required_check_fields(uuid) is
  'Feltene et evidensfunn faktisk påstår noe om, og som til sammen må være kontrollert før funnet kan bære en publisert påstand (publiseringsgatens G5b). Utledet av raden selv framfor av en vedlikeholdt liste: et felt som ikke er rapportert, påstår ingenting og kreves ikke — men at det er ført som ikke rapportert, dekkes av availability_semantics, som alltid kreves. Én kontroll trenger ikke dekke alt; kravet gjelder unionen over funnets bekreftede kontroller, slik at flere verifikatorledd kan dele arbeidet.';

revoke all on function workflow.required_check_fields(uuid) from public;

create or replace function knowledge.assert_claim_revision_publishable(p_claim_revision_id uuid)
  returns void
  language plpgsql
  set search_path = ''
as $$
declare
  v_claim_id uuid;
  v_knowledge_type knowledge.knowledge_type;
  v_retired_at timestamptz;
  v_offenders text;
  v_latest_decision workflow.review_outcome;
  v_approved_digest text;
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
      order by ev.verified_at desc, ev.created_at desc, ev.id desc
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
  -- Kravet er derfor at unionen av `checked_fields` over funnets bekreftede
  -- kontroller dekker feltene raden påstår noe om. Unionen, ikke den siste
  -- raden: en kontroll kan dekke en delmengde, og flere verifikatorledd kan
  -- til sammen dekke resten. G5 står ved siden av og krever fortsatt at den
  -- *siste* kontrollen er en bekreftelse, slik at et senere avvik ikke kan
  -- overstyres av en tidligere delkontroll.
  select string_agg(distinct l.evidence_item_id::text, ', ' order by l.evidence_item_id::text)
    into v_offenders
  from knowledge.claim_evidence_links l
  where l.claim_revision_id = p_claim_revision_id
    and exists (
      select 1
      from unnest(workflow.required_check_fields(l.evidence_item_id)) as required(field)
      where required.field <> all (
        select distinct f.field
        from workflow.evidence_verifications ev
        cross join unnest(ev.checked_fields) as f(field)
        where ev.evidence_item_id = l.evidence_item_id
          and ev.outcome = 'verified'
      )
    );

  if v_offenders is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Evidensfunn uten fullstendig kontrollert ekstraksjon: %s.', v_offenders
      ),
      hint = 'De registrerte kontrollene dekker ikke alle feltene funnet påstår noe om. workflow.required_check_fields(evidence_item_id) viser hva som kreves; en delkontroll kan ikke alene tilfredsstille publiseringsgaten (ANTIDEP_CONSTITUTION.md §11, DATABASE_ARCHITECTURE.md §29).';
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
      order by rd.decided_at desc, rd.created_at desc, rd.id desc
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

  -- G9: den gjeldende claim-verifikasjonen bekrefter påstanden.
  if (
    select cv.outcome
    from workflow.claim_verifications cv
    where cv.claim_revision_id = p_claim_revision_id
    order by cv.verified_at desc, cv.created_at desc, cv.id desc
    limit 1
  ) <> 'verified' then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Den gjeldende claim-verifikasjonen for revisjon %L konkluderer ikke med verified.',
        p_claim_revision_id
      ),
      hint = 'Den siste registrerte kontrollen er den gjeldende. Rett påstanden i en ny revisjon og få den kontrollert på nytt; en tidligere bekreftelse opphever ikke et senere avvik.';
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

  -- G11: menneskelig faglig godkjenning finnes.
  select rd.decision, rd.approved_evidence_set_digest
    into v_latest_decision, v_approved_digest
  from workflow.review_decisions rd
  where rd.claim_revision_id = p_claim_revision_id
    and rd.review_type = 'publication_approval'
  order by rd.decided_at desc, rd.created_at desc, rd.id desc
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

comment on function knowledge.assert_claim_revision_publishable(uuid) is
  'Publiseringsgaten. Uendret fra migrasjon 20260819210000 bortsett fra G5b, som krever at unionen av checked_fields over funnets bekreftede ekstraksjonsverifikasjoner dekker feltene raden påstår noe om (workflow.required_check_fields). Uten det kunne en kontroll som med vilje lar felter stå ukontrollert, alene tilfredsstille en gate som er ment å bety at ekstraksjonen er kontrollert.';
