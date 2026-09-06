// SHAAR · emissor de bilhetes RS256
//
// O SHAAR e uma pagina estatica: nao tem servidor onde guardar chave privada
// nem assinar. Este e esse servidor.
//
// Fluxo:
//   1. recebe o token do GoTrue que o utilizador ja tem
//   2. pergunta a base, COM esse token, se ele pode entrar na aplicacao
//   3. se puder, assina um bilhete RS256 com aud = codigo da aplicacao
//
// O bilhete e curto (15 min), tem destinatario, e a aplicacao valida a
// assinatura com a chave PUBLICA. Nenhuma aplicacao consegue emitir bilhete:
// so o SHAAR tem a privada. E a razao de ser da fase 2.
//
// Nada do que vai no bilhete vem do cliente. Tudo sai de
// shaar_autorizar_bilhete(), que le da base. Alterar o papel no DevTools nao
// muda nada, porque o cliente nunca opina sobre o conteudo.

const URL_BASE = Deno.env.get("SUPABASE_URL") ?? "http://api-gw:8000";
const ANON = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const PEM_B64 = Deno.env.get("SHAAR_SIGNING_PEM_B64") ?? "";
const KID = Deno.env.get("SHAAR_SIGNING_KID") ?? "";
const EMISSOR = "https://api.xptoinc.com.br/shaar";
const VIDA_SEG = 15 * 60;

const cabecalhos = {
  "content-type": "application/json",
  "cache-control": "no-store",
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, apikey, content-type",
  "access-control-allow-methods": "POST, OPTIONS",
};

function b64u(dados: Uint8Array | string): string {
  const bytes = typeof dados === "string" ? new TextEncoder().encode(dados) : dados;
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// PEM PKCS#8 -> CryptoKey de assinatura
let chaveCache: CryptoKey | null = null;
async function chave(): Promise<CryptoKey> {
  if (chaveCache) return chaveCache;
  const pem = atob(PEM_B64);
  const corpo = pem.replace(/-----(BEGIN|END)[^-]+-----/g, "").replace(/\s+/g, "");
  const bruto = Uint8Array.from(atob(corpo), (c) => c.charCodeAt(0));
  chaveCache = await crypto.subtle.importKey(
    "pkcs8", bruto,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false, ["sign"],
  );
  return chaveCache;
}

async function assinar(carga: Record<string, unknown>): Promise<string> {
  const cab = b64u(JSON.stringify({ alg: "RS256", typ: "JWT", kid: KID }));
  const pay = b64u(JSON.stringify(carga));
  const ass = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5", await chave(), new TextEncoder().encode(`${cab}.${pay}`),
  );
  return `${cab}.${pay}.${b64u(new Uint8Array(ass))}`;
}

const erro = (codigo: number, motivo: string) =>
  new Response(JSON.stringify({ erro: motivo }), { status: codigo, headers: cabecalhos });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cabecalhos });
  if (req.method !== "POST") return erro(405, "metodo_nao_suportado");
  if (!PEM_B64 || !KID) return erro(503, "emissor_sem_chave");

  const auth = req.headers.get("authorization") ?? "";
  if (!auth.toLowerCase().startsWith("bearer ")) return erro(401, "sem_token");

  let app = "";
  try {
    const corpo = await req.json();
    app = String(corpo?.app ?? "").trim().toUpperCase();
  } catch { /* corpo invalido cai no teste seguinte */ }
  // so letras, digitos e sublinhado: o codigo entra numa consulta e num aud
  if (!app || !/^[A-Z0-9_]{2,32}$/.test(app)) return erro(400, "app_invalida");

  // A decisao e da base, com o token de QUEM PEDE — nunca com o service role.
  // Assim shaar_usuario_atual() resolve a pessoa certa e a auditoria regista
  // o pedido em nome dela.
  const r = await fetch(`${URL_BASE}/rest/v1/rpc/shaar_autorizar_bilhete`, {
    method: "POST",
    headers: { "apikey": ANON, "authorization": auth, "content-type": "application/json" },
    body: JSON.stringify({ p_app_code: app }),
  });
  if (!r.ok) return erro(401, "token_invalido");

  const d = await r.json();
  if (!d?.permitido) {
    // 403 mesmo com token valido: e exactamente o caso do briefing
    return new Response(JSON.stringify({ erro: "sem_acesso", motivo: d?.motivo ?? "negado" }),
      { status: 403, headers: cabecalhos });
  }

  const agora = Math.floor(Date.now() / 1000);
  const bilhete = await assinar({
    iss: EMISSOR,
    aud: d.app,                 // o destinatario: bilhete do TIKKUN nao serve no JIREH
    sub: d.sub,
    email: d.email,
    nome: d.nome,
    perfil: d.perfil,
    nivel: d.nivel,
    cargo: d.cargo,
    iat: agora,
    nbf: agora - 5,             // tolerancia para relogios ligeiramente adiantados
    exp: agora + VIDA_SEG,
    jti: crypto.randomUUID(),
  });

  return new Response(JSON.stringify({
    bilhete, expira_em: VIDA_SEG, url: d.url, app: d.app,
  }), { headers: cabecalhos });
});
