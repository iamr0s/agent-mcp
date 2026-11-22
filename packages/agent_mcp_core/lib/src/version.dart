import 'dart:convert';

const String agentMcpVersion = '2.4.0';

const String appIconSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">'
    '<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">'
    '<stop offset="0%" stop-color="#4F46E5"/>'
    '<stop offset="100%" stop-color="#312E81"/>'
    '</linearGradient></defs>'
    '<rect x="2" y="2" width="60" height="60" rx="16" fill="url(#g)"/>'
    '<path d="M32 12L36.8 27.2L52 32L36.8 36.8L32 52L27.2 36.8L12 32L27.2 27.2L32 12Z" fill="#FAF9F6"/>'
    '<line x1="21" y1="43" x2="43" y2="21" stroke="#C7D2FE" stroke-width="3.2" stroke-linecap="round"/>'
    '<circle cx="21" cy="43" r="4" fill="#FAF9F6" stroke="#4338CA" stroke-width="1.6"/>'
    '<circle cx="43" cy="21" r="4" fill="#FAF9F6" stroke="#4338CA" stroke-width="1.6"/>'
    '</svg>';

final String appIconDataUri =
    'data:image/svg+xml;base64,${base64Encode(utf8.encode(appIconSvg))}';
