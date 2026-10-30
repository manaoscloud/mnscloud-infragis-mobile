// Native SQLite (dart:ffi) is not available on the web, where the store opens through
// tenant_store_web.dart instead.
export 'sqlite_open_stub.dart' if (dart.library.ffi) 'sqlite_open_io.dart';
