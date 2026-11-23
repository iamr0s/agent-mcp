import 'dart:convert';

const String agentMcpVersion = '3.4.2';

const String appIconSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">'
    '<defs>'
    '<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">'
    '<stop offset="0%" stop-color="#161838"/>'
    '<stop offset="100%" stop-color="#090A16"/>'
    '</linearGradient>'
    '<radialGradient id="aura" cx="0.68" cy="0.70" r="0.52">'
    '<stop offset="0%" stop-color="#4F46E5" stop-opacity="0.56"/>'
    '<stop offset="100%" stop-color="#4F46E5" stop-opacity="0"/>'
    '</radialGradient>'
    '<linearGradient id="pBack" x1="0" y1="0" x2="1" y2="1">'
    '<stop offset="0%" stop-color="#939EFF"/>'
    '<stop offset="100%" stop-color="#4F46E5"/>'
    '</linearGradient>'
    '<linearGradient id="pFront" x1="0" y1="0" x2="1" y2="1">'
    '<stop offset="0%" stop-color="#FFFFFF"/>'
    '<stop offset="100%" stop-color="#DFE6FF"/>'
    '</linearGradient>'
    '</defs>'
    '<rect x="2" y="2" width="60" height="60" rx="15" fill="url(#bg)" stroke="#818CF8" stroke-opacity="0.28" stroke-width="1"/>'
    '<rect x="2" y="2" width="60" height="60" rx="15" fill="url(#aura)"/>'
    '<path fill="url(#pBack)" fill-rule="evenodd" d="M35.6 18.2a3.2 3.2 0 0 1 4.5 0l12.7 12.7a3.2 3.2 0 0 1 0 4.5L40.1 48.1a3.2 3.2 0 0 1-4.5 0L22.9 35.4a3.2 3.2 0 0 1 0-4.5Z M36.6 26.2a1.8 1.8 0 0 1 2.5 0l5.7 5.7a1.8 1.8 0 0 1 0 2.5l-5.7 5.7a1.8 1.8 0 0 1-2.5 0l-5.7-5.7a1.8 1.8 0 0 1 0-2.5Z"/>'
    '<path fill="url(#pFront)" fill-rule="evenodd" d="M26.9 11.4a3.4 3.4 0 0 1 4.8 0l13.9 13.9a3.4 3.4 0 0 1 0 4.8L31.7 44.0a3.4 3.4 0 0 1-4.8 0L13.0 30.1a3.4 3.4 0 0 1 0-4.8Z M28.0 19.9a1.9 1.9 0 0 1 2.6 0l6.3 6.3a1.9 1.9 0 0 1 0 2.6l-6.3 6.3a1.9 1.9 0 0 1-2.6 0l-6.3-6.3a1.9 1.9 0 0 1 0-2.6Z"/>'
    '</svg>';

final String appIconDataUri =
    'data:image/svg+xml;base64,${base64Encode(utf8.encode(appIconSvg))}';
