import 'dart:convert';

const String agentMcpVersion = '2.3.0';

const String appIconSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">'
    '<rect x="2" y="2" width="60" height="60" rx="16" fill="#FAF9F5" stroke="#E3E0D6" stroke-width="2.5"/>'
    '<path d="M32 10L37.4 26.6L54 32L37.4 37.4L32 54L26.6 37.4L10 32L26.6 26.6L32 10Z" fill="#D97757"/>'
    '</svg>';

final String appIconDataUri =
    'data:image/svg+xml;base64,${base64Encode(utf8.encode(appIconSvg))}';
