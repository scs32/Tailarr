import 'package:lunasea/core.dart';
import 'package:lunasea/system/log_redactor.dart';

Future<void> showLunaErrorSnackBar({
  required String title,
  dynamic error,
  String? message,
  bool showButton = false,
  String buttonText = 'view',
  Function? buttonOnPressed,
}) async =>
    showLunaSnackBar(
      title: title,
      message: message ?? LunaLogger.checkLogsMessage,
      type: LunaSnackbarType.ERROR,
      showButton: error != null || showButton,
      buttonText: buttonText,
      buttonOnPressed: () async {
        if (error != null) {
          LunaDialogs().textPreview(
            LunaState.context,
            'Error',
            // Scrub credentials: this dialog is viewable, screenshotted, and
            // has a Copy-to-pasteboard button — the same leak surface the log
            // redactor closed. A DioException.toString() embeds the request
            // URI (…?apikey=…, NZBGet user:pass), so redact before display.
            LogRedactor.scrub(error.toString()),
          );
        } else if (buttonOnPressed != null) {
          buttonOnPressed();
        }
      },
    );
