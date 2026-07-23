import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/extensions/string/string.dart';
import 'package:lunasea/modules/settings.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

/// Bottom sheet presenting a freshly-minted enrollment key with copy/share.
/// The key is shown exactly once — it is single-use and expires in 24h.
///
/// When [inviteLink] is provided (a https://tailarr.com/import universal
/// link carrying the enroll payload), the sheet leads with a QR code: the
/// native iOS camera scans it, devices WITH Tailarr land on the one-tap
/// join screen, devices WITHOUT it land on tailarr.com/import to install
/// first. The QR is the invite — treat it like the key itself.
class TailarrServerKeySheet {
  TailarrServerKeySheet._();

  static void show(
    BuildContext context, {
    required String enrollmentKey,
    required String message,
    required String shareMessage,
    String? inviteLink,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                inviteLink != null ? 'Invite' : 'Enrollment Key',
                style: const TextStyle(
                  fontSize: LunaUI.FONT_SIZE_H1,
                  fontWeight: LunaUI.FONT_WEIGHT_BOLD,
                ),
              ),
              const SizedBox(height: 12),
              if (inviteLink != null) ...[
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius:
                          BorderRadius.circular(LunaUI.BORDER_RADIUS),
                    ),
                    child: QrImageView(
                      data: inviteLink,
                      version: QrVersions.auto,
                      size: 220,
                      backgroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Scan with the phone\'s camera. With Tailarr installed it '
                  'joins and sets everything up in one tap; without it, the '
                  'link leads to the install page and works after install.',
                ),
                const SizedBox(height: 12),
              ],
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
                      onTap: () async =>
                          (inviteLink ?? enrollmentKey).copyToClipboard(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: LunaButton.text(
                      text: 'Share',
                      icon: Icons.ios_share_rounded,
                      onTap: () async => Share.share(
                        '$shareMessage\n\n${inviteLink ?? enrollmentKey}',
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
