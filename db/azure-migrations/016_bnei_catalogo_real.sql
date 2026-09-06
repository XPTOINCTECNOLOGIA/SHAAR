-- =====================================================================
-- O catalogo do BNEI passa a ser o que a aplicacao diz, e nao o que eu disse
-- =====================================================================
--
-- Eu tinha inventado nove permissoes para o BNEI, na forma `pessoa.consultar`,
-- porque nao encontrei catalogo e assumi que nao havia. Havia:
--
--   bnei_has_permission(p)      = bnei_role_has_permission(bnei_current_role(), p)
--   bnei_role_has_permission    = seis papeis, dezasseis permissoes
--
-- e 55 politicas a chamar `bnei_has_permission('people:read')` e companhia.
-- O meu catalogo nao coincidia com nenhuma delas: nao era uma nomenclatura
-- diferente para a mesma coisa, era outra coisa. Dava `financeiro.consultar`
-- a 23 pessoas do papel `consulta`, que nao tem `finance:read`, e escrita em
-- pessoas e contratos a 11 `gestor`, que so escreve em `projects`. E nao
-- tinha `documents`, `projects`, `training`, `audit` nem `ai` — cinco
-- dominios inteiros.
--
-- Este ficheiro deita fora a minha invencao e constroi o catalogo e as
-- concessoes a partir da propria funcao. Nenhuma linha aqui e opiniao minha
-- sobre quem pode o que: quem responde e `bnei_role_has_permission`.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. A MEDICAO DEIXA DE SER SO DO JIREH
-- ---------------------------------------------------------------------
-- `shaar_divergencia_real_resumo` comparava sempre contra
-- `jireh_has_permission_legado`. O BNEI e o TIKKUN tem funcoes proprias, e
-- para os medir com o mesmo rigor a funcao antiga passa a ser um parametro.
drop function if exists public.shaar_divergencia_real_resumo(text);

create function public.shaar_divergencia_real_resumo(
  p_app    text,
  p_legado text default 'jireh_has_permission_legado'
)
returns table (
  total              bigint,
  perdia             bigint,
  perde_sem_portao   bigint,
  ganharia           bigint,
  ganha_sem_revisao  bigint,
  pessoas            bigint,
  pessoas_sem_portao bigint,
  controlo_positivos bigint,
  pares_avaliados    bigint
)
language plpgsql
volatile
set search_path = public
as $$
declare
  r          record;
  v_a        boolean;
  v_c        boolean;
  v_quem     bigint[] := '{}';
  v_quem_sp  bigint[] := '{}';
  v_sql      text;
begin
  total := 0; perdia := 0; perde_sem_portao := 0;
  ganharia := 0; ganha_sem_revisao := 0;
  controlo_positivos := 0; pares_avaliados := 0;

  if to_regprocedure('public.' || quote_ident(p_legado) || '(text)') is null
     and to_regprocedure('public.' || quote_ident(p_legado) || '(character varying)') is null then
    raise exception 'a funcao antiga % nao existe', p_legado;
  end if;
  v_sql := format('select public.%I($1)', p_legado);

  for r in
    select u.id, u.auth_user_id, sp.code,
           exists (select 1 from public.shaar_gate_access g
                    where g.user_id = u.id and g.app_code = p_app) as tem_portao,
           exists (select 1 from public.shaar_permission_revisao rv
                    where rv.user_id = u.id and rv.resolvido_em is null) as tem_revisao
      from public.users u
      cross join public.shaar_permission sp
     where u.active and not u.blocked
       and sp.app_code = p_app and sp.active
  loop
    if r.auth_user_id is null then
      perform set_config('request.jwt.claim.sub', '',   true);
      perform set_config('request.jwt.claims',    '{}', true);
    else
      perform set_config('request.jwt.claim.sub', r.auth_user_id::text, true);
      perform set_config('request.jwt.claims',
                         json_build_object('sub', r.auth_user_id::text)::text, true);
    end if;

    execute v_sql into v_a using r.code;
    v_c := public.shaar_pode(p_app, r.code, '{}'::jsonb, r.id);
    v_a := coalesce(v_a, false);

    pares_avaliados := pares_avaliados + 1;
    if v_a and r.auth_user_id is not null then
      controlo_positivos := controlo_positivos + 1;
    end if;

    if v_a is distinct from v_c then
      total := total + 1;
      if v_a and not v_c then
        if r.tem_portao then
          perdia := perdia + 1;
        else
          perde_sem_portao := perde_sem_portao + 1;
          if not (r.id = any (v_quem_sp)) then v_quem_sp := v_quem_sp || r.id; end if;
        end if;
      else
        ganharia := ganharia + 1;
        if not r.tem_revisao then ganha_sem_revisao := ganha_sem_revisao + 1; end if;
      end if;
      if not (r.id = any (v_quem)) then v_quem := v_quem || r.id; end if;
    end if;
  end loop;

  perform set_config('request.jwt.claim.sub', '',   true);
  perform set_config('request.jwt.claims',    '{}', true);

  pessoas            := coalesce(array_length(v_quem,    1), 0);
  pessoas_sem_portao := coalesce(array_length(v_quem_sp, 1), 0);
  return next;
