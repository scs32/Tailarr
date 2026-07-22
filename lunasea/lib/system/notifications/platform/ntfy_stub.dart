/// Web stub — the notification inbox renders from Hive everywhere, but
/// syncing, streaming, and background refresh are dart:io only.
class LunaNtfy {
  static bool get isSupported => false;
  static bool get isBackgroundRefreshSupported => false;

  Future<void> initialize() async {}
  Future<int> syncInbox() async => 0;
  void restartStream() {}
  Future<void> onConfigChanged() async {}
  Future<bool> enableBackgroundRefresh() async => false;
  Future<void> disableBackgroundRefresh() async {}
}
