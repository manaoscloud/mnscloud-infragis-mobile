class RuntimeReleaseInfo {
  const RuntimeReleaseInfo({this.version, this.buildRef, this.minimumVersion});

  final String? version;
  final String? buildRef;

  /// Releases below this version must update (critical fix); null when unset.
  final String? minimumVersion;
}

String normalizeVersion(String? value) =>
    (value ?? '').trim().replaceFirst(RegExp('^v', caseSensitive: false), '');

bool isReleaseVersion(String value) =>
    RegExp(r'^\d+\.\d+\.\d+([-+][0-9A-Za-z.-]+)?$').hasMatch(value);

/// Compares the numeric `major.minor.patch` part; suffixes are ignored.
int compareSemver(String left, String right) {
  List<int> parts(String value) {
    final core = normalizeVersion(
      value,
    ).split(RegExp(r'[+-]')).first.split('.');
    return List<int>.generate(
      3,
      (index) => index < core.length ? int.tryParse(core[index]) ?? 0 : 0,
    );
  }

  final a = parts(left);
  final b = parts(right);
  for (var index = 0; index < 3; index += 1) {
    final diff = a[index] - b[index];
    if (diff != 0) return diff;
  }
  return 0;
}
