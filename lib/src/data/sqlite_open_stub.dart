import 'package:sqlite3/common.dart';

CommonDatabase openNativeDatabase(String path) =>
    throw UnsupportedError('Native SQLite is not available on this platform');
