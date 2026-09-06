// SHAAR · verificação síncrona de autorização
//
// Uma das três implementações do mesmo contrato:
//
//     pode(pessoa, aplicacao, permissao, contexto) -> permitido | negado
//
// As outras duas sao shaar_pode() em SQL, dentro das politicas RLS, e
// podeFazer() no cliente, a ler o bilhete. Esta serve dois casos:
//
//   · ACTOS DE ALTO VALOR — aprovar, assinar, exportar em massa. E mais
//     lenta de proposito: o objectivo e deixar registo de que foi
//     perguntado, por quem, quando e de que maquina — mesmo quando a
//     resposta e "nao". Uma recusa que nao fica registada nao serve para
//     auditoria nenhuma.
//
//   · SISTEMAS FORA DESTA BASE — hoje nao ha nenhum, mas o dia em que
//     houver, ou em que as bases se separem, esta funcao passa a ser o
//     caminho principal sem que nenhuma aplicacao mude uma linha. E essa a
//     razao de existir um contrato em vez de chamadas directas as tabelas.
//
// A decisao NAO e tomada aqui. E tomada pela base, por shaar_porque(),
// chamada com o token de quem pergunta — nunca com service_role. Assim
// shaar_usuario_atual() resolve a pessoa certa e nao ha forma de perguntar
// "pode o Joao?" fazendo-se passar por outro.

const URL_BASE = Deno.env.get("SUPABASE_URL") ?? "http://api-gw:8000";
const ANON = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

const cabecalhos = {
  "content-type": "application/json",
  "cache-control": "no-store",
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, apikey, content-type",
  "access-control-allow-methods": "POST, OPTIONS",
};

const erro = (codigo: number, motivo: string) =>
  new Response(JSON.stringify({ permitido: false, erro: motivo }),
    { status: codigo, headers: cabecalhos });

// Chama uma funcao da base em nome de quem pergunta.
async function rpc(nome: string, auth: string, args: Record<string, unknown>) {
  const r = await fetch(`${URL_BASE}/rest/v1/rpc/${nome}`, {
    method: "POST",
    headers: { apikey: ANON, authorization: auth, "content-type": "application/json" },
    body: JSON.stringify(args),
  });
  if (!r.ok) return null;
  // shaar_registrar devolve void: o PostgREST responde 204 com corpo vazio, e
  // r.json() rebenta nele. Ler texto primeiro e o que torna esta funcao util
  // tanto para quem devolve dados como para quem so regista.
  const texto = await r.text();
  if (!texto) return null;
  try { return JSON.parse(texto); } catch { return null; }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cabecalhos });
  if (req.method !== "POST") return erro(405, "metodo_nao_suportado");

  const auth = req.headers.get("authorization") ?? "";
  if (!auth.toLowerCase().startsWith("bearer ")) return erro(401, "sem_token");

  let app = "", pedidas: string[] = [], contexto: Record<string, unknown> = {};
  let recurso: Record<string, unknown> | null = null;
  try {
    const corpo = await req.json();
    app = String(corpo?.app ?? "").trim().toUpperCase();
    if (typeof corpo?.permissao === "string") pedidas = [corpo.permissao];
    else if (Array.isArray(corpo?.permissoes)) pedidas = corpo.permissoes.map(String);
    if (corpo?.contexto && typeof corpo.contexto === "object") contexto = corpo.contexto;
    if (corpo?.recurso && typeof corpo.recurso === "object") recurso = corpo.recurso;
  } catch { /* corpo invalido cai nos testes seguintes */ }

  if (!app || !/^[A-Z0-9_]{2,32}$/.test(app)) return erro(400, "app_invalida");
  if (pedidas.length === 0 || pedidas.length > 50) return erro(400, "permissoes_invalidas");
  for (const p of pedidas) {
    // a mesma forma que o catalogo aceita: nada de texto livre a entrar numa consulta
    if (!/^[a-z][a-z0-9_-]*([.:][a-z][a-z0-9_-]*)+$/.test(p)) {
      return erro(400, "permissao_com_forma_invalida");
    }
  }

  const resultados: Record<string, { permitido: boolean; motivo: string }> = {};
  let todas = true;

  for (const p of pedidas) {
    const d = await rpc("shaar_porque", auth, {
      p_app: app, p_code: p, p_ctx: contexto,
    });
    // shaar_porque devolve uma linha; qualquer coisa que nao seja um "permitido"
    // claro conta como negacao. Falha fechada, sempre.
    const linha = Array.isArray(d) ? d[0] : d;
    const permitido = Boolean(linha?.permitido);
    const motivo = String(linha?.motivo ?? "indisponivel");
    resultados[p] = { permitido, motivo };
    if (!permitido) todas = false;
  }

  // O registo da tentativa e a razao de ser deste caminho. Vai tanto o "sim"
  // como o "nao": saber quem tentou o que nao podia vale tanto como saber
  // quem fez o que podia.
  await rpc("shaar_registrar", auth, {
    p_evento: todas ? "ACTO_AUTORIZADO" : "ACTO_NEGADO",
    p_resultado: todas ? "sucesso" : "negado",
    p_app_code: app,
    p_detalhe: {
      permissoes: pedidas,
      contexto,
      recurso,
      resultados,
    },
  });

  const negadas = Object.entries(resultados)
    .filter(([, v]) => !v.permitido)
    .map(([k, v]) => ({ permissao: k, motivo: v.motivo }));

  return new Response(JSON.stringify({
    permitido: todas,
    motivo: todas ? "permitido" : (negadas[0]?.motivo ?? "negado"),
    negadas,
    resultados,
  }), { status: todas ? 200 : 403, headers: cabecalhos });
});
