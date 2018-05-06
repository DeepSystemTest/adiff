{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE MultiWayIf            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE UndecidableInstances  #-}

-- | Implements the core instrumentation functions.
module VDiff.Instrumentation
 (
   -- * Handling C files
  openCFile
 , prettyp
 , maskAsserts
 , defineAssert
 , Direction(..)
 , MonadBrowser
 , BrowserT
 , runBrowserT
 , insertBefore
 , buildTranslationUnit
 , tryout
 , go
 , gotoPosition
 , gotoFunction
 , currentReads
 , currentStmt
 , currentPosition
 , findCalledFunction
 , go_
 , AstPosition
 -- * Internals
 , insertBeforeNthStatement
 , markAllReads
 -- * Other
 , VarRead(..), position, varType, identifier
 , findAllReads
 ) where

import           RIO
import           RIO.FilePath
import           Safe

import           Control.Lens.Operators            hiding ((^.))
import           Control.Monad.Writer              hiding ((<>))
import qualified Data.DList                        as DL
import           Data.Functor.Identity
import           Data.Generics.Uniplate.Data       ()
import           Data.Generics.Uniplate.Operations
import           Data.List                         (isPrefixOf)
import qualified Data.List.Index                   as IL
import           Data.Text                         (pack)
import           Language.C.Analysis.TravMonad
import           Language.C.Analysis.TypeUtils
import           Language.C.Data.Lens
import           Language.C.System.GCC
import           Text.PrettyPrint                  (render)
import           UnliftIO.Directory

import           VDiff.Instrumentation.Browser
import qualified VDiff.Instrumentation.Fragments   as Fragments
import           VDiff.Instrumentation.Reads
import           VDiff.Types


instance Display Stmt where
  display = display . pack . prettyp

prettyp :: Pretty a => a -> String
prettyp = render . pretty

-- | short-hand for open, parse and type annotate, will log parse and type checking errors and warnings.
openCFile :: HasLogFunc env => FilePath -> RIO env (Maybe (TU))
openCFile fn = do
  -- we need GCC to remove preprocessor tokens and comments,
  -- unfortunately, GCC only works on files with .c ending. Hence this hack.
  let templateName = takeFileName $ replaceExtension fn ".c"
  withSystemTempFile  templateName $  \fnC _ ->  do
    copyFile fn fnC
    x <- liftIO $ parseCFile (newGCC "gcc") Nothing [] fnC
    case x of
      Left parseError -> do
        logError $ "parse error: " <> displayShow parseError
        return Nothing
      Right tu -> case runTrav_ (analyseAST tu) of
          Left typeError -> do
            logError $ "type error: " <> displayShow typeError
            return Nothing
          Right (tu', warnings) -> do
            unless (null warnings) $ logWarn $ "warnings: " <> displayShow warnings
            return (Just tu')

--------------------------------------------------------------------------------

findCalledFunction :: (MonadBrowser m) => m (Maybe String)
findCalledFunction = do
  stmt <- currentStmt
  let subExprs = universeBi stmt :: [CExpression SemPhase]
  let fns = [ n
            | CCall (CVar i _) _ _ <- subExprs
            , let n = identToString i
            , not ("__" `isPrefixOf` n)
            ]
  return $ headMay fns



--------------------------------------------------------------------------------
-- | * Masking
--------------------------------------------------------------------------------

-- TODO: Also mask original calls to __VERIFIER_error()
maskAsserts :: TU -> TU
maskAsserts = insertDummy . transformBi rename
  where
    insertDummy = insertExtDeclAt 0 (CFDefExt Fragments.dummyAssert)
    rename :: Ident -> Ident
    rename s = case identToString s of
                 "__VERIFIER_assert"  -> (internalIdent "__DUMMY_VERIFIER_assert")
                 _ -> s


-- | Some test cases only use @__VERIFIER_error()@, in those cases we have to define @__VERIFIER_assert()@
-- It's important to insert the definition /after/ the external declaration of @__VERIFIER_error()@.
defineAssert :: TU -> TU
defineAssert tu = case tu ^? (ix "__VERIFIER_assert") of
                    Just _  -> tu
                    Nothing ->
                      let (Just p) = indexOfDeclaration "__VERIFIER_error" tu
                      in insertExtDeclAt (p+1) (CFDefExt Fragments.assertDefinition) tu

insertExtDeclAt  :: Int -> CExternalDeclaration p -> CTranslationUnit p -> CTranslationUnit p
insertExtDeclAt  n d (CTranslUnit exts ann) = CTranslUnit (IL.insertAt n d exts) ann

-- | returns the index of the declaration that declares the given name.
indexOfDeclaration :: String -> TU -> Maybe Int
indexOfDeclaration name (CTranslUnit exts _) = IL.ifindIndex flt exts
  where flt _ d =
          let idents = map identToString $ universeBi d
          in  name `elem` idents

