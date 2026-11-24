/// `_shimState` re-evaluates every earlier top-level term while
/// elaborating the next declaration. A stored term containing a bare
/// `Eq.refl` (the elaborator's auto-refl sugar) used to evaluate to a
/// zero-argument `VConstr('Eq', 'refl')`, which crashed the iota
/// reducer when an `Eq.rec` scrutinised it. These tests check that the
/// re-evaluation survives a `div_add_mod` term followed by another
/// declaration.
///
/// The seven declarations below are inlined when `proofs.doxa` does
/// not already define them, so this file runs on a tree without the
/// `div_add_mod` block as well as on a tree with it.
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

/// The seven declarations from the `div_add_mod` increment, inserted
/// verbatim. Used only when `proofs.doxa` predates them.
const _divAddModBlock = '''
val leq_succ_true: (m: Nat) -> (k: Nat) -> Eq Bool (leq m k) false_ -> Eq Bool (leq (succ k) m) true_ =
  (m: Nat) => Nat.ind
    ((j: Nat) => (k: Nat) -> Eq Bool (leq j k) false_ -> Eq Bool (leq (succ k) j) true_)
    ((k: Nat) => (h: Eq Bool (leq zero k) false_) =>
      False.rec ((_: False) => Eq Bool (leq (succ k) zero) true_) (true_ne_false h))
    ((j: Nat) => (ih: (k: Nat) -> Eq Bool (leq j k) false_ -> Eq Bool (leq (succ k) j) true_) =>
      (k: Nat) => Nat.ind
        ((i: Nat) => Eq Bool (leq (succ j) i) false_ -> Eq Bool (leq (succ i) (succ j)) true_)
        ((h: Eq Bool (leq (succ j) zero) false_) => refl)
        ((i: Nat) => (ihi: Eq Bool (leq (succ j) i) false_ -> Eq Bool (leq (succ i) (succ j)) true_) =>
          (h: Eq Bool (leq (succ j) (succ i)) false_) => ih i h)
        k)
    m

val lt_false_leq: (m: Nat) -> (n: Nat) -> Eq Bool (lt m n) false_ -> Eq Bool (leq n m) true_ =
  (m: Nat) => (n: Nat) => (h: Eq Bool (lt m n) false_) => Nat.ind
    ((k: Nat) => Eq Bool (lt m k) false_ -> Eq Bool (leq k m) true_)
    ((h0: Eq Bool (lt m zero) false_) => refl)
    ((k: Nat) => (ih: Eq Bool (lt m k) false_ -> Eq Bool (leq k m) true_) =>
      (h0: Eq Bool (leq m k) false_) => leq_succ_true m k h0)
    n h

val sub_add: (m: Nat) -> (n: Nat) -> Eq Bool (leq n m) true_ -> Eq Nat (plus (sub m n) n) m =
  (m: Nat) => Nat.ind
    ((j: Nat) => (n: Nat) -> Eq Bool (leq n j) true_ -> Eq Nat (plus (sub j n) n) j)
    ((n: Nat) => Nat.ind
      ((i: Nat) => Eq Bool (leq i zero) true_ -> Eq Nat (plus (sub zero i) i) zero)
      ((h: Eq Bool (leq zero zero) true_) => refl)
      ((i: Nat) => (ihi: Eq Bool (leq i zero) true_ -> Eq Nat (plus (sub zero i) i) zero) =>
        (h: Eq Bool (leq (succ i) zero) true_) => False.rec
          ((_: False) => Eq Nat (plus (sub zero (succ i)) (succ i)) zero)
          (true_ne_false (sym_e Bool false_ true_ h)))
      n)
    ((j: Nat) => (ih: (n: Nat) -> Eq Bool (leq n j) true_ -> Eq Nat (plus (sub j n) n) j) =>
      (n: Nat) => Nat.ind
        ((i: Nat) => Eq Bool (leq i (succ j)) true_ -> Eq Nat (plus (sub (succ j) i) i) (succ j))
        ((h: Eq Bool (leq zero (succ j)) true_) =>
          cong_e Nat Nat ((q: Nat) => succ q) (plus j zero) j (plus_zero j))
        ((i: Nat) => (ihi: Eq Bool (leq i (succ j)) true_ -> Eq Nat (plus (sub (succ j) i) i) (succ j)) =>
          (h: Eq Bool (leq (succ i) (succ j)) true_) =>
            trans_e Nat
              (plus (sub (succ j) (succ i)) (succ i))
              (succ (plus (sub j i) i))
              (succ j)
              (plus_succ (sub j i) i)
              (cong_e Nat Nat ((q: Nat) => succ q) (plus (sub j i) i) j (ih i h)))
        n)
    m

fun div_step(d: Nat, j: Nat, m: Nat, b: Bool): Nat = match b {
  case true_ => zero
  case false_ => succ (div_acc j (sub m (succ d)) (succ d))
}

val div_add_mod_step: (d: Nat) -> (j: Nat) -> (m: Nat) -> (b: Bool)
  -> Eq Bool (lt m (succ d)) b
  -> Eq Nat (plus (multiply (div_acc j (sub m (succ d)) (succ d)) (succ d))
                 (mod_acc j (sub m (succ d)) (succ d)))
            (sub m (succ d))
  -> Eq Nat (plus (multiply (div_step d j m b) (succ d)) (mod_step d j m b)) m =
  (d: Nat) => (j: Nat) => (m: Nat) => (b: Bool)
    => (eq: Eq Bool (lt m (succ d)) b)
    => (ih: Eq Nat (plus (multiply (div_acc j (sub m (succ d)) (succ d)) (succ d))
                          (mod_acc j (sub m (succ d)) (succ d)))
                     (sub m (succ d))) =>
      Bool.ind
        ((x: Bool) => Eq Bool (lt m (succ d)) x
          -> Eq Nat (plus (multiply (div_acc j (sub m (succ d)) (succ d)) (succ d))
                          (mod_acc j (sub m (succ d)) (succ d)))
                     (sub m (succ d))
          -> Eq Nat (plus (multiply (div_step d j m x) (succ d)) (mod_step d j m x)) m)
        ((e: Eq Bool (lt m (succ d)) true_) =>
          (g: Eq Nat (plus (multiply (div_acc j (sub m (succ d)) (succ d)) (succ d))
                           (mod_acc j (sub m (succ d)) (succ d)))
                      (sub m (succ d))) => refl)
        ((e: Eq Bool (lt m (succ d)) false_) =>
          (g: Eq Nat (plus (multiply (div_acc j (sub m (succ d)) (succ d)) (succ d))
                           (mod_acc j (sub m (succ d)) (succ d)))
                      (sub m (succ d))) =>
            trans_e Nat
              (plus (plus (succ d) (multiply (div_acc j (sub m (succ d)) (succ d)) (succ d)))
                    (mod_acc j (sub m (succ d)) (succ d)))
              (plus (succ d) (plus (multiply (div_acc j (sub m (succ d)) (succ d)) (succ d))
                                   (mod_acc j (sub m (succ d)) (succ d))))
              m
              (plus_assoc (succ d) (multiply (div_acc j (sub m (succ d)) (succ d)) (succ d))
                          (mod_acc j (sub m (succ d)) (succ d)))
              (trans_e Nat
                (plus (succ d) (plus (multiply (div_acc j (sub m (succ d)) (succ d)) (succ d))
                                     (mod_acc j (sub m (succ d)) (succ d))))
                (plus (succ d) (sub m (succ d)))
                m
                (cong_e Nat Nat ((t: Nat) => plus (succ d) t)
                  (plus (multiply (div_acc j (sub m (succ d)) (succ d)) (succ d))
                        (mod_acc j (sub m (succ d)) (succ d)))
                  (sub m (succ d))
                  g)
                (trans_e Nat
                  (plus (succ d) (sub m (succ d)))
                  (plus (sub m (succ d)) (succ d))
                  m
                  (sym_e Nat (plus (sub m (succ d)) (succ d)) (plus (succ d) (sub m (succ d)))
                    (plus_comm (sub m (succ d)) (succ d)))
                  (sub_add m (succ d) (lt_false_leq m (succ d) e)))))
        b eq ih

val div_add_mod_acc: (d: Nat) -> (k: Nat) -> (m: Nat)
  -> Eq Nat (plus (multiply (div_acc k m (succ d)) (succ d)) (mod_acc k m (succ d))) m =
  (d: Nat) => (k: Nat) => (m: Nat) => Nat.ind
    ((j: Nat) => (m2: Nat) -> Eq Nat (plus (multiply (div_acc j m2 (succ d)) (succ d)) (mod_acc j m2 (succ d))) m2)
    ((m2: Nat) => refl)
    ((j: Nat) => (ih: (m2: Nat) -> Eq Nat (plus (multiply (div_acc j m2 (succ d)) (succ d)) (mod_acc j m2 (succ d))) m2) =>
      (m2: Nat) => div_add_mod_step d j m2 (lt m2 (succ d)) (refl (lt m2 (succ d))) (ih (sub m2 (succ d))))
    k m

val div_add_mod: (m: Nat) -> (n: Nat) -> Lt zero n
  -> Eq Nat (plus (multiply (div m n) n) (mod m n)) m =
  (m: Nat) => (n: Nat) => Nat.ind
    ((k: Nat) => Lt zero k -> Eq Nat (plus (multiply (div m k) k) (mod m k)) m)
    ((h: Lt zero zero) => False.rec
      ((_: False) => Eq Nat (plus (multiply (div m zero) zero) (mod m zero)) m)
      (lt_zero_absurd h))
    ((k: Nat) => (ih: Lt zero k -> Eq Nat (plus (multiply (div m k) k) (mod m k)) m) =>
      (h: Lt zero (succ k)) => div_add_mod_acc k m m)
    n
''';

