/// Minimal WasmGC entry for measuring Doxa's browser payload and, later,
/// driving the browser demo. Exposes a single `doxaCheck(source)` that runs
/// the full parse -> elaborate -> check pipeline and returns a JSON string.
///
/// This is deliberately self-contained (the pure pipeline driver inlines the
/// prelude) so the whole kernel is reachable from `main` and survives
/// tree-shaking, an entry that only touched the parser would undercount the
/// real payload.
///
/// The structured-output logic lives in `lib/src/web_check.dart`
/// (`checkSourceJson`) so it can be exercised by a native Dart harness
/// without a browser/Node runtime.
///
/// Build: `dart compile wasm web/doxa_check.dart -o web/doxa_check.wasm`
library;

import 'dart:js_interop';

import 'package:doxa/src/web_check.dart';

/// Run the full checker on the JS-supplied source; return a JSON result.
@JS('doxaCheck')
external set _doxaCheck(JSFunction f);

void main() {
  _doxaCheck = ((JSString src) => checkSourceJson(src.toDart).toJS).toJS;
}
