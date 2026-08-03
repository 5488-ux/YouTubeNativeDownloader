import { BotGuardClient, getChallenge } from 'bgutils-js/botguard';
import { buildURL, getHeaders } from 'bgutils-js/utils';
import { WebPoMinter } from 'bgutils-js/webpo';

const REQUEST_KEY = 'O43z0dpjhgX20SCx4KAo';

type TokenMinter = {
  minter: WebPoMinter;
  expiresAt: number;
};

let cachedMinter: TokenMinter | undefined;

async function createMinter(): Promise<TokenMinter> {
  const challenge = await getChallenge({
    fetchFunction: fetch,
    requestKey: REQUEST_KEY
  });
  const interpreterJavascript = challenge.interpreterJavascript
    ?.privateDoNotAccessOrElseSafeScriptWrappedValue;
  if (!interpreterJavascript) {
    throw new Error('BotGuard challenge did not include interpreter JavaScript');
  }

  new Function(interpreterJavascript)();
  const botGuardClient = await BotGuardClient.create({
    program: challenge.program,
    globalName: challenge.globalName,
    globalObject: globalThis,
    userInteractionElement: document.body
  });

  const webPoSignalOutput: unknown[] = [];
  const botguardResponse = await botGuardClient.snapshot({ webPoSignalOutput });
  const integrityResponse = await fetch(buildURL('GenerateIT', false), {
    method: 'POST',
    headers: getHeaders(),
    body: JSON.stringify([REQUEST_KEY, botguardResponse])
  });
  if (!integrityResponse.ok) {
    throw new Error(`GenerateIT returned HTTP ${integrityResponse.status}`);
  }

  const [integrityToken, estimatedTtlSecs, mintRefreshThreshold, websafeFallbackToken]
    = await integrityResponse.json() as [string, number, number, string];
  const minter = await WebPoMinter.create({
    integrityToken,
    estimatedTtlSecs,
    mintRefreshThreshold,
    websafeFallbackToken
  }, webPoSignalOutput);

  return {
    minter,
    expiresAt: Date.now() + Math.max(60, estimatedTtlSecs - 60) * 1000
  };
}

async function generatePoToken(contentBinding: string): Promise<string> {
  if (!/^[A-Za-z0-9_\-=|.%]{1,512}$/.test(contentBinding)) {
    throw new Error('Invalid PO Token content binding');
  }
  if (!cachedMinter || cachedMinter.expiresAt <= Date.now()) {
    cachedMinter = await createMinter();
  }
  return await cachedMinter.minter.mintAsWebsafeString(contentBinding);
}

Object.assign(globalThis, {
  LocalYouTubePO: {
    generatePoToken,
    reset() {
      cachedMinter = undefined;
    }
  }
});
