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
        check,
        closeValueOverCtx,
        closeTermOverCtx;
export 'src/check.dart';
export 'src/elab.dart'
    show
        elabDecl,
        elabExpr,
        elabExprWithType,
        elabExprInScope,
        elabCheckInCtx,
        elabInferInCtx,
        checkDeclResult,
        declNames,
        ctorSignatureTerm,
        ClassInfo,
        ImportState,
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
        UnannotatedDeclIndeterminate,
        UnknownCtorInMatch,
        CtorMismatchInMatch,
        MatchArmArityMismatch,
        DuplicateMatchCase,
        NonExhaustiveMatch,
        CyclicImport,
        ImportFileNotFound,
        ImportPackageNotFound,
        StructAnnotationNotFound,
        DecreasesBadParams,
        DecreasesWithStruct,
        DecreasesInMutualBlock,
        DecreasesNonRecursive,
        DecreasesNotDecreasing,
        QuotientNeedsExpectedType,
        TypeclassUnsupported,
        SuperclassUnsupported,
        UnknownTypeclass,
        TypeclassArityMismatch,
        MissingInstanceMethod,
        UnknownInstanceMethod,
        UnsupportedInstanceTarget,
        TacticFailed,
        TacticIncomplete,
        NoInstanceFound,
        OverlappingInstances,
        InstanceSearchDepthExceeded,
        SPropFieldNotProofIrrelevant;
export 'src/parse.dart';
export 'src/surface.dart';
export 'src/pretty.dart';
export 'src/proof_state.dart';
export 'src/report.dart';
export 'src/source.dart';
export 'src/sem_info.dart';
export 'src/prelude.dart';
export 'src/tactic.dart' hide conv;
export 'src/import_resolver.dart' show ImportResolver;
