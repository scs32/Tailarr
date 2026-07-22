import 'package:flutter/material.dart';

import 'package:lunasea/core.dart';
import 'package:lunasea/system/network/platform/network_io.dart'
    if (dart.library.html) 'package:lunasea/system/network/platform/network_html.dart';
import 'package:tailscale_embed/tailscale_embed.dart';

class ConfigurationGeneralTailscaleStatusRoute extends StatefulWidget {
  const ConfigurationGeneralTailscaleStatusRoute({
    Key? key,
  }) : super(key: key);

  @override
  State createState() => _State();
}

class _State extends State<ConfigurationGeneralTailscaleStatusRoute>
    with LunaScrollControllerMixin {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  Timer? _timer;
  TailscaleStatus? _status;
  Object? _error;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final status = await IO.tailscaleStatus();
      if (!mounted) return;
      setState(() {
        _status = status;
        _error = null;
        _loaded = true;
      });
    } catch (error, stack) {
      LunaLogger().error('Failed to fetch Tailscale status', error, stack);
      if (!mounted) return;
      setState(() {
        _error = error;
        _loaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return LunaScaffold(
      scaffoldKey: _scaffoldKey,
      appBar: _appBar(),
      body: _body(),
    );
  }

  PreferredSizeWidget _appBar() {
    return LunaAppBar(
      title: 'Tailscale Status',
      scrollControllers: [scrollController],
    );
  }

  Widget _body() {
    if (!_loaded) return const LunaLoader();
    if (_error != null) return LunaMessage.error(onTap: _refresh);
    final status = _status;
    if (status == null) {
      return LunaMessage(
        text: 'Status Unavailable',
        buttonText: 'Retry',
        onTap: _refresh,
      );
    }
    return LunaRefreshIndicator(
      context: context,
      onRefresh: _refresh,
      child: LunaListView(
        controller: scrollController,
        children: [
          _connectionBlock(status),
          _nodeCard(status),
          if (status.health.isNotEmpty) _healthCard(status),
          if (status.running) ..._peers(status),
        ],
      ),
    );
  }

  Widget _connectionBlock(TailscaleStatus status) {
    final String state;
    final Color color;
    if (!status.running) {
      state = 'Stopped';
      color = LunaColours.red;
    } else if (status.isHealthy) {
      state = 'Connected';
      color = LunaColours.accent;
    } else if (status.backendState == 'Starting') {
      state = 'Starting…';
      color = LunaColours.orange;
    } else if (status.backendState == 'NeedsLogin') {
      state = 'Needs Login';
      color = LunaColours.red;
    } else {
      state = status.backendState.isEmpty
          ? 'Attention Needed'
          : status.backendState;
      color = LunaColours.orange;
    }

    return LunaBlock(
      title: 'Connection',
      body: [
        TextSpan(
          text: state,
          style: TextStyle(
            color: color,
            fontWeight: LunaUI.FONT_WEIGHT_BOLD,
          ),
        ),
        if (!status.running)
          const TextSpan(text: 'Enable Tailscale to connect'),
        if (status.running && status.tailnetName != null)
          TextSpan(text: status.tailnetName),
      ],
      trailing: LunaIconButton(
        icon: Icons.vpn_lock_rounded,
        color: color,
      ),
    );
  }

  Widget _nodeCard(TailscaleStatus status) {
    final self = status.self;
    return LunaTableCard(
      title: 'Node',
      content: [
        LunaTableContent(title: 'identity', body: status.identity),
        if (self != null) ...[
          LunaTableContent(title: 'hostname', body: self.hostName),
          LunaTableContent(title: 'magicdns', body: self.dnsName),
          LunaTableContent(
            title: self.ips.length > 1 ? 'addresses' : 'address',
            body: self.ips.isEmpty ? null : self.ips.join('\n'),
          ),
        ],
        LunaTableContent(title: 'dns suffix', body: status.magicDnsSuffix),
        if (status.running)
          LunaTableContent(
            title: 'proxy',
            body: '127.0.0.1:${status.proxyPort}',
          ),
      ],
    );
  }

  Widget _healthCard(TailscaleStatus status) {
    return LunaTableCard(
      title: 'Health Warnings',
      content: status.health
          .map((warning) => LunaTableContent(body: warning))
          .toList(),
    );
  }

  List<Widget> _peers(TailscaleStatus status) {
    final peers = [...status.peers]..sort((a, b) {
        if (a.online != b.online) return a.online ? -1 : 1;
        return a.hostName.toLowerCase().compareTo(b.hostName.toLowerCase());
      });
    return [
      LunaHeader(
        text: 'Peers',
        subtitle: peers.isEmpty
            ? null
            : '${status.onlinePeerCount} of ${peers.length} online',
      ),
      if (peers.isEmpty)
        const LunaBlock(
          title: 'No Peers Visible',
          body: [
            TextSpan(
              text: 'No other devices are visible to this node — check the '
                  'tailnet\'s access controls',
            ),
          ],
        ),
      for (final peer in peers) _peerBlock(peer),
    ];
  }

  Widget _peerBlock(TailscaleNode peer) {
    final String title;
    if (peer.hostName.isNotEmpty) {
      title = peer.hostName;
    } else if (peer.dnsName.isNotEmpty) {
      title = peer.dnsName;
    } else {
      title = peer.ips.isEmpty ? 'Unknown Device' : peer.ips.first;
    }
    return LunaBlock(
      title: title,
      body: [
        TextSpan(
          text: peer.online ? 'Online' : 'Offline',
          style: TextStyle(
            color: peer.online ? LunaColours.accent : LunaColours.red,
            fontWeight: LunaUI.FONT_WEIGHT_BOLD,
          ),
        ),
        if (peer.dnsName.isNotEmpty) TextSpan(text: peer.dnsName),
        if (peer.ips.isNotEmpty) TextSpan(text: peer.ips.join(' · ')),
        if (peer.routes.isNotEmpty)
          TextSpan(text: 'Routes: ${peer.routes.join(', ')}'),
      ],
      trailing: LunaIconButton(
        icon: Icons.devices_rounded,
        color: peer.online ? LunaColours.accent : LunaColours.red,
      ),
    );
  }
}
