-- SHAAR · a auditoria precisa sobreviver ao rollback
--
-- O registo de negativa estava a ser perdido, e a razão é sutil: a função
-- regista o evento e logo a seguir levanta a exceção que nega o acesso. A
-- exceção desfaz a transação inteira — incluindo o INSERT da auditoria.
--
-- Ou seja: exatamente os eventos que mais interessam a uma investigação
-- — acesso negado, tentativa de escalonamento — eram os únicos que nunca
-- ficavam registados. Silenciosamente, porque shaar_registrar engole falhas
-- de propósito.
--
-- Postgres não tem transação autónoma nativa. O caminho normal é dblink:
-- abrir uma ligação de volta ao próprio servidor, escrever lá e fechar. Essa
-- escrita tem transação própria e não é afetada pelo rollback de quem chamou.

create extension if not exists dblink;

create or replace function public.shaar_registrar(
  p_evento    text,
  p_resultado text default 'sucesso',
  p_app_code  text default null,
  p_detalhe   jsonb default '{}'::jsonb,
  p_email     text default null,
  p_user_id   bigint default null
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_uid   bigint;
  v_email text;
  v_ip    text;
  v_ag    text;
  v_hdr   jsonb;
  v_sql   text;
begin
  begin
    v_uid := coalesce(p_user_id, public.shaar_usuario_atual());

    v_email := coalesce(
      p_email,
      nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'email', ''),
      (select u.email from public.users u where u.id = v_uid)
    );

    -- cabecalhos que o PostgREST expoe; ausentes fora de uma requisicao HTTP
    v_hdr := nullif(current_setting('request.headers', true), '')::jsonb;
    v_ip  := nullif(split_part(coalesce(v_hdr ->> 'x-forwarded-for', ''), ',', 1), '');
    v_ag  := nullif(left(coalesce(v_hdr ->> 'user-agent', ''), 400), '');

    -- Tudo por quote_nullable: os valores vem de cabecalho HTTP e de JWT, que
    -- sao entrada externa. Nenhum deles entra na instrucao sem ser citado.
    v_sql := format(
      'insert into public.shaar_auditoria
         (evento, resultado, user_id, email, app_code, ip, agente, detalhe)
       values (%L, %L, %s, %s, %s, %s::inet, %s, %L::jsonb)',
      p_evento, p_resultado,
      coalesce(v_uid::text, 'null'),
      quote_nullable(lower(v_email)),
      quote_nullable(p_app_code),
      quote_nullable(v_ip),
      quote_nullable(v_ag),
      coalesce(p_detalhe, '{}'::jsonb)
    );

    -- ligacao de volta ao proprio servidor: transacao propria, imune ao
    -- rollback de quem chamou
    perform dblink('dbname=' || current_database(), v_sql);

  exception when others then
    -- engolir de proposito: auditoria que derruba a operacao auditada seria
    -- um modo de negacao de servico
    null;
  end;
end;
$$;

comment on function public.shaar_registrar is
  'Regista um evento na auditoria central, em transacao propria via dblink, para '
  'que a negativa sobreviva ao rollback da excecao que a produziu. Nunca levanta '
  'excecao.';

revoke all on function public.shaar_registrar(text,text,text,jsonb,text,bigint) from public;
grant execute on function public.shaar_registrar(text,text,text,jsonb,text,bigint) to authenticated;
