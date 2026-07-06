// esbuild entry point — exposes router.js handleApiRequest/getBridgeStatus to globalThis
// for JavaScriptCore consumption inside MineradioBridgeEngine.
import { handleApiRequest, getBridgeStatus } from './api/router.js';

globalThis.__mineradioHandleApiRequest = handleApiRequest;
globalThis.__mineradioGetBridgeStatus = getBridgeStatus;