const _requiredDeclarations = [
  'val leq_succ_true:',
  'val lt_false_leq:',
  'val sub_add:',
  'fun div_step(',
  'val div_add_mod_step:',
  'val div_add_mod_acc:',
  'val div_add_mod:',
];

String _source(String body) {
  final proofs =
      File('../doxa_stdlib/lib/stdlib/proofs.doxa').readAsStringSync();
  final missing = _requiredDeclarations.where((d) => !proofs.contains(d));
  final block = missing.isEmpty ? '' : _divAddModBlock;
  return '''
import "../doxa_stdlib/lib/stdlib/proofs.doxa"
$block
$body
''';
}

void main() {
  group('div_add_mod shim re-evaluation', () {
    test('div_add_mod_acc followed by a declaration checks', () {
      final r = runSource(
        _source('''
val e = div_add_mod_acc zero (succ (succ zero)) (succ (succ zero))
val z: Nat = zero
'''),
      );
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test(
      'the false branch of div_add_mod followed by a declaration checks',
      () {
        final r = runSource(
          _source('''
val e = div_add_mod (succ (succ zero)) (succ (succ zero)) (lt_zero_succ (succ zero))
val z: Nat = zero
'''),
        );
        expect(r.code, 0, reason: 'stderr: ${r.stderr}');
      },
    );

    test('the true branch of div_add_mod followed by a declaration checks', () {
      final r = runSource(
        _source('''
val e = div_add_mod zero (succ zero) (lt_zero_succ zero)
val z: Nat = zero
'''),
      );
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('mod_lt and sub_add followed by a declaration check', () {
      final r = runSource(
        _source('''
val e1 = mod_lt (succ (succ zero)) (succ (succ zero)) (lt_zero_succ (succ zero))
val e2 = sub_add (succ zero) (succ zero) (leq_refl (succ zero))
val z: Nat = zero
'''),
      );
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });
  });
}
