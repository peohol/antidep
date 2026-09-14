-- Antidep 2: the public read model is a read-only projection of published knowledge.
begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

select set_eq(
  $$select c.relname || ':' || c.relkind::text
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'api' and c.relkind in ('r','p','v','m','f')$$,
  $$values ('published_drugs:v'), ('published_claims:v'), ('published_claim_evidence:v'),
           ('my_actor:v'), ('my_roles:v'), ('editor_sources:v'),
           ('editor_source_versions:v'), ('editor_drugs:v'), ('editor_outcomes:v'),
           ('editor_populations:v'), ('editor_evidence_items:v')$$,
  'api inventory is explicit and unchanged by the reset'
);

select is_empty(
  $$select t.view_name, r.role_name, p.privilege
    from (values ('api.published_drugs'), ('api.published_claims'),
                 ('api.published_claim_evidence')) as t(view_name)
    cross join (values ('anon'), ('authenticated'), ('service_role'), ('public')) as r(role_name)
    cross join (values ('select'), ('insert'), ('update'), ('delete'), ('truncate'),
                       ('references'), ('trigger')) as p(privilege)
    where has_table_privilege(r.role_name, t.view_name, p.privilege)
      and not (p.privilege = 'select' and r.role_name in ('anon','authenticated'))$$,
  'published views grant only SELECT to anon and authenticated'
);

select is_empty(
  $$select t.view_name, r.role_name
    from (values ('api.published_drugs'), ('api.published_claims'),
                 ('api.published_claim_evidence')) as t(view_name)
    cross join (values ('anon'), ('authenticated')) as r(role_name)
    where not has_table_privilege(r.role_name, t.view_name, 'select')$$,
  'both Data API roles can read all published views'
);

select is_empty(
  $$select n.nspname, c.relname, r.role_name, p.privilege
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    cross join (values ('anon'), ('authenticated')) as r(role_name)
    cross join (values ('insert'), ('update'), ('delete'), ('truncate')) as p(privilege)
    where n.nspname in ('catalog','knowledge','workflow','provenance','audit')
      and c.relkind in ('r','p')
      and has_table_privilege(r.role_name, format('%I.%I', n.nspname, c.relname), p.privilege)$$,
  'client roles cannot write canonical tables'
);

set local role anon;
select is((select count(*) from api.published_claims), 0::bigint,
          'fresh Antidep 2 exposes no published claims');
select is((select count(*) from api.published_claim_evidence), 0::bigint,
          'fresh Antidep 2 exposes no published evidence');
reset role;

set local role authenticated;
select is((select count(*) from api.published_claims), 0::bigint,
          'authenticated sees the same empty published claim set');
select is((select count(*) from api.published_claim_evidence), 0::bigint,
          'authenticated sees the same empty published evidence set');
reset role;

select * from finish();
rollback;
