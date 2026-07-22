import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/extensions/string/string.dart';
import 'package:lunasea/modules/settings.dart';
import 'package:share_plus/share_plus.dart';

/// Bottom sheet presenting a freshly-minted enrollment key with copy/share.
/// The key is shown exactly once — it is single-use and expires in 24h.
class TailarrServerKeySheet {
  TailarrServerKeySheet._();

  static void show(
    BuildContext context, {
    required String enrollmentKey,
    required String message,
    required String shareMessage,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enrollment Key',
                style: TextStyle(
                  fontSize: LunaUI.FONT_SIZE_H1,
                  fontWeight: LunaUI.FONT_WEIGHT_BOLD,
                ),
              ),
              const SizedBox(height: 12),
              SelectableText(
                enrollmentKey,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              const SizedBox(height: 12),
              Text(message),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: LunaButton.text(
                      text: 'Copy',
                      icon: Icons.copy_rounded,
                      onTap: () async => enrollmentKey.copyToClipboard(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: LunaButton.text(
                      text: 'Share',
                      icon: Icons.ios_share_rounded,
                      onTap: () async => Share.share(
                        '$shareMessage\n\n$enrollmentKey',
                        sharePositionOrigin:
                            SharedModuleConfiguration.shareOriginOf(context),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
