// SHAAR · chaves públicas de verificação (JWKS)
//
// Cada aplicação valida o bilhete sozinha, com a chave pública que busca aqui.
// Não precisa de falar com o SHAAR a cada pedido: busca uma vez, guarda em
// cache, e verifica localmente. É o que torna a fronteira barata.
//
// Endpoint deliberadamente público e sem autenticação — chave pública é para
// ser lida. O que ele nunca serve é a chave privada, que só existe em
// /etc/xpto/shaar-signing.pem, modo 600, na máquina do emissor.

const JWKS = Deno.env.get("SHAAR_JWKS") ?? "";

Deno.serve((req) => {
  const cabecalhos = {
    "content-type": "application/json",
    // uma hora de cache: a rotação de chave publica a nova e mantém a antiga
    // no conjunto durante a sobreposição, tal como se fez com a chave anónima
    "cache-control": "public, max-age=3600",
    "access-control-allow-origin": "*",
  };
  if (req.method === "OPTIONS") return new Response("ok", { headers: cabecalhos });
  if (!JWKS) {
    return new Response(JSON.stringify({ erro: "sem_chaves" }),
      { status: 503, headers: cabecalhos });
  }
  return new Response(JWKS, { headers: cabecalhos });
});
