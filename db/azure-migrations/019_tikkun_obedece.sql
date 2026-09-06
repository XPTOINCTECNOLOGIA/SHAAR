-- =====================================================================
-- TIKKUN passa a obedecer a Central
-- =====================================================================
--
-- O catalogo ficou com duas capacidades e as concessoes vieram de perguntar
-- as proprias funcoes, pessoa a pessoa: 31 concessoes para 16 pessoas. So
-- duas dessas pessoas vem de papeis — o supervisor e o gestor. As outras
-- catorze vem do `tikkun_is_admin()` que esta por baixo do can_supervise.
-- Nunca teria adivinhado esse conjunto a ler codigo, e e por isso que
-- perguntei em vez de decompor.
--
-- A leitura continua aberta: nenhuma politica muda, e o `select` de todas as
-- tabelas continua `true`.
--
-- O que muda: 26 das 31 concessoes sao de gente sem o portao do TIKKUN. Como
-- `shaar_pode` exige portao, essas pessoas deixam de poder supervisionar e
-- gerir ordens de servico ate alguem lhes abrir a entrada. Conseguiam hoje
-- porque as nove aplicacoes partilham a mesma base — e o mesmo buraco que se
-- fechou no JIREH, pela mesma razao. Os direitos ficam guardados.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. AS COPIAS LEGADAS
-- ---------------------------------------------------------------------
do $mig$
declare f text; v_oid oid; v_n int;
begin
  foreach f in array array['tikkun_can_supervise','tikkun_can_manage'] loop
    select count(*), min(p.oid) into v_n, v_oid
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = f;
    if v_n <> 1 then
      raise exception '% tem % assinaturas; esperava uma', f, v_n;
    end if;
    if pg_get_function_result(v_oid) <> 'boolean' then
      raise exception '% devolve %, esperava boolean', f, pg_get_function_result(v_oid);
    end if;
    if not exists (
         select 1 from pg_proc p2 join pg_namespace n2 on n2.oid = p2.pronamespace
          where n2.nspname = 'public' and p2.proname = f || '_legado') then
      execute regexp_replace(pg_get_functiondef(v_oid),
                             'FUNCTION public\.' || f || '\(',
                             'FUNCTION public.' || f || '_legado(');
    end if;
  end loop;
end
$mig$;


-- ---------------------------------------------------------------------
-- 2. A PECA DE ENCAIXE
-- ---------------------------------------------------------------------
-- O medidor pergunta a funcao antiga passando-lhe um codigo. As capacidades
-- do TIKKUN nao recebem argumento nenhum: sao `can_supervise()` e
-- `can_manage()`. Esta funcao traduz um no outro, e serve so para a medicao.
create or replace function public.tikkun_capacidade_legada(p_code text)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select case p_code
    when 'os.supervisionar' then public.tikkun_can_supervise_legado()
    when 'os.gerir'         then public.tikkun_can_manage_legado()
    else false
  end;
$$;

comment on function public.tikkun_capacidade_legada(text) is
  'Da as capacidades antigas do TIKKUN a forma que o medidor de divergencia '
  'espera: um codigo a entrada. Existe para a medicao, nao para decidir nada.';

revoke all on function public.tikkun_capacidade_legada(text) from public;


-- ---------------------------------------------------------------------
-- 3. MEDIR E LIGAR
-- ---------------------------------------------------------------------
select public.shaar_ligar_central(
  'TIKKUN',
  'Traducao fiel das capacidades da aplicacao: as concessoes vieram de '
  'perguntar a tikkun_can_supervise() e tikkun_can_manage(), pessoa a pessoa, '
  'e nao de eu decompor o codigo delas. A leitura das ordens de servico fica '
  'aberta a toda a gente, por decisao do dono: nenhuma politica muda e nao ha '
  'permissao de leitura no catalogo.',
  'tikkun_capacidade_legada');


-- ---------------------------------------------------------------------
-- 4. A TROCA
-- ---------------------------------------------------------------------
-- As 56 politicas nao mudam uma linha, e o `select true` de cada tabela
-- continua a ser `select true`. Muda quem responde a duas perguntas.
create or replace function public.tikkun_can_supervise()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select public.shaar_pode('TIKKUN', 'os.supervisionar');
$function$;

create or replace function public.tikkun_can_manage()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select public.shaar_pode('TIKKUN', 'os.gerir');
$function$;

comment on function public.tikkun_can_supervise is
  'Desde 06/09/2026 pergunta a Central. A regra antiga — papel em '
  '(administrador, gestor, supervisor) ou tikkun_is_admin() — esta guardada '
  'em tikkun_can_supervise_legado e foi a origem das concessoes.';

comment on function public.tikkun_can_manage is
  'Desde 06/09/2026 pergunta a Central. A regra antiga esta guardada em '
  'tikkun_can_manage_legado e foi a origem das concessoes.';


-- ---------------------------------------------------------------------
-- Conferencia
-- ---------------------------------------------------------------------
select 'aplicacoes a obedecer: ' ||
       string_agg(app_code, ', ' order by app_code)
  from public.shaar_app_central;

select 'direitos por guardar: ' || count(*)::text
  from public.shaar_permissao_verdade_antiga a
  left join public.shaar_permission_grant g
    on g.user_id = a.user_id and g.app_code = a.app_code and g.code = a.code
 where g.user_id is null;

select 'divergencia: ' || count(*)::text
  from public.shaar_permissao_divergencias;

-- A leitura tem de continuar aberta. Se alguma tabela do TIKKUN tiver
-- ganho uma politica restritiva, isto acusa — e nao devia ter ganho
-- nenhuma, porque nenhum destes ficheiros criou uma.
select 'politicas restritivas no TIKKUN (tem de ser 0): ' || count(*)::text
  from pg_policy p
  join pg_class c on c.oid = p.polrelid
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relname like 'tikkun%'
   and not p.polpermissive;

select 'politicas de leitura do TIKKUN abertas: ' || count(*)::text
  from pg_policy p
  join pg_class c on c.oid = p.polrelid
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relname like 'tikkun%'
   and p.polcmd = 'r'
   and coalesce(pg_get_expr(p.polqual, p.polrelid), '') = 'true';

select 'tikkun_can_supervise responde: ' ||
       coalesce(public.tikkun_can_supervise()::text, 'nulo');
