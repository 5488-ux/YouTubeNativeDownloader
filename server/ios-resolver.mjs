import { createServer } from 'node:http';
import { request as httpsRequest } from 'node:https';
import { request as httpRequest } from 'node:http';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { randomBytes } from 'node:crypto';
import { copyFile, mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';

const execFileAsync = promisify(execFile);
const HOST = '127.0.0.1';
const PORT = 19193;
const YTDLP = '/opt/ytdlp-php/bin/yt-dlp';
const DENO = '/usr/local/bin/deno';
const SOURCE_COOKIE_FILE = '/www/wwwroot/youtube.789113.cn/storage/cookies.txt';
const COOKIE_FILE = '/var/lib/youtube-ios-resolver/cookies.txt';
const TOKEN_FILE = '/var/lib/youtube-ios-resolver/tokens.json';
const TOKEN_TTL = 6 * 60 * 60 * 1000;
const MAX_BODY = 32 * 1024;
const tokens = new Map();
const rateLimits = new Map();

await mkdir(dirname(TOKEN_FILE), { recursive: true });
try {
  await copyFile(SOURCE_COOKIE_FILE, COOKIE_FILE);
} catch {}
try {
  const saved = JSON.parse(await readFile(TOKEN_FILE, 'utf8'));
  const now = Date.now();
  for (const [token, value] of Object.entries(saved)) {
    if (value.expiresAt > now) tokens.set(token, value);
  }
} catch {}

function json(res, status, value) {
  const body = Buffer.from(JSON.stringify(value));
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': body.length,
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff'
  });
  res.end(body);
}

