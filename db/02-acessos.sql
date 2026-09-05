-- SHAAR · quem pode abrir qual portão
--
-- O SHAAR NÃO cria um sistema de permissão paralelo. Cada aplicação continua
-- dona da sua autorização, exatamente como é hoje. Esta view apenas LÊ as
-- fontes existentes e responde a uma única pergunta: quais aplicações esta
-- pessoa pode abrir, e com que papel.
--
-- Hoje o ecossistema usa dois mecanismos diferentes, e ambos são respeitados:
--
--   a) RBAC central do TETELESTAI — profiles → profile_permissions →
--      permissions.module. Usado por MANNA e FAITH (module 'oportunidades').
--   b) Tabela própria da aplicação — tikkun_user_roles, bnei_user_roles,
--      jireh_user_permissions, merkavah_memberships, sphragis_perfis_assinatura.
--
-- Acrescentar uma aplicação nova = acrescentar um bloco no union.

create or replace view public.shaar_user_apps as
with concessoes as (

  -- TETELESTAI: ter perfil ativo já é o acesso à plataforma-mãe
  select u.id as user_id, 'TETELESTAI'::text as app_code,
         p.name::text as role, 'perfil'::text as fonte
    from public.users u
    join public.profiles p on p.id = u.profile_id and p.active

  union all
  -- MANNA: RBAC central, módulo MANNA
  select distinct u.id, 'MANNA', 'Conforme perfil', 'rbac'
    from public.users u
    join public.profile_permissions pp on pp.profile_id = u.profile_id
    join public.permissions pe on pe.id = pp.permission_id
   where pe.active and pe.module = 'MANNA'

  union all
  -- FAITH: RBAC central, módulo 'oportunidades'
  select distinct u.id, 'FAITH', 'Conforme perfil', 'rbac'
    from public.users u
    join public.profile_permissions pp on pp.profile_id = u.profile_id
    join public.permissions pe on pe.id = pp.permission_id
   where pe.active and pe.module = 'oportunidades'

  union all
  -- JIREH: concessão nominal
  select distinct j.user_id, 'JIREH', 'Conforme concessão', 'tabela'
    from public.jireh_user_permissions j

  union all
  -- TIKKUN: papel próprio
  select t.user_id, 'TIKKUN', t.role::text, 'tabela'
    from public.tikkun_user_roles t

  union all
  -- BNEI YISRAEL: papel próprio
  select b.user_id, 'BNEI', b.role::text, 'tabela'
    from public.bnei_user_roles b

  union all
  -- MERKAVAH: vínculo ativo com um tenant
  select m.user_id, 'MERKAVAH', m.role::text, 'tabela'
    from public.merkavah_memberships m
   where m.active

  union all
  -- SPHRAGIS: possuir perfil de assinatura
  select s.user_id, 'SPHRAGIS', 'Signatário(a)', 'tabela'
    from public.sphragis_perfis_assinatura s
)
select
  u.id                                as user_id,
  u.email,
  u.full_name,
  u.user_kind,
  a.code                              as app_code,
  a.name                              as app_name,
  a.description                       as app_description,
  a.url                               as app_url,
  a.sort_order,
  -- um papel por aplicação: o primeiro em ordem alfabética quando há vários
  min(c.role)                         as role,
  min(c.fonte)                        as fonte
from public.users u
join concessoes c   on c.user_id = u.id
join public.shaar_apps a on a.code = c.app_code and a.active
where u.active
  and not u.blocked
group by u.id, u.email, u.full_name, u.user_kind,
         a.code, a.name, a.description, a.url, a.sort_order;

comment on view public.shaar_user_apps is
  'Leitura agregada: quais aplicações cada pessoa pode abrir e com que papel. '
  'Não concede nada — apenas reflete as autorizações que já existem em cada aplicação.';

-- Identidade do requisitante.
--
-- A autenticação tem dois caminhos e a resolução precisa servir aos dois:
--   Entra ID  — quem existe no tenant entra por lá; chega o e-mail no claim.
--   Credencial local — terceiros e quem não está no Entra.
--
-- Em ambos os casos a pessoa é a MESMA linha de public.users. O e-mail é a
-- chave que une os dois caminhos; auth_user_id continua valendo para quem
-- autenticou pelo Supabase Auth.
create or replace function public.shaar_usuario_atual()
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select u.id
    from public.users u
   where u.active and not u.blocked
     and (
          u.auth_user_id = auth.uid()
       or lower(u.email) = lower(coalesce(
            nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'email', ''),
            nullif(current_setting('request.jwt.claims', true)::jsonb
                     -> 'user_metadata' ->> 'email', ''),
            ''))
     )
   limit 1;
$$;

comment on function public.shaar_usuario_atual is
  'Resolve quem esta pedindo, venha de Entra ID ou de credencial local. '
  'O e-mail e a chave comum aos dois caminhos de autenticacao.';

-- O hub consulta apenas as próprias linhas. A regra "o que não é autorizado
-- não aparece" fica garantida no banco, não no front.
create or replace function public.shaar_minhas_apps()
returns setof public.shaar_user_apps
language sql
stable
security definer
set search_path = public
as $$
  select *
    from public.shaar_user_apps
   where user_id = public.shaar_usuario_atual()
   order by sort_order;
$$;

comment on function public.shaar_minhas_apps is
  'Aplicações que o usuário autenticado pode abrir. Base do painel do SHAAR. '
  'A autorizacao vem sempre da base do TETELESTAI — o Entra ID autentica, nunca autoriza.';

revoke all on function public.shaar_usuario_atual() from public;
revoke all on function public.shaar_minhas_apps() from public;
grant execute on function public.shaar_usuario_atual() to authenticated;
grant execute on function public.shaar_minhas_apps() to authenticated;
