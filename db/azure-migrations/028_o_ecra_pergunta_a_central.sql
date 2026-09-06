-- =====================================================================
-- O ecrã pergunta à Central — e deixa de perguntar ao perfil
-- =====================================================================
--
-- O RLS das aplicações já obedece à Central (has_permission delega em
-- shaar_pode para os códigos herdados; as novas políticas chamam shaar_pode
-- directamente). Faltava o outro lado do vidro: os frontends ainda montam
-- menus e botões lendo `profile_permissions` por `profile_id` — perfil como
-- autoridade, exactamente o que docs/PERMISSOES-PARA-AGENTES.md proíbe.
-- O sintoma é a UI divergir das decisões: uma concessão individual nova não
-- acende o menu; uma negação individual deixa o menu aceso e as acções a
-- falhar no RLS.
--
-- Esta migração dá aos ecrãs uma pergunta certa para fazer: "que permissões
-- EU tenho nesta aplicação?" — respondida pela própria shaar_pode, código a
-- código, para a pessoa corrente. Nada de novo decide aqui; isto só LISTA o
-- que a Central já decidiu, para a UI mostrar os controlos certos.
--
-- Nota sobre alçada: shaar_pode é chamada sem contexto, e dimensão declarada
-- e ausente NEGA (falha fechado). Logo, permissões com escopo_dimensoes só
-- aparecem nesta lista quando valem incondicionalmente; o ecrã que precisa
-- de testar um limite concreto continua a chamar shaar_pode com o contexto.
-- =====================================================================

create or replace function public.shaar_minhas_permissoes(p_app text)
returns table (code text)
language sql stable security definer set search_path = public
as $fn$
  select sp.code
    from public.shaar_permission sp
   where sp.app_code = p_app
     and sp.active
     and public.shaar_pode(sp.app_code, sp.code)
   order by sp.code;
$fn$;

comment on function public.shaar_minhas_permissoes(text) is
  'Códigos de permissão da aplicação que a pessoa corrente tem, segundo a '
  'Central (shaar_pode, sem contexto de alçada). Para a UI montar menus e '
  'botões — a decisão de cada acto continua no RLS/RPC.';

revoke all on function public.shaar_minhas_permissoes(text) from public;
grant execute on function public.shaar_minhas_permissoes(text) to authenticated;

-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
-- Fumo: responde sem rebentar. Corre como postgres (shaar_usuario_atual é
-- nulo), portanto o esperado é zero linhas — o que se testa é que a listagem
-- não levanta excepção em nenhuma aplicação do catálogo.
select 'shaar_minhas_permissoes responde: ' ||
       string_agg(d.app_code || '=' || d.n, ', ' order by d.app_code)
  from (
    select a.code as app_code,
           (select count(*) from public.shaar_minhas_permissoes(a.code))::text as n
      from public.shaar_apps a
  ) d;

-- E devolve subconjunto do catálogo activo (nunca inventa códigos).
select 'codigos fora do catalogo: ' || count(*)::text
  from (
    select a.code as app_code, m.code
      from public.shaar_apps a,
           lateral public.shaar_minhas_permissoes(a.code) m
  ) x
 where not exists (
   select 1 from public.shaar_permission sp
    where sp.app_code = x.app_code and sp.code = x.code and sp.active
 );
