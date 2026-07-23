import 'package:lunasea/core.dart';

part 'external_module.g.dart';

@JsonSerializable()
@HiveType(typeId: 26, adapterName: 'LunaExternalModuleAdapter')
class LunaExternalModule extends HiveObject {
  @JsonKey()
  @HiveField(0, defaultValue: '')
  String displayName;

  @JsonKey()
  @HiveField(1, defaultValue: '')
  String host;

  /// Non-empty when this bookmark is managed by the tailarr-gate
  /// /self/services endpoint — holds the service's stable `name` so
  /// re-syncs can reconcile it. Empty for user-created bookmarks.
  @JsonKey(defaultValue: '')
  @HiveField(2, defaultValue: '')
  String gatewayName;

  LunaExternalModule({
    this.displayName = '',
    this.host = '',
    this.gatewayName = '',
  });

  @override
  String toString() => json.encode(this.toJson());

  Map<String, dynamic> toJson() => _$LunaExternalModuleToJson(this);

  factory LunaExternalModule.fromJson(Map<String, dynamic> json) {
    return _$LunaExternalModuleFromJson(json);
  }

  factory LunaExternalModule.clone(LunaExternalModule profile) {
    return LunaExternalModule.fromJson(profile.toJson());
  }

  factory LunaExternalModule.get(String key) {
    return LunaBox.externalModules.read(key)!;
  }
}
