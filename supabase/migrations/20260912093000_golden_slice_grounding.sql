-- ============================================================================
-- Migrasjon 003c — golden slicen får sin kildeforankring
--
-- Migrasjon 005u innførte knowledge.evidence_field_groundings, og 005v gjorde
-- komplett forankring til et krav for enhver ny agentekstraksjon. De to
-- evidensfunnene fra migrasjon 003 er eldre enn begge, og står derfor uten
-- forankring. Kontrolløkten stopper på nettopp den tilstanden og ber om ny
-- ekstraksjon — som er riktig oppførsel, men som gjør at golden slicen ikke kan
-- kontrolleres av et menneske i det hele tatt.
--
-- ----------------------------------------------------------------------------
-- Hvorfor forankringen skrives her, og hva den er
--
-- Utdragene er ikke gjettet ut av `raw_extraction` av kode. De er ført opp her,
-- felt for felt, med den samme forfatterstatusen de to seedede radene selv har:
-- migrasjon 003 er redigert testdata for golden slicen, skrevet ut i klartekst
-- og etterprøvbar mot kilden ved lesing. Forankringen arver nøyaktig den
-- statusen — verken mer eller mindre.
--
-- Hvert utdrag er en sammenhengende del av `raw_extraction`, som selv er
-- ordrett fra de MEDLINE-postene kildeversjonene er hashet fra. Den
-- deterministiske verifikatoren kan derfor bevise hvert av dem mot den
-- registrerte kildeversjonen, og gjør det (`src/agents/extraction-checks.ts`).
--
-- Dette er ikke en generell tilbakefylling. Ingen annen rad får forankring av
-- denne migrasjonen, og det finnes ingen funksjon som kan gi noen rad det:
-- veien inn er api.register_agent_extraction, i samme transaksjon som
-- ekstraksjonen. Et funn Antidep ikke kan forankre, skal stoppe kontrolløkten
-- (ANTIDEP_CONSTITUTION.md §6, §8, §11).
--
-- ----------------------------------------------------------------------------
-- Kildeversjonene får sin representasjonstype
--
-- Begge er hentet med EUtils efetch, som gir MEDLINE-posten: tittel, forfattere
-- og sammendrag, ikke fulltekstartikkelen. `abstract` er derfor den riktige
-- verdien, og den er en opplysning kontrolløren skal ha (EVIDENCE_PIPELINE.md
-- §13): et sammendrag kan ikke bære alt en fulltekst kan.
--
-- Bare disse to radene røres, og bare der verdien er NULL. En kildeversjon som
-- allerede sier hva den er, skal ikke kunne omskrives av en migrasjon.
--
-- ----------------------------------------------------------------------------
-- Hva som IKKE endres
--
-- Ingen ekstraksjonsverdi, ingen `content_hash`, ingen `raw_extraction`, ingen
-- constraint, trigger, policy eller grant. `content_hash` beregnes av
-- ekstraksjonens egne kolonner og er derfor uendret; grunnlagsavtrykket
-- `workflow.evidence_extraction_digest(uuid)` dekker forankringen og *endrer*
-- seg, som det skal — en kontrolløkt som var i gang, skal måtte se det nye
-- grunnlaget.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §4, §6, §8, §11, §12
--   docs/DATABASE_ARCHITECTURE.md §18, §19, §20, §43
--   docs/EVIDENCE_PIPELINE.md §13
--   docs/MVP_IMPLEMENTATION_PLAN.md §12, §20, §29
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Representasjonstypen på de to seedede kildeversjonene
-- ----------------------------------------------------------------------------
update knowledge.source_versions sv
set representation = 'abstract'
where sv.representation is null
  and sv.source_id in (
    select si.source_id
    from knowledge.source_identifiers si
    where si.identifier_system = 'pmid'
      and si.identifier_value in ('11105740', '15697327')
  );

-- ----------------------------------------------------------------------------
-- 2. Forankringen, felt for felt
--
-- created_by_actor_id er evidensfunnets egen skaper. Det er ikke et valg her:
-- den sammensatte fremmednøkkelen evidence_field_groundings_item_fkey låser de
-- to sammen, slik at forankringen aldri kan tilskrives noen annen enn den som
-- laget ekstraksjonen.
-- ----------------------------------------------------------------------------
insert into knowledge.evidence_field_groundings
  (evidence_item_id, created_by_actor_id, check_field,
   source_excerpt, source_locator, justification)
select
  e.id,
  e.created_by_actor_id,
  g.check_field::workflow.evidence_check_field,
  g.source_excerpt,
  g.source_locator,
  g.justification
