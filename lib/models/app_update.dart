class AppUpdate {
  const AppUpdate({
    required this.version,
    required this.buildNumber,
    required this.apkKey,
    required this.publishedAt,
    required this.releaseNotes,
  });

  final String version;
  final int buildNumber;
  final String apkKey;
  final DateTime publishedAt;
  final String releaseNotes;

  Map<String, dynamic> toJson() => {
    'version': version,
    'buildNumber': buildNumber,
    'apkKey': apkKey,
    'publishedAt': publishedAt.toUtc().toIso8601String(),
    'releaseNotes': releaseNotes,
  };

  factory AppUpdate.fromJson(Map<String, dynamic> json) => AppUpdate(
    version: json['version'] as String,
    buildNumber: (json['buildNumber'] as num).toInt(),
    apkKey: json['apkKey'] as String,
    publishedAt: DateTime.parse(json['publishedAt'] as String).toLocal(),
    releaseNotes: json['releaseNotes'] as String? ?? '',
  );
}
