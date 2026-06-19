import 'package:doxa/src/elab.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/term.dart';
import 'package:doxa/src/value.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

SProgram _pp(String src) {
  final r = parseProgram(src);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  fail('parse failed: $r');
}

void main() {
  group('opaque val', () {
    test('opaque x conv x is ConvOk (name identity)', () {
      final topEnv = elabProgram(_pp('opaque val x = Type'));
      final ctx = topEnv.toCtx();
      final v1 = eval(const TTop('x'), ctx.env);
      final v2 = eval(const TTop('x'), ctx.env);
      expect(conv(0, v1, v2), isA<ConvOk>());
    });

    test('opaque x does NOT unfold when compared to its body', () {
      final topEnv = elabProgram(_pp('opaque val x = Type'));
      final ctx = topEnv.toCtx();
      final vOpaque = eval(const TTop('x'), ctx.env);
      final vBody = eval(const TType(LLevel(0)), ctx.env);
      expect(conv(0, vOpaque, vBody), isA<ConvMismatch>());
    });

    test('transparent val unfolds normally', () {
      final topEnv = elabProgram(_pp('val y = Type'));
      final ctx = topEnv.toCtx();
      final vRef = eval(const TTop('y'), ctx.env);
      final vBody = eval(const TType(LLevel(0)), ctx.env);
      expect(conv(0, vRef, vBody), isA<ConvOk>());
    });

    test('infer opaque val yields its type, not a neutral', () {
      final topEnv = elabProgram(_pp('opaque val x: Type 1 = Type'));
      final ctx = topEnv.toCtx();
      final t = infer(ctx, const TTop('x'));
      expect(t, isA<VType>());
      expect((t as VType).level, const LLevel(1));
    });
  });

  group('opaque fun', () {
    test('opaque fun applied stays stuck as NApp(NTop(...), ...)', () {
      final topEnv = elabProgram(_pp('opaque fun id[A: Type](x: A): A = x'));
      final ctx = topEnv.toCtx();
      final v = eval(const TTop('id'), ctx.env);
      final applied = apply(v, const VType(LLevel(0)));
      expect(applied, isA<VNeutral>());
      final neutral = applied as VNeutral;
      expect(neutral.neutral, isA<NApp>());
      final app = neutral.neutral as NApp;
      expect(app.fn, isA<NTop>());
      expect((app.fn as NTop).name, 'id');
      expect(app.arg, const VType(LLevel(0)));
    });
  });
}
