-- SHAAR · o Quadro passa a listar em ordem hierárquica corporativa
--
-- Até aqui o Quadro ordenava por nível de perfil e nome. Isso põe CFO, CTO,
-- CMO e CISO num empate — todos são C-LEVEL, nível 70 — e o desempate saía
-- por ordem alfabética do nome da pessoa, que não diz nada sobre a estrutura.
--
-- A tabela `positions` já tinha os campos certos para resolver isto:
-- `nivel_organizacional`, `is_executive` e `codigo`. Estavam todos vazios.
-- Preenchê-los é melhor do que inventar uma tabela nova: o cargo é de quem
-- ocupa o cargo, não do hub.

-- ------------------------------------------------------------------
-- 1. Ordem hierárquica de cada cargo
--
-- Os três primeiros postos (SUPERADMIN, BOARD, CEO) vêm do perfil, não do
-- cargo — quem os ocupa não tem cargo registado. A numeração começa no 4
-- para que perfil e cargo caibam na mesma escala.
-- ------------------------------------------------------------------
update public.positions
   set codigo = upper(btrim(name))
 where codigo is null and name is not null;

update public.positions p
   set nivel_organizacional = case upper(btrim(p.name))
         -- C-level, na ordem do organograma
         when 'CFO'  then 4
         when 'COO'  then 5
         when 'CTO'  then 6
         when 'CMO'  then 7
         when 'CHRO' then 8
         -- demais C-level
         when 'CISO' then 9
         when 'CSCO' then 9
         when 'DPO'  then 9
         -- executivos não-C-level
         when 'BPM'                  then 10
         when 'PROCESSOS GERENCIAIS' then 10
         when 'REL. COM GORVERNO'    then 10
         -- assistência executiva
         when 'EA' then 11
         else case when upper(btrim(p.name)) like 'GERENTE%' then 12 else 13 end
       end,
       updated_at = now();

update public.positions
   set is_executive = (nivel_organizacional is not null and nivel_organizacional <= 10),
       updated_at = now();

comment on column public.positions.nivel_organizacional is
  'Ordem hierarquica do cargo, 4 a 13. Os postos 1 a 3 (SUPERADMIN, BOARD, CEO) '
  'vem do perfil, porque quem os ocupa nao tem cargo registado.';

-- ------------------------------------------------------------------
-- 2. A escala completa, perfil e cargo na mesma régua
-- ------------------------------------------------------------------
create or replace function public.shaar_posto(p_nivel_perfil int, p_nivel_cargo int)
returns int
language sql immutable as $$
  select case
    when p_nivel_perfil >= 100 then 1    -- SUPERADMIN
    when p_nivel_perfil >=  90 then 2    -- BOARD
    when p_nivel_perfil >=  80 then 3    -- CEO
    else coalesce(p_nivel_cargo,          -- 4..13, pelo cargo
           case                           -- sem cargo: cai para o perfil
             when p_nivel_perfil >= 65 then 10
             when p_nivel_perfil >= 60 then 11
             when p_nivel_perfil >= 40 then 12
             when p_nivel_perfil >= 20 then 13
             else 14                      -- SEM PERFIL: quem chegou pela sincronizacao
           end)
  end;
$$;

comment on function public.shaar_posto is
  'Posto hierarquico de uma pessoa: 1 SUPERADMIN, 2 BOARD, 3 CEO, 4 CFO, 5 COO, '
  '6 CTO, 7 CMO, 8 CHRO, 9 demais C-level, 10 executivos, 11 EA, 12 gerentes, '
  '13 colaboradores, 14 aguardando perfil.';

-- ------------------------------------------------------------------
-- 3. O Quadro, na ordem certa
--
-- Dentro do mesmo posto, gerentes e colaboradores saem por área e depois por
-- nome, como pedido.
--
-- ATENCAO: a area ainda nao existe como dado. A tabela org_departments esta
-- vazia e nenhum usuario tem department_id. O espelho do diretorio traz o
-- campo department do Entra ID, mas so 5 de 35 pessoas o tem preenchido.
-- Enquanto isso, o desempate real acaba sendo o cargo e depois o nome — o
-- que ja e uma ordenacao util. Assim que org_departments for preenchida e os
-- usuarios ligados a ela, a ordem por area passa a valer sozinha, sem mexer
-- nesta funcao.
-- ------------------------------------------------------------------
drop function if exists public.shaar_quadro();
create function public.shaar_quadro()
returns table (
  user_id bigint, full_name text, email varchar, user_kind varchar,
  profile_name text, app_code text, app_name text, app_released boolean,
  posto int, cargo text, area text
)
language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(public.shaar_meu_nivel(), 0) < 100 then
    raise exception 'Acesso restrito ao super administrador.' using errcode = '42501';
  end if;
  return query
    with pessoa as (
      select u.id, u.full_name, u.email, u.user_kind,
             pr.name::text as profile_name,
             po.name::text as cargo,
             coalesce(nullif(btrim(dep.nome), ''), nullif(btrim(dir.department), '')) as area,
             public.shaar_posto(pr.level, po.nivel_organizacional) as posto
        from public.users u
        left join public.profiles    pr  on pr.id  = u.profile_id
        left join public.positions   po  on po.id  = u.position_id
        left join public.org_departments dep on dep.id = u.department_id
        left join public.shaar_directory dir on dir.user_id = u.id and dir.presente
       where u.active and not u.blocked
    )
    select p.id, p.full_name, p.email, p.user_kind, p.profile_name,
           v.app_code, v.app_name, v.app_released,
           p.posto, p.cargo, p.area
      from pessoa p
      left join public.shaar_user_apps v on v.user_id = p.id
     -- NULLS LAST em vez de uma sentinela tipo '~~~~': sob a collation desta
     -- base o til ordena ANTES das letras, entao a sentinela faria o oposto
     -- do pretendido. NULLS LAST nao depende de collation.
     order by p.posto,
              p.area  nulls last,
              p.cargo nulls last,
              p.full_name,
              v.sort_order;
end;
$$;

comment on function public.shaar_quadro is
  'Quadro de Acessos em ordem hierarquica corporativa: posto, area, cargo, nome.';

revoke all on function public.shaar_quadro() from public;
grant execute on function public.shaar_quadro() to authenticated;