from (values
  -- =========================================================================
  -- Sertralin × vektendring (PMID 11105740)
  -- =========================================================================
  ('11105740', 'intervention_arm',
   'Patients (N = 284) with major depressive disorder (DSM-IV) were randomly assigned to double-blind treatment with fluoxetine (N = 92), sertraline, (N = 96), or paroxetine (N = 96) for a total of 26 to 32 weeks.',
   'Sammendrag (MEDLINE-post), avsnittet METHOD',
   'Sertralin er én av de tre armene metodeavsnittet navngir. Funnet gjelder denne armen alene, ikke sammenligningen mellom dem.'),

  ('11105740', 'outcome',
   'The mean percent change in weight was compared for each group, as was the number of patients who had > or = 7% weight increase from baseline.',
   'Sammendrag (MEDLINE-post), avsnittet METHOD',
   'Endepunktet er vektendring, oppgitt av kilden som gjennomsnittlig prosentvis endring fra baseline.'),

  ('11105740', 'population',
   'Patients (N = 284) with major depressive disorder (DSM-IV) were randomly assigned to double-blind treatment with fluoxetine (N = 92), sertraline, (N = 96), or paroxetine (N = 96) for a total of 26 to 32 weeks.',
   'Sammendrag (MEDLINE-post), avsnittet METHOD',
   'Populasjonen er pasienter med depressiv lidelse etter DSM-IV, slik metodeavsnittet beskriver dem.'),

  ('11105740', 'sample_size',
   'Patients (fluoxetine, N = 44; sertraline, N = 48; paroxetine, N = 47) who completed the trial were included in these analyses.',
   'Sammendrag (MEDLINE-post), avsnittet RESULTS',
   'Antallet 48 er sertralinarmen, og det er de som fullførte og inngår i analysen — ikke de 96 som ble randomisert.'),

  ('11105740', 'timepoint',
   'Patients (N = 284) with major depressive disorder (DSM-IV) were randomly assigned to double-blind treatment with fluoxetine (N = 92), sertraline, (N = 96), or paroxetine (N = 96) for a total of 26 to 32 weeks.',
   'Sammendrag (MEDLINE-post), avsnittet METHOD',
   'Behandlingsvarigheten er 26 til 32 uker, som er de 182 til 224 dagene funnet er registrert med.'),

  ('11105740', 'reported_direction',
   'Paroxetine-treated patients experienced a significant weight increase, fluoxetine-treated patients had a modest but nonsignificant weight decrease, and patients treated with sertraline had a modest but nonsignificant weight increase.',
   'Sammendrag (MEDLINE-post), avsnittet RESULTS',
   'Retningen for sertralinarmen er en økning. Setningen navngir alle tre armene, og bare den siste delen gjelder dette funnet.'),

  ('11105740', 'effect_measure',
   'The mean percent change in weight was compared for each group, as was the number of patients who had > or = 7% weight increase from baseline.',
   'Sammendrag (MEDLINE-post), avsnittet METHOD',
   'Effektmålet er gjennomsnittlig endring innen hver arm, ikke en forskjell mellom armene.'),

  ('11105740', 'availability_semantics',
   'Paroxetine-treated patients experienced a significant weight increase, fluoxetine-treated patients had a modest but nonsignificant weight decrease, and patients treated with sertraline had a modest but nonsignificant weight increase.',
   'Sammendrag (MEDLINE-post), avsnittet RESULTS',
   'Resultatavsnittet karakteriserer endringen uten å oppgi noen tallverdi eller noe konfidensintervall. Estimatet og intervallet er derfor ført som ikke rapportert, ikke som null.'),

  ('11105740', 'limitations',
   'Patients (fluoxetine, N = 44; sertraline, N = 48; paroxetine, N = 47) who completed the trial were included in these analyses.',
   'Sammendrag (MEDLINE-post), avsnittet RESULTS',
   'Forbeholdet om frafallsskjevhet hviler på at bare de som fullførte inngår: 48 av de 96 randomiserte i sertralinarmen.'),

  -- =========================================================================
  -- Mirtazapin × vektendring (PMID 15697327)
  -- =========================================================================
  ('15697327', 'intervention_arm',
   'In this double-blind study, 297 severely depressed patients were randomised to receive mirtazapine 15-60 mg/day (n = 147) or fluoxetine 20-40 mg/day (n = 152) for 8 weeks.',
   'Sammendrag (MEDLINE-post), avsnittet METHODS',
   'Mirtazapin er den ene av de to armene metodeavsnittet navngir. Funnet gjelder denne armen alene.'),

  ('15697327', 'outcome',
   'mirtazapine-treated patients experienced a mean weight gain of 0.8 +/- 2.7 kg compared with a mean decrease in weight of 0.4 +/- 2.1 kg for fluoxetine-treated patients',
   'Sammendrag (MEDLINE-post), avsnittet RESULTS',
   'Endepunktet er vektendring, oppgitt av kilden i kilogram.'),

  ('15697327', 'timepoint',
   'In this double-blind study, 297 severely depressed patients were randomised to receive mirtazapine 15-60 mg/day (n = 147) or fluoxetine 20-40 mg/day (n = 152) for 8 weeks.',
   'Sammendrag (MEDLINE-post), avsnittet METHODS',
   'Behandlingsvarigheten er åtte uker, som er de 56 dagene funnet er registrert med.'),

  ('15697327', 'reported_direction',
   'mirtazapine-treated patients experienced a mean weight gain of 0.8 +/- 2.7 kg',
   'Sammendrag (MEDLINE-post), avsnittet RESULTS',
   'Retningen for mirtazapinarmen er en økning.'),

  ('15697327', 'effect_measure',
   'mirtazapine-treated patients experienced a mean weight gain of 0.8 +/- 2.7 kg',
   'Sammendrag (MEDLINE-post), avsnittet RESULTS',
   'Effektmålet er gjennomsnittlig vektendring innen mirtazapinarmen, ikke en forskjell mellom armene.'),

  ('15697327', 'estimate',
   'mirtazapine-treated patients experienced a mean weight gain of 0.8 +/- 2.7 kg',
   'Sammendrag (MEDLINE-post), avsnittet RESULTS',
   'Estimatet 0,8 kg er den gjennomsnittlige vektendringen i mirtazapinarmen. Tallet 2,7 er standardavviket og ikke en intervallgrense.'),

  ('15697327', 'availability_semantics',
   'Both agents were generally well tolerated but mirtazapine-treated patients experienced a mean weight gain of 0.8 +/- 2.7 kg compared with a mean decrease in weight of 0.4 +/- 2.1 kg for fluoxetine-treated patients (p < 0.001).',
   'Sammendrag (MEDLINE-post), avsnittet RESULTS',
   'Kilden oppgir spredningen som standardavvik og ikke som konfidensintervall, og oppgir ingen N for vektanalysen. Begge er derfor ført uten verdi, med hver sin begrunnelse.'),

  ('15697327', 'limitations',
   'Both agents were generally well tolerated but mirtazapine-treated patients experienced a mean weight gain of 0.8 +/- 2.7 kg compared with a mean decrease in weight of 0.4 +/- 2.1 kg for fluoxetine-treated patients (p < 0.001).',
   'Sammendrag (MEDLINE-post), avsnittet RESULTS',
   'Forbeholdet hviler på at spredningen er et standardavvik, og at p-verdien gjelder sammenligningen mot fluoksetin — ikke den armspesifikke endringen alene.')
) as g(pmid, check_field, source_excerpt, source_locator, justification)
-- Radene identifiseres av kildens PubMed-ID, ikke av en id: id-ene i migrasjon
-- 003 er databasegenererte, og en migrasjon som navnga dem, ville truffet en
-- annen rad i hver database.
join knowledge.source_identifiers si
  on si.identifier_system = 'pmid' and si.identifier_value = g.pmid
