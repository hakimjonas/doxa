/// Tests for `Nat` primality, coprimality, and the gcd fuel bound.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:doxa/src/source.dart';
import 'package:test/test.dart';

import '../bin/doxa.dart' show checkSource;

class _BufferedSink implements IOSink {
  final StringBuffer _buffer = StringBuffer();

  @override
  void write(Object? obj) {
    _buffer.write(obj);
  }

  @override
  void writeln([Object? obj = '']) {
    _buffer.writeln(obj);
  }

  @override
  void writeAll(Iterable<dynamic> objects, [String sep = '']) {
    _buffer.writeAll(objects, sep);
  }

  @override
  void writeCharCode(int charCode) {
    _buffer.writeCharCode(charCode);
  }

  @override
  String toString() => _buffer.toString();
  @override
  Encoding encoding = utf8;
  @override
  void add(List<int> data) {}
  @override
  void addError(Object error, [StackTrace? st]) {}
  @override
  Future<dynamic> addStream(Stream<List<int>> stream) async {}
  @override
  Future<dynamic> close() async {}
  @override
  Future<dynamic> get done => Future.value();
  @override
  Future<dynamic> flush() async {}
}

({int code, String stdout, String stderr}) runSource(
  String src, {
  String filename = 'test.doxa',
}) {
  final source = SourceFile(filename: filename, text: src);
  final outBuf = _BufferedSink();
  final errBuf = _BufferedSink();
  final code = checkSource(source, out: outBuf, err: errBuf);
  return (code: code, stdout: outBuf.toString(), stderr: errBuf.toString());
}

const _preamble = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
val one: Nat = succ zero
val two: Nat = succ (succ zero)
val three: Nat = succ (succ (succ zero))
val four: Nat = succ (succ (succ (succ zero)))
val five: Nat = succ (succ (succ (succ (succ zero))))
val six: Nat = succ (succ (succ (succ (succ (succ zero)))))
val seven: Nat = succ (succ (succ (succ (succ (succ (succ zero))))))
val eight: Nat = succ (succ (succ (succ (succ (succ (succ (succ zero)))))))
val nine: Nat = succ (succ (succ (succ (succ (succ (succ (succ (succ zero))))))))
val eleven: Nat = plus five six
val thirteen: Nat = plus six seven
val fifteen: Nat = multiply three five
''';

void main() {
  group('Nat prime', () {
    test('small primes return true', () {
      final r = runSource('''
$_preamble
val p2: Eq Bool (prime two) true_ = refl true_
val p3: Eq Bool (prime three) true_ = refl true_
val p5: Eq Bool (prime five) true_ = refl true_
val p7: Eq Bool (prime seven) true_ = refl true_
val p11: Eq Bool (prime eleven) true_ = refl true_
val p13: Eq Bool (prime thirteen) true_ = refl true_
''');
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('zero, one, and composites return false', () {
      final r = runSource('''
$_preamble
val p0: Eq Bool (prime zero) false_ = refl false_
val p1: Eq Bool (prime one) false_ = refl false_
val p4: Eq Bool (prime four) false_ = refl false_
val p6: Eq Bool (prime six) false_ = refl false_
val p8: Eq Bool (prime eight) false_ = refl false_
val p9: Eq Bool (prime nine) false_ = refl false_
val p15: Eq Bool (prime fifteen) false_ = refl false_
''');
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });
  });

  group('Nat coprime', () {
    test('zero-zero is not coprime', () {
      final r = runSource('''
$_preamble
val c00: Eq Bool (coprime zero zero) false_ = refl false_
''');
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('gcd one is coprime', () {
      final r = runSource('''
$_preamble
val c01: Eq Bool (coprime zero one) true_ = refl true_
val c10: Eq Bool (coprime one zero) true_ = refl true_
val c11: Eq Bool (coprime one one) true_ = refl true_
val c23: Eq Bool (coprime two three) true_ = refl true_
''');
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('gcd above one is not coprime', () {
      final r = runSource('''
