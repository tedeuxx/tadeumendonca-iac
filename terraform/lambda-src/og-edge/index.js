// og-edge — CloudFront Viewer Request handler (/backend/og-edge-handler).
//
// 3-way User-Agent routing at the edge so the SPA stays a fast client app for humans while bots get
// real HTML:
//   human   → passthrough (return the request unchanged; CloudFront serves the S3 SPA)
//   social  → synth a tiny OG-only HTML doc from /og-meta JSON (what link unfurlers actually read)
//   crawler → synth the full indexable HTML from /prerender (what search engines index)
//
// Lambda@Edge constraints shape every choice here:
//   * NO env vars allowed → the API base is derived from the request Host header (api.<host>), so the
//     SAME function works in staging and production with zero build-time injection.
//   * Zero dependencies → only Node built-ins (global fetch, available on nodejs18+). Nothing to bundle;
//     Terraform zips this single file directly (/infrastructure/lambda, /infrastructure/cloudfront).
//   * CommonJS (exports.handler) → matches handler "index.handler".
//
// TRADE-OFF (viewer-request generated responses are capped at 40 KB incl. headers): we guard on body
// size and fall back to passthrough if a prerender ever exceeds it. The alternative — origin-request
// rewriting to the API GW origin (1 MB cap, CloudFront-cacheable) — is heavier infra (the distribution
// would need the API GW as an origin and the association moved to origin-request); deferred until a
// rendered page actually approaches the cap. For Phase 1 the profile HTML is a few KB, well under.

'use strict';

const MAX_GENERATED_BODY = 40000; // viewer-request response ceiling (bytes, incl. headers ≈ body)
const FETCH_TIMEOUT_MS = 3500; // absorb a cold (in-VPC) BFF start; still <5s viewer-request ceiling — fall back on timeout
const CACHE = 'public, max-age=300';

// Order matters: a few UAs match both lists, and social link-unfurlers should win (they want OG tags,
// not a full crawl). Keep these conservative — an unmatched bot just gets the SPA (still valid HTML).
const SOCIAL =
  /facebookexternalhit|facebot|twitterbot|linkedinbot|slackbot|slack-imgproxy|whatsapp|discordbot|telegrambot|pinterest|redditbot|skypeuripreview|vkshare|embedly|quora link preview|nuzzel|bitlybot|flipboard|tumblr|mastodon|iframely/i;
const CRAWLER =
  /googlebot|bingbot|google-inspectiontool|duckduckbot|baiduspider|yandex|sogou|exabot|ia_archiver|applebot|petalbot|bingpreview|chrome-lighthouse/i;

// URI → (type, slug). The homepage maps to the profile (the CV); /posts/<id> → a feed post (Phase 2);
// /articles/<slug> → a long-form article (Phase 3). Everything else is passthrough (humans + bots get
// the SPA shell).
function route(uri) {
  if (uri === '/' || uri === '/index.html') return { type: 'profile', slug: 'me' };
  const post = /^\/posts\/([^/]+)\/?$/.exec(uri);
  if (post) return { type: 'posts', slug: post[1] };
  const article = /^\/articles\/([^/]+)\/?$/.exec(uri);
  if (article) return { type: 'articles', slug: article[1] };
  // /p/<code> → short share URL; the BFF resolves the code → post for og-meta/prerender.
  const short = /^\/p\/([a-zA-Z0-9]{6,8})\/?$/.exec(uri);
  if (short) return { type: 'p', slug: short[1] };
  return null;
}

function classify(ua) {
  if (!ua) return 'human';
  if (SOCIAL.test(ua)) return 'social';
  if (CRAWLER.test(ua)) return 'crawler';
  return 'human';
}

const header = (request, name) => {
  const h = request.headers[name];
  return h && h[0] ? h[0].value : undefined;
};

async function fetchText(url) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), FETCH_TIMEOUT_MS);
  try {
    const res = await fetch(url, { signal: ctrl.signal, headers: { accept: '*/*' } });
    if (!res.ok) return null;
    return await res.text();
  } catch {
    return null; // network error / timeout → caller falls back to passthrough
  } finally {
    clearTimeout(t);
  }
}

const escapeHtml = (s) =>
  String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// Minimal OG-only document for social unfurlers — they parse <head> meta and ignore <body>.
function ogHtml(meta) {
  const { title, description, image_url, url } = meta;
  return `<!doctype html><html lang="en"><head><meta charset="utf-8" />
<title>${escapeHtml(title)}</title>
<meta name="description" content="${escapeHtml(description)}" />
<link rel="canonical" href="${escapeHtml(url)}" />
<meta property="og:type" content="website" />
<meta property="og:title" content="${escapeHtml(title)}" />
<meta property="og:description" content="${escapeHtml(description)}" />
<meta property="og:url" content="${escapeHtml(url)}" />
<meta property="og:image" content="${escapeHtml(image_url)}" />
<meta name="twitter:card" content="summary_large_image" /></head><body></body></html>`;
}

function htmlResponse(body) {
  if (Buffer.byteLength(body, 'utf8') > MAX_GENERATED_BODY) return null; // too big → passthrough
  return {
    status: '200',
    statusDescription: 'OK',
    headers: {
      'content-type': [{ key: 'Content-Type', value: 'text/html; charset=utf-8' }],
      'cache-control': [{ key: 'Cache-Control', value: CACHE }],
      'x-prerendered-by': [{ key: 'X-Prerendered-By', value: 'og-edge' }],
    },
    body,
  };
}

exports.handler = async (event) => {
  const request = event.Records[0].cf.request;
  const kind = classify(header(request, 'user-agent'));
  if (kind === 'human') return request;

  const target = route(request.uri);
  if (!target) return request;

  const host = header(request, 'host');
  if (!host) return request;
  const apiBase = `https://api.${host}`;

  if (kind === 'social') {
    const json = await fetchText(`${apiBase}/og-meta/${target.type}/${target.slug}`);
    if (!json) return request;
    let meta;
    try {
      meta = JSON.parse(json);
    } catch {
      return request;
    }
    return htmlResponse(ogHtml(meta)) || request;
  }

  // crawler
  const html = await fetchText(`${apiBase}/prerender/${target.type}/${target.slug}`);
  if (!html) return request;
  return htmlResponse(html) || request;
};
