-- SHAAR · espelho do diretório corporativo
--
-- O Entra ID diz quem a pessoa é; a base das microaplicações diz o que ela
-- acessa. As duas listas precisam apontar para as mesmas pessoas, senão o
-- login único leva gente a lugar nenhum.
--
-- Este arquivo cria o espelho e a rotina que o mantém em dia. O critério de
-- quem entra no espelho é decidido fora, por quem chama a rotina; hoje é
-- "conta ativa, com licença do Microsoft 365 e endereço @xptoinc.com.br".
--
-- Duas linhas que a sincronização NÃO cruza, de propósito:
--   · não altera pessoa que já existe na base — divergência vira relatório,
--     nunca UPDATE silencioso num cadastro que alguém curou à mão;
--   · não abre portão nenhum. Criar a pessoa e dar-lhe acesso são decisões
--     diferentes, e a segunda é do administrador.

-- Perfil de chegada: existe para satisfazer a obrigatoriedade de profile_id
-- sem conceder nada. Quem chega por sincronização fica aqui até alguém
-- decidir o perfil de verdade.
insert into public.profiles (name, description, level, active, is_system)
select 'SEM PERFIL', 'Perfil de chegada da sincronizacao com o diretorio. Nao concede nada.', 0, true, true
 where not exists (select 1 from public.profiles where name = 'SEM PERFIL');

create table if not exists public.shaar_directory (
  entra_object_id uuid primary key,
  email           text        not null,
  enderecos       text[]      not null default '{}',
  display_name    text,
  job_title       text,
  department      text,
  presente        boolean     not null default true,   -- apareceu na ultima sincronizacao
  user_id         bigint      references public.users(id) on delete set null,
  primeira_vez    timestamptz not null default now(),
  visto_em        timestamptz not null default now(),
  criado_por_sync boolean     not null default false
);

comment on table public.shaar_directory is
  'Espelho do diretorio corporativo: uma linha por conta do Entra ID elegivel, '
  'ligada a linha correspondente de public.users quando existe.';

create unique index if not exists shaar_directory_email on public.shaar_directory(lower(email));
create index if not exists shaar_directory_user on public.shaar_directory(user_id);

alter table public.shaar_directory enable row level security;
revoke all on table public.shaar_directory from public, anon, authenticated;

