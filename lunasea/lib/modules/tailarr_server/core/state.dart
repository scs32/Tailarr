import 'package:lunasea/core.dart';
import 'package:lunasea/modules/tailarr_server.dart';

class TailarrServerState extends LunaModuleState {
  TailarrServerState() {
    reset();
  }

  @override
  void reset() {
    _pods = null;
    _network = null;
    _updates = null;
    resetProfile();
    if (_enabled) {
      resetPods();
      resetUpdates();
    }
    notifyListeners();
  }

  ///////////////
  /// PROFILE ///
  ///////////////

  TailarrServerAPI? _api;
  TailarrServerAPI? get api => _api;

  bool _enabled = false;
  bool get enabled => _enabled;

  String _host = '';
  String get host => _host;

  Map<dynamic, dynamic> _headers = {};
  Map<dynamic, dynamic> get headers => _headers;

  void resetProfile() {
    LunaProfile _profile = LunaProfile.current;
    _enabled = _profile.tailarrServerEnabled;
    _host = _profile.tailarrServerHost;
    _headers = _profile.tailarrServerHeaders;
    final headers = Map<String, dynamic>.from(_headers);
    // Quick Connect admin bearer (server v0.77.0+ Option A): sent on ALL /api/*
    // calls — reads included, since a later release makes reads require it too.
    // Empty until "Connect this device" self-configures; a 401 then triggers it.
    final token = _profile.serverAdminToken.trim();
    if (token.isNotEmpty) headers['Authorization'] = 'Bearer $token';
    _api = _enabled && _host.isNotEmpty
        ? TailarrServerAPI(host: _host, headers: headers)
        : null;
  }

  ////////////
  /// PODS ///
  ////////////

  Future<List<TailarrServerPod>>? _pods;
  Future<List<TailarrServerPod>>? get pods => _pods;

  /// Per-pod networking (tailnet IP, MagicDNS name, service URL). Fetched
  /// separately from the pods list — the server shells into each sidecar to
  /// read its identity, so this call is much slower than `getPods()`.
  Future<List<TailarrServerNetworkEntry>>? _network;
  Future<List<TailarrServerNetworkEntry>>? get network => _network;

  void resetPods() {
    if (_api != null) {
      _pods = _api!.getPods();
      _network = _api!.getNetwork();
    }
    notifyListeners();
  }

  ///////////////
  /// UPDATES ///
  ///////////////

  Future<TailarrServerUpdates>? _updates;
  Future<TailarrServerUpdates>? get updates => _updates;

  void resetUpdates() {
    if (_api != null) _updates = _api!.getUpdates();
    notifyListeners();
  }
}
