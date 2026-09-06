-- =====================================================================
-- O interruptor passa para o sitio por onde todos passam
-- =====================================================================
--
-- A troca do TETELESTAI foi feita em `has_permission`. Mas ha 15 politicas
-- RLS e 7 funcoes que nao chamam `has_permission`: chamam
-- `jireh_has_permission` directamente. Essas nao passam pelo interruptor.
--
-- Hoje isso nao muda uma resposta, porque a divergencia e zero e os dois
-- lados dizem o mesmo. O que muda e o futuro: uma concessao feita na Central
-- nunca chegaria a esses 22 sitios. E "a Central e a fonte unica da verdade"
-- deixaria de ser verdade sem que ninguem reparasse — que e a maneira mais
-- cara de descobrir uma coisa destas.
--
-- A correccao e mudar o interruptor de sitio: sai de `has_permission` e
-- entra em `jireh_has_permission`, por onde passam todos. `has_permission`
-- volta a ser o que era, uma passagem directa.
--
-- Nao ha recursao: `shaar_pode` so olha para `shaar_gate_access`,
-- `shaar_permission_grant`, `shaar_escopo_satisfeito` e
-- `shaar_usuario_atual`. Nunca volta a `has_permission` nem a
-- `jireh_has_permission`.
--
-- COMO o corpo antigo e preservado, e a parte que importa: nao e transcrito
-- por mim. O bloco abaixo le `pg_get_functiondef` da propria base, troca so
-- o nome na assinatura, e executa o resultado. O corpo legado passa
-- caracter a caracter como esta em producao. Numa funcao de que dependem
-- 169 politicas, a diferenca entre copiar e transcrever e a diferenca entre
-- um risco nulo e um erro de um caracter.
-- =====================================================================


do $mig$
declare
  v_oid   oid;
  v_n     int;
  v_args  text;
  v_ident text;
  v_def   text;
begin
  select count(*), min(p.oid) into v_n, v_oid
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'jireh_has_permission';

  -- Tres verificacoes antes de mexer. Se alguma falhar, a migracao rebenta e
  -- o --single-transaction do pipeline desfaz tudo: e o que se quer.
  if v_n = 0 then
    raise exception 'jireh_has_permission nao existe';
  elsif v_n > 1 then
    raise exception 'jireh_has_permission tem % assinaturas; esta migracao assume uma', v_n;
  end if;

  if pg_get_function_result(v_oid) <> 'boolean' then
    raise exception 'jireh_has_permission devolve %, esperava boolean',
                    pg_get_function_result(v_oid);
  end if;

  if pg_get_functiondef(v_oid) ~ 'public\.has_permission\s*\(' then
    raise exception 'jireh_has_permission chama has_permission: mover o interruptor criaria um ciclo';
  end if;

  v_args  := pg_get_function_arguments(v_oid);
  v_ident := pg_get_function_identity_arguments(v_oid);

  -- 1. A COPIA LEGADA, feita pela base a partir do seu proprio texto.
  --    A existencia pergunta-se ao catalogo, nao com to_regprocedure: o que
  --    pg_get_function_identity_arguments devolve inclui o NOME do parametro
  --    ("p_code character varying"), e regprocedure quer so tipos.
  if not exists (
       select 1 from pg_proc p2 join pg_namespace n2 on n2.oid = p2.pronamespace
        where n2.nspname = 'public' and p2.proname = 'jireh_has_permission_legado') then
    v_def := regexp_replace(pg_get_functiondef(v_oid),
                            'FUNCTION public\.jireh_has_permission\(',
                            'FUNCTION public.jireh_has_permission_legado(');
    execute v_def;
  end if;

  -- Sem revoke aqui de proposito: `jireh_has_permission` e security definer e
  -- corre como o dono dela, que pode nao ser quem esta a aplicar esta
  -- migracao. Tirar o execute do public arriscava que a funcao nova nao
  -- conseguisse chamar a legada. E nao ha nada a proteger: chamar a legada
  -- directamente so responde sobre quem chama, tal como sempre respondeu.

  -- 2. O INTERRUPTOR, com a assinatura exacta da funcao que substitui.
  --    Usa $1 em vez do nome do parametro, para nao depender de proargnames.
  execute format($tpl$
    create or replace function public.jireh_has_permission(%s)
    returns boolean
    language sql
    stable
    security definer
    set search_path to 'public'
    as $corpo$
      select case
        when exists (
          select 1 from public.shaar_permission sp
           where sp.code = $1
             and sp.app_code = 'TETELESTAI'
             and sp.origem = 'herdado'
             and sp.active)
        then public.shaar_pode('TETELESTAI', $1)
        else public.jireh_has_permission_legado($1)
      end;
    $corpo$
  $tpl$, v_args);

  execute format(
    'comment on function public.jireh_has_permission_legado(%s) is %L',
    v_ident,
    'Copia intacta da logica antiga: perfil, concessoes individuais do JIREH e o '
    'cargo CFO a exercer o perfil FINANCEIRO. Nao chamar directamente — quem '
    'decide e jireh_has_permission, que encaminha para a Central o que ja '
    'estiver trocado.');

  execute format(
    'comment on function public.jireh_has_permission(%s) is %L',
    v_ident,
    'Apesar do nome, decide para o ecossistema todo: veio de quando as bases se '
    'juntaram. E o unico interruptor. Cada aplicacao que passa a obedecer a '
    'Central e uma condicao a mais aqui, e reverter e tira-la.');
end
$mig$;



-- ---------------------------------------------------------------------
-- has_permission volta a ser uma passagem
-- ---------------------------------------------------------------------
-- Deixar a condicao nos dois sitios daria a mesma resposta, mas seriam dois
-- sitios para manter e um deles seria esquecido.
create or replace function public.has_permission(perm_code character varying)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select public.jireh_has_permission(perm_code);
$function$;


-- ---------------------------------------------------------------------
-- Conferencia
-- ---------------------------------------------------------------------
select 'copias legadas criadas: ' || count(*)::text
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'jireh_has_permission_legado';

select 'divergencia total: ' || count(*)::text
  from public.shaar_permissao_divergencias;

-- Fumo dos dois caminhos. Corre como postgres, sem JWT: o esperado e falso
-- nos dois. O que se testa e que nenhum levanta excepcao nem entra em ciclo.
select 'has_permission (codigo TETELESTAI): ' ||
       coalesce(public.has_permission('todo.create'::varchar)::text, 'nulo');

select 'jireh_has_permission (codigo antigo): ' ||
       coalesce(public.jireh_has_permission('audit:read'::varchar)::text, 'nulo');

-- E o que passou a ficar por fora: so quem chamar a legada directamente.
select 'politicas a chamar a legada directamente: ' || count(*)::text
  from pg_policy p
  join pg_class c on c.oid = p.polrelid
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public'
   and (coalesce(pg_get_expr(p.polqual, p.polrelid), '')
     || coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '')) ~ 'jireh_has_permission_legado';
