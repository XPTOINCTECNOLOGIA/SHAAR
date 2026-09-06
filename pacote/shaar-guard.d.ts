/**
 * SHAAR Guard · declarações de tipo
 *
 * Vive ao lado de shaar-guard.js e viaja com ele. Sem isto, cada aplicação em
 * TypeScript teria de silenciar o import ou inventar os seus próprios tipos —
 * e nove aplicações inventando tipos para a mesma coisa é como as definições
 * divergem.
 */

/** O que o bilhete afirma. Tudo vem da base do SHAAR, nunca do navegador. */
export interface Identidade {
  /** emissor: sempre o SHAAR */
  iss: string;
  /** destinatário: o código da aplicação a que este bilhete serve */
  aud: string;
  /** id da pessoa em public.users, como texto */
  sub: string;
  email: string;
  nome: string | null;
  perfil: string | null;
  nivel: number;
  cargo: string | null;
  /** o que esta pessoa pode nesta aplicacao: codigo -> limites */
  perms: Record<string, Record<string, unknown>>;
  /** versao das permissoes; muda sempre que alguem lhes mexe */
  pv: number;
  iat: number;
  nbf: number;
  exp: number;
  /** identificador único deste bilhete */
  jti: string;
  /**
   * Sessão do ecossistema, entregue pelo SHAAR só na chegada. É o que dispensa
   * novo login: a aplicação deve passá-la ao seu cliente Supabase com
   * `supabase.auth.setSession(sessao)` ANTES de renderizar.
   */
  sessao?: { access_token: string; refresh_token: string } | null;
}

export type MotivoRecusa =
  | "sem_bilhete"
  | "malformado"
  | "algoritmo_recusado"
  | "kid_desconhecido"
  | "assinatura_invalida"
  | "emissor_errado"
  | "destinatario_errado"
  | "expirado"
  | "ainda_nao_vale"
  | "erro_verificacao";

export interface Veredicto {
  ok: boolean;
  motivo?: MotivoRecusa;
  detalhe?: string;
  /** presente mesmo em algumas recusas, para o registo saber de quem se trata */
  dados?: Identidade;
}

export interface Opcoes {
  /** código da aplicação, tal como está em shaar_apps.code */
  app: string;
  /**
   * "exigir"   — sem bilhete válido, manda a pessoa ao SHAAR
   * "observar" — verifica e regista, mas deixa passar. Para estrear em
   *              produção sem risco de trancar alguém fora.
   */
  modo?: "exigir" | "observar";
  shaar?: string;
  api?: string;
  /** tolerância de relógio entre máquinas, em segundos */
  margemSegundos?: number;
  /** quantos segundos antes de expirar se vai buscar bilhete novo */
  renovarAntesDe?: number;
  /** chamado em modo de observação, com o veredicto */
  aoObservar?: (veredicto: Veredicto) => void;
}

/**
 * Regista a aplicação na fronteira do SHAAR.
 * Devolve a identidade do bilhete, ou null quando não há bilhete válido
 * (em modo "exigir" a navegação já terá sido redireccionada).
 */
export function registerApplication(opcoes: Opcoes): Promise<Identidade | null>;

/** Verifica um bilhete isolado. Nunca lança. */
export function verificarBilhete(
  bilhete: string,
  opcoes?: Partial<Opcoes>,
): Promise<Veredicto>;

/**
 * Adopta a sessão no cliente Supabase da aplicação e confirma que colou.
 * Se não colar, devolve a pessoa ao SHAAR em vez de deixar a aplicação
 * mostrar o seu próprio ecrã de login.
 */
export function adoptarSessao(
  supabase: { auth: { setSession: Function; getSession: Function } },
  eu: Identidade | null,
  opcoes?: Partial<Opcoes>,
): Promise<boolean>;

/** Apaga o bilhete guardado nesta aba. */
export function esquecerBilhete(app: string): void;

/**
 * Limites de uma concessão. Objecto vazio significa sem limite.
 *
 *   { departamento: ["FIN","OPS"] }   valor tem de estar na lista
 *   { valor_max: 50000 }              contexto.valor <= 50000
 *   { nivel_min: 3 }                  contexto.nivel  >= 3
 *   { unidade: "matriz" }             igualdade exacta
 */
export type Escopo = Record<string, string | number | boolean | string[]>;

/** Os factos do recurso concreto sobre o qual se pergunta. */
export type Contexto = Record<string, string | number | boolean>;

/**
 * Esta pessoa pode, nesta aplicação, fazer isto — neste contexto?
 *
 * Responde pelo bilhete assinado pelo SHAAR e já verificado por esta
 * biblioteca. Zero chamadas de rede.
 *
 * DECIDE O QUE APARECE, NÃO O QUE ACONTECE. Quem alterar a lista no navegador
 * vê o botão, e ao carregar nele leva um "não" da base de dados. Esconder um
 * botão nunca foi autorização.
 *
 * Dimensão de escopo declarada e ausente do contexto devolve `false` — nunca
 * "sim por omissão".
 */
export function podeFazer(codigo: string, contexto?: Contexto): boolean;

/** Todas as permissões desta pessoa nesta aplicação, com os seus limites. */
export function minhasPermissoes(): Record<string, Escopo>;

/**
 * A versão das permissões que veio no bilhete. Compare-a com
 * `GET /permissoes/versao` quando a aba ganhar foco para saber se o que tem
 * na mão ficou velho, sem perguntar a cada clique.
 */
export function versaoPermissoes(): number;

declare const _default: {
  registerApplication: typeof registerApplication;
  adoptarSessao: typeof adoptarSessao;
  verificarBilhete: typeof verificarBilhete;
  esquecerBilhete: typeof esquecerBilhete;
  podeFazer: typeof podeFazer;
  minhasPermissoes: typeof minhasPermissoes;
  versaoPermissoes: typeof versaoPermissoes;
};
export default _default;
