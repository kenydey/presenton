const DEFAULT_NEXTJS_INTERNAL_BASE_URL = "http://127.0.0.1:5000";

function normalizeBaseUrl(rawUrl: string): string {
  return rawUrl.replace(/\/+$/, "");
}

export function getNextjsInternalBaseUrl(): string {
  const envUrl = process.env.PRESENTON_NEXTJS_INTERNAL_URL?.trim();
  if (envUrl) {
    return normalizeBaseUrl(envUrl);
  }
  return DEFAULT_NEXTJS_INTERNAL_BASE_URL;
}

