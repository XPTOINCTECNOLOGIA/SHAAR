-- =====================================================================
-- O anónimo não pergunta
-- =====================================================================
--
-- A verificação da 028 em produção mostrou que `shaar_minhas_permissoes`
-- responde também à role `anon` (HTTP 200, lista vazia). Não é fuga de
-- informação — sem identidade a função não lista nada — mas expõe que os
-- default privileges do banco dão EXECUTE ao `anon` mesmo depois do
-- `revoke ... from public`, porque a role recebe o privilégio por outra
-- via. A Central só fala com pessoas autenticadas; fecha-se a porta
-- explicitamente, e fica o registo do porquê.
--
-- Idempotente: revoke de privilégio inexistente é um no-op.
-- =====================================================================

revoke all on function public.shaar_minhas_permissoes(text) from anon;

-- Reafirma o par correcto, para o caso de a ACL ter sido recriada entretanto.
revoke all on function public.shaar_minhas_permissoes(text) from public;
grant execute on function public.shaar_minhas_permissoes(text) to authenticated;

-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
-- O anon não pode executar; o authenticated pode. Lê-se directamente da ACL,
-- sem depender de sessão.
select 'anon executa shaar_minhas_permissoes: ' ||
       has_function_privilege('anon', 'public.shaar_minhas_permissoes(text)', 'execute')::text;

select 'authenticated executa shaar_minhas_permissoes: ' ||
       has_function_privilege('authenticated', 'public.shaar_minhas_permissoes(text)', 'execute')::text;

do $$
begin
  if has_function_privilege('anon', 'public.shaar_minhas_permissoes(text)', 'execute') then
    raise exception 'anon ainda executa shaar_minhas_permissoes — a ACL não fechou';
  end if;
  if not has_function_privilege('authenticated', 'public.shaar_minhas_permissoes(text)', 'execute') then
    raise exception 'authenticated perdeu o execute de shaar_minhas_permissoes — a UI ficaria cega';
  end if;
end $$;