end $$;

revoke all on function public.shaar_divergencia_real_resumo(text, text) from public;

-- Nota: o filtro `sp.origem = 'herdado'` saiu daqui. Servia quando so as
-- aplicacoes do catalogo antigo eram medidas; o BNEI tem catalogo proprio e
-- ficaria de fora. Passa a medir todas as permissoes activas da aplicacao.


-- ---------------------------------------------------------------------
-- 1. UM PAPEL POR PESSOA, OU NAO SE AVANCA
-- ---------------------------------------------------------------------
-- `bnei_current_role()` escolhe UM papel. Se alguem tiver dois, a uniao dos
-- dois daria mais do que a aplicacao da, e eu nao vou adivinhar qual e que
-- ela escolhe. Falha fechada.
do $$
declare v int;
begin
  select count(*) into v from (
    select r.user_id from public.bnei_user_roles r
      join public.users u on u.id = r.user_id and u.active
     group by r.user_id having count(distinct r.role) > 1) d;
  if v > 0 then
    raise exception
      '% pessoas tem mais do que um papel no BNEI. bnei_current_role() escolhe '
      'um; a uniao dos dois daria mais acesso do que a aplicacao da hoje, e '
      'adivinhar qual e que ela escolhe nao e aceitavel', v;
  end if;
end $$;


-- ---------------------------------------------------------------------
-- 2. FORA A INVENCAO
-- ---------------------------------------------------------------------
-- As nove permissoes que eu inventei nunca foram usadas por politica
-- nenhuma: as politicas do BNEI chamam os codigos reais. Sao inertes, mas
-- deixa-las tornaria a Central uma fonte de direitos que ninguem tem — e o
-- historico de eventos regista a remocao, que e imutavel.
delete from public.shaar_permission_grant
 where app_code = 'BNEI'
   and code in ('pessoa.consultar','pessoa.gerir','contrato.consultar',
                'contrato.gerir','financeiro.consultar','financeiro.gerir',
                'compliance.consultar','compliance.gerir','configuracao.gerir');

delete from public.shaar_permission
 where app_code = 'BNEI'
   and code in ('pessoa.consultar','pessoa.gerir','contrato.consultar',
                'contrato.gerir','financeiro.consultar','financeiro.gerir',
                'compliance.consultar','compliance.gerir','configuracao.gerir');


-- ---------------------------------------------------------------------
-- 3. O CATALOGO REAL
-- ---------------------------------------------------------------------
insert into public.shaar_permission
  (app_code, code, name, description, grupo, sort_order, origem)
