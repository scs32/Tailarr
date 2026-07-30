import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/extensions/datetime.dart';
import 'package:lunasea/extensions/string/string.dart';
import 'package:lunasea/modules/radarr.dart';
import 'package:lunasea/router/routes/radarr.dart';

class RadarrMissingTile extends StatefulWidget {
  static final itemExtent = LunaBlock.calculateItemExtent(3);

  final RadarrMovie movie;
  final RadarrQualityProfile? profile;

  const RadarrMissingTile({
    super.key,
    required this.movie,
    required this.profile,
  });

  @override
  State<RadarrMissingTile> createState() => _State();
}

class _State extends State<RadarrMissingTile> {
  @override
  Widget build(BuildContext context) {
    return Selector<RadarrState, Future<List<RadarrMovie>>?>(
      selector: (_, state) => state.missing,
      builder: (context, missing, _) => LunaBlock(
        backgroundUrl:
            context.read<RadarrState>().getFanartURL(widget.movie.id),
        posterUrl: context.read<RadarrState>().getPosterURL(widget.movie.id),
        posterHeaders: context.read<RadarrState>().headers,
        posterPlaceholderIcon: LunaIcons.VIDEO_CAM,
        disabled: widget.movie.monitored != true,
        title: widget.movie.title,
        body: [
          _subtitle1(),
          _subtitle2(),
          _subtitle3(),
        ],
        trailing: _trailing(),
        onTap: _onTap,
      ),
    );
  }

  TextSpan _subtitle1() {
    return TextSpan(
      children: [
        TextSpan(text: widget.movie.lunaYear),
        TextSpan(text: LunaUI.TEXT_BULLET.pad()),
        TextSpan(text: widget.movie.lunaRuntime),
        TextSpan(text: LunaUI.TEXT_BULLET.pad()),
        TextSpan(text: widget.movie.lunaStudio),
      ],
    );
  }

  TextSpan _subtitle2() {
    return TextSpan(
      children: [
        TextSpan(text: widget.profile!.lunaName),
        TextSpan(text: LunaUI.TEXT_BULLET.pad()),
        TextSpan(text: widget.movie.lunaMinimumAvailability),
        TextSpan(text: LunaUI.TEXT_BULLET.pad()),
        TextSpan(text: widget.movie.lunaReleaseDate),
      ],
    );
  }

  TextSpan _subtitle3() {
    String? _days = widget.movie.lunaEarlierReleaseDate?.asDaysDifference();
    return TextSpan(
        style: const TextStyle(
          fontWeight: LunaUI.FONT_WEIGHT_BOLD,
          color: LunaColours.red,
        ),
        text: _days == null
            ? 'radarr.Released'.tr()
            : _days == 'Today'
                ? 'radarr.ReleasedToday'.tr()
                : 'Released $_days Ago');
  }

  LunaIconButton _trailing() {
    return LunaIconButton(
      icon: Icons.search_rounded,
      onPressed: () async {
        final id = widget.movie.id;
        if (id == null) return;
        RadarrAPIHelper().automaticSearch(
            context: context, movieId: id, title: (widget.movie.title ?? ""));
      },
      onLongPress: () {
        final id = widget.movie.id;
        if (id == null) return;
        RadarrRoutes.MOVIE_RELEASES.go(params: {'movie': id.toString()});
      },
    );
  }

  Future<void> _onTap() async {
    final id = widget.movie.id;
    if (id == null) return;
    RadarrRoutes.MOVIE.go(params: {'movie': id.toString()});
  }
}
