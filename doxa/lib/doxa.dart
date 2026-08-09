/// Doxa kernel: a dependently typed proof checker for the Calculus of
/// Inductive Constructions.
///
/// See `SPEC.md` for the design.
library;

export 'src/term.dart';
export 'src/value.dart';
export 'src/env.dart';
export 'src/ctx.dart';
export 'src/meta.dart';
export 'src/registry.dart';
export 'src/eval.dart'
    show
        eval,
        apply,
        quote,
        nf,
        conv,
        ConvResult,
        ConvOk,
        ConvMismatch,
        infer,
        check;
export 'src/check.dart';
export 'src/elab.dart'
    show
        elabDecl,
        elabExpr,
        elabExprInScope,
        checkDeclResult,
        declNames,
        ClassInfo,
        currentImportPath,
        importedPaths,
        TopBinding,
        TopEnv,
        CorecursiveGroup,
        mergeNamespace,
        ElabError,
        UnresolvedName,
        DuplicateDeclaration,
        NonStructuralRecursion,
        LambdaRequiresAnnotation,
        DataSortNotASort,
        MutualHeaderCycle,
        CtorResultShapeMismatch,
        PositivityViolation,
        MatchIndeterminateType,
        UnknownCtorInMatch,
        CtorMismatchInMatch,
        MatchArmArityMismatch,
        DuplicateMatchCase,
        NonExhaustiveMatch,
        CyclicImport,
        ImportFileNotFound,
        StructAnnotationNotFound,
        TerminationByParamNotFound,
        TacticFailed,
        TacticIncomplete,
        NoInstanceFound,
        OverlappingInstances,
        SPropFieldNotProofIrrelevant;
export 'src/parse.dart';
export 'src/surface.dart';
export 'src/pretty.dart';
export 'src/report.dart';
export 'src/source.dart';
export 'src/sem_info.dart';
export 'src/prelude.dart';
export 'src/tactic.dart' hide conv;
