// Where the encrypted store of a tenant lives: a file in the application support directory on
// Android, iOS and desktop; an IndexedDB database through sqlite3mc.wasm on the web.
export 'tenant_store_io.dart' if (dart.library.js_interop) 'tenant_store_web.dart';
