import 'dart:convert';
import 'dart:io';

const _replacements = [
  (from: r'..\lib\', to: r'.\lib\\'),
  (from: '../lib/', to: './lib//'),
];

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: dart tool/patch_native_asset_paths.dart <executable>...',
    );
    exitCode = 64;
    return;
  }

  var hadError = false;
  for (final arg in args) {
    final file = File(arg);
    if (!file.existsSync()) {
      stderr.writeln('Missing executable: $arg');
      hadError = true;
      continue;
    }

    final bytes = file.readAsBytesSync();
    var count = 0;

    for (final replacement in _replacements) {
      final from = ascii.encode(replacement.from);
      final to = ascii.encode(replacement.to);
      count += _replaceAll(bytes, from, to);
    }

    if (count > 0) {
      file.writeAsBytesSync(bytes, flush: true);
    }

    stdout.writeln('Patched $count native asset path(s) in ${file.path}');
  }

  if (hadError) {
    exitCode = 1;
  }
}

int _replaceAll(List<int> bytes, List<int> from, List<int> to) {
  if (from.length != to.length) {
    throw ArgumentError('Replacement must keep the same byte length.');
  }

  var count = 0;
  for (var i = 0; i <= bytes.length - from.length; i++) {
    var matches = true;
    for (var j = 0; j < from.length; j++) {
      if (bytes[i + j] != from[j]) {
        matches = false;
        break;
      }
    }

    if (!matches) continue;

    for (var j = 0; j < to.length; j++) {
      bytes[i + j] = to[j];
    }
    count++;
    i += from.length - 1;
  }

  return count;
}
