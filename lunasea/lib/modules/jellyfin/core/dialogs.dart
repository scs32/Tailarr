import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';

/// What the set-password dialog resolved to.
enum JellyfinPasswordChoice { cancelled, save, clear }

class JellyfinPasswordResult {
  final JellyfinPasswordChoice choice;
  final String password;

  const JellyfinPasswordResult(this.choice, [this.password = '']);
}

class JellyfinDialogs {
  /// Generic destructive-action confirmation. Returns true when confirmed.
  Future<bool> confirmAction(
    BuildContext context, {
    required String title,
    required String message,
    String buttonText = 'Confirm',
    Color buttonColor = LunaColours.red,
  }) async {
    bool flag = false;
    await LunaDialog.dialog(
      context: context,
      title: title,
      buttons: [
        LunaDialog.button(
          text: buttonText,
          textColor: buttonColor,
          onPressed: () {
            flag = true;
            Navigator.of(context, rootNavigator: true).pop();
          },
        ),
      ],
      content: [LunaDialog.textContent(text: message)],
      contentPadding: LunaDialog.textDialogContentPadding(),
    );
    return flag;
  }

  /// Prompt for a Quick Connect code. Returns (confirmed, code).
  Future<Tuple2<bool, String>> enterQuickConnectCode(
    BuildContext context,
  ) async {
    bool flag = false;
    final formKey = GlobalKey<FormState>();
    final controller = TextEditingController();

    void submit() {
      if (formKey.currentState?.validate() ?? false) {
        flag = true;
        Navigator.of(context, rootNavigator: true).pop();
      }
    }

    await LunaDialog.dialog(
      context: context,
      title: 'Quick Connect',
      buttons: [
        LunaDialog.button(text: 'Authorize', onPressed: submit),
      ],
      content: [
        LunaDialog.richText(children: [
          const TextSpan(
            text: 'Start Quick Connect in the official Jellyfin app, then '
                'enter the code it shows here to sign that device in as you — '
                'no password needed.',
          ),
        ]),
        Form(
          key: formKey,
          child: LunaDialog.textFormInput(
            controller: controller,
            title: 'Quick Connect Code',
            keyboardType: TextInputType.text,
            onSubmitted: (_) => submit(),
            validator: (value) =>
                (value?.trim().isEmpty ?? true) ? 'Enter the code' : null,
          ),
        ),
      ],
      contentPadding: LunaDialog.inputTextDialogContentPadding(),
    );
    return Tuple2(flag, controller.text.trim());
  }

  /// Set or clear the account password. Offers a Clear action only when a
  /// password is already set. Returns the chosen action + the new password.
  Future<JellyfinPasswordResult> setPassword(
    BuildContext context, {
    required bool hasPassword,
  }) async {
    JellyfinPasswordChoice choice = JellyfinPasswordChoice.cancelled;
    final formKey = GlobalKey<FormState>();
    final controller = TextEditingController();

    void save() {
      if (formKey.currentState?.validate() ?? false) {
        choice = JellyfinPasswordChoice.save;
        Navigator.of(context, rootNavigator: true).pop();
      }
    }

    await LunaDialog.dialog(
      context: context,
      title: hasPassword ? 'Change Password' : 'Set Password',
      buttons: [
        if (hasPassword)
          LunaDialog.button(
            text: 'Clear',
            textColor: LunaColours.red,
            onPressed: () {
              choice = JellyfinPasswordChoice.clear;
              Navigator.of(context, rootNavigator: true).pop();
            },
          ),
        LunaDialog.button(text: 'Save', onPressed: save),
      ],
      content: [
        LunaDialog.richText(children: [
          TextSpan(
            text: hasPassword
                ? 'Enter a new password for your Jellyfin account. Clearing it '
                    'returns to passwordless sign-in with Quick Connect.'
                : 'Set a password for your Jellyfin account. You can keep '
                    'signing in with Quick Connect either way.',
          ),
        ]),
        Form(
          key: formKey,
          child: LunaDialog.textFormInput(
            controller: controller,
            title: 'Password',
            obscureText: true,
            onSubmitted: (_) => save(),
            validator: (value) =>
                (value?.isEmpty ?? true) ? 'Enter a password' : null,
          ),
        ),
      ],
      contentPadding: LunaDialog.inputTextDialogContentPadding(),
    );
    return JellyfinPasswordResult(choice, controller.text);
  }
}
