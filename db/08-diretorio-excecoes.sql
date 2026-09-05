-- SHAAR · exceções da sincronização
--
-- Nem toda conta com licença corresponde a uma pessoa nova. Há caixas de
-- serviço e há a mesma pessoa com duas contas no diretório. Ignorar esses
-- casos dentro de um script seria esconder a decisão; aqui ela fica na base,
-- com motivo e data, e qualquer um pode auditar.

create table if not exists public.shaar_directory_ignorar (
  email      text primary key,
  motivo     text not null,
  criado_em  timestamptz not null default now()
);

comment on table public.shaar_directory_ignorar is
  'Enderecos do diretorio que a sincronizacao nao deve trazer para a base, com o motivo.';

alter table public.shaar_directory_ignorar enable row level security;
revoke all on table public.shaar_directory_ignorar from public, anon, authenticated;

insert into public.shaar_directory_ignorar (email, motivo) values
  ('sphragis@xptoinc.com.br',
   'Caixa de servico da aplicacao SPHRAGIS, nao e pessoa. Consome duas licencas — rever.'),
  ('victor.silva@xptoinc.com.br',
   'Segunda conta de Vitor Rogerio Soares Campelo da Silva, que ja esta na base como '
   'vitor.silva@xptoinc.com.br (id 15). As duas contas tem licenca. Resolver no Entra ID.')
on conflict (email) do nothing;

-- a rotina passa a respeitar a lista
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

  -- o que a lista de excecoes tira de circulacao, com o motivo, para o relatorio
  select coalesce(jsonb_agg(jsonb_build_object('email', i.email, 'motivo', i.motivo)), '[]'::jsonb)
    into v_ignorados
    from public.shaar_directory_ignorar i
   where exists (select 1 from jsonb_array_elements(p_payload) e
                  where lower(e->>'email') = lower(i.email));

  -- 1. o que veio do diretorio entra no espelho
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

  -- 2. quem estava no espelho e nao veio desta vez: saiu do criterio
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

  -- 3. ligar quem ja existe na base, por qualquer um dos enderecos conhecidos
  for r in
    select d.entra_object_id, d.email, d.display_name, u.id as uid
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
    'ignorados',         v_ignorados,
    'sairam_do_criterio',v_sumidos
  );
end;
$$;

revoke all on function public.shaar_sync_diretorio(jsonb, boolean) from public, anon, authenticated;
