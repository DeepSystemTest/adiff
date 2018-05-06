module VDiff.Instrumentation.Fragments where

import RIO
import VDiff.Types
import Language.C.Analysis.TypeUtils

mkReadMarker ::  [(Ident,Type)] -> Stmt
mkReadMarker vars =
  let fun = CVar (builtinIdent "__VERIFIER_read") (undefNode,voidType)
      expressions = map (\(i,ty) -> CVar i (undefNode, ty)) vars
  in CExpr (Just $ CCall fun expressions  (undefNode,voidType)) (undefNode,voidType)

-- | This is a function definition defining the function __dummy__verifier_assert that does nothing
-- | (Existing asserts will be disabled by renaming things to this function's name)
-- | NOTE: (to myself) a quasi-quoter would be really nice, or at least some exported sub-parsers.
dummyAssert :: CFunctionDef SemPhase
dummyAssert = CFunDef specs decl [] body' undefNode
  where specs = [CTypeSpec (CVoidType undefNode)]
        decl = CDeclr  (Just $ internalIdent "__DUMMY_VERIFIER_assert" ) derived Nothing [] undefNode
        derived = [CFunDeclr (Right ([param], False)) [] undefNode]
        param = CDecl [CTypeSpec $ CIntType undefNode] [(Just paramDecl, Nothing, Nothing)]  undefNode
        paramDecl = CDeclr (Just $ internalIdent "condition") [] Nothing [] undefNode :: CDeclarator SemPhase
        body' = CCompound [] [] (undefNode, voidType)



assertDefinition :: CFunctionDef SemPhase
assertDefinition = CFunDef specs decl [] body' undefNode
  where specs     = [CTypeSpec (CVoidType undefNode)]
        decl      = CDeclr  (Just $ internalIdent "__VERIFIER_assert" ) derived Nothing [] undefNode
        derived   = [CFunDeclr (Right ([param], False)) [] undefNode]
        param     = CDecl [CTypeSpec $ CIntType undefNode] [(Just paramDecl, Nothing, Nothing)]  undefNode
        paramDecl = CDeclr (Just $ internalIdent "cond") [] Nothing [] undefNode :: CDeclarator SemPhase
        body'     = CCompound [] [CBlockStmt ifStmt] (undefNode, voidType)
        ifStmt    = CIf notCond errorStmt Nothing (undefNode, voidType)
        notCond   = CUnary CNegOp (CVar (internalIdent "cond") (undefNode, intType)) (undefNode, intType)
        errorStmt = CLabel (builtinIdent "ERROR")  callError [] (undefNode, voidType)
        callError = CExpr (Just (CCall (CVar (builtinIdent "__VERIFIER_ERROR") (undefNode,voidType)) [] (undefNode, voidType))) (undefNode,voidType)
        intType   = voidType -- not correct, but doesn't matter