values
 ('BNEI','people:read',      'Consultar pessoas',    'Ver o quadro de pessoas e a linha do tempo','pessoas',    10,'aplicacao'),
 ('BNEI','people:write',     'Gerir pessoas',        'Criar e editar registos de pessoas',        'pessoas',    20,'aplicacao'),
 ('BNEI','contracts:read',   'Consultar contratos',  'Ver contratos e prazos',                    'contratos',  30,'aplicacao'),
 ('BNEI','contracts:write',  'Gerir contratos',      'Criar, editar e encerrar contratos',        'contratos',  40,'aplicacao'),
 ('BNEI','finance:read',     'Consultar financeiro', 'Ver valores e historico financeiro',        'financeiro', 50,'aplicacao'),
 ('BNEI','finance:write',    'Gerir financeiro',     'Alterar valores e vinculos financeiros',    'financeiro', 60,'aplicacao'),
 ('BNEI','documents:read',   'Consultar documentos', 'Ver documentos e tipos de documento',       'documentos', 70,'aplicacao'),
 ('BNEI','documents:write',  'Gerir documentos',     'Carregar e editar documentos',              'documentos', 80,'aplicacao'),
 ('BNEI','compliance:read',  'Consultar compliance', 'Ver avaliacoes e trilha de conformidade',   'compliance', 90,'aplicacao'),
 ('BNEI','compliance:write', 'Gerir compliance',     'Registar e encerrar avaliacoes',            'compliance',100,'aplicacao'),
 ('BNEI','projects:read',    'Consultar projectos',  'Ver projectos e alocacoes',                 'projectos', 110,'aplicacao'),
 ('BNEI','projects:write',   'Gerir projectos',      'Criar, editar e alocar em projectos',       'projectos', 120,'aplicacao'),
 ('BNEI','training:read',    'Consultar formacao',   'Ver accoes de formacao',                    'formacao',  130,'aplicacao'),
 ('BNEI','training:write',   'Gerir formacao',       'Criar e editar accoes de formacao',         'formacao',  140,'aplicacao'),
 ('BNEI','audit:read',       'Consultar auditoria',  'Ver a trilha de auditoria do BNEI',         'auditoria', 150,'aplicacao'),
 ('BNEI','ai:query',         'Perguntar a assistente','Usar a consulta assistida da aplicacao',   'assistente',160,'aplicacao')
on conflict (app_code, code) do update
  set name = excluded.name, description = excluded.description,
      grupo = excluded.grupo, sort_order = excluded.sort_order,
      origem = excluded.origem, active = true;


-- ---------------------------------------------------------------------
-- 4. AS CONCESSOES, DECIDIDAS PELA PROPRIA FUNCAO
-- ---------------------------------------------------------------------
-- Repare-se no `where`: quem decide se a pessoa tem o codigo e
-- `bnei_role_has_permission`, nao eu. Sem portao no meio — a permissao e da
-- pessoa, o portao diz se ela entra.
insert into public.shaar_permission_grant
  (user_id, app_code, code, efeito, escopo, motivo, granted_by, granted_at)
select distinct u.id, 'BNEI', sp.code, 'permitir', '{}'::jsonb,
       'migracao do modelo anterior — papel ' || r.role ||
       ', segundo bnei_role_has_permission',
       null::bigint, now()
  from public.bnei_user_roles r
  join public.users u          on u.id = r.user_id and u.active
  join public.shaar_permission sp on sp.app_code = 'BNEI' and sp.active
 where public.bnei_role_has_permission(r.role, sp.code)
on conflict (user_id, app_code, code) do nothing;


