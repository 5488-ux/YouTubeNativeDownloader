import { createServer } from 'node:http';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const HOST = '127.0.0.1';
const PORT = 19194;
const PROVIDER_URL = 'http://127.0.0.1:4416/get_pot';
const MAX_BODY = 4096;
const requestsByIP = new Map();
const execFileAsync = promisify(execFile);

function sendJSON(response, status, value) {
  const body = Buffer.from(JSON.stringify(value));
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': body.length,
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff'
  });
  response.end(body);
}

async function readJSON(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > MAX_BODY) throw new Error('请求内容过大');
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

function clientIP(request) {
  return String(
    request.headers['cf-connecting-ip'] ||
    request.headers['x-forwarded-for'] ||
    request.socket.remoteAddress || ''
  ).split(',')[0].trim();
}

function allowRequest(request) {
  const key = clientIP(request);
  const now = Date.now();
  const recent = (requestsByIP.get(key) || []).filter(value => now - value < 10 * 60 * 1000);
  if (recent.length >= 30) return false;
  recent.push(now);
  requestsByIP.set(key, recent);
  return true;
}

async function createToken(request, response) {
  if (!allowRequest(request)) {
    sendJSON(response, 429, { ok: false, message: 'Token 请求太频繁，请稍后重试。' });
    return;
  }

  let input;
  try {
    input = await readJSON(request);
  } catch (error) {
    sendJSON(response, 400, { ok: false, message: error.message || 'JSON 无效' });
    return;
  }

  const contentBinding = String(input.content_binding || '').trim();
  if (!contentBinding || contentBinding.length > 512 || !/^[A-Za-z0-9_\-=|.%]+$/.test(contentBinding)) {
    sendJSON(response, 422, { ok: false, message: 'content_binding 无效' });
    return;
  }

  try {
    const providerResponse = await fetch(PROVIDER_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ content_binding: contentBinding }),
      signal: AbortSignal.timeout(60_000)
    });
    const data = await providerResponse.json();
    if (!providerResponse.ok || typeof data.poToken !== 'string' || !data.poToken) {
      sendJSON(response, 502, {
        ok: false,
        message: String(data.error || 'PO Token Provider 返回异常').slice(0, 500)
      });
      return;
    }
    sendJSON(response, 200, {
      ok: true,
      content_binding: contentBinding,
      po_token: data.poToken,
      expires_at: data.expiresAt || null
    });
  } catch (error) {
    sendJSON(response, 502, {
      ok: false,
      message: `PO Token Provider 不可用：${String(error.message || error).slice(0, 400)}`
    });
  }
}

async function createMediaAccess(request, response) {
  if (!allowRequest(request)) {
    sendJSON(response, 429, { ok: false, message: '媒体授权请求太频繁，请稍后重试。' });
    return;
  }

  let input;
  try {
    input = await readJSON(request);
  } catch (error) {
    sendJSON(response, 400, { ok: false, message: error.message || 'JSON 无效' });
    return;
  }

  const videoID = String(input.video_id || '').trim();
  const challenge = String(input.n || '').trim();
  const playerURL = String(input.player_url || '').trim();
  if (!/^[A-Za-z0-9_-]{11}$/.test(videoID) ||
      !/^[A-Za-z0-9_-]{1,200}$/.test(challenge) ||
      !/^https:\/\/www\.youtube\.com\/s\/player\/[A-Za-z0-9_-]+\/[^\s]+\/base\.js$/.test(playerURL)) {
    sendJSON(response, 422, { ok: false, message: '播放器挑战参数无效' });
    return;
  }

  try {
    const [providerResponse, solverResult] = await Promise.all([
      fetch(PROVIDER_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ content_binding: videoID }),
        signal: AbortSignal.timeout(60_000)
      }),
      execFileAsync(
        '/opt/ytdlp-php/bin/python',
        ['/opt/youtube-pot-gateway/solve-youtube-n.py', videoID, playerURL, challenge],
        { timeout: 60_000, maxBuffer: 1024 * 1024, env: { ...process.env, LC_ALL: 'C.UTF-8' } }
      )
    ]);
    const tokenData = await providerResponse.json();
    const solverData = JSON.parse(solverResult.stdout);
    if (!providerResponse.ok || typeof tokenData.poToken !== 'string' ||
        !solverData.ok || typeof solverData.n !== 'string') {
      throw new Error(tokenData.error || solverData.message || '媒体授权生成失败');
    }
    sendJSON(response, 200, {
      ok: true,
      po_token: tokenData.poToken,
      solved_n: solverData.n,
      expires_at: tokenData.expiresAt || null
    });
  } catch (error) {
    sendJSON(response, 502, {
      ok: false,
      message: `播放器挑战处理失败：${String(error.message || error).slice(0, 400)}`
    });
  }
}

const server = createServer(async (request, response) => {
  const path = new URL(request.url || '/', 'http://localhost').pathname;
  if (request.method === 'GET' && path === '/health') {
    sendJSON(response, 200, { ok: true, service: 'youtube-pot-gateway' });
    return;
  }
  if (request.method === 'POST' && path === '/token') {
    await createToken(request, response);
    return;
  }
  if (request.method === 'POST' && path === '/media-access') {
    await createMediaAccess(request, response);
    return;
  }
  sendJSON(response, 404, { ok: false, message: '接口不存在' });
});

setInterval(() => {
  const now = Date.now();
  for (const [key, values] of requestsByIP) {
    const recent = values.filter(value => now - value < 10 * 60 * 1000);
    if (recent.length) requestsByIP.set(key, recent);
    else requestsByIP.delete(key);
  }
}, 30 * 60 * 1000).unref();

server.listen(PORT, HOST, () => {
  console.log(`youtube-pot-gateway listening on http://${HOST}:${PORT}`);
});