-- ------------------------------------------------------------------
-- A rotina.
--   p_payload  · array json vindo do Microsoft Graph, ja filtrado
--   p_criar    · false apenas simula e devolve o que faria (padrao)
-- ------------------------------------------------------------------
create or replace function public.shaar_sync_diretorio(p_payload jsonb, p_criar boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_perfil    bigint;
  v_criados   jsonb := '[]'::jsonb;
  v_ligados   jsonb := '[]'::jsonb;
  v_sumidos   jsonb := '[]'::jsonb;
  v_sem_par   jsonb := '[]'::jsonb;
  r           record;
  v_id        bigint;
begin
  if jsonb_typeof(p_payload) <> 'array' then
    raise exception 'payload precisa ser um array json' using errcode = '22023';
  end if;
  if jsonb_array_length(p_payload) = 0 then
    raise exception 'payload vazio — recusando para nao marcar o diretorio inteiro como ausente'
      using errcode = '22023';
  end if;

  select id into v_perfil from public.profiles where name = 'SEM PERFIL' limit 1;

  -- 1. o que veio do diretorio entra no espelho
  insert into public.shaar_directory as d
        (entra_object_id, email, enderecos, display_name, job_title, department, presente, visto_em)
  select (e->>'oid')::uuid,
         lower(e->>'email'),
         coalesce(array(select lower(jsonb_array_elements_text(e->'enderecos'))), '{}'),
         nullif(e->>'nome',''), nullif(e->>'cargo',''), nullif(e->>'area',''),
         true, now()
    from jsonb_array_elements(p_payload) e
      on conflict (entra_object_id) do update
     set email        = excluded.email,
         enderecos    = excluded.enderecos,
         display_name = excluded.display_name,
         job_title    = excluded.job_title,
         department   = excluded.department,
         presente     = true,
         visto_em     = now();

  -- 2. quem estava no espelho e nao veio desta vez: saiu do criterio
  --    (perdeu a licenca, foi desativado, mudou de endereco)
  update public.shaar_directory
     set presente = false
   where presente
     and entra_object_id not in (
       select (e->>'oid')::uuid from jsonb_array_elements(p_payload) e
     );

  select coalesce(jsonb_agg(jsonb_build_object('email', email, 'nome', display_name)), '[]'::jsonb)
    into v_sumidos
    from public.shaar_directory where not presente;

  -- 3. ligar quem ja existe na base, por qualquer um dos enderecos conhecidos
  for r in
    select d.entra_object_id, d.email, d.enderecos, d.display_name, u.id as uid
      from public.shaar_directory d
      left join lateral (
        select u.id from public.users u
         where lower(u.email) = any (d.enderecos)
         order by u.active desc, u.id
         limit 1
      ) u on true
     where d.presente and d.user_id is null
  loop
    if r.uid is not null then
      update public.shaar_directory set user_id = r.uid where entra_object_id = r.entra_object_id;
      v_ligados := v_ligados || jsonb_build_object('email', r.email, 'nome', r.display_name, 'user_id', r.uid);
    else
      v_sem_par := v_sem_par || jsonb_build_object('email', r.email, 'nome', r.display_name);
    end if;
  end loop;

  -- 4. criar quem nao tem par — so quando pedido
  if p_criar then
    for r in
      select d.entra_object_id, d.email, d.display_name
        from public.shaar_directory d
       where d.presente and d.user_id is null
       order by d.email
    loop
      insert into public.users (email, full_name, profile_id, login_method, user_kind, active)
      values (r.email, coalesce(nullif(r.display_name,''), r.email), v_perfil, 'entra', 'real', true)
      returning id into v_id;

      update public.shaar_directory
         set user_id = v_id, criado_por_sync = true
       where entra_object_id = r.entra_object_id;

      v_criados := v_criados || jsonb_build_object('email', r.email, 'nome', r.display_name, 'user_id', v_id);
    end loop;
    v_sem_par := '[]'::jsonb;
  end if;

  return jsonb_build_object(
    'quando',            now(),
    'aplicou',           p_criar,
    'no_diretorio',      jsonb_array_length(p_payload),
    'ligados_agora',     v_ligados,
    'criados',           v_criados,
    'sem_par_na_base',   v_sem_par,
    'sairam_do_criterio',v_sumidos
  );
end;
$$;

comment on function public.shaar_sync_diretorio is
  'Espelha o diretorio corporativo e, quando p_criar, cria na base quem falta. '
  'Nunca altera cadastro existente nem abre portao.';

revoke all on function public.shaar_sync_diretorio(jsonb, boolean) from public, anon, authenticated;

-- ------------------------------------------------------------------
-- O que o administrador precisa enxergar depois de sincronizar
-- ------------------------------------------------------------------
create or replace view public.shaar_divergencias as
  -- pessoa no diretorio, sem cadastro na base
  select 'sem cadastro na base'::text as situacao, d.email, d.display_name as nome,
         null::bigint as user_id, d.job_title as cargo
    from public.shaar_directory d
   where d.presente and d.user_id is null
  union all
  -- pessoa cadastrada e ativa, que nao esta no criterio do diretorio
  select 'sem conta no diretorio', u.email, u.full_name, u.id, p.name::text
    from public.users u
    left join public.profiles p on p.id = u.profile_id
   where u.active and not u.blocked and u.user_kind = 'real'
     and not exists (select 1 from public.shaar_directory d
                      where d.presente and d.user_id = u.id)
  union all
  -- pessoa que saiu do criterio mas continua ativa na base
  select 'saiu do diretorio, ativa na base', u.email, u.full_name, u.id, p.name::text
    from public.shaar_directory d
    join public.users u on u.id = d.user_id and u.active and not u.blocked
    left join public.profiles p on p.id = u.profile_id
   where not d.presente
  union all
  -- chegou pela sincronizacao e ainda espera perfil
  select 'aguardando perfil', u.email, u.full_name, u.id, p.name::text
    from public.shaar_directory d
    join public.users u on u.id = d.user_id
    left join public.profiles p on p.id = u.profile_id
   where d.presente and p.name = 'SEM PERFIL';

comment on view public.shaar_divergencias is
  'O que nao bate entre o diretorio corporativo e a base das microaplicacoes.';

create or replace function public.shaar_ver_divergencias()
returns setof public.shaar_divergencias
language sql stable security definer set search_path = public as $$
  select * from public.shaar_divergencias
   where coalesce(public.shaar_meu_nivel(), 0) >= 100
   order by situacao, email;
$$;

revoke all on function public.shaar_ver_divergencias() from public;
grant execute on function public.shaar_ver_divergencias() to authenticated;