async function readJson(req) {
  const chunks = [];
  let length = 0;
  for await (const chunk of req) {
    length += chunk.length;
    if (length > MAX_BODY) throw new Error('请求内容过大');
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

function validYouTubeURL(value) {
  try {
    const parsed = new URL(value);
    const host = parsed.hostname.toLowerCase();
    return parsed.protocol === 'https:' && (
      host === 'youtu.be' || host === 'youtube.com' || host.endsWith('.youtube.com')
    );
  } catch {
    return false;
  }
}

function clientIP(req) {
  return String(req.headers['cf-connecting-ip'] || req.headers['x-forwarded-for'] || req.socket.remoteAddress || '')
    .split(',')[0]
    .trim();
}

function allowResolve(req) {
  const key = clientIP(req);
  const now = Date.now();
  const recent = (rateLimits.get(key) || []).filter(value => now - value < 10 * 60 * 1000);
  if (recent.length >= 20) return false;
  recent.push(now);
  rateLimits.set(key, recent);
  return true;
}

function asNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? Math.round(number) : null;
}

function safeMediaURL(value) {
  try {
    const parsed = new URL(value);
    const host = parsed.hostname.toLowerCase();
    if (parsed.protocol !== 'https:') return null;
    if (!host.endsWith('.googlevideo.com') && !host.endsWith('.youtube.com')) return null;
    return parsed.toString();
  } catch {
    return null;
  }
}

let persistTimer;
function schedulePersist() {
  clearTimeout(persistTimer);
  persistTimer = setTimeout(async () => {
    const temporary = `${TOKEN_FILE}.tmp`;
    await writeFile(temporary, JSON.stringify(Object.fromEntries(tokens)), { mode: 0o600 });
    await rename(temporary, TOKEN_FILE);
  }, 100);
}

function publicBase(req) {
  const host = String(req.headers['x-forwarded-host'] || req.headers.host || 'youtube.789113.cn')
    .replace(/[^A-Za-z0-9.:-]/g, '');
  return `https://${host}/ios-api`;
}

function registerSource(req, format) {
  const sourceURL = safeMediaURL(format?.url);
  if (!sourceURL) throw new Error('解析结果包含无效媒体地址');
  const token = randomBytes(24).toString('hex');
  tokens.set(token, {
    url: sourceURL,
    expiresAt: Date.now() + TOKEN_TTL,
    userAgent: format?.http_headers?.['User-Agent'] || 'Mozilla/5.0'
  });
  schedulePersist();
  const relayURL = `${publicBase(req)}/media/${token}`;
  return {
    url: relayURL,
    fallback_url: null,
    direct_url: sourceURL,
    content_length: asNumber(format.filesize || format.filesize_approx),
    codec: format.vcodec && format.vcodec !== 'none' ? format.vcodec : format.acodec,
    width: asNumber(format.width),
    height: asNumber(format.height),
    fps: asNumber(format.fps),
    bitrate: asNumber((format.tbr || format.abr || format.vbr) * 1000)
  };
}

async function resolveMedia(req, res) {
  if (!allowResolve(req)) {
    json(res, 429, { ok: false, message: '解析太频繁，等几分钟再试。' });
    return;
  }

  let body;
  try {
    body = await readJson(req);
  } catch (error) {
    json(res, 400, { ok: false, message: error.message || 'JSON 无效' });
    return;
  }

  const url = String(body.url || '').trim();
  const kind = body.kind === 'audio' ? 'audio' : 'video';
  const quality = ['best', '1080', '720', '480'].includes(String(body.quality))
    ? String(body.quality)
    : 'best';
  if (!validYouTubeURL(url)) {
    json(res, 422, { ok: false, message: '只支持有效的 YouTube HTTPS 链接。' });
    return;
  }

  const height = quality === 'best' ? '' : `[height<=${quality}]`;
  const format = kind === 'audio'
    ? 'ba[acodec^=mp4a]/ba[ext=m4a]/ba'
    : `bv*[vcodec^=avc1]${height}+ba[acodec^=mp4a]/b[ext=mp4][vcodec^=avc1]${height}`;
  const args = [
    '--dump-single-json', '--skip-download', '--no-playlist', '--no-warnings',
    '--js-runtimes', `deno:${DENO}`,
    '--cookies', COOKIE_FILE,
    '--format', format,
    '--format-sort', 'res,fps,vbr,abr',
    '--user-agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131 Safari/537.36',
    '--', url
  ];

  try {
    const { stdout } = await execFileAsync(YTDLP, args, {
      timeout: 55_000,
      maxBuffer: 24 * 1024 * 1024,
      env: { ...process.env, LC_ALL: 'C.UTF-8' }
    });
    const info = JSON.parse(stdout);
    const requested = Array.isArray(info.requested_formats) ? info.requested_formats : [];
    const videoFormat = requested.find(item => item.vcodec && item.vcodec !== 'none');
    const audioFormat = requested.find(item => item.acodec && item.acodec !== 'none' && (!item.vcodec || item.vcodec === 'none'));
    const single = info.url ? info : null;
    const selectedAudio = kind === 'audio' ? (single || audioFormat) : audioFormat;

    if (!selectedAudio || (kind === 'video' && !videoFormat)) {
      json(res, 422, { ok: false, message: '没有找到兼容的 H.264/AAC 格式。' });
      return;
    }

    json(res, 200, {
      ok: true,
      title: String(info.title || `YouTube-${info.id || 'video'}`).slice(0, 180),
      video_id: String(info.id || ''),
      video: kind === 'video' ? registerSource(req, videoFormat) : null,
      audio: registerSource(req, selectedAudio)
    });
  } catch (error) {
    const stderr = String(error.stderr || '');
    console.error('resolve failed', error.message, stderr.slice(-2000));
    const line = stderr.split('\n').find(value => value.includes('ERROR:')) || '';
    const message = line.replace(/^.*ERROR:\s*/i, '').slice(0, 500)
      || (error.killed ? '解析超时，请重试。' : 'yt-dlp 解析失败。');
    json(res, 502, { ok: false, message });
  }
}

function proxyMedia(req, res, token, redirectCount = 0) {
  const entry = tokens.get(token);
  if (!entry || entry.expiresAt <= Date.now()) {
    tokens.delete(token);
    json(res, 410, { ok: false, message: '下载地址已过期，请重新解析。' });
    return;
  }

  const source = new URL(entry.url);
  const transport = source.protocol === 'https:' ? httpsRequest : httpRequest;
  const headers = {
    'User-Agent': entry.userAgent,
    'Accept': '*/*',
    'Accept-Encoding': 'identity',
    'Connection': 'keep-alive'
  };
  if (req.headers.range) headers.Range = req.headers.range;

  const upstream = transport(source, { method: req.method, headers, family: 4 }, upstreamResponse => {
    if ([301, 302, 303, 307, 308].includes(upstreamResponse.statusCode) && upstreamResponse.headers.location && redirectCount < 3) {
      upstreamResponse.resume();
      entry.url = new URL(upstreamResponse.headers.location, source).toString();
      proxyMedia(req, res, token, redirectCount + 1);
      return;
    }
    const responseHeaders = {};
    for (const name of ['content-type', 'content-length', 'content-range', 'accept-ranges', 'etag', 'last-modified']) {
      if (upstreamResponse.headers[name] !== undefined) responseHeaders[name] = upstreamResponse.headers[name];
    }
    responseHeaders['cache-control'] = 'private, max-age=300';
    res.writeHead(upstreamResponse.statusCode || 502, responseHeaders);
    if (req.method === 'HEAD') {
      upstreamResponse.resume();
      res.end();
    } else {
      upstreamResponse.pipe(res);
    }
  });
  upstream.setTimeout(60_000, () => upstream.destroy(new Error('upstream timeout')));
  upstream.on('error', error => {
    if (!res.headersSent) json(res, 502, { ok: false, message: `媒体中转失败：${error.message}` });
    else res.destroy(error);
  });
  req.on('close', () => upstream.destroy());
  upstream.end();
}

const server = createServer(async (req, res) => {
  const path = new URL(req.url || '/', 'http://localhost').pathname;
  if (req.method === 'GET' && path === '/health') {
    json(res, 200, { ok: true, service: 'youtube-ios-resolver' });
    return;
  }
  if (req.method === 'POST' && (path === '/resolve' || path === '/resolv')) {
    await resolveMedia(req, res);
    return;
  }
  const match = path.match(/^\/media\/([a-f0-9]{48})$/);
  if (match && (req.method === 'GET' || req.method === 'HEAD')) {
    proxyMedia(req, res, match[1]);
    return;
  }
  json(res, 404, { ok: false, message: '接口不存在' });
});

setInterval(() => {
  const now = Date.now();
  for (const [token, value] of tokens) {
    if (value.expiresAt <= now) tokens.delete(token);
  }
  for (const [key, values] of rateLimits) {
    const recent = values.filter(value => now - value < 10 * 60 * 1000);
    if (recent.length) rateLimits.set(key, recent);
    else rateLimits.delete(key);
  }
  schedulePersist();
}, 30 * 60 * 1000).unref();

server.listen(PORT, HOST, () => {
  console.log(`youtube-ios-resolver listening on http://${HOST}:${PORT}`);
});
