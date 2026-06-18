/// Kernel shape of TData/TConstr/VData/VConstr: equality, open/close, eval, quote, conv, pretty.
library;

import 'package:doxa/src/env.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/pretty.dart';
import 'package:doxa/src/term.dart';
import 'package:doxa/src/value.dart';
import 'package:test/test.dart';

void main() {
  group('TData structural equality', () {
    test('same name + same args compare equal', () {
      expect(const TData('Nat', <Term>[]), const TData('Nat', <Term>[]));
      expect(const TData('List', [TType(0)]), const TData('List', [TType(0)]));
    });

    test('different name compares unequal', () {
      expect(
        const TData('Nat', <Term>[]),
        isNot(const TData('Bool', <Term>[])),
      );
    });

    test('different args compare unequal', () {
      expect(
        const TData('List', [TType(0)]),
        isNot(const TData('List', [TType(1)])),
      );
    });
  });

  group('TConstr structural equality', () {
    test('same data+ctor+args', () {
      expect(
        const TConstr('Nat', 'zero', <Term>[]),
        const TConstr('Nat', 'zero', <Term>[]),
      );
    });

    test('different ctor', () {
      expect(
        const TConstr('Nat', 'zero', <Term>[]),
        isNot(const TConstr('Nat', 'succ', <Term>[])),
      );
    });
  });

  group('open/close on TData/TConstr', () {
    test('open walks TData args at current depth', () {
      const input = TData('Foo', [TBound(0)]);
      final opened = openTerm(input, 'x');
      expect(opened, const TData('Foo', [TFree('x')]));
    });

    test('close on TData args rebuilds index correctly', () {
      final closed = closeTerm(const TData('Foo', [TFree('x')]), 'x');
      expect(closed, const TData('Foo', [TBound(0)]));
    });

    test('open/close round-trip on TData with multiple args', () {
      const input = TData('Pair', [TBound(0), TBound(1)]);
      final opened = openTerm(input, 'fresh');
      final closed = closeTerm(opened, 'fresh');
      expect(closed, input);
    });

    test('TConstr: same traversal pattern', () {
      const input = TConstr('Nat', 'succ', [TBound(0)]);
      expect(openTerm(input, 'x'), const TConstr('Nat', 'succ', [TFree('x')]));
    });
  });

  group('eval on TData/TConstr', () {
    test('empty-args TData evaluates to empty-args VData', () {
      final v = eval(const TData('Nat', <Term>[]), const ENil());
      expect(v, isA<VData>());
      expect((v as VData).name, 'Nat');
      expect(v.args, isEmpty);
    });

    test('TData args are evaluated', () {
      final v = eval(const TData('List', [TType(0)]), const ENil());
      expect(v, isA<VData>());
      expect((v as VData).args, hasLength(1));
      expect(v.args[0], isA<VType>());
      expect((v.args[0] as VType).level, 0);
    });

    test('TConstr args are evaluated', () {
      final v = eval(
        const TConstr('Nat', 'succ', [TConstr('Nat', 'zero', <Term>[])]),
        const ENil(),
      );
      expect(v, isA<VConstr>());
      expect((v as VConstr).ctorName, 'succ');
      expect(v.args, hasLength(1));
      expect(v.args[0], isA<VConstr>());
      expect((v.args[0] as VConstr).ctorName, 'zero');
    });
  });

  group('quote on VData/VConstr', () {
    test('VData round-trips through quote', () {
      const v = VData('Nat', <Value>[]);
      expect(quote(0, v), const TData('Nat', <Term>[]));
    });

    test('VData with args round-trips', () {
      const v = VData('List', [VType(0)]);
      expect(quote(0, v), const TData('List', [TType(0)]));
    });

    test('VConstr round-trips', () {
      const v = VConstr('Nat', 'succ', [VConstr('Nat', 'zero', <Value>[])]);
      expect(
        quote(0, v),
        const TConstr('Nat', 'succ', [TConstr('Nat', 'zero', <Term>[])]),
      );
    });
  });

  group('conv on VData/VConstr', () {
    test('VData × VData same shape: Ok', () {
      final r = conv(
        0,
        const VData('Nat', <Value>[]),
        const VData('Nat', <Value>[]),
      );
      expect(r, isA<ConvOk>());
    });

    test('VData × VData different name: mismatch', () {
      final r = conv(
        0,
        const VData('Nat', <Value>[]),
        const VData('Bool', <Value>[]),
      );
      expect(r, isA<ConvMismatch>());
    });

    test('VData × VData different args: mismatch', () {
      final r = conv(
        0,
        const VData('List', [VType(0)]),
        const VData('List', [VType(1)]),
      );
      expect(r, isA<ConvMismatch>());
    });

    test('VConstr × VConstr same shape: Ok', () {
      final r = conv(
        0,
        const VConstr('Nat', 'zero', <Value>[]),
        const VConstr('Nat', 'zero', <Value>[]),
      );
      expect(r, isA<ConvOk>());
    });

    test('VConstr × VConstr different ctor: mismatch', () {
      final r = conv(
        0,
        const VConstr('Nat', 'zero', <Value>[]),
        const VConstr('Nat', 'succ', <Value>[]),
      );
      expect(r, isA<ConvMismatch>());
    });

    test('VData vs VConstr: mismatch', () {
      final r = conv(
        0,
        const VData('Nat', <Value>[]),
        const VConstr('Nat', 'zero', <Value>[]),
      );
      expect(r, isA<ConvMismatch>());
    });
  });

  group('pretty-print VData/VConstr', () {
    test('bare TData renders as its name', () {
      expect(prettyTerm(const TData('Nat', <Term>[])), 'Nat');
    });

    test('TData with args', () {
      expect(prettyTerm(const TData('List', [TType(0)])), 'List Type');
    });

    test('TConstr with args', () {
      expect(
        prettyTerm(
          const TConstr('Nat', 'succ', [TConstr('Nat', 'zero', <Term>[])]),
        ),
        'succ zero',
      );
    });
  });

  group('stack safety on deep args', () {
    test('10,000-arg TData evaluates without blowing stack', () {
      final args = List<Term>.generate(10000, (_) => const TType(0));
      final v = eval(TData('Vec', args), const ENil());
      expect(v, isA<VData>());
      expect((v as VData).args, hasLength(10000));
    });
  });
}
