-- =====================================================================
-- BNEI passa a obedecer a Central
-- =====================================================================
--
-- Medido contra a propria funcao da aplicacao, depois de o catalogo passar
-- a ser o dela e nao o meu:
--
--   controlo 303 | perde com portao 0 | ganha 0 | ganha sem revisao 0
--   pares 640    | perde sem portao 28
--
-- O controlo em 303 e o numero que valida tudo o resto: diz que a
-- impersonacao funciona tambem por este caminho, que passa por
-- `bnei_current_role()` e `current_app_user_id()` em vez de `auth.uid()`.
-- Sem ele, os zeros nao queriam dizer nada.
--
-- A troca e a mesma que fiz no TETELESTAI, e nao toca em nenhuma das 55
-- politicas: `bnei_has_permission` e uma delegacao fina, e e o corpo dela
-- que muda. As 28 respostas que deixam de valer sao de gente com papel e
-- sem portao — direitos guardados, a espera de entrada.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. A COPIA LEGADA, outra vez feita pela propria base
-- ---------------------------------------------------------------------
do $mig$
declare v_oid oid; v_n int; v_def text;
begin
  select count(*), min(p.oid) into v_n, v_oid
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'bnei_has_permission';
  if v_n <> 1 then
    raise exception 'bnei_has_permission tem % assinaturas; esperava uma', v_n;
  end if;
  if pg_get_function_result(v_oid) <> 'boolean' then
    raise exception 'bnei_has_permission devolve %, esperava boolean',
                    pg_get_function_result(v_oid);
  end if;

  if not exists (
       select 1 from pg_proc p2 join pg_namespace n2 on n2.oid = p2.pronamespace
        where n2.nspname = 'public' and p2.proname = 'bnei_has_permission_legado') then
    v_def := regexp_replace(pg_get_functiondef(v_oid),
                            'FUNCTION public\.bnei_has_permission\(',
                            'FUNCTION public.bnei_has_permission_legado(');
    execute v_def;
  end if;
end
$mig$;


-- ---------------------------------------------------------------------
-- 2. O GUARD DEIXA DE SER SO DO CAMINHO HERDADO
-- ---------------------------------------------------------------------
-- Ate agora `shaar_ligar_central` so sabia ligar aplicacoes com codigos
-- herdados, medidas contra a funcao do JIREH. O BNEI tem catalogo proprio e
-- funcao propria: o que muda e de onde vem a resposta antiga, e isso passa a
-- ser um parametro. As tres perguntas que ele faz sao as mesmas.
create or replace function public.shaar_ligar_central(
  p_app    text,
  p_motivo text,
  p_legado text default 'jireh_has_permission_legado'
)
returns text
language plpgsql
volatile
set search_path = public
as $$
declare r record; v_cods bigint; v_falta bigint;
begin
  if not exists (select 1 from public.shaar_apps a where a.code = p_app) then
    raise exception 'aplicacao % nao existe no catalogo', p_app;
  end if;

  if exists (select 1 from public.shaar_app_central c where c.app_code = p_app) then
    return p_app || ' ja obedecia; nada a fazer';
  end if;

  select count(*) into v_cods
    from public.shaar_permission sp
   where sp.app_code = p_app and sp.active;

  if v_cods = 0 then
    raise exception 'a aplicacao % nao tem catalogo: nao ha o que ligar', p_app;
  end if;

  -- Nenhum direito pode ficar por guardar: quem nao tem portao hoje pode
  -- te-lo amanha, e nesse dia o que ja era dele tem de estar la.
  select count(*) into v_falta
    from public.shaar_permissao_verdade_antiga a
    left join public.shaar_permission_grant g
      on g.user_id = a.user_id and g.app_code = a.app_code and g.code = a.code
   where a.app_code = p_app and g.user_id is null;

  if v_falta > 0 then
    raise exception
      'ha % direitos do modelo antigo do % que nao estao guardados na Central',
      v_falta, p_app;
  end if;

  select * into r from public.shaar_divergencia_real_resumo(p_app, p_legado);

  if r.controlo_positivos = 0 then
    raise exception
      'o controlo da impersonacao contra % deu zero: a medicao nao esta a '
      'funcionar e os outros numeros nao valem nada', p_legado;
  end if;

  if r.perdia > 0 then
    raise exception
      'ligar % tiraria acesso em % respostas a gente COM o portao aberto',
      p_app, r.perdia;
  end if;

  if r.ganha_sem_revisao > 0 then
    raise exception
      'ligar % daria acesso novo em % respostas a gente sem revisao aberta',
      p_app, r.ganha_sem_revisao;
  end if;

  insert into public.shaar_app_central (app_code, motivo) values (p_app, p_motivo);

  return format(
    '%s obedece a Central. %s permissoes, %s pares medidos contra %s, controlo '
    '%s, ninguem com portao perde acesso, %s de acesso novo. E %s respostas '
    'deixam de valer para quem NAO tem portao — direitos guardados, a espera '
    'de entrada',
    p_app, v_cods, r.pares_avaliados, p_legado, r.controlo_positivos,
    r.ganharia, r.perde_sem_portao);
end $$;

revoke all on function public.shaar_ligar_central(text, text, text) from public;


-- ---------------------------------------------------------------------
-- 3. MEDIR E LIGAR
-- ---------------------------------------------------------------------
-- Repare-se na ordem: mede-se contra a copia legada ANTES de trocar o corpo.
-- Trocar primeiro tornaria a medicao uma comparacao da Central consigo
-- mesma, que da sempre zero e nao prova nada.
select public.shaar_ligar_central(
  'BNEI',
  'Catalogo e concessoes reconstruidos a partir de bnei_role_has_permission '
  'depois de eu ter descoberto que o catalogo que tinha escrito era invencao '
  'minha. Medido contra bnei_has_permission_legado: ninguem com portao perde '
  'acesso, ninguem ganha, e 28 respostas deixam de valer para quem tem papel '
  'e nao tem portao.',
  'bnei_has_permission_legado');


-- ---------------------------------------------------------------------
-- 4. A TROCA
-- ---------------------------------------------------------------------
-- As 55 politicas nao mudam uma linha. Muda-se a fonte da verdade por baixo
-- delas, como no TETELESTAI.
--
-- O `case` existe para o codigo que nao esteja no catalogo: nesse caso vai
-- pelo caminho antigo, em vez de a Central responder falso por nao conhecer
-- o codigo. Hoje os dezasseis estao todos la, e isto e para o dia em que
-- alguem acrescentar um a aplicacao e se esquecer do catalogo.
create or replace function public.bnei_has_permission(p_permission text)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select case
    when exists (select 1 from public.shaar_permission sp
                  where sp.app_code = 'BNEI' and sp.code = p_permission
                    and sp.active)
    then public.shaar_pode('BNEI', p_permission)
    else public.bnei_has_permission_legado(p_permission)
  end;
$function$;

comment on function public.bnei_has_permission(text) is
  'Decide as permissoes do BNEI. Desde 06/09/2026 pergunta a Central para os '
  'codigos que estao no catalogo, e ao modelo antigo para os que nao estao. '
  'As 55 politicas da aplicacao continuam a chama-la sem saber da diferenca.';


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

-- Fumo: corre como postgres, sem identidade, portanto o esperado e falso.
-- O que se testa e que nao rebenta nem entra em ciclo.
select 'bnei_has_permission responde: ' ||
       coalesce(public.bnei_has_permission('people:read')::text, 'nulo');
