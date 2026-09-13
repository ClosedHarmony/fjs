// Merges partial local precompiled generation fragments produced on different
// CI runners into a single generation directory consumable by
// `finalize-local-generation` / `publish-precompiled-generation`.
//
// Each fragment directory must be the output of one
// `build-precompiled-generation` invocation: a `local-generation.json` file
// plus the asset files it declares. All fragments must share the same
// generation hash and build recipe. Asset contents are re-verified against
// the fragment metadata (length + sha256) while merging.
//
// Usage:
//   dart run tool/merge_generations.dart --output-dir <dir> <fragmentDir>...
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

const String fragmentFileName = 'local-generation.json';
const String fragmentScope = 'cargokit-local-precompiled-generation';

void main(List<String> args) {
  String? outputDir;
  final fragmentDirs = <String>[];
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--output-dir') {
      if (i + 1 >= args.length) {
        _fail('--output-dir requires a value.');
      }
      outputDir = args[++i];
    } else {
      fragmentDirs.add(args[i]);
    }
  }
  if (outputDir == null || fragmentDirs.length < 2) {
    stderr.writeln(
      'usage: dart run tool/merge_generations.dart '
      '--output-dir <dir> <fragmentDir> <fragmentDir>...',
    );
    exit(2);
  }

  final merged = <String, Map<String, Object>>{};
  final sourceDirs = <String, String>{};
  String? generationHash;
  String? recipeJson;

  for (final dir in fragmentDirs) {
    final fragmentFile = File(pathFromPosix(dir, fragmentFileName));
    if (!fragmentFile.existsSync()) {
      _fail('Fragment not found: ${fragmentFile.path}');
    }
    final fragment = _parseFragment(fragmentFile.readAsStringSync(), dir);
    final hash = fragment['generation_hash'] as String;
    final recipe = jsonEncode(_canonicalize(fragment['recipe']));
    if (generationHash == null) {
      generationHash = hash;
      recipeJson = recipe;
    } else {
      if (hash != generationHash) {
        _fail('Fragment $dir has generation hash $hash, expected '
            '$generationHash. All fragments must come from the same inputs.');
      }
      if (recipe != recipeJson) {
        _fail('Fragment $dir has a different build recipe.');
      }
    }

    for (final assetValue in fragment['assets'] as List<dynamic>) {
      final asset = (assetValue as Map<String, dynamic>).cast<String, Object>();
      final name = asset['name'] as String;
      final length = asset['length'] as int;
      final sha = asset['sha256'] as String;
      final relativePath = asset['path'] as String;
      final previous = merged[name];
      if (previous != null) {
        if (previous['sha256'] != sha ||
            previous['length'] != length ||
            previous['path'] != relativePath) {
          _fail('Conflicting definitions for asset "$name".');
        }
        continue;
      }
      final source = File(pathFromPosix(dir, relativePath));
      if (!source.existsSync()) {
        _fail('Asset "$name" is missing from fragment $dir '
            '(expected at ${source.path}).');
      }
      final bytes = source.readAsBytesSync();
      if (bytes.length != length) {
        _fail('Asset "$name" has length ${bytes.length}, expected $length.');
      }
      final actualSha = sha256.convert(bytes).toString();
      if (actualSha != sha) {
        _fail('Asset "$name" has sha256 $actualSha, expected $sha.');
      }
      merged[name] = asset;
      sourceDirs[name] = dir;
    }
  }

  final output = Directory(outputDir);
  if (output.existsSync()) {
    _fail('Output directory already exists: $outputDir');
  }
  final assets = merged.values.toList()
    ..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
  for (final asset in assets) {
    final name = asset['name'] as String;
    final destination = File(pathFromPosix(outputDir, asset['path'] as String));
    destination.parent.createSync(recursive: true);
    File(pathFromPosix(sourceDirs[name]!, asset['path'] as String))
        .copySync(destination.path);
  }

  final fragment = <String, Object>{
    'schema_version': 1,
    'scope': fragmentScope,
    'generation_hash': generationHash!,
    'recipe': jsonDecode(recipeJson!),
    'assets': [
      for (final asset in assets)
        {
          'name': asset['name'],
          'length': asset['length'],
          'sha256': asset['sha256'],
          'path': asset['path'],
        },
    ],
  };
  File(pathFromPosix(outputDir, fragmentFileName))
      .writeAsStringSync('${jsonEncode(fragment)}\n', flush: true);

  stdout.writeln(
    'Merged ${fragmentDirs.length} fragments into $outputDir: '
    '${assets.length} assets, generation $generationHash',
  );
}

String pathFromPosix(String root, String posixRelative) {
  return '$root${Platform.pathSeparator}'
      '${posixRelative.replaceAll('/', Platform.pathSeparator)}';
}

Map<String, dynamic> _parseFragment(String contents, String dir) {
  final dynamic value = jsonDecode(contents);
  if (value is! Map<String, dynamic> ||
      value['schema_version'] != 1 ||
      value['scope'] != fragmentScope ||
      value['generation_hash'] is! String ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(value['generation_hash'] as String) ||
      value['recipe'] == null ||
      value['assets'] is! List ||
      (value['assets'] as List).isEmpty) {
    _fail('Malformed fragment in $dir.');
  }
  return value;
}

Object? _canonicalize(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return {
      for (final key in keys) key: _canonicalize(value[key]),
    };
  }
  if (value is List) {
    return [for (final item in value) _canonicalize(item)];
  }
  return value;
}

Never _fail(String message) {
  stderr.writeln('error: $message');
  exit(1);
}
