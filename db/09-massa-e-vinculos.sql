-- SHAAR · vínculos manuais, TETELESTAI de chegada e autorização em massa

-- ==================================================================
-- 1. Vínculo manual entre um endereço do diretório e alguém da base
--
-- Nem sempre o casamento por endereço funciona. Luca Borges Confente esta no
-- diretorio como luca.borges@ e na base como luca.confente@ — endereco que o
-- Entra nao conhece. Sem isto, a sincronizacao criaria uma segunda pessoa.
-- Corrigir mudando o e-mail da base seria mexer num cadastro curado a mao, o
-- que esta rotina nunca faz. Entao o vinculo fica declarado aqui, com motivo.
-- ==================================================================
create table if not exists public.shaar_directory_vinculo (
  email_diretorio text primary key,
  user_id         bigint not null references public.users(id) on delete cascade,
  motivo          text   not null,
  criado_em       timestamptz not null default now()
);

comment on table public.shaar_directory_vinculo is
  'Casamentos que o endereco nao resolve sozinho: aponta um endereco do diretorio '
  'para a pessoa que ja existe na base.';

alter table public.shaar_directory_vinculo enable row level security;
revoke all on table public.shaar_directory_vinculo from public, anon, authenticated;

insert into public.shaar_directory_vinculo (email_diretorio, user_id, motivo)
select 'luca.borges@xptoinc.com.br', u.id,
       'Mesma pessoa: no diretorio e luca.borges@, na base e luca.confente@. '
       'O Entra nao conhece o segundo endereco, entao o casamento automatico falha.'
  from public.users u
 where lower(u.email) = 'luca.confente@xptoinc.com.br'
on conflict (email_diretorio) do nothing;

-- ==================================================================
-- 2. Autorização em massa — um portão para muita gente de uma vez
-- ==================================================================
create or replace function public.shaar_portao_em_massa(
  p_app_code text, p_user_ids bigint[], p_abrir boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_eu    bigint;
  v_mexi  int;
begin
  if coalesce(public.shaar_meu_nivel(), 0) < 100 then
    raise exception 'Acesso restrito ao super administrador.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.shaar_apps a where a.code = p_app_code and a.active) then
    raise exception 'Aplicacao inexistente no catalogo.' using errcode = '22023';
  end if;
  if p_user_ids is null or cardinality(p_user_ids) = 0 then
    raise exception 'Nenhuma pessoa informada.' using errcode = '22023';
  end if;

  v_eu := public.shaar_usuario_atual();

  if p_abrir then
    insert into public.shaar_gate_access (user_id, app_code, granted_by)
    select u.id, p_app_code, v_eu
      from public.users u
     where u.id = any (p_user_ids) and u.active and not u.blocked
        on conflict (user_id, app_code) do nothing;
    get diagnostics v_mexi = row_count;
  else
    -- o proprio portao nunca se fecha aqui: ninguem se tranca do lado de fora
    delete from public.shaar_gate_access
     where app_code = p_app_code
       and user_id = any (p_user_ids)
       and user_id is distinct from v_eu;
    get diagnostics v_mexi = row_count;
  end if;

  return jsonb_build_object(
    'app', p_app_code, 'abriu', p_abrir,
    'pedidas', cardinality(p_user_ids), 'mudaram', v_mexi);
end;
$$;

comment on function public.shaar_portao_em_massa is
  'Abre ou fecha um portao para varias pessoas de uma vez. Nivel 100. '
  'Quem ja estava como se pede nao conta como mudanca.';

revoke all on function public.shaar_portao_em_massa(text, bigint[], boolean) from public;
grant execute on function public.shaar_portao_em_massa(text, bigint[], boolean) to authenticated;

-- ==================================================================
-- 3. A sincronização passa a respeitar o vínculo e a abrir o TETELESTAI
--
-- Quem chega pelo diretorio precisa ter para onde ir no primeiro login. Sem
-- isto, a pessoa autentica com sucesso e encontra um salao vazio.
-- ==================================================================
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
  v_ignorados jsonb := '[]'::jsonb;
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

  select coalesce(jsonb_agg(jsonb_build_object('email', i.email, 'motivo', i.motivo)), '[]'::jsonb)
    into v_ignorados
    from public.shaar_directory_ignorar i
   where exists (select 1 from jsonb_array_elements(p_payload) e
                  where lower(e->>'email') = lower(i.email));

  insert into public.shaar_directory as d
        (entra_object_id, email, enderecos, display_name, job_title, department, presente, visto_em)
  select (e->>'oid')::uuid,
         lower(e->>'email'),
         coalesce(array(select lower(jsonb_array_elements_text(e->'enderecos'))), '{}'),
         nullif(e->>'nome',''), nullif(e->>'cargo',''), nullif(e->>'area',''),
         true, now()
    from jsonb_array_elements(p_payload) e
   where not exists (select 1 from public.shaar_directory_ignorar i
                      where lower(i.email) = lower(e->>'email'))
      on conflict (entra_object_id) do update
     set email        = excluded.email,
         enderecos    = excluded.enderecos,
         display_name = excluded.display_name,
         job_title    = excluded.job_title,
         department   = excluded.department,
         presente     = true,
         visto_em     = now();

  update public.shaar_directory
     set presente = false
   where presente
     and entra_object_id not in (
       select (e->>'oid')::uuid from jsonb_array_elements(p_payload) e
        where not exists (select 1 from public.shaar_directory_ignorar i
                           where lower(i.email) = lower(e->>'email'))
     );

  select coalesce(jsonb_agg(jsonb_build_object('email', email, 'nome', display_name)), '[]'::jsonb)
    into v_sumidos
    from public.shaar_directory where not presente;

  -- ligar: primeiro o vinculo declarado, depois qualquer endereco conhecido
  for r in
    select d.entra_object_id, d.email, d.display_name,
           coalesce(vin.user_id, u.id) as uid
      from public.shaar_directory d
      left join public.shaar_directory_vinculo vin on lower(vin.email_diretorio) = lower(d.email)
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

      -- porta de chegada: quem entra no ecossistema entra pelo TETELESTAI.
      -- Sem isto a pessoa autentica no dia seguinte e encontra o salao vazio.
      insert into public.shaar_gate_access (user_id, app_code)
      values (v_id, 'TETELESTAI')
          on conflict (user_id, app_code) do nothing;

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
    'ignorados',         v_ignorados,
    'sairam_do_criterio',v_sumidos
  );
end;
$$;

revoke all on function public.shaar_sync_diretorio(jsonb, boolean) from public, anon, authenticated;

-- as quatro pessoas criadas na primeira execucao, antes desta regra existir
insert into public.shaar_gate_access (user_id, app_code)
select d.user_id, 'TETELESTAI'
  from public.shaar_directory d
 where d.criado_por_sync and d.user_id is not null
on conflict (user_id, app_code) do nothing;