-- ---------------------------------------------------------------------
-- 5. A VISTA DO MODELO ANTIGO TAMBEM DEIXA DE ME CITAR
-- ---------------------------------------------------------------------
-- O ramo do BNEI na vista tinha os meus nove codigos escritos a mao. Apagar
-- os codigos sem corrigir a vista poria DIREITOS_POR_GUARDAR acima de zero
-- por causa de uma ficcao — o relatorio ficaria vermelho a apontar para
-- nada, que e a maneira mais rapida de o tornar inutil.
--
-- Passa a perguntar a `bnei_role_has_permission`, tal como as concessoes.
create or replace view public.shaar_permissao_verdade_antiga as
  select distinct u.id as user_id, sp.app_code, sp.code
    from public.users u
    join public.profile_permissions pp on pp.profile_id = u.profile_id
    join public.permissions p          on p.id = pp.permission_id
    join public.shaar_permission sp    on sp.code = p.code and sp.origem = 'herdado'
   where u.active
  union
  select distinct u.id, sp.app_code, sp.code
    from public.jireh_user_permissions jup
    join public.users u             on u.id = jup.user_id and u.active
    join public.permissions p       on p.id = jup.permission_id
    join public.shaar_permission sp on sp.code = p.code and sp.origem = 'herdado'
  union
  select distinct u.id, sp.app_code, sp.code
    from public.users u
    join public.positions pos on pos.id = u.position_id and pos.active
    join public.profiles fin  on upper(fin.name) = 'FINANCEIRO' and fin.active
    join public.profile_permissions pp on pp.profile_id = fin.id
    join public.permissions p          on p.id = pp.permission_id
    join public.shaar_permission sp    on sp.code = p.code and sp.origem = 'herdado'
   where u.active and not u.blocked and upper(pos.name) = 'CFO'
  union
  -- BNEI: quem responde e a funcao da aplicacao
  select distinct u.id, 'BNEI', sp.code
    from public.bnei_user_roles r
    join public.users u             on u.id = r.user_id and u.active
    join public.shaar_permission sp on sp.app_code = 'BNEI' and sp.active
   where public.bnei_role_has_permission(r.role, sp.code)
  union
  -- TIKKUN: continua com o meu mapeamento por agora. Fica assim ate a
  -- traducao fiel das funcoes de capacidade, e nao antes.
  select u.id, 'TIKKUN', c.code
    from public.tikkun_user_roles r
    join public.users u on u.id = r.user_id and u.active
    cross join lateral (select unnest(case r.role::text
      when 'tecnico'       then array['os.consultar','os.executar','os.assinar']
      when 'supervisor'    then array['os.consultar','os.executar','os.assinar','os.criar','os.aprovar']
      when 'gestor'        then array['os.consultar','os.executar','os.assinar','os.criar','os.aprovar','equipa.gerir','custo.consultar','relatorio.consultar']
      when 'administrador' then array['os.consultar','os.executar','os.assinar','os.criar','os.aprovar','equipa.gerir','custo.consultar','relatorio.consultar','configuracao.gerir']
      else array[]::text[] end) as code) c
  union
  select g.user_id, 'SPHRAGIS', sp.code
    from public.shaar_gate_access g
    join public.users u             on u.id = g.user_id and u.active
    join public.shaar_permission sp on sp.app_code = 'SPHRAGIS'
   where g.app_code = 'SPHRAGIS';


-- ---------------------------------------------------------------------
-- Conferencia
-- ---------------------------------------------------------------------
select 'catalogo BNEI: ' || count(*)::text || ' permissoes'
  from public.shaar_permission where app_code = 'BNEI' and active;

select 'concessoes BNEI: ' || count(*)::text || ' para ' ||
       count(distinct user_id)::text || ' pessoas'
  from public.shaar_permission_grant where app_code = 'BNEI';

select 'por papel: ' || string_agg(t, ', ' order by t) from (
  select r.role || ' ' || count(distinct r.user_id)::text || 'p/' ||
         (select count(*) from public.shaar_permission sp
           where sp.app_code = 'BNEI' and sp.active
             and public.bnei_role_has_permission(r.role, sp.code))::text || 'x' as t
    from public.bnei_user_roles r
    join public.users u on u.id = r.user_id and u.active
   group by r.role) d;

-- O que ligar o BNEI faria, medido contra a propria funcao da aplicacao.
-- Ainda nao liga: isto e so o numero.
select 'BNEI — controlo: '     || r.controlo_positivos::text ||
       ' | perde com portao: ' || r.perdia            ::text ||
       ' | perde sem portao: ' || r.perde_sem_portao  ::text ||
       ' | ganha: '            || r.ganharia          ::text ||
       ' | ganha sem revisao: '|| r.ganha_sem_revisao ::text ||
       ' | pares: '            || r.pares_avaliados   ::text
  from public.shaar_divergencia_real_resumo('BNEI', 'bnei_has_permission') r;

select 'divergencia: ' || count(*)::text
  from public.shaar_permissao_divergencias;
