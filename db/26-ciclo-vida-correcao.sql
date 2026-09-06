-- =====================================================================
-- Ciclo de vida — correcção às colunas reais do directório
-- =====================================================================
--
-- A primeira versão adivinhou nomes de colunas que não existem
-- (`departamento`, `email_secundario`, `email_principal`). As reais são:
--
--   shaar_directory          email · display_name · job_title · department ·
--                            presente · user_id
--   shaar_directory_vinculo  email_diretorio · user_id
--   shaar_directory_ignorar  email
--
-- Vale registar porque é que a mudança de área precisava de mais do que uma
-- correcção de nomes. A ideia inicial era comparar o directório com
-- `org_departments` — mas essa tabela está vazia e nenhuma pessoa tem
-- `department_id`, portanto a comparação nunca dispararia e a transição
-- ficaria por implementar sem ninguém dar por isso.
--
-- Em vez disso, guarda-se um retrato do que o directório dizia da última vez.
-- A mudança é a diferença entre o retrato e o que o Entra ID diz hoje. Não
-- depende de nenhuma tabela por preencher e funciona a partir da primeira
-- passagem.
-- =====================================================================

begin;

-- O retrato da última passagem. Sem isto não há como saber o que mudou.
create table if not exists public.shaar_directory_estado (
  user_id     bigint primary key references public.users(id) on delete cascade,
  department  text,
  job_title   text,
  visto_em    timestamptz not null default now()
);

create or replace function public.shaar_ciclo_de_vida_diario()
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  r          record;
  v_saidas   integer := 0;
  v_mudancas integer := 0;
  v_entradas integer := 0;
  v_expiradas integer := 0;
begin
  -- SAÍDAS: inactivo, bloqueado ou desligado no cadastro, mas ainda com portões.
  -- Sem revisão e sem prazo: uma conta que saiu da empresa e mantém acesso é o
  -- achado número um de qualquer auditoria, e não há caso legítimo do outro lado.
  for r in
    select u.id from public.users u
     where (not u.active or u.blocked or u.terminated_at is not null)
       and exists (select 1 from public.shaar_gate_access g where g.user_id = u.id)
  loop
    perform public.shaar_processar_saida(r.id, 'saida — conta inactiva no cadastro');
    v_saidas := v_saidas + 1;
  end loop;

  -- SAÍDAS: desapareceu do directório licenciado, sem excepção nem vínculo
  -- declarados. `presente = false` é o que a sincronização escreve quando a
  -- conta deixa de aparecer no Entra ID com licença.
  for r in
    select u.id from public.users u
     where u.active
       and u.login_method = 'entra'
       and exists (select 1 from public.shaar_gate_access g where g.user_id = u.id)
       and not exists (select 1 from public.shaar_directory d
                        where lower(d.email) = lower(u.email) and d.presente)
       and not exists (select 1 from public.shaar_directory_ignorar i
                        where lower(i.email) = lower(u.email))
       and not exists (select 1 from public.shaar_directory_vinculo v
                        where v.user_id = u.id)
  loop
    perform public.shaar_processar_saida(r.id, 'saida — sem licenca no Entra ID');
    v_saidas := v_saidas + 1;
  end loop;

  -- ENTRADAS: activo no cadastro, ainda sem portão nenhum. Recebe o portão de
  -- chegada e zero permissões — quem atribui é gente, não a sincronização.
  for r in
    select u.id from public.users u
     where u.active and not u.blocked and u.terminated_at is null
       and not exists (select 1 from public.shaar_gate_access g where g.user_id = u.id)
  loop
    perform public.shaar_processar_entrada(r.id);
    v_entradas := v_entradas + 1;
  end loop;

  -- MUDANÇAS: o directório diz hoje algo diferente do que dizia da última vez.
  -- Sinaliza, não revoga: revogar automaticamente deixa a pessoa sem trabalhar
  -- na manhã seguinte, ninguém percebe porquê, e ao fim de duas vezes alguém
  -- desliga a automatização. A que a equipa desliga não protege nada.
  for r in
    select u.id,
           e.department as antes_area, d.department as agora_area,
           e.job_title  as antes_cargo, d.job_title as agora_cargo
      from public.users u
      join public.shaar_directory d on lower(d.email) = lower(u.email) and d.presente
      join public.shaar_directory_estado e on e.user_id = u.id
     where u.active
       and (coalesce(d.department,'') is distinct from coalesce(e.department,'')
         or coalesce(d.job_title,'')  is distinct from coalesce(e.job_title,''))
       and exists (select 1 from public.shaar_permission_grant g where g.user_id = u.id)
  loop
    if coalesce(r.agora_area,'') is distinct from coalesce(r.antes_area,'') then
      perform public.shaar_processar_mudanca(r.id, 'area', r.antes_area, r.agora_area);
      v_mudancas := v_mudancas + 1;
    end if;
    if coalesce(r.agora_cargo,'') is distinct from coalesce(r.antes_cargo,'') then
      perform public.shaar_processar_mudanca(r.id, 'cargo', r.antes_cargo, r.agora_cargo);
      v_mudancas := v_mudancas + 1;
    end if;
  end loop;

  -- actualiza o retrato para a próxima passagem
  insert into public.shaar_directory_estado (user_id, department, job_title, visto_em)
  select u.id, d.department, d.job_title, now()
    from public.users u
    join public.shaar_directory d on lower(d.email) = lower(u.email) and d.presente
  on conflict (user_id) do update
     set department = excluded.department,
         job_title  = excluded.job_title,
         visto_em   = excluded.visto_em;

  -- e as permissões com prazo que chegaram ao fim
  v_expiradas := public.shaar_expirar_permissoes();

  perform public.shaar_registrar('CICLO_DIARIO','sucesso', null,
    jsonb_build_object('saidas', v_saidas, 'entradas', v_entradas,
                       'mudancas', v_mudancas, 'expiradas', v_expiradas));

  return jsonb_build_object('ok', true, 'saidas', v_saidas, 'entradas', v_entradas,
                            'mudancas', v_mudancas, 'expiradas', v_expiradas);
end $$;

grant execute on function public.shaar_ciclo_de_vida_diario() to authenticated;

commit;

-- Primeira passagem: enche o retrato sem sinalizar mudança nenhuma, porque
-- não há retrato anterior com que comparar. Só a partir da segunda é que a
-- deteção de mudança faz sentido.
insert into public.shaar_directory_estado (user_id, department, job_title, visto_em)
select u.id, d.department, d.job_title, now()
  from public.users u
  join public.shaar_directory d on lower(d.email) = lower(u.email) and d.presente
on conflict (user_id) do nothing;

select public.shaar_ciclo_de_vida_diario() as primeira_passagem;
