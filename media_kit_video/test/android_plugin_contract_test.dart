import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

File _packageFile(String relativePath) {
  final workspacePackage = File('media_kit_video/$relativePath');
  if (workspacePackage.existsSync()) {
    return workspacePackage;
  }
  return File(relativePath);
}

void main() {
  test('declares the Android Flutter plugin without dropping other platforms',
      () {
    final pubspec = loadYaml(_packageFile('pubspec.yaml').readAsStringSync())
        as YamlMap;
    final flutter = pubspec['flutter'] as YamlMap;
    final plugin = flutter['plugin'] as YamlMap;
    final platforms = plugin['platforms'] as YamlMap;

    expect(
      platforms.keys.toSet(),
      containsAll(<String>{'windows', 'linux', 'macos', 'ios', 'web'}),
    );
    expect(
      platforms['android'],
      isNotNull,
      reason: 'Android Java sources require an explicit Flutter plugin stanza.',
    );
    expect(
      platforms['android'],
      equals(<String, String>{
        'package': 'com.alexmercerind.media_kit_video',
        'pluginClass': 'MediaKitVideoPlugin',
      }),
    );
  });

  test('declares the Android minimum required by the Atlas dependency graph',
      () {
    final androidBuild =
        _packageFile('android/build.gradle').readAsStringSync();
    final minSdk = RegExp(r'\bminSdkVersion\s+(\d+)\b')
        .firstMatch(androidBuild);

    expect(minSdk, isNotNull, reason: 'Android minSdkVersion must be explicit.');
    expect(
      int.parse(minSdk!.group(1)!),
      21,
      reason: 'Atlas locks wakelock_plus 1.4.0, whose Android minimum is 21.',
    );
  });
}
