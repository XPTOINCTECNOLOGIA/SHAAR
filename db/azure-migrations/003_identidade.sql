-- =====================================================================
-- Identidade: fechar o ramo do e-mail, e registar quem so entra por ele
-- =====================================================================
--
-- Ao conferir o TETELESTAI depois da troca, duas coisas apareceram.
--
-- A primeira e um buraco em `shaar_usuario_atual`, e nao tem nada a ver com
-- a Central: e anterior. A funcao resolve a pessoa por `auth_user_id` OU por
-- e-mail — tem de ser assim, porque ha dois caminhos de autenticacao (Entra
-- ID e credencial local) e a mesma pessoa e a mesma linha de `users` nos
-- dois. Mas o ramo do e-mail comparava com `coalesce(<claim>, '')`. Um
-- pedido que chegue sem claim de e-mail poe a cadeia vazia do lado direito,
-- e a cadeia vazia casa com qualquer linha de `users` cujo e-mail seja
-- vazio. Bastaria existir uma para que pedidos sem identidade passassem a
-- ser essa pessoa.
--
-- A segunda e o desempate. Havendo mais do que uma linha a casar, o `limit
-- 1` sem ordem escolhia arbitrariamente — e podia escolher a linha do
-- e-mail em vez da linha do `auth_user_id`, ou seja, a errada de duas
-- maneiras diferentes.
--
-- As duas correccoes so podem estreitar. Nao ha nenhum caso em que a funcao
-- passe a devolver nada onde hoje devolve alguem legitimo: o e-mail vazio
-- nunca identificou ninguem de proposito, e a ordem so decide entre
-- candidatos que ja casavam.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. A FUNCAO
-- ---------------------------------------------------------------------
create or replace function public.shaar_usuario_atual()
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  with pedido as (
    select auth.uid() as uid,
           lower(coalesce(
             nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'email', ''),
             nullif(current_setting('request.jwt.claims', true)::jsonb
                      -> 'user_metadata' ->> 'email', ''),
             '')) as email
  )
  select u.id
    from public.users u, pedido p
   where u.active and not u.blocked
     and (
          (p.uid is not null and u.auth_user_id = p.uid)
       or (p.email <> ''   and lower(u.email) = p.email)
     )
   -- Quem tem conta de autenticacao ligada ganha ao que so casa por e-mail,
   -- e entre iguais decide o id. Deixa de haver escolha arbitraria.
   -- coalesce por causa da logica de tres valores: com auth_user_id nulo a
   -- expressao da nulo, e DESC em PostgreSQL e NULLS FIRST por omissao — sem
   -- isto a linha que so casa por e-mail passava a frente da certa.
   order by coalesce(p.uid is not null and u.auth_user_id = p.uid, false) desc, u.id
   limit 1;
$$;

comment on function public.shaar_usuario_atual is
  'Resolve quem esta pedindo, venha de Entra ID ou de credencial local. '
  'O e-mail e a chave comum aos dois caminhos de autenticacao. '
  'E-mail vazio nunca identifica ninguem, e a conta ligada ganha ao e-mail.';

-- Sem revoke/grant de proposito: `create or replace` preserva a ACL que a
-- funcao ja tem. Repeti-los aqui arriscava retirar em silencio uma concessao
-- que exista em producao e nao neste ficheiro.


-- ---------------------------------------------------------------------
-- 2. QUEM SO E RECONHECIDO POR E-MAIL FICA REGISTADO
-- ---------------------------------------------------------------------
-- Quatro pessoas activas, com portao aberto, nao tem `auth_user_id`. A
-- migracao anterior tentou liga-las e ligou zero: nao foi salvaguarda a
-- travar, foi impossibilidade — nao existe conta em `auth.users` com aquele
-- e-mail. Entram por Entra ID, onde a conta de autenticacao vive no tenant
-- e nao aqui.
--
-- Isto tem uma consequencia concreta que nao devia passar em silencio: o
-- codigo antigo do TETELESTAI so olhava para `auth_user_id`, portanto a
-- aplicacao estava partida para elas. A Central reconhece-as pelo e-mail,
-- portanto passou a funcionar. Ninguem decidiu isso — foi consequencia de
-- trocar a autoridade. Fica uma revisao aberta por pessoa para que alguem
-- confirme que o acesso e mesmo para existir.
insert into public.shaar_permission_revisao (user_id, app_code, gatilho, detalhe)
select u.id, null, 'migracao',
       jsonb_build_object(
         'nota', 'Esta pessoa nao tem conta em auth.users: e reconhecida pelo e-mail, '
              || 'pelo caminho do Entra ID. O codigo antigo do TETELESTAI so olhava para '
              || 'auth_user_id, por isso a aplicacao nao funcionava para ela. Agora que a '
              || 'Central decide, funciona. Confirmar que o acesso e para existir.',
         'origem', 'identidade_so_por_email')
  from public.users u
 where u.active and not u.blocked and u.auth_user_id is null
   and exists (select 1 from public.shaar_gate_access g where g.user_id = u.id)
   and not exists (
     select 1 from public.shaar_permission_revisao r
      where r.user_id = u.id
        and r.detalhe ->> 'origem' = 'identidade_so_por_email');


-- ---------------------------------------------------------------------
-- Conferencia
-- ---------------------------------------------------------------------
select 'pessoas activas com e-mail vazio: ' || count(*)::text
  from public.users u
 where u.active and not u.blocked and coalesce(u.email, '') = '';

select 'e-mails partilhados por mais de uma pessoa activa: ' || count(*)::text
  from (select lower(email) from public.users
         where active and not blocked
         group by lower(email) having count(*) > 1) d;

select 'revisoes de identidade abertas: ' || count(*)::text
  from public.shaar_permission_revisao
 where detalhe ->> 'origem' = 'identidade_so_por_email' and resolvido_em is null;

-- Fumo: a funcao continua a responder. Corre como postgres, sem JWT, portanto
-- o esperado e nulo — e agora e nulo por construcao, nao por acaso.
select 'shaar_usuario_atual sem JWT: ' ||
       coalesce(public.shaar_usuario_atual()::text, 'nulo');

select 'divergencia total: ' || count(*)::text
  from public.shaar_permissao_divergencias;