$_preamble
val c24: Eq Bool (coprime two four) false_ = refl false_
val c33: Eq Bool (coprime three three) false_ = refl false_
''');
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });
  });

  group('Nat gcd and lcm', () {
    test('gcd handles a first argument below the second', () {
      final r = runSource('''
$_preamble
val g23: Eq Nat (gcd two three) one = refl one
val g25: Eq Nat (gcd two five) one = refl one
val g64: Eq Nat (gcd six four) two = refl two
val l23: Eq Nat (lcm two three) six = refl six
''');
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });
  });

  group('Nat step-branch congruences', () {
    test('concrete applications check', () {
      final r = runSource('''
import "../doxa_stdlib/lib/stdlib/proofs.doxa"

val one: Nat = succ zero
val two: Nat = succ (succ zero)
val three: Nat = succ (succ (succ zero))
val four: Nat = succ (succ (succ (succ zero)))
val five: Nat = succ (succ (succ (succ (succ zero))))

val mt: Eq Nat (modStep two three four true_) (modStep two five four true_) =
  modStepTrueEq two three five four
val dt: Eq Nat (divStep two three four true_) (divStep two five four true_) =
  divStepTrueEq two three five four
val mf: Eq Nat (modStep two three four false_) (modStep two five four false_) =
  modStepFalseEq two three five four (refl one)
val df: Eq Nat (divStep two three four false_) (divStep two five four false_) =
  divStepFalseEq two three five four (refl zero)
''');
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });
  });

  group('Nat fuel boundary helpers', () {
    test('concrete applications check', () {
      final r = runSource('''
import "../doxa_stdlib/lib/stdlib/proofs.doxa"

val two: Nat = succ (succ zero)
val three: Nat = succ (succ (succ zero))
val four: Nat = succ (succ (succ (succ zero)))
val five: Nat = succ (succ (succ (succ (succ zero))))

val mz: Eq Nat (modAcc three zero two) zero = modAccZeroValue three two
val ls: Eq Nat four four = leqSuccCases four four (refl true_) (refl false_)
val es: Eq Nat five (succ four) = eqSuccOfLeq four five (refl true_) (refl false_)
''');
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });
  });

  group('Nat division unfolding facts', () {
    test('sum order and the first step check', () {
      final r = runSource('''
import "../doxa_stdlib/lib/stdlib/proofs.doxa"

val two: Nat = succ (succ zero)
val four: Nat = succ (succ (succ (succ zero)))

val sa: Eq Nat (sub (four + two) four) two = subAddRight four two
val la: Eq Bool (lt (four + two) four) false_ = ltAddFalse four two
val ls: Eq Bool (succ (four + two) <= four) false_ = leqSuccAddFalse four two
''');
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });
  });

  group('Nat division and divisibility facts', () {
    test('concrete applications check', () {
      final r = runSource('''
import "../doxa_stdlib/lib/stdlib/proofs.doxa"

val one: Nat = succ zero
val two: Nat = succ (succ zero)
val five: Nat = succ (succ (succ (succ (succ zero))))
val six: Nat = succ (succ (succ (succ (succ (succ zero)))))

val ss: Eq Nat (sub six six) zero = subSelf six
val lf: Eq Bool (lt six six) false_ = ltSelfFalse six
val zq: Eq Nat (sub six six) zero = leqZeroEq (sub six six) (refl true_)
val ms: Eq Nat (mod six six) zero = modSelf six (ltZeroSucc five)
val ds: Eq Nat (div six six) (succ zero) = divSelf six (ltZeroSucc five)
val d2m: Eq Nat (mod six two) zero = dividesToMod one six (refl true_)
val m2d: Eq Bool (divides two six) true_ = modToDivides one six (refl zero)
val dl: Eq Bool (two <= six) true_ = dividesLe one six (ltZeroSucc five) (refl true_)
''');
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });
  });
}
