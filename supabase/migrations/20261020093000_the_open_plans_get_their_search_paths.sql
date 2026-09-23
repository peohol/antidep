-- ============================================================================
-- Migrasjon 014e — de åpne planene får søkeveiene som nå finnes
--
-- 014c og 014d gjelder nye planer av seg selv. Denne migrasjonen gjør det
-- samme for dem som alt står åpne, og den gjør det med de samme funksjonene —
-- ingen egen regel for gamle rader:
--
--   * Hvert spor føres mot registeret på nytt
--     (`workflow.mark_tracks_without_machine_path`). Et spor som har fått en
--     maskinell søkemetode, går fra no_machine_path tilbake til den maskinelle
--     køen, og får en runde åpnet i den runden planen står i. Porten holder
--     den semantiske oppgaven tilbake til runden er utført, slik at
--     vurderingen skjer på det nye grunnlaget og ikke på det gamle.
--   * Gjenbrukskontrollen blir answer_control, med begrunnelsen skrevet ut.
--   * En plan for en profil uten ett eneste søkespor — sammendragsleddet — var
--     aldri en søkeplan. Den lukkes med en begrunnelse som sier nøyaktig det, og
--     uten at noe søk erklæres gjort: sporet står som answer_control, ikke som
--     covered. En semantisk oppgave som alt sto ute for en slik plan, foreldes
--     med begrunnelsen skrevet ut, slik 013v gjorde med oppgavene den foreldet.
--
-- Sporene en redaktør allerede har registrert for hånd, står urørt: covered og
-- unavailable er historiske fakta, og de er dokumentert arbeid.
-- ============================================================================

do $$
declare
  v_actor uuid;
  v_plan workflow.monograph_search_plans;
  v_job workflow.pipeline_jobs;
  v_marked integer := 0;
  v_closed integer := 0;
  v_stale integer := 0;
  v_opened integer;
  v_remaining integer;
begin
  select a.id into v_actor
  from provenance.actors a where a.actor_key = 'human:peder-holman';

  if v_actor is null then
    raise exception using
      errcode = 'no_data_found',
      message = 'Grunnaktøren finnes ikke, og en lukking uten opphav ville vært arbeid ingen kan spore tilbake.';
  end if;

  select count(*) into v_opened from workflow.monograph_search_requests;

  for v_plan in
    select p.*
    from workflow.monograph_search_plans p
    join knowledge.monograph_editions e on e.id = p.edition_id
    where p.closed_at is null and e.superseded_at is null
    order by p.created_at
  loop
    v_marked := v_marked + workflow.mark_tracks_without_machine_path(v_plan.id);

    if not knowledge.monograph_profile_has_search_tracks(v_plan.profile_id) then
      update workflow.monograph_search_plans
      set closed_at = now(),
          closed_note = 'Ingen søkeplan: profilen gjør ingen selvstendig litteraturjakt (SOURCE_POLICY.md §4.2), og det eneste obligatoriske sporet — at hvert brukt svar fortsatt gjelder den samme avgrensningen — er svarkontrollens derivation_basis, som utføres hver gang et avledet svar registreres. Ingen søk er erklært gjort. Lukket av migrasjon 014e.',
          closed_by_actor_id = v_actor,
          paused_at = null,
          paused_reason = null
      where id = v_plan.id;

      for v_job in
        select j.*
        from workflow.pipeline_jobs j
        where j.agent_role in ('source_discovery'::provenance.agent_role,
                               'source_quality_assessment'::provenance.agent_role)
          and j.state in ('ready', 'leased')
          and j.input_manifest ->> 'search_plan_id' = v_plan.id::text
      loop
        update workflow.pipeline_jobs
        set state = 'failed',
            leased_by_agent_identity_id = null,
            lease_expires_at = null,
            lease_token = null,
            completed_at = now(),
            failure_reason = 'Foreldet av migrasjon 014e: planen var aldri en søkeplan. Profilen gjør ingen selvstendig litteraturjakt, og kontrollen den krever, utføres av svarkontrollen.'
        where id = v_job.id;

        perform workflow.record_pipeline_job_event(
          v_job.id, v_job.state, 'failed'::workflow.pipeline_job_state, v_job.attempts,
          v_actor, null,
          'Foreldet: en profil uten søkespor får ingen søkeplan (migrasjon 014c).');

        v_stale := v_stale + 1;
      end loop;

      v_closed := v_closed + 1;
    end if;
  end loop;

  select count(*) - v_opened into v_opened from workflow.monograph_search_requests;

  select count(*) into v_remaining
  from workflow.monograph_search_track_attempts a
  join workflow.monograph_search_plans p on p.id = a.plan_id
  where p.closed_at is null and a.state = 'no_machine_path';

  raise notice 'Migrasjon 014e: % spor ført mot registeret, % maskinelle runder åpnet, % planer uten søkespor lukket, % oppgaver foreldet, % spor uten maskinell søkevei igjen på åpne planer.',
    v_marked, v_opened, v_closed, v_stale, v_remaining;
end;
$$;
