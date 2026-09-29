/// Where a bill invite is shared as a link a chat app shows as tappable.
///
/// The site at this host serves the two files that tie it to this app —
/// `/.well-known/apple-app-site-association` and
/// `/.well-known/assetlinks.json` — so a tapped `https://<host>/join#…` opens
/// the wallet on a phone that has it. The invite rides in the fragment, which
/// a browser never sends to the host (SPEC §11.1).
library;

/// The host invite links are issued under, and that the app claims.
const String splitsInviteLinkHost = 'kamaiops.github.io';

/// What every invite link begins with; the invite URI follows a `#`.
const String splitsInviteLinkBase = 'https://$splitsInviteLinkHost/join';

/// Whether [uri] is an invite link this app issues: https, this host, and
/// the `/join` path.
bool isSplitsInviteLink(Uri uri) =>
    uri.scheme.toLowerCase() == 'https' &&
    uri.host.toLowerCase() == splitsInviteLinkHost &&
    uri.userInfo.isEmpty &&
    !uri.hasPort &&
    (uri.path == '/join' || uri.path.startsWith('/join/'));
