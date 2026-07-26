/// Models for the controller's Quick Connect pairing surface (server v0.77.0+).
/// Frozen contract (app-quick-connect-design.md §5):
///   POST /pair/start  {device}        → {code, poll_id}
///   GET  /pair/status?id=<poll_id>    → {status, token?}   (token once, on
///                                        the first "approved" read)
///   POST /pair/approve {code}         → {ok, person, error?}   (no token)
library pairing_models;

/// `{code, poll_id}` from `POST /pair/start`.
class PairStartResponse {
  final String code;
  final String pollId;

  const PairStartResponse({required this.code, required this.pollId});

  factory PairStartResponse.fromJson(Map<String, dynamic> json) {
    return PairStartResponse(
      code: (json['code'] ?? '').toString(),
      // Frozen field name is `poll_id` (design §5 B).
      pollId: (json['poll_id'] ?? '').toString(),
    );
  }

  bool get isValid => code.isNotEmpty && pollId.isNotEmpty;
}

/// `{status, token?}` from `GET /pair/status?id=<poll_id>`.
/// `token` is present exactly once, on the first read after "approved" — this
/// is how BOTH the browser requester and the self-config app receive the token.
class PairStatus {
  final String status; // pending | approved | denied | expired
  final String? token;

  const PairStatus({required this.status, this.token});

  factory PairStatus.fromJson(Map<String, dynamic> json) {
    final token = json['token'];
    return PairStatus(
      status: (json['status'] ?? '').toString(),
      token: (token is String && token.isNotEmpty) ? token : null,
    );
  }

  bool get isPending => status == 'pending';
  bool get isApproved => status == 'approved';
  bool get isDenied => status == 'denied';
  bool get isExpired => status == 'expired';

  /// Terminal states — polling should stop.
  bool get isSettled => isApproved || isDenied || isExpired;
}

/// `{ok, person, error?}` from `POST /pair/approve`. Never carries a token
/// (§5 A — the token lives only on `/pair/status`).
class PairApproveResult {
  final bool ok;
  final String? person; // the approving person's uid
  final String? error; // "no server badge" | "not a live peer" | "bad or expired code"
  final int? statusCode;

  const PairApproveResult({
    required this.ok,
    this.person,
    this.error,
    this.statusCode,
  });

  factory PairApproveResult.fromJson(
    Map<String, dynamic> json, {
    int? statusCode,
  }) {
    return PairApproveResult(
      ok: json['ok'] == true,
      person: (json['person'] as String?)?.trim(),
      error: (json['error'] as String?)?.trim(),
      statusCode: statusCode,
    );
  }
}
