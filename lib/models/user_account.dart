class UserAccount {
  UserAccount({
    required this.email,
    required this.displayName,
    required this.passwordHash,
    required this.salt,
    required this.createdAt,
    this.avatarKey,
    this.bannerKey,
  });

  final String email;
  final String displayName;
  final String passwordHash;
  final String salt;
  final DateTime createdAt;

  /// Ключ объекта аватарки в Yandex Object Storage (avatars/<email>.<ext>),
  /// либо null, если аватарка не задана.
  final String? avatarKey;

  /// Ключ объекта баннера профиля (banners/<email>.<ext>), либо null.
  final String? bannerKey;

  UserAccount copyWith({
    String? displayName,
    String? passwordHash,
    String? salt,
    String? avatarKey,
    String? bannerKey,
  }) =>
      UserAccount(
        email: email,
        displayName: displayName ?? this.displayName,
        passwordHash: passwordHash ?? this.passwordHash,
        salt: salt ?? this.salt,
        createdAt: createdAt,
        avatarKey: avatarKey ?? this.avatarKey,
        bannerKey: bannerKey ?? this.bannerKey,
      );

  Map<String, dynamic> toJson() => {
        'email': email,
        'displayName': displayName,
        'passwordHash': passwordHash,
        'salt': salt,
        'createdAt': createdAt.toIso8601String(),
        'avatarKey': avatarKey,
        'bannerKey': bannerKey,
      };

  factory UserAccount.fromJson(Map<String, dynamic> json) => UserAccount(
        email: json['email'] as String,
        displayName: json['displayName'] as String? ?? '',
        passwordHash: json['passwordHash'] as String,
        salt: json['salt'] as String,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.now(),
        avatarKey: json['avatarKey'] as String?,
        bannerKey: json['bannerKey'] as String?,
      );

  /// Копия без чувствительных полей — то, что можно спокойно хранить
  /// локально на устройстве для восстановления сессии.
  Map<String, dynamic> toPublicJson() => {
        'email': email,
        'displayName': displayName,
        'createdAt': createdAt.toIso8601String(),
        'avatarKey': avatarKey,
        'bannerKey': bannerKey,
      };
}