join knowledge.evidence_items e on e.source_id = si.source_id
-- Idempotent: en rad som allerede har forankring for feltet, røres ikke.
where not exists (
  select 1 from knowledge.evidence_field_groundings x
  where x.evidence_item_id = e.id
    and x.check_field = g.check_field::workflow.evidence_check_field
);

-- ----------------------------------------------------------------------------
-- 3. Vakten: forankringen skal dekke nøyaktig det kontrolløkten spør om
--
-- En stille delvis forankring ville vært verre enn ingen: kontrolløkten ville
-- stoppet på et hull ingen visste om. Migrasjonen feiler heller.
-- ----------------------------------------------------------------------------
do $$
declare
  v_item uuid;
  v_missing text;
  v_count integer := 0;
begin
  for v_item in
    select e.id
    from knowledge.evidence_items e
    join knowledge.source_identifiers si on si.source_id = e.source_id
    where si.identifier_system = 'pmid'
      and si.identifier_value in ('11105740', '15697327')
  loop
    v_count := v_count + 1;

    select string_agg(f.field::text, ', ')
      into v_missing
    from unnest(workflow.semantic_check_fields(v_item)) as f(field)
    where f.field <> all (workflow.grounded_check_fields(v_item));

    if v_missing is not null then
      raise exception
        'Evidensfunnet % mangler fortsatt forankring for: %. Migrasjonen skal forankre hvert semantiske felt.',
        v_item, v_missing;
    end if;
  end loop;

  -- En stille null-treffer ville sett ut som suksess. Golden slicen har to funn.
  if v_count <> 2 then
    raise exception
      'Fant % evidensfunn for golden slicens to PubMed-ID-er, ikke 2.', v_count;
  end if;
end $$;

do $$
declare
  v_unset integer;
begin
  select count(*)
    into v_unset
  from knowledge.evidence_items e
  join knowledge.source_versions sv on sv.id = e.source_version_id
  join knowledge.source_identifiers si on si.source_id = e.source_id
  where si.identifier_system = 'pmid'
    and si.identifier_value in ('11105740', '15697327')
    and sv.representation is null;

  if v_unset > 0 then
    raise exception
      '% av golden slicens kildeversjoner mangler fortsatt representasjonstype.', v_unset;
  end if;
end $$;
