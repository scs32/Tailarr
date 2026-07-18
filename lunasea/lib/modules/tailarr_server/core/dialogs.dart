import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';

class TailarrServerDialogs {
  /// Generic destructive-action confirmation. Returns true when confirmed.
  Future<bool> confirmAction(
    BuildContext context, {
    required String title,
    required String message,
    String buttonText = 'Confirm',
    Color buttonColor = LunaColours.red,
  }) async {
    bool _flag = false;

    void _confirm() {
      _flag = true;
      Navigator.of(context, rootNavigator: true).pop();
    }

    await LunaDialog.dialog(
      context: context,
      title: title,
      buttons: [
        LunaDialog.button(
          text: buttonText,
          textColor: buttonColor,
          onPressed: _confirm,
        ),
      ],
      content: [
        LunaDialog.textContent(text: message),
      ],
      contentPadding: LunaDialog.textDialogContentPadding(),
    );
    return _flag;
  }
}
