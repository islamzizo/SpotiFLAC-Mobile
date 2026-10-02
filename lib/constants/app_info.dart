import 'package:flutter/foundation.dart';

class AppInfo {
  static const String version = '5.0.8';
  static const String buildNumber = '157';

  static const String gitCommit = String.fromEnvironment('GIT_COMMIT');
  static String get shortGitCommit =>
      gitCommit.length > 8 ? gitCommit.substring(0, 8) : gitCommit;

  static String get displayVersion => kDebugMode ? 'Internal' : version;

  static const String appName = 'SpotiFLAC Mobile';
  static const String copyright = '© 2026 Zarz Eleutherius';

  static const String mobileAuthor = 'zarzet';
  static const String originalAuthor = 'afkarxyz';

  static const String githubRepo = 'spotiflacapp/SpotiFLAC-Mobile';
  static const String githubUrl = 'https://github.com/$githubRepo';
  static const String originalGithubUrl =
      'https://github.com/afkarxyz/SpotiFLAC';
  static const String remoteConfigApiUrl =
      'https://api.zarz.moe/v1/spotiflac-mobile/config';

  static const String kofiUrl = 'https://ko-fi.com/zarzet';
  static const String githubSponsorsUrl = 'https://github.com/sponsors/zarzet/';
}
